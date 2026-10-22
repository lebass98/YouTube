import AVFoundation
import SwiftUI
import WebKit

/// 듣기 모드: 영상은 받지 않고 소리만 재생 (데이터·배터리 절약, 화면 없이 일하면서 듣기)
/// 작은 듣기 창(미니 플레이어)과 메뉴 막대에서 조작
@MainActor
final class ListenPlayer: ObservableObject {
    static let shared = ListenPlayer()

    enum State: Equatable { case idle, loading, playing, failed(String) }

    @Published private(set) var item: PlayerItem?
    @Published private(set) var state = State.idle
    @Published private(set) var info: YTDLP.StreamInfo?
    private(set) var player: AVPlayer?
    private var task: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var positionObserver: Any?

    var isActive: Bool { item != nil }

    func play(_ item: PlayerItem) {
        stop(closeWindow: false)
        self.item = item
        state = .loading
        MiniPlayerWindow.shared.show()
        guard let pageURL = URL(string: item.url) else { return }
        task = Task {
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let windows = PlayerWindowController.shared
            var lastError: Error?
            for attempt in 1...2 {
                do {
                    let info = try await windows.streamInfo(for: item.id, pageURL: pageURL, cookies: cookies)
                    let playerItem: AVPlayerItem
                    if let audio = info.audio {
                        // 소리 파일만 (색인으로 만든 재생목록 → 바로 시작, 안 되면 파일 그대로)
                        if let fast = try? await LocalHLS.shared.audioItem(audio: audio) {
                            playerItem = fast
                        } else {
                            playerItem = AVPlayerItem(url: audio)
                        }
                    } else if let manifest = info.manifest {
                        playerItem = AVPlayerItem(url: manifest)   // 라이브
                        playerItem.preferredPeakBitRate = 300_000   // 화면은 안 보니 가장 낮은 화질로
                    } else {
                        playerItem = AVPlayerItem(url: try await windows.hlsURL(for: item.id, pageURL: pageURL))
                        playerItem.preferredPeakBitRate = 300_000
                    }
                    guard !Task.isCancelled else { return }
                    start(playerItem, info: info, item: item)
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    lastError = error
                    windows.forgetStreams(for: item.id)
                    DebugLog.write("듣기 준비 실패 (\(attempt)번째, \(item.id)): \(error.localizedDescription)")
                }
            }
            state = .failed(lastError?.localizedDescription ?? "알 수 없는 오류")
        }
    }

    private func start(_ playerItem: AVPlayerItem, info: YTDLP.StreamInfo, item: PlayerItem) {
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        self.info = info
        let resume = item.startAt > 1 ? item.startAt : (PlaybackMemory.position(for: item.id) ?? 0)
        if resume > 1 {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { _ in
            MainActor.assumeIsolated {
                PlaybackMemory.forget(item.id)
                DebugLog.write("듣기: 끝까지 들음")
                if !Playback.finished(item.id, listen: true) { ListenPlayer.shared.stop() }
            }
        }
        positionObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak player] time in
            MainActor.assumeIsolated {
                PlaybackMemory.save(id: item.id, position: time.seconds, duration: player?.currentItem?.duration.seconds ?? .nan)
            }
        }
        NowPlaying.shared.attach(player, id: item.id, title: info.title.isEmpty ? item.title : info.title,
                                 channel: info.channelName ?? "", channelID: info.channelID,
                                 duration: info.duration, chapters: info.chapters ?? [], source: .listen)
        player.play()
        state = .playing
        NSApp.dockTile.badgeLabel = "🎧"   // Dock 아이콘에 듣는 중 표시
        DebugLog.write("듣기 모드 재생: \(info.title)" + (resume > 1 ? " (\(Int(resume))초부터)" : ""))
    }

    /// 멈추고 정리. closeWindow: 듣기 창도 닫음
    func stop(closeWindow: Bool = true) {
        task?.cancel()
        task = nil
        if let player {
            player.pause()
            if let id = item?.id {
                PlaybackMemory.save(id: id, position: player.currentTime().seconds, duration: player.currentItem?.duration.seconds ?? .nan)
            }
            if let positionObserver { player.removeTimeObserver(positionObserver) }
            NowPlaying.shared.detach(player)
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        positionObserver = nil
        player = nil
        info = nil
        if item != nil { WatchMarks.shared.refresh() }
        item = nil
        state = .idle
        NSApp.dockTile.badgeLabel = nil
        if closeWindow { MiniPlayerWindow.shared.close() }
    }

    /// 같은 위치에서 재생 창(영상)으로
    func switchToVideo() {
        guard var next = item else { return }
        next.startAt = max(player?.currentTime().seconds ?? 0, 1.5)
        stop()
        Playback.open(next, listen: false)
    }
}

