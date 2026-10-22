import AVFoundation
import SwiftUI
import WebKit

/// 목록 카드에 마우스를 올리면 썸네일 자리에서 소리 없이 미리 보기 (한 번에 하나만)
@MainActor
final class HoverPreview: ObservableObject {
    static let shared = HoverPreview()

    /// 지금 마우스가 올라가 있는 영상 (준비 중 표시용)
    @Published private(set) var hoveredID: String?
    /// 미리 보기가 재생 중인 영상
    @Published private(set) var playingID: String?
    private(set) var player: AVPlayer?
    private var task: Task<Void, Never>?
    private var loopObserver: NSObjectProtocol?

    func hover(_ video: FeedVideo, inside: Bool) {
        if inside {
            guard hoveredID != video.id else { return }
            stop()
            hoveredID = video.id
            guard let pageURL = URL(string: video.watchURL) else { return }
            task = Task { [weak self] in
                // 0.25초 머물면 재생용 주소부터 미리 받기 (목록을 훑고 지나갈 때는 받지 않음, 라이브도)
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                PlayerWindowController.shared.prefetch(id: video.id, pageURL: pageURL)
                guard !video.isLive else { return }   // 라이브는 미리 보기 없음
                // 0.5초 머물면 미리 보기 시작
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await self?.start(video, pageURL: pageURL)
            }
        } else if hoveredID == video.id {
            stop()
        }
    }

    private func start(_ video: FeedVideo, pageURL: URL) async {
        do {
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            // 재생 창과 같은 저장소 → 미리 본 영상은 눌렀을 때 더 빨리 열림
            let info = try await PlayerWindowController.shared.streamInfo(for: video.id, pageURL: pageURL, cookies: cookies)
            guard !Task.isCancelled, hoveredID == video.id else { return }
            // 미리 보기는 가벼운 화질: 360~480p H.264 (없으면 가장 낮은 것)
            let candidates = info.streams.sorted { $0.shortSide < $1.shortSide }
            guard let stream = candidates.first(where: { $0.shortSide >= 360 && $0.codec.hasPrefix("avc1") })
                    ?? candidates.first(where: { $0.shortSide >= 360 }) ?? candidates.last else { return }

            // 색인으로 만든 HLS(빠름), 안 되면 파일 그대로
            let item = (try? await LocalHLS.shared.item(video: stream.url, codec: stream.codec,
                                                        width: stream.width, height: stream.height, audio: nil))
                ?? AVPlayerItem(url: stream.url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            // 앞부분(인트로)보다 내용이 보이게 15% 지점부터
            if let duration = info.duration, duration > 20 {
                await player.seek(to: CMTime(seconds: duration * 0.15, preferredTimescale: 600))
            }
            guard !Task.isCancelled, hoveredID == video.id else { return }
            // 끝나면 처음(15% 지점)부터 다시
            let start = player.currentTime()
            loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak player] _ in
                player?.seek(to: start)
                player?.play()
            }
            self.player = player
            playingID = video.id
            player.play()
        } catch {
            DebugLog.write("미리 보기 실패: \(error.localizedDescription)")
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.pause()
        player = nil
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        hoveredID = nil
        playingID = nil
    }
}

/// 썸네일 자리를 꽉 채우는 소리 없는 영상
struct PreviewVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
