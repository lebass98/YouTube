import Foundation
import VideoToolbox

/// yt-dlp로 유튜브 페이지 주소 → 실제 영상·소리 파일 주소를 받아 옴
enum YTDLP {
    struct Video {
        let title: String
        /// 실제로 고른 화질 (예: "2160p")
        let quality: String
        /// 영상+소리가 따로면 2개, 합쳐진 파일이면 1개
        let urls: [URL]
    }

    enum Failure: LocalizedError {
        case notInstalled
        case failed(String)
        case listFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "yt-dlp가 설치되어 있지 않아요. 터미널에서 brew install yt-dlp 를 실행해 주세요."
            case .failed(let message):
                return "영상 주소를 가져오지 못했어요.\n\(message)"
            case .listFailed(let message):
                return "영상 목록을 불러오지 못했어요.\n\(message)"
            }
        }
    }

    /// 화질 규칙: 4K(2160p)까지 중 가장 높은 화질, 8K는 제외, 4K가 없으면 그 바로 아래 화질.
    /// 맥 플레이어가 읽을 수 있는 mp4만 고름: 4K·1440p는 AV1, 1080p 이하는 AV1 또는 H.264. 소리는 AAC
    private static func format(safe: Bool) -> String {
        // AV1은 M3 이후 칩에서만 하드웨어 재생 → 지원 안 하는 Mac은 H.264(최대 1080p)만
        // safe: 4K(AV1) 영상이 자꾸 멈출 때 쓰는 안정 모드 → H.264(최대 1080p)
        let codecs = !safe && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) ? "av01|avc1" : "avc1"
        return "bv*[height<=2160][ext=mp4][protocol=https][vcodec~='^(\(codecs))']+ba[ext=m4a][protocol=https]"
            + "/b[ext=mp4][protocol=https]/b"
    }

    // 앱은 터미널과 달리 Homebrew 경로를 모르므로 직접 찾음
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static var executable: URL? {
        searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent("yt-dlp") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func resolve(_ pageURL: URL, cookies: [HTTPCookie], safe: Bool = false) async throws -> Video {
        guard let exe = executable else { throw Failure.notInstalled }

        var args = ["--no-warnings", "--no-playlist", "-f", format(safe: safe), "--print", "title", "--print", "%(width)sx%(height)s", "-g"]
        // 앱에 로그인한 상태를 그대로 넘김 (프리미엄 화질, 나이 제한 영상, "로봇 아님" 확인 대비)
        if let cookieFile = try? writeCookies(cookies) {
            args += ["--cookies", cookieFile.path]
        }
        args.append(pageURL.absoluteString)

        let result = try await run(exe, args)
        DebugLog.write("yt-dlp 종료 코드 \(result.status) \(result.stderr.prefix(300))")
        guard result.status == 0 else {
            throw Failure.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let lines = result.stdout.split(separator: "\n").map(String.init)
        let urls = lines.dropFirst(2).compactMap { URL(string: $0) }.filter { $0.scheme == "https" }
        guard lines.count >= 3, !urls.isEmpty else {
            throw Failure.failed("yt-dlp가 빈 결과를 돌려줬어요.")
        }
        return Video(title: lines[0], quality: qualityLabel(lines[1]), urls: urls)
    }

    /// "3840x2160" → "4K (3840×2160)": 긴 쪽 기준으로 이름을 붙임 (와이드·세로 영상도 맞게)
    private static func qualityLabel(_ size: String) -> String {
        let parts = size.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return size }
        let long = max(parts[0], parts[1]), short = min(parts[0], parts[1])
        let name = long >= 3200 ? "4K" : long >= 2400 ? "1440p" : long >= 1800 ? "1080p" : "\(short)p"
        return "\(name) (\(parts[0])×\(parts[1]))"
    }

    /// 영상 목록 받기: ":ytrec"(내 추천 홈), ":ytsubs"(구독), ":ytwatchlater"(나중에 볼 영상), "ytsearchN:검색어"
    /// 영상 하나하나를 열지 않고 목록 정보만 빠르게 받음 (--flat-playlist)
    static func listFeed(_ source: String, from start: Int, to end: Int, cookies: [HTTPCookie]) async throws -> [FeedVideo] {
        guard let exe = executable else { throw Failure.notInstalled }
        var args = ["--no-warnings", "--flat-playlist", "-j", "-I", "\(start):\(end)"]
        if let cookieFile = try? writeCookies(cookies) {
            args += ["--cookies", cookieFile.path]
        }
        args.append(source)

        let result = try await run(exe, args)
        guard result.status == 0 else {
            DebugLog.write("목록 받기 실패 \(source): \(result.stderr.prefix(300))")
            throw Failure.listFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // 영상과 재생목록이 섞여 올 수 있음 (가려내는 건 부르는 쪽에서)
        return result.stdout.split(separator: "\n").compactMap {
            try? decoder.decode(FeedVideo.self, from: Data($0.utf8))
        }
    }

    /// 영상들의 최고 화질 알아내기 (화질 선택용). 결과: 영상 코드 → (짧은 변 길이, VR 여부)
    /// 영상 하나에 약 3초라 부르는 쪽에서 몇 개씩 나눠 동시에 부름
    /// 결과: 영상 코드 → (최고 화질, 등록 정보: 날짜·올린 시각·조회수)
    static func probeQuality(_ ids: [String], cookies: [HTTPCookie]) async -> [String: (quality: VideoQuality, meta: VideoMeta)] {
        guard let exe = executable, !ids.isEmpty else { return [:] }
        var args = ["--no-warnings", "--ignore-errors", "--skip-download", "-f", "bv*",
                    "--print", "%(id)s|%(width)s|%(height)s|%(format_note)s|%(upload_date)s|%(timestamp)s|%(view_count)s"]
        if let cookieFile = try? writeCookies(cookies) {
            args += ["--cookies", cookieFile.path]
        }
        args += ids.map { "https://www.youtube.com/watch?v=\($0)" }

        var found: [String: (quality: VideoQuality, meta: VideoMeta)] = [:]
        if let result = try? await run(exe, args) {
            for line in result.stdout.split(separator: "\n") {
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 7, ids.contains(parts[0]) else { continue }
                let w = Int(parts[1]) ?? 0, h = Int(parts[2]) ?? 0
                // 360° 영상은 형식 메모에 "equi"(360° 펼친 화면)나 "2160s" 같은 s가 붙음
                let note = parts[3]
                let isVR = note.contains("equi") || note.range(of: #"\d+s\b"#, options: .regularExpression) != nil
                let meta = VideoMeta(date: parts[4].count == 8 ? parts[4] : "",
                                     timestamp: Double(parts[5]), views: Int(parts[6]))
                found[parts[0]] = (VideoQuality(shortSide: min(w, h), isVR: isVR, isVertical: h > w), meta)
            }
        }
        // 못 알아낸 영상(비공개·회원 전용 등)은 0으로 기록해 다시 묻지 않음
        for id in ids where found[id] == nil { found[id] = (VideoQuality(shortSide: 0, isVR: false), VideoMeta(date: "")) }
        return found
    }

    /// 로그인한 계정의 채널 코드 (내 동영상용)
    static func myChannelID(cookies: [HTTPCookie]) async -> String? {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/account")!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let youtube = cookies.filter { $0.domain.hasSuffix("youtube.com") }
        for (key, value) in HTTPCookie.requestHeaderFields(with: youtube) { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        guard let range = html.range(of: #""browseId":"UC[A-Za-z0-9_-]{22}""#, options: .regularExpression) else { return nil }
        return String(html[range].dropFirst(#""browseId":""#.count).dropLast())
    }

    /// 영상 하나의 화질별 주소를 한 번에 (화질 바꿀 때 다시 묻지 않으려고)
    struct StreamInfo: Codable {
        struct Stream: Codable {
            let shortSide: Int      // 화질 단계 기준 (세로 영상도 같게 짧은 변)
            let width: Int
            let height: Int
            let codec: String
            let bitrate: Double
            let url: URL
        }
        let title: String
        let streams: [Stream]       // 영상만 있는 파일들
        let audio: URL?             // 소리만 있는 파일 (AAC)
        let combined: URL?          // 영상+소리 합쳐진 파일 (360p, 마지막 수단)
        var channelID: String? = nil  // 채널 코드 (UC…) — "채널로 가기"용
        /// 실제 길이(초). 맥 플레이어는 유튜브 영상·소리 파일 길이를 2배로 잘못 읽어서 이 값으로 자름
        var duration: Double? = nil
        var channelName: String? = nil
        /// 로그인한 채로 받은 HLS 주소 (라이브는 이것만 있음 → yt-dlp를 한 번 더 안 돌려도 됨)
        var manifest: URL? = nil
        /// 챕터 (영상 설명에 시간표가 있으면)
        var chapters: [Chapter]? = nil
        /// 자막 주소 (json3, AI 요약용): 직접 단 자막(한국어→영어) → 자동 자막(원래 언어)
        var captionURL: URL? = nil

        struct Chapter: Codable, Hashable {
            let title: String
            let start: Double
        }

        /// 화질 단계: 높은 것부터 1080p까지 → HLS(안정) → 720p·480p
        var levels: [QualityLevel] {
            let heights = Set(streams.map(\.shortSide)).filter { $0 >= 480 && $0 <= 2160 }.sorted(by: >)
            return heights.filter { $0 >= 1080 }.map { .direct($0) } + [.hls] + heights.filter { $0 < 1080 }.prefix(2).map { .direct($0) }
        }

        /// 그 화질의 영상 파일: 1080p 이하는 더 무난한 H.264를 먼저, 그 위는 AV1
        func stream(for shortSide: Int) -> Stream? {
            let same = streams.filter { $0.shortSide == shortSide }
            let preferred = same.filter { shortSide <= 1080 ? $0.codec.hasPrefix("avc1") : $0.codec.hasPrefix("av01") }
            return (preferred.isEmpty ? same : preferred).max { $0.bitrate < $1.bitrate }
        }
    }

    static func streamInfo(_ pageURL: URL, cookies: [HTTPCookie]) async throws -> StreamInfo {
        guard let exe = executable else { throw Failure.notInstalled }
        var args = ["--no-warnings", "--no-playlist", "-j"]
        if let cookieFile = try? writeCookies(cookies) { args += ["--cookies", cookieFile.path] }
        args.append(pageURL.absoluteString)
        let result = try await run(exe, args)

        struct Info: Decodable {
            struct Format: Decodable {
                let formatId: String?
                let url: String?
                let `protocol`: String?
                let ext: String?
                let vcodec: String?
                let acodec: String?
                let width: Int?
                let height: Int?
                let tbr: Double?
                let languagePreference: Int?
                let formatNote: String?
                let manifestUrl: String?
            }
            struct Chapter: Decodable {
                let startTime: Double?
                let title: String?
            }
            struct Caption: Decodable, CaptionLike {
                let ext: String?
                let url: String?
            }
            let title: String?
            let chapters: [Chapter]?
            let language: String?
            let subtitles: [String: [Caption]]?
            let automaticCaptions: [String: [Caption]]?
            let channelId: String?
            let channel: String?
            let uploader: String?
            let duration: Double?
            let formats: [Format]?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard result.status == 0,
              let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix("{") }),
              let info = try? decoder.decode(Info.self, from: Data(line.utf8)) else {
            DebugLog.write("yt-dlp 형식 목록 실패 \(result.stderr.prefix(300))")
            throw Failure.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        let formats = (info.formats ?? []).filter { $0.protocol == "https" && $0.url != nil }
        let streams: [StreamInfo.Stream] = formats.compactMap { f in
            guard f.ext == "mp4", f.acodec == "none", let codec = f.vcodec,
                  codec.hasPrefix("avc1") || (av1 && codec.hasPrefix("av01")),
                  let w = f.width, let h = f.height, let url = URL(string: f.url!) else { return nil }
            return .init(shortSide: min(w, h), width: w, height: h, codec: codec, bitrate: f.tbr ?? 0, url: url)
        }
        // 소리: 원래 언어(더빙 아님) + 일반 AAC(140), 없으면 다른 AAC
        let aac = formats.filter { $0.ext == "m4a" && $0.vcodec == "none" && ($0.acodec ?? "").hasPrefix("mp4a")
            && !($0.formatNote ?? "").contains("DRC") }
        let topLanguage = aac.map { $0.languagePreference ?? -1 }.max() ?? -1
        let original = aac.filter { ($0.languagePreference ?? -1) == topLanguage }
        let audio = (original.first { ($0.formatId ?? "").hasPrefix("140") } ?? original.max { ($0.tbr ?? 0) < ($1.tbr ?? 0) })
            .flatMap { URL(string: $0.url!) }
        let combined = formats.first { $0.formatId == "18" }.flatMap { URL(string: $0.url!) }
        return StreamInfo(title: info.title ?? "", streams: streams, audio: audio, combined: combined,
                          channelID: info.channelId, duration: info.duration,
                          channelName: info.channel ?? info.uploader,
                          manifest: (info.formats ?? []).first { ($0.protocol ?? "").contains("m3u8") && $0.manifestUrl != nil }
                            .flatMap { URL(string: $0.manifestUrl!) },
                          chapters: (info.chapters ?? []).compactMap { c in
                              c.startTime.map { StreamInfo.Chapter(title: c.title ?? "", start: $0) } },
                          captionURL: captionURL(info.subtitles, info.automaticCaptions, language: info.language))
    }

    /// AI 요약에 쓸 자막: 직접 단 한국어·영어 → 다른 직접 단 자막 → 자동 자막(원래 언어, 한국어, 영어)
    private static func captionURL(_ manual: [String: [some CaptionLike]]?, _ auto: [String: [some CaptionLike]]?, language: String?) -> URL? {
        func json3(_ list: [any CaptionLike]?) -> URL? {
            list?.first { $0.ext == "json3" }.flatMap { $0.url }.flatMap(URL.init(string:))
        }
        let manual = manual ?? [:], auto = auto ?? [:]
        let lang = language ?? "en"
        for key in ["ko", "en"] { if let url = json3(manual[key]) { return url } }
        if let any = manual.first(where: { !$0.key.hasPrefix("live_chat") })?.value, let url = json3(any) { return url }
        for key in ["\(lang)-orig", lang, "ko", "en"] { if let url = json3(auto[key]) { return url } }
        return nil
    }

    /// 안정 모드용 HLS(애플 방식 스트리밍) 주소. 맥 플레이어가 직접 다루는 방식이라 화면이 멈추지 않음 (H.264 최대 1080p)
    /// 로그인 정보를 넘기면 HLS를 안 주는 방식으로 받아 와서, 로그인 정보 없이 받음
    static func hlsManifest(_ pageURL: URL) async throws -> (title: String, url: URL) {
        guard let exe = executable else { throw Failure.notInstalled }
        let result = try await run(exe, ["--no-warnings", "--no-playlist", "-j", pageURL.absoluteString])
        struct Info: Decodable {
            struct Format: Decodable {
                let manifestUrl: String?
                let `protocol`: String?
            }
            let title: String?
            let formats: [Format]?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard result.status == 0,
              let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix("{") }),
              let info = try? decoder.decode(Info.self, from: Data(line.utf8)),
              let manifest = info.formats?.first(where: { ($0.protocol ?? "").contains("m3u8") && $0.manifestUrl != nil })?.manifestUrl,
              let url = URL(string: manifest) else {
            throw Failure.failed("HLS 주소를 받지 못했어요. \(result.stderr.prefix(200))")
        }
        return (info.title ?? "", url)
    }

    /// 자막 미리 만들기용: 소리만(AAC m4a) 파일로 받기
    static func downloadAudio(_ pageURL: URL, cookies: [HTTPCookie], to dest: URL) async throws {
        guard let exe = executable else { throw Failure.notInstalled }
        var args = ["--no-warnings", "--no-playlist", "--no-part", "--force-overwrites",
                    "-f", "ba[ext=m4a]/ba[acodec^=mp4a]", "-o", dest.path]
        if let cookieFile = try? writeCookies(cookies) {
            args += ["--cookies", cookieFile.path]
        }
        args.append(pageURL.absoluteString)

        let result = try await run(exe, args)
        DebugLog.write("yt-dlp 소리 받기 종료 코드 \(result.status) \(result.stderr.prefix(300))")
        guard result.status == 0, FileManager.default.fileExists(atPath: dest.path) else {
            throw Failure.failed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 유튜브 주소에서 영상 코드 뽑기 (watch?v=코드, shorts/코드, live/코드, youtu.be/코드)
    static func videoID(from url: URL) -> String? {
        if url.host?.hasSuffix("youtu.be") == true { return url.pathComponents.dropFirst().first }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        let parts = url.pathComponents
        if parts.count >= 3, ["shorts", "live"].contains(parts[1]) { return parts[2] }
        return nil
    }

    /// 웹 화면의 쿠키를 yt-dlp가 읽는 형식(Netscape cookies.txt)으로 저장. 나만 읽을 수 있게 600 권한
    static func writeCookies(_ cookies: [HTTPCookie]) throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTube")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("cookies.txt")

        var lines = ["# Netscape HTTP Cookie File"]
        for c in cookies where c.domain.hasSuffix("youtube.com") || c.domain.hasSuffix("google.com") {
            lines.append([
                c.domain,
                c.domain.hasPrefix(".") ? "TRUE" : "FALSE",
                c.path,
                c.isSecure ? "TRUE" : "FALSE",
                String(Int(c.expiresDate?.timeIntervalSince1970 ?? 0)),
                c.name,
                c.value,
            ].joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    private final class Output: @unchecked Sendable {
        var stderr = Data()
    }

    private static func run(_ exe: URL, _ args: [String]) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = exe
                process.arguments = args
                // yt-dlp가 유튜브 암호 풀이에 쓰는 deno도 Homebrew 경로에 있음
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (searchPaths + ["/bin"]).joined(separator: ":")
                process.environment = env

                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    cont.resume(throwing: error)
                    return
                }

                // 두 출력을 동시에 읽어야 한쪽이 가득 차서 멈추는 일이 없음
                let box = Output()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    box.stderr = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                cont.resume(returning: (
                    process.terminationStatus,
                    String(decoding: stdout, as: UTF8.self),
                    String(decoding: box.stderr, as: UTF8.self)
                ))
            }
        }
    }
}

/// 자막 항목 (yt-dlp 정보 안의 subtitles·automatic_captions)
protocol CaptionLike {
    var ext: String? { get }
    var url: String? { get }
}