// MARK: - 듣기 창 (작은 창)

@MainActor
final class MiniPlayerWindow: NSObject, NSWindowDelegate {
    static let shared = MiniPlayerWindow()
    private var window: NSWindow?
    /// 닫기(빨간 단추) = 듣기 끝, 숨기기 = 계속 들으며 창만 감춤
    private var hiding = false

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if let window {
            window.orderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: MiniPlayerView().themed())
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "듣기"
        window.delegate = self
        if !window.setFrameUsingName("MyTubeListen") {
            // 처음: 화면 오른쪽 아래
            if let screen = NSScreen.main?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: screen.maxX - 420, y: screen.minY + 24))
            }
        }
        window.setFrameAutosaveName("MyTubeListen")
        self.window = window
        window.orderFront(nil)
    }

    /// 창만 숨기고 계속 재생 (메뉴 막대에서 다시 열 수 있음)
    func hide() {
        hiding = true
        window?.orderOut(nil)
        hiding = false
        Toast.shared.show("듣기 창을 숨겼어요. 메뉴 막대 🎧에서 다시 열 수 있어요", seconds: 3)
    }

    func close() {
        window?.close()
    }

    func setPinned(_ pinned: Bool) {
        window?.level = pinned ? .floating : .normal
    }

    func windowWillClose(_ notification: Notification) {
        guard !hiding else { return }
        window = nil
        if ListenPlayer.shared.isActive { ListenPlayer.shared.stop(closeWindow: false) }
    }
}

/// 끌어서 옮길 수 있는 재생 막대 (끄는 동안에는 1초마다 오는 위치로 덮어쓰지 않음)
@MainActor
final class ScrubState: ObservableObject {
    @Published var dragging = false
    @Published var value: Double = 0
}

struct ScrubBar: View {
    @ObservedObject var now = NowPlaying.shared
    @StateObject private var scrub = ScrubState()
    var compact = false

