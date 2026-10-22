import AVFoundation

/// 유튜브 영상·소리 파일을 맥 플레이어가 빨리 열 수 있게 HLS 재생목록으로 바꿔 줌
///
/// 왜: 유튜브 파일(조각난 mp4)을 맥 플레이어에 그대로 주면 길이를 알려고 파일 전체를 훑어서
/// 첫 화면까지 10~40초가 걸리고, 길이도 2배로 잘못 읽음.
/// 파일 앞부분의 색인(sidx, 몇 KB)만 직접 읽어 "몇 번째 바이트부터 몇 초짜리 조각" 목록(HLS)을 만들어 주면
/// 첫 화면이 0.3초 안팎에 나오고 길이도 정확함.
/// 재생목록은 앱이 직접 답하는 주소(mytubehls://)로 넘기고, 조각은 맥 플레이어가 유튜브에서 바로 받음.
final class LocalHLS: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = LocalHLS()

    enum Failure: LocalizedError {
        case noIndex
        var errorDescription: String? { "영상 파일에 색인(sidx)이 없어요." }
    }

    /// 파일 색인: 앞부분(ftyp+moov) 길이와 조각들 (시작 바이트, 길이, 초)
    struct Index {
        let initLength: Int
        let segments: [(offset: Int, length: Int, seconds: Double)]
    }

    private let lock = NSLock()
    private var playlists: [String: Data] = [:]   // "키/이름.m3u8" → 내용
    private var indexes: [URL: Index] = [:]        // 파일 주소 → 색인 (같은 주소는 다시 안 읽음)
    private let queue = DispatchQueue(label: "MyTube.LocalHLS")

    /// 영상(+소리) 재생 항목. 소리가 없으면 영상만 (미리 보기용)
    func item(video: URL, codec: String, width: Int, height: Int, audio: URL?) async throws -> AVPlayerItem {
        async let videoIndex = index(of: video)
        async let audioIndex: Index? = { if let audio { try await index(of: audio) } else { nil } }()
        let (v, a) = try await (videoIndex, audioIndex)

        let key = UUID().uuidString
        var master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        var codecs = codec
        var audioAttr = ""
        if let audio, let a {
            store("\(key)/a.m3u8", Self.mediaPlaylist(audio, a))
            master += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"main\",DEFAULT=YES,AUTOSELECT=YES,URI=\"a.m3u8\"\n"
            codecs += ",mp4a.40.2"
            audioAttr = ",AUDIO=\"aud\""
        }
        store("\(key)/v.m3u8", Self.mediaPlaylist(video, v))
        master += "#EXT-X-STREAM-INF:BANDWIDTH=20000000,CODECS=\"\(codecs)\",RESOLUTION=\(width)x\(height)\(audioAttr)\nv.m3u8\n"
        store("\(key)/m.m3u8", master)

        let asset = AVURLAsset(url: URL(string: "mytubehls://\(key)/m.m3u8")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return AVPlayerItem(asset: asset)
    }

    /// 소리만 (듣기 모드): 소리 파일 하나의 재생목록을 바로 넘김
    func audioItem(audio: URL) async throws -> AVPlayerItem {
        let index = try await index(of: audio)
        let key = UUID().uuidString
        store("\(key)/a.m3u8", Self.mediaPlaylist(audio, index))
        let asset = AVURLAsset(url: URL(string: "mytubehls://\(key)/a.m3u8")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return AVPlayerItem(asset: asset)
    }

    /// 색인만 미리 읽어 둠 (목록에서 마우스를 올렸을 때)
    func prefetch(_ urls: [URL]) {
        for url in urls { Task { _ = try? await index(of: url) } }
    }

    // MARK: 색인 읽기

    private func index(of url: URL) async throws -> Index {
        if let cached = lock.withLock({ indexes[url] }) { return cached }
        var length = 65_536
        while true {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
            let (data, _) = try await URLSession.shared.data(for: request)
            switch Self.parse(data) {
            case .found(let index):
                lock.withLock {
                    if indexes.count > 40 { indexes.removeAll() }
                    indexes[url] = index
                }
                return index
            case .needMore(let total) where total > length && total < 4_000_000:
                length = total   // 색인이 길면 그만큼 다시
            default:
                throw Failure.noIndex
            }
        }
    }

    private enum Parsed { case found(Index), needMore(Int), none }

    private static func parse(_ d: Data) -> Parsed {
        let bytes = [UInt8](d)
        func be(_ i: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 << 8 | Int(bytes[i + $1]) } }
        var i = 0, initLength = 0
        while i + 8 <= bytes.count {
            let size = be(i, 4)
            let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
            guard size >= 8 else { return .none }
            if type == "moov" { initLength = i + size }
            if type == "sidx" {
                guard i + size <= bytes.count else { return .needMore(i + size) }
                let version = be(i + 8, 1)
                var p = i + 16                      // 크기·종류·판·플래그·reference_ID 건너뜀
                let timescale = Double(be(p, 4)); p += 4
                let first: Int
                if version == 0 { p += 4; first = be(p, 4); p += 4 } else { p += 8; first = be(p, 8); p += 8 }
                p += 2
                let count = be(p, 2); p += 2
                guard timescale > 0, initLength > 0 else { return .none }
                var offset = i + size + first
                var segments: [(offset: Int, length: Int, seconds: Double)] = []
                for _ in 0..<count {
                    let length = be(p, 4) & 0x7fff_ffff
                    segments.append((offset, length, Double(be(p + 4, 4)) / timescale))
                    offset += length
                    p += 12
                }
                return segments.isEmpty ? .none : .found(Index(initLength: initLength, segments: segments))
            }
            i += size
        }
        return .none
    }

    private static func mediaPlaylist(_ url: URL, _ index: Index) -> String {
        let u = url.absoluteString
        let target = Int((index.segments.map(\.seconds).max() ?? 10).rounded(.up))
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-TARGETDURATION:\(target)\n"
        s += "#EXT-X-MAP:URI=\"\(u)\",BYTERANGE=\"\(index.initLength)@0\"\n"
        for seg in index.segments {
            s += String(format: "#EXTINF:%.3f,\n", seg.seconds) + "#EXT-X-BYTERANGE:\(seg.length)@\(seg.offset)\n\(u)\n"
        }
        return s + "#EXT-X-ENDLIST\n"
    }

    private func store(_ name: String, _ text: String) {
        lock.withLock {
            if playlists.count > 60 { playlists.removeAll() }   // 오래된 것 정리 (지금 재생 중인 것은 이미 읽혀 있음)
            playlists[name] = Data(text.utf8)
        }
    }

    // MARK: 맥 플레이어가 재생목록을 달라고 할 때

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, url.scheme == "mytubehls", let host = url.host else { return false }
        let name = "\(host)/\(url.lastPathComponent)"
        guard let data = lock.withLock({ playlists[name] }) else { return false }
        request.contentInformationRequest?.contentType = "public.m3u-playlist"
        request.contentInformationRequest?.contentLength = Int64(data.count)
        request.contentInformationRequest?.isByteRangeAccessSupported = false
        request.dataRequest?.respond(with: data)
        request.finishLoading()
        return true
    }
}