    var body: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(get: { scrub.dragging ? scrub.value : now.position },
                                  set: { scrub.value = $0 }),
                   in: 0...max(now.duration, 1)) { editing in
                if editing {
                    scrub.value = now.position
                    scrub.dragging = true
                } else {
                    now.seek(to: scrub.value)
                    scrub.dragging = false
                }
            }
            .controlSize(.mini)
            .disabled(now.duration <= 0)
            HStack {
                Text(PlaybackMemory.timeText(scrub.dragging ? scrub.value : now.position))
                Spacer()
                Text(now.duration > 0 ? PlaybackMemory.timeText(now.duration) : "LIVE")
            }
            .font(.system(size: compact ? 9 : 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

/// 재생 속도 메뉴 (재생 창·듣기 창·메뉴 막대 공통)
struct SpeedMenu<Label: View>: View {
    @ObservedObject var now = NowPlaying.shared
    @ViewBuilder let label: (Float) -> Label

    var body: some View {
        Menu {
            ForEach(PlaybackSpeed.choices, id: \.self) { value in
                Button((abs(now.rate - value) < 0.01 ? "✓ " : "    ") + PlaybackSpeed.label(value)) { now.setRate(value) }
            }
            Divider()
            Text("채널마다 마지막 속도를 기억해요 · ⇧. 빠르게 ⇧, 느리게")
        } label: {
            label(now.rate)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("재생 속도 (지금 \(PlaybackSpeed.label(now.rate)))")
    }
}

/// 챕터 메뉴 (챕터가 있는 영상만)
struct ChapterMenu<Label: View>: View {
    @ObservedObject var now = NowPlaying.shared
    @ViewBuilder let label: () -> Label

    var body: some View {
        if !now.chapters.isEmpty {
            Menu {
                ForEach(Array(now.chapters.enumerated()), id: \.offset) { index, chapter in
                    let current = now.position >= chapter.start
                        && (index + 1 == now.chapters.count || now.position < now.chapters[index + 1].start)
                    Button((current ? "▶ " : "    ") + "\(PlaybackMemory.timeText(chapter.start))  \(chapter.title)") {
                        now.seek(to: chapter.start)
                    }
                }
            } label: {
                label()
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("챕터로 이동")
        }
    }
}

/// 듣기 창 내용
struct MiniPlayerView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var listen = ListenPlayer.shared
    @ObservedObject private var now = NowPlaying.shared
    @ObservedObject private var queue = PlayQueue.shared
    @StateObject private var pin = PinState()
    @StateObject private var summary = PopoverState()
    @ObservedObject private var layout = ListenLayout.shared

    var body: some View {
        Group {
            if layout.expanded { expandedView } else { compactView }
        }
        .animation(.easeInOut(duration: 0.25), value: layout.expanded)
    }

    /// 큰 화면 높이: 다음 재생 목록이 있으면 그만큼 더 (줄 수에 따라 정해진 값)
    private var expandedHeight: CGFloat {
        let rows = min(queue.entries.count, 3)
        return 600 + (rows == 0 ? 0 : 44 + CGFloat(rows) * 46)
    }

    private var artworkURL: URL? {
        listen.item.map { URL(string: "https://i.ytimg.com/vi/\($0.id)/hqdefault.jpg")! }
    }

    /// 큰 화면: 흐린 배경 + 큰 썸네일 + 큰 조작 단추 + 다음 재생
    private var expandedView: some View {
        VStack(spacing: 16) {
            HStack {
                Button { layout.expanded = false } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help("작게 보기")
                Spacer()
                Text("지금 듣는 중").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { MiniPlayerWindow.shared.hide() } label: { Image(systemName: "chevron.down.circle") }
                    .help("창만 숨기고 계속 듣기")
            }
            .buttonStyle(.borderless)
            .padding(.top, 18)

            AsyncImage(url: artworkURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
            }
            .frame(width: 388, height: 218)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)

            VStack(spacing: 4) {
                Text(listen.info?.title ?? listen.item?.title ?? "")
                    .font(.system(size: 17, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(now.channel).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)

            ScrubBar()

            HStack(spacing: 30) {
                Button { now.skip(-15) } label: { Image(systemName: "gobackward.15").font(.system(size: 22)) }
                Button { now.togglePlay() } label: {
                    Image(systemName: now.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(theme.style)
                }
                Button { now.skip(15) } label: { Image(systemName: "goforward.15").font(.system(size: 22)) }
                Button { now.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 20)) }
                    .disabled(queue.entries.isEmpty)
            }
            .buttonStyle(.borderless)

            HStack(spacing: 18) {
                SpeedMenu { rate in
                    Text(PlaybackSpeed.label(rate)).font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.6)))
                }
                ChapterMenu { Image(systemName: "list.bullet.indent") }
                Button { summary.isShown.toggle() } label: { Image(systemName: "sparkle") }
                    .help("이 동영상에 대해 물어보기 · AI 요약")
                    .popover(isPresented: $summary.isShown, arrowEdge: .top) {
                        if let item = listen.item {
                            AIPanel(videoID: item.id, title: listen.info?.title ?? item.title, captionURL: listen.info?.captionURL)
                                .frame(width: 400, height: 520)
                        }
                    }
                Button { pin.isOn.toggle(); MiniPlayerWindow.shared.setPinned(pin.isOn) } label: {
                    Image(systemName: pin.isOn ? "pin.fill" : "pin")
                }
                .help("다른 창 위에 늘 띄우기")
                Button { ListenPlayer.shared.switchToVideo() } label: { Image(systemName: "play.rectangle") }
                    .help("같은 위치에서 영상으로 보기")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)

            if !queue.entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("다음 재생").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(queue.entries.prefix(3)) { entry in
                        Button { queue.play(entry, listen: true) } label: {
                            HStack(spacing: 10) {
                                AsyncImage(url: entry.thumbnailURL) { phase in
                                    if let image = phase.image { image.resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
                                }
                                .frame(width: 64, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.title).font(.caption.weight(.medium)).lineLimit(1)
                                    Text(entry.channel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        // 크기를 고정: 배경 그림이 창 크기를 바꾸고 → 창이 다시 크기를 재는 일이 끝없이 반복되면
        // macOS가 앱을 강제로 끔(실제로 있었던 문제) → 큰 화면은 늘 같은 크기, 배경은 그 틀 안에만
        .frame(width: 432, height: expandedHeight, alignment: .top)
        // 흐린 썸네일 배경 (틀 크기에 딱 맞춰 자름)
        .background {
            Color.clear
                .overlay {
                    AsyncImage(url: artworkURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { Color.clear }
                    }
                    .blur(radius: 60)
                    .opacity(0.55)
                }
                .overlay(.regularMaterial.opacity(0.5))
                .frame(width: 432, height: expandedHeight)
                .clipped()
        }
        .overlay(alignment: .bottom) { ToastView().scaleEffect(0.85) }
    }

    private var compactView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: listen.item.map { URL(string: "https://i.ytimg.com/vi/\($0.id)/mqdefault.jpg")! }) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
                }
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "headphones")
                        .font(.system(size: 10, weight: .bold))
                        .padding(4)
                        .background(theme.style, in: Circle())
                        .foregroundStyle(.white)
                        .padding(4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(listen.info?.title ?? listen.item?.title ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(now.channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    switch listen.state {
                    case .loading:
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("소리 준비 중…") }
                            .font(.caption).foregroundStyle(.secondary)
                    case .failed(let message):
                        Text("재생 실패: \(message)").font(.caption).foregroundStyle(.orange).lineLimit(2)
                    default:
                        if let next = queue.entries.first {
                            Text("다음: \(next.title)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    Button { pin.isOn.toggle(); MiniPlayerWindow.shared.setPinned(pin.isOn) } label: {
                        Image(systemName: pin.isOn ? "pin.fill" : "pin")
                    }
                    .help(pin.isOn ? "다른 창 위에 띄우기 끄기" : "다른 창 위에 늘 띄우기")
                    Button { MiniPlayerWindow.shared.hide() } label: { Image(systemName: "chevron.down.circle") }
                        .help("창만 숨기고 계속 듣기 (메뉴 막대 🎧에서 다시 열기)")
                    Button { layout.expanded = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("크게 보기")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            ScrubBar()

            HStack(spacing: 14) {
                Button { now.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    .help("15초 뒤로")
                Button { now.togglePlay() } label: {
                    Image(systemName: now.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(theme.style)
                }
                .help("재생/일시정지 (키보드 ⏯ 키도 돼요)")
                Button { now.skip(15) } label: { Image(systemName: "goforward.15") }
                    .help("15초 앞으로")
                Button { now.next() } label: { Image(systemName: "forward.end.fill") }
                    .disabled(queue.entries.isEmpty)
                    .help(queue.entries.isEmpty ? "대기열이 비어 있어요" : "다음 영상 (대기열 \(queue.entries.count)개)")
                Spacer()
                SpeedMenu { rate in
                    Text(PlaybackSpeed.label(rate)).font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6).frame(height: 20)
                        .background(Capsule().strokeBorder(Color.secondary.opacity(0.6)))
                }
                ChapterMenu { Image(systemName: "list.bullet.indent") }
                Button { summary.isShown.toggle() } label: { Image(systemName: "sparkles") }
                    .help("AI 요약")
                    .disabled(listen.item == nil)
                    .popover(isPresented: $summary.isShown, arrowEdge: .bottom) {
                        if let item = listen.item {
                            AIPanel(videoID: item.id, title: listen.info?.title ?? item.title, captionURL: listen.info?.captionURL)
                                .frame(width: 400, height: 520)
                        }
                    }
                Button { ListenPlayer.shared.switchToVideo() } label: { Image(systemName: "play.rectangle") }
                    .help("같은 위치에서 영상으로 보기")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15))
        }
        .padding(.horizontal, 16)
        .padding(.top, 30)
        .padding(.bottom, 14)
        .frame(width: 400)
        .overlay(alignment: .bottom) { ToastView().scaleEffect(0.85) }
    }
}

/// 듣기 창 "늘 위에" 상태
@MainActor
final class PinState: ObservableObject {
    @Published var isOn = false
}

/// 듣기 창 크기 (작게/크게, 다음에도 유지)
@MainActor
final class ListenLayout: ObservableObject {
    static let shared = ListenLayout()
    @Published var expanded = UserDefaults.standard.bool(forKey: "listenExpanded") {
        didSet { UserDefaults.standard.set(expanded, forKey: "listenExpanded") }
    }
}
