import AVKit
import SwiftUI
import WebKit

// EpoBrowser의 재생 창을 MyTube용으로 옮김 (영상 주소는 yt-dlp로 찾음)

/// 재생 창에 넘기는 값 (창을 다시 열 때 복원되도록 Codable)
struct PlayerItem: Codable, Hashable {
    /// 유튜브 영상 코드 (미리 만든 자막 파일 이름으로도 씀)
    let id: String
    let title: String
    let url: String
    /// 웹에서 보던 위치 (초)
    var startAt: Double = 0
    /// 화질: nil = 자동(가능한 가장 높은 화질부터), 값 = 그 화질로
    var level: QualityLevel? = nil
    /// 자동 화질 조절 (멈추면 낮추고, 안정되면 다시 올림). 직접 고르면 꺼짐 (멈추면 낮추기는 그대로)
    var auto = true
    /// 다시 만들 때: 자막 켜 둔 채로, 몇 번째로 다시 만든 것인지 (값이 달라야 플레이어가 새로 만들어짐)
    var subtitlesOn = false
    var attempt = 0
    /// 쇼츠 모드로 연 쇼츠 (세로 창, ↑↓로 넘기기)
    var shorts: Bool? = nil
    var isShorts: Bool { shorts == true }
}

/// 지금 재생 창에 띄울 영상 (재생 창은 하나뿐이라 앱 전체에서 하나만 가짐)
@MainActor
final class PlayerHub: ObservableObject {
    static let shared = PlayerHub()
    @Published var item: PlayerItem?
    /// 영상 회전 각도 (0·90·180·270, 시계 방향). 화질을 바꿔도 그대로, 다른 영상을 열면 0으로
    @Published var rotation = 0

    func rotate() {
        rotation = (rotation + 90) % 360
        DebugLog.write("영상 회전: \(rotation)도")
    }

    /// 지금 영상의 원래 크기 (고른 화질 파일의 가로×세로). HLS처럼 모르면 nil → 화면에 나오는 크기로
    var videoSize: CGSize?

    enum WindowScale { case actual, half, quarter, width1920 }

    /// 1·2·3 키: 재생 창을 영상 1배 / 0.5배 / 가로 1920 (세로는 비율대로) 크기로
    /// 화면보다 크면 비율 그대로 화면에 맞추고, 지금 창 가운데를 기준으로 바꿈. 돌려 놓았으면 돌린 방향 기준
    func resizeWindow(_ window: NSWindow, scale: WindowScale, fallback: CGSize) {
        var size = videoSize ?? fallback
        guard size.width > 0, size.height > 0 else { return }
        if rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        switch scale {
        case .actual: break
        case .half: size = CGSize(width: size.width / 2, height: size.height / 2)
        case .quarter: size = CGSize(width: size.width / 4, height: size.height / 4)
        case .width1920: size = CGSize(width: 1920, height: (1920 * size.height / size.width).rounded())
        }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }   // 전체 화면이면 먼저 빠져나옴

        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let fit = min(1, screen.width / size.width, screen.height / size.height)
        let target = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        // 지금 창 가운데 기준, 화면 밖으로 나가지 않게
        var origin = CGPoint(x: window.frame.midX - target.width / 2, y: window.frame.midY - target.height / 2)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - target.width)
        origin.y = min(max(origin.y, screen.minY), screen.maxY - target.height)
        window.setFrame(NSRect(origin: origin, size: target), display: true, animate: true)

        let name = switch scale { case .actual: "1배"; case .half: "0.5배"; case .quarter: "0.25배"; case .width1920: "가로 1920" }
        let note = fit < 1 ? " (화면에 맞춰 줄임)" : ""
        DebugLog.write("창 크기 \(name): \(Int(target.width))×\(Int(target.height))\(note)")
        Toast.shared.show("창 크기 \(name) — \(Int(target.width))×\(Int(target.height))\(note)", seconds: 2)
    }
}

/// 재생 창 하나를 직접 만들고 닫음
/// - 열기: 창이 있으면 영상만 바꾸고 앞으로, 없으면 새로 만듦
/// - 닫기(Esc·빨간 단추·⌘W 모두): 영상을 비워 재생·자막을 멈추고 창을 완전히 버림 → 다음 재생은 늘 새 창
@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    static let shared = PlayerWindowController()
    private var window: NSWindow?
    /// 지금 재생 창 (위쪽 막대 크기 단추용)
    var playerWindow: NSWindow? { window }

    func open(_ item: PlayerItem) {
        if PlayerHub.shared.item?.id != item.id { PlayerHub.shared.rotation = 0 }   // 다른 영상이면 회전 처음대로
        let wasShorts = PlayerHub.shared.item?.isShorts == true
        PlayerHub.shared.item = item
        if let window {
            // 쇼츠 ↔ 일반 영상이 바뀌면 창 모양도 바꿈 (쇼츠는 세로로 긴 창)
            if item.isShorts != wasShorts { shape(window, shorts: item.isShorts) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let hosting = NSHostingController(rootView: PlayerRoot().themed())
        hosting.sizingOptions = []   // 창 크기는 사용자가 정한 대로 (영상 바뀔 때 크기가 튀지 않게)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.delegate = self
        window.setContentSize(NSSize(width: 1280, height: 720))
        // 지난번 위치·크기 기억 (처음이면 화면 가운데)
        self.window = window
        shape(window, shorts: item.isShorts)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DebugLog.write("재생 창 새로 만듦")
    }

    /// 창 모양: 일반 영상은 지난번 위치·크기, 쇼츠는 화면 높이의 88% 세로 창 (각각 따로 기억)
    private func shape(_ window: NSWindow, shorts: Bool) {
        let name = shorts ? "MyTubeShorts" : "MyTubePlayer"
        window.setFrameAutosaveName("")
        if !window.setFrameUsingName(name) {
            if shorts, let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
                let height = (screen.height * 0.88).rounded()
                let width = (height * 9 / 16).rounded()
                window.setFrame(NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height), display: true)
            } else {
                window.setContentSize(NSSize(width: 1280, height: 720))
                window.center()
            }
        }
        // 쇼츠는 9:16 비율 고정, 일반 영상은 비율 풀기 (비율과 크기 단위는 서로 하나만 적용돼서, 단위를 1로 주면 비율이 풀림)
        if shorts {
            window.contentAspectRatio = NSSize(width: 9, height: 16)
        } else {
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
        }
        window.setFrameAutosaveName(name)
    }

    /// 영상이 끝나면 재생 창을 닫음 (Esc와 같음: 재생 멈추고 창 정리)
    func closePlayer() {
        window?.close()
    }

    /// "채널로 가기": 기본 창을 앞으로 가져와 그 채널의 영상 목록을 엶 (재생 창은 그대로)
    func showChannel(_ channel: CollectionRef) {
        let feeds = FeedStore.shared
        feeds.openInNewTab(channel)   // 보던 탭은 그대로 두고 새 탭으로
        DebugLog.write("채널로 가기: \(channel.title) \(channel.id)")
        // 재생 창이 아닌 보이는 창 = 기본 창
        if let main = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeMain }) {
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }   // 전체 화면이면 먼저 빠져나옴
            main.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            Toast.shared.show("기본 창이 닫혀 있어요. 메뉴 Window → MyTube로 열어 주세요.", error: true, seconds: 5)
        }
    }

    // MARK: 화질

    /// 영상마다 화질별 주소 (5시간 안이면 다시 묻지 않음, 유튜브 주소는 6시간 동안 쓸 수 있음)
    private var infos: [String: StreamCache.Entry] = StreamCache.load()
    /// 받는 중인 것 (마우스 올려 미리 받는 중에 누르면 같은 작업을 기다림 → yt-dlp를 두 번 돌리지 않음)
    private var pending: [String: Task<YTDLP.StreamInfo, Error>] = [:]
    private var hlsURLs: [String: (url: URL, at: Date)] = [:]
    private var pendingHLS: [String: Task<URL, Error>] = [:]
    /// 영상마다 멈췄던 화질과 시각: 10분 동안은 그 화질로 다시 올리지 않음
    private var badLevels: [String: [QualityLevel: Date]] = [:]
    /// 영상마다 최근 멈춤 시각 (2분 안에 너무 자주면 그만)
    private var stalls: [String: [Date]] = [:]

    func streamInfo(for id: String, pageURL: URL, cookies: [HTTPCookie]) async throws -> YTDLP.StreamInfo {
        if let cached = infos[id], Date().timeIntervalSince(cached.at) < 5 * 3600 { return cached.info }
        if let running = pending[id] { return try await running.value }
        let job = Task { try await YTDLP.streamInfo(pageURL, cookies: cookies) }
        pending[id] = job
        defer { pending[id] = nil }
        let info = try await job.value
        infos[id] = StreamCache.Entry(info: info, at: Date())
        StreamCache.save(infos)
        return info
    }

    /// 목록에서 마우스를 올리면: 주소를 미리 받고, 처음 틀 화질의 파일 색인까지 미리 읽어 둠 (누르면 바로 재생)
    func prefetch(id: String, pageURL: URL) {
        Task {
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            guard let info = try? await streamInfo(for: id, pageURL: pageURL, cookies: cookies) else { return }
            let levels = info.levels
            let first = startLevel(for: id, levels: levels)
            // 라이브처럼 HLS로 틀 영상은 HLS 주소까지 미리
            if first == nil || first == .hls {
                if info.streams.isEmpty, info.manifest != nil { return }   // 라이브: 이미 HLS 주소가 있음
                _ = try? await hlsURL(for: id, pageURL: pageURL)
                return
            }
            guard let first, case .direct(let height) = first, let stream = info.stream(for: height), let audio = info.audio else { return }
            LocalHLS.shared.prefetch([stream.url, audio])
        }
    }

    func hlsURL(for id: String, pageURL: URL) async throws -> URL {
        if let cached = hlsURLs[id], Date().timeIntervalSince(cached.at) < 5 * 3600 { return cached.url }
        if let running = pendingHLS[id] { return try await running.value }
        let job = Task { try await YTDLP.hlsManifest(pageURL).url }
        pendingHLS[id] = job
        defer { pendingHLS[id] = nil }
        let url = try await job.value
        hlsURLs[id] = (url, Date())
        return url
    }

    /// 주소가 만료됐거나 거절될 때: 다음엔 새로 받게
    func forgetStreams(for id: String) {
        infos[id] = nil
        StreamCache.save(infos)
        hlsURLs[id] = nil
    }

    private func isBad(_ level: QualityLevel, _ id: String) -> Bool {
        guard let at = badLevels[id]?[level] else { return false }
        return Date().timeIntervalSince(at) < 600
    }

    /// 자동일 때 처음 고를 화질: 가장 높은 것부터, 최근 멈췄던 화질은 건너뜀
    func startLevel(for id: String, levels: [QualityLevel]) -> QualityLevel? {
        levels.first { !isBad($0, id) } ?? levels.last
    }

    /// 빨리 시작할 화질: 가장 좋은 화질이 1080p보다 높으면 우선 1080p 이하 중 가장 높은 것으로 틀고 (4K 파일은 앞부분 읽기가 느림)
    /// 몇 초 뒤 가장 좋은 화질로 바꿈. 가장 좋은 화질이 1080p 이하면 nil (바로 그 화질로)
    func quickLevel(for id: String, levels: [QualityLevel]) -> QualityLevel? {
        guard let best = startLevel(for: id, levels: levels), case .direct(let top) = best, top > 1080 else { return nil }
        return levels.first {
            if case .direct(let h) = $0, h <= 1080, !isBad($0, id) { return true }
            return false
        }
    }

    /// 실시간 자막을 켜려고 같은 화질·위치에서 다시 열기 (자막 켠 채로)
    func reopenForSubtitles(_ item: PlayerItem, level: QualityLevel, at seconds: Double) {
        DebugLog.write("자막 켜기: 소리를 받으려고 파일 합치기 방식으로 다시 열기")
        reload(item, level: level, auto: item.auto, at: seconds, subtitlesOn: true)
    }

    /// 같은 위치에서 다른 화질로 다시 만들기 (값이 바뀌면 PlayerView가 통째로 새로 만들어짐)
    private func reload(_ item: PlayerItem, level: QualityLevel, auto: Bool, at seconds: Double, subtitlesOn: Bool) {
        var next = item
        next.startAt = max(seconds, 1.5)
        next.level = level
        next.auto = auto
        next.subtitlesOn = subtitlesOn
        next.attempt = item.attempt + 1
        PlayerHub.shared.item = next
    }

    /// 화면이 멈췄을 때: 한 단계 낮은 화질로 같은 위치부터 (그 화질은 10분 동안 다시 안 올림)
    func stepDown(_ item: PlayerItem, from current: QualityLevel, levels: [QualityLevel], at seconds: Double, subtitlesOn: Bool) {
        guard window != nil, PlayerHub.shared.item?.id == item.id else { return }
        let recent = (stalls[item.id] ?? []).filter { Date().timeIntervalSince($0) < 120 } + [Date()]
        stalls[item.id] = recent
        badLevels[item.id, default: [:]][current] = Date()
        guard recent.count <= 5 else {
            DebugLog.write("화면 멈춤: 2분 안에 너무 자주 → 그만")
            Toast.shared.show("화면이 계속 멈춰요. 창을 닫고 다시 열어 보세요.", error: true, seconds: 6)
            return
        }
        let index = levels.firstIndex(of: current) ?? -1
        guard let lower = levels.dropFirst(index + 1).first else {
            // 가장 낮은 화질에서도 멈춤: 주소를 새로 받아 같은 화질로 한 번 더
            forgetStreams(for: item.id)
            DebugLog.write("화면 멈춤 (가장 낮은 \(current.label)) → 주소 새로 받아 다시")
            reload(item, level: current, auto: item.auto, at: seconds, subtitlesOn: subtitlesOn)
            return
        }
        DebugLog.write("화면 멈춤 (\(current.label), \(safeInt(seconds))초) → \(lower.label)로 낮춤")
        Toast.shared.show("화면이 멈춰서 \(lower.label)로 낮췄어요", seconds: 3)
        reload(item, level: lower, auto: item.auto, at: seconds, subtitlesOn: subtitlesOn)
    }

    /// 자동일 때 2분 동안 잘 나오면: 한 단계 높은 화질로 (최근 멈췄던 화질은 건너뜀)
    func stepUp(_ item: PlayerItem, from current: QualityLevel, levels: [QualityLevel], at seconds: Double, subtitlesOn: Bool) {
        guard item.auto, window != nil, PlayerHub.shared.item?.id == item.id,
              let index = levels.firstIndex(of: current), index > 0,
              let higher = levels[..<index].last(where: { !isBad($0, item.id) }) else { return }
        DebugLog.write("2분 동안 잘 나옴 (\(current.label)) → \(higher.label)로 올림")
        Toast.shared.show("화질을 \(higher.label)로 올렸어요", seconds: 3)
        reload(item, level: higher, auto: true, at: seconds, subtitlesOn: subtitlesOn)
    }

    /// 위쪽 막대에서 화질을 고를 때 (nil = 자동)
    func choose(_ item: PlayerItem, level: QualityLevel?, levels: [QualityLevel], at seconds: Double, subtitlesOn: Bool) {
        if let level {
            badLevels[item.id]?[level] = nil   // 직접 고른 화질은 다시 시도
            DebugLog.write("화질 직접 선택: \(level.label)")
            reload(item, level: level, auto: false, at: seconds, subtitlesOn: subtitlesOn)
        } else {
            let best = startLevel(for: item.id, levels: levels) ?? .hls
            DebugLog.write("화질 자동으로 (\(best.label)부터)")
            reload(item, level: best, auto: true, at: seconds, subtitlesOn: subtitlesOn)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
        PlayerHub.shared.item = nil   // PlayerView가 사라지며 재생·자막 멈춤
        PlayerPanel.shared.mode = nil
        DispatchQueue.main.async { closing.contentViewController = nil }
        DebugLog.write("재생 창 닫음")
    }
}

/// 재생 창의 바탕: 영상이 바뀌면 PlayerView를 새로 만들어 이전 영상·자막을 멈추고 새 영상을 재생
struct PlayerRoot: View {
    @ObservedObject private var hub = PlayerHub.shared

    var body: some View {
        if let item = hub.item {
            PlayerView(item: item)
                .id(item)
        } else {
            // 창을 닫는 중 (영상을 비워서 PlayerView가 사라지며 재생·자막이 멈춤)
            Color.black
                .frame(minWidth: 640, minHeight: 380)
                .ignoresSafeArea()
        }
    }
}

/// 재생 창: 4K까지 최고 화질을 찾아 macOS 기본 플레이어로 자동 재생
struct PlayerView: View {
    let item: PlayerItem
    @StateObject private var loader = PlayerLoader()
    @StateObject private var subtitles = SubtitleEngine()
    @StateObject private var builder = SubtitleBuilder()
    @StateObject private var fullScreen = FullScreenState()
    @StateObject private var pin = WindowPin()
    @StateObject private var downloadPopover = PopoverState()
    @StateObject private var chrome = PlayerChrome()
    /// 플레이어 안 오른쪽 판 (댓글·질문하기·다운로드) — 창 밖으로 나가는 팝업 대신
    @ObservedObject private var panel = PlayerPanel.shared
    /// 유튜브 정보·행동 (좋아요·댓글·설명·저장)
    @StateObject private var videoPage: VideoPage

    init(item: PlayerItem) {
        self.item = item
        _videoPage = StateObject(wrappedValue: VideoPage(videoID: item.id))
    }
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var hub = PlayerHub.shared

    var body: some View {
        content
            // 쇼츠는 세로로 좁은 창(9:16)이라 최소 너비를 작게
            .frame(minWidth: item.isShorts ? 300 : 640, minHeight: 380)
            .background(.black)
            // 제목 막대 없이 영상이 창 끝까지 차게 (위쪽 막대는 마우스를 올릴 때만 영상 위에 뜸)
            .ignoresSafeArea()
            .background(WindowReader { fullScreen.attach($0); pin.attach($0); chrome.attach($0) })
            // 창 제목은 Window 메뉴·미션 컨트롤용으로만 (제목 막대에 검은 글자로 그려지지 않게 navigationTitle은 안 씀)
            .onChange(of: displayTitle, initial: true) { _, title in chrome.setTitle(title) }
            // 오른쪽 판: 플레이어 오른쪽 끝에 붙어 위아래로 꽉 참, 뒤 영상이 흐리게 비치는 유리
            .overlay(alignment: .trailing) {
                if let mode = panel.mode { sidePanel(mode) }
            }
            .animation(.easeOut(duration: 0.22), value: panel.mode)
            .overlay(alignment: .top) { topChrome.ignoresSafeArea() }
            // 쇼츠: 오른쪽에 이전·다음 단추와 몇 번째인지
            .overlay(alignment: .trailing) { if item.isShorts { ShortsSideBar() } }
            .overlay(alignment: .bottom) { ToastView() }
            // 팝업(댓글·AI·다운로드)이 열려 있는 동안은 위쪽 막대를 숨기지 않음
            // 오른쪽 판이 열려 있는 동안은 위쪽 막대를 숨기지 않음
            .onChange(of: panel.mode != nil) { _, open in
                chrome.keepOpen = open
                if !open { chrome.hideSoon() }
            }
            .task {
                videoPage.load()   // 좋아요 상태·개수, 댓글 수 등
                // 화면이 멈추면 이 플레이어를 버리고 같은 위치에서 새 플레이어로 (자막 켜 둔 것도 그대로)
                // 멈추면 한 단계 낮춰서, 2분 동안 잘 나오면 한 단계 올려서 같은 위치부터 새 플레이어로 (자막 켜 둔 것도 그대로)
                loader.onStall = { at in
                    guard let level = loader.level else { return }
                    PlayerWindowController.shared.stepDown(item, from: level, levels: loader.levels, at: at, subtitlesOn: subtitles.isOn)
                }
                loader.onStable = { at in
                    guard let level = loader.level else { return }
                    PlayerWindowController.shared.stepUp(item, from: level, levels: loader.levels, at: at, subtitlesOn: subtitles.isOn)
                }
                // 1080p → 4K로 바꿀 때 실시간 자막은 새 항목에 다시 걸기 (미리 만든 자막은 시간만 보니 그대로)
                loader.onItemReplaced = { newItem in
                    guard subtitles.isOn, !subtitles.usingPrebuilt else { return }
                    subtitles.stop()
                    subtitles.start(item: newItem)
                }
                // 실시간 자막을 켤 영상은 소리를 직접 받아야 해서 예전 방법(파일 합치기)으로 (색인 HLS는 소리 트랙을 못 꺼냄)
                let liveSubtitles = (item.subtitlesOn || subtitles.autoOn) && SubtitleStore.load(item.id) == nil
                loader.start(item, needsAudioTap: liveSubtitles)
            }
            .onDisappear { loader.stop(); subtitles.stop() }
            // 재생이 시작되면 자막 자동으로 켜기 (메뉴에서 켤 수 있음, 기본은 꺼짐)
            .onReceive(loader.$mode) { mode in
                switch mode {
                case .native(let player):
                    if let saved = SubtitleStore.load(item.id) {
                        subtitles.showPrebuilt(saved, player: player)
                    } else if subtitles.autoOn || item.subtitlesOn, !subtitles.isOn, let current = player.currentItem {
                        subtitles.start(item: current)
                    }
                case .failed:
                    subtitles.stop()
                case .finding:
                    break
                }
            }
            // 자막 번역: 언어가 정해지면 번역 세션을 받아서 계속 번역
            .translationTask(subtitles.translationConfig) { session in
                await subtitles.runTranslation(session)
            }
            // 미리 만들기 번역: 받아쓰기가 끝나면 한꺼번에 번역
            .translationTask(builder.translationConfig) { session in
                await builder.translateAll(session)
            }
            .overlay(alignment: .topLeading) { builderStatus.padding(.top, 40) }
    }

    private var displayTitle: String { loader.title.isEmpty ? item.title : loader.title }

    /// 창 위쪽 영역: 마우스가 들어오면 떠 있는 판을 보여 주고, 나가면 잠시 뒤 숨김
    private var topChrome: some View {
        VStack(spacing: 0) {
            chromeBar
                .opacity(chrome.isShown ? 1 : 0)
                .offset(y: chrome.isShown ? 0 : -10)
                .allowsHitTesting(chrome.isShown)
            Spacer(minLength: 0)
        }
        .frame(height: 80)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chrome.setWidth($0) }
        .onContinuousHover { phase in
            switch phase {
            case .active: chrome.hover(true)
            case .ended: chrome.hover(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: chrome.isShown)
    }

    /// 맥 기본 플레이어의 조작 막대처럼: 가장자리에서 떠 있는 둥근 어두운 반투명 판 + 흰 아이콘
    private var chromeBar: some View {
        // 창이 좁으면 단추 사이를 좁히고 덜 중요한 글자를 숨겨 제목 자리를 남김
        HStack(spacing: chrome.compact == 0 ? 16 : 11) {
            WindowLights(chrome: chrome)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !loader.subtitle.isEmpty, chrome.compact < 2 {
                    Text(loader.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 8)

            // 채널로 가기: 기본 창에서 이 영상 채널의 영상 목록을 엶 (재생은 그대로)
            if let channel = loader.channel {
                Button {
                    PlayerWindowController.shared.showChannel(channel)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.crop.circle")
                        if chrome.compact == 0 {
                            Text(channel.title).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(maxWidth: 200)
                    .frame(height: 22)
                    .background(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1.2))
                    .contentShape(Capsule())
                    // 좁아서 아이콘만 있을 때는 아이콘 크기만큼만
                    .fixedSize(horizontal: chrome.compact > 0, vertical: true)
                }
                .help("\(channel.title) 채널의 영상 보기 (기본 창에서)")
            }

            // 화질 고르기: 자동(멈추면 낮추고 안정되면 올림) 또는 고정
            if !loader.levels.isEmpty {
                Menu {
                    // 메뉴 앞의 ✓ = 지금 설정
                    Button((item.auto ? "✓ " : "    ") + "자동 (가장 높은 화질부터, 멈추면 낮추고 안정되면 올림)") { changeQuality(nil) }
                    Divider()
                    ForEach(loader.levels, id: \.self) { level in
                        Button((!item.auto && loader.level == level ? "✓ " : "    ") + level.label
                               + (item.auto && loader.level == level ? "  (지금)" : "")) { changeQuality(level) }
                    }
                } label: {
                    Text(loader.level?.label ?? "화질")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1.2))
                        .contentShape(Capsule())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(item.auto ? "화질: 자동 (지금 \(loader.level?.label ?? "-"))" : "화질: \(loader.level?.label ?? "-") 고정")
            }

            // 재생 속도 (채널마다 기억)
            if case .native = loader.mode {
                SpeedMenu { rate in
                    Text(PlaybackSpeed.label(rate))
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1.2))
                        .contentShape(Capsule())
                }
                .menuStyle(.button)
            }

            // 유튜브와 같은 행동 줄: 좋아요 · 싫어요 · 댓글 · 공유 · ✦ 질문하기 · 듣기 · 더보기
            Button { videoPage.toggleLike() } label: {
                HStack(spacing: 4) {
                    Image(systemName: videoPage.status == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                    if chrome.compact == 0, let count = videoPage.likeCount {
                        Text(count).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                }
            }
            .help(videoPage.status == .like ? "좋아요 취소" : "좋아요 (유튜브 계정에 반영)")

            Button { videoPage.toggleDislike() } label: {
                Image(systemName: videoPage.status == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            .help(videoPage.status == .dislike ? "싫어요 취소" : "싫어요 (유튜브 계정에 반영)")

            Button { panel.toggle(.comments) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble")
                    if chrome.compact == 0, let count = videoPage.commentCount {
                        Text(count).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                }
            }
            .help("댓글·설명·채널 정보")

            Menu {
                Button("링크 복사") { videoPage.copyLink() }
                Button("지금 위치부터 보는 링크 복사") { videoPage.copyLink(at: currentSeconds) }
                if let url = URL(string: videoPage.link) {
                    ShareLink("다른 앱으로 공유…", item: url)
                }
            } label: {
                Image(systemName: "arrowshape.turn.up.right").frame(width: 24, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("공유")

            Button { panel.toggle(.ai) } label: { Image(systemName: "sparkle") }
                .help("이 동영상에 대해 물어보기 · AI 요약")

            Button { switchToListen() } label: { Image(systemName: "headphones") }
                .help("같은 위치에서 소리만 듣기 (듣기 창으로)")

            // 자막 켜기·끄기 (켜지면 채워진 아이콘 + 밝은 동그라미) + 옆의 ▾ 자막 설정
            Button { toggleSubtitles() } label: {
                ToggleIcon(systemName: subtitles.isOn ? "captions.bubble.fill" : "captions.bubble", isOn: subtitles.isOn)
            }
            .help(subtitles.isOn ? "자막 켜짐 — 누르면 끄기" : "자막 꺼짐 — 누르면 한국어 자막 켜기")
            Menu {
                // 미리 만들기: 영상 전체를 한 번에 받아쓰고 번역해서 저장 (말과 정확히 맞는 자막)
                if builder.isWorking {
                    Button("자막 만들기 취소") { builder.cancel() }
                } else if SubtitleStore.load(item.id) != nil {
                    Text("미리 만든 자막이 있어요")
                    Button("자막 다시 만들기") { SubtitleStore.delete(item.id); subtitles.stop(); buildSubtitles() }
                    Button("만든 자막 지우기") { SubtitleStore.delete(item.id); subtitles.stop() }
                    Button("자막 파일(SRT) Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([SubtitleStore.srtURL(item.id)])
                    }
                } else {
                    Button("자막 미리 만들기 (정확한 자막)") { buildSubtitles() }
                }
                Divider()
                Toggle("영상 열 때 자막 자동으로 켜기", isOn: $subtitles.autoOn)
                Toggle("원문도 같이 보기", isOn: $subtitles.showOriginal)
                // 꺼져 있으면 자막을 켜면서 언어 찾기 시작
                Button(subtitles.isOn ? "언어 다시 찾기" : "자막 켜고 언어 찾기") {
                    if subtitles.isOn { subtitles.restart() } else { toggleSubtitles() }
                }
                Divider()
                Picker("자막 크기", selection: $subtitles.fontSize) {
                    ForEach(SubtitleEngine.fontSizes, id: \.size) { option in
                        Text("\(option.label) (\(Int(option.size)))").tag(option.size)
                    }
                    // 단축키로 바꾼 크기가 목록에 없을 때도 표시
                    if !SubtitleEngine.fontSizes.contains(where: { $0.size == subtitles.fontSize }) {
                        Text("사용자 지정 (\(Int(subtitles.fontSize)))").tag(subtitles.fontSize)
                    }
                }
                Picker("자막 위치", selection: $subtitles.position) {
                    ForEach(SubtitleEngine.positions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                    if !SubtitleEngine.positions.contains(where: { $0.value == subtitles.position }) {
                        Text("사용자 지정 (\(Int(subtitles.position * 100))%)").tag(subtitles.position)
                    }
                }
                Button("자막 위로") { subtitles.moveUp() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("자막 아래로") { subtitles.moveDown() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("자막 크게") { subtitles.biggerFont() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("자막 작게") { subtitles.smallerFont() }
                    .keyboardShortcut("-", modifiers: .command)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.leading, -10)
            .help("자막 설정 (원문 같이 보기·크기·위치·미리 만들기)")

            // 더보기: 챕터·저장·다운로드·창 크기·회전·늘 위에·브라우저
            Menu {
                if !NowPlaying.shared.chapters.isEmpty {
                    Menu("챕터로 이동") {
                        ForEach(Array(NowPlaying.shared.chapters.enumerated()), id: \.offset) { _, chapter in
                            Button("\(PlaybackMemory.timeText(chapter.start))  \(chapter.title)") { NowPlaying.shared.seek(to: chapter.start) }
                        }
                    }
                }
                Divider()
                Button("나중에 볼 동영상에 저장") { videoPage.saveToWatchLater() }
                Button("대기열에서 다음 영상") { NowPlaying.shared.next() }
                    .disabled(PlayQueue.shared.entries.isEmpty)
                Menu("다운로드") {
                    Button("최고 화질 (4K까지, mp4)") { downloadThis() }
                    Button("소리만 (m4a)") { downloadThis(audioOnly: true) }
                }
                Divider()
                Menu("창 크기") {
                    Button("영상 1배 (1)") { resizeWindow(.actual) }
                    Button("영상 0.5배 (2)") { resizeWindow(.half) }
                    Button("가로 1920 (3)") { resizeWindow(.width1920) }
                    Button("영상 0.25배 (4)") { resizeWindow(.quarter) }
                }
                Button(hub.rotation == 0 ? "화면 90도 돌리기 (R)" : "화면 90도 더 돌리기 (지금 \(hub.rotation)도, R)") { hub.rotate() }
                Toggle("다른 창 위에 늘 띄우기", isOn: $pin.isOn)
                Divider()
                Button("유튜브에서 열기 (브라우저)") { NSWorkspace.shared.open(URL(string: item.url)!) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("더보기")
        }
        .buttonStyle(.plain)
        .font(.system(size: 16))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 16)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        // 영상이 잘 비치도록 옅은 유리: 가장 얇은 흐림을 반만 깔고 검은 칠은 하지 않음
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.5)
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .environment(\.colorScheme, .dark)
        // 밝은 영상 위에서도 글자·아이콘이 보이게 그림자는 글자 쪽에 살짝
        .shadow(color: .black.opacity(0.35), radius: 3)
        // 판의 빈 곳을 끌면 창이 움직임 (제목 막대가 없어서)
        .gesture(WindowDragGesture())
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    /// 위쪽 막대 크기 단추: 키보드 1·2·3과 같은 창 크기 바꾸기
    private func resizeWindow(_ scale: PlayerHub.WindowScale) {
        guard let window = PlayerWindowController.shared.playerWindow else { return }
        var shown = CGSize.zero
        if case .native(let player) = loader.mode { shown = player.currentItem?.presentationSize ?? .zero }
        hub.resizeWindow(window, scale: scale, fallback: shown)
    }

    /// 위쪽 막대 화질 메뉴에서 고를 때 (nil = 자동): 지금 위치부터 그 화질로
    private func changeQuality(_ level: QualityLevel?) {
        guard case .native(let player) = loader.mode else { return }
        PlayerWindowController.shared.choose(item, level: level, levels: loader.levels,
                                             at: player.currentTime().seconds, subtitlesOn: subtitles.isOn)
    }

    private var isDownloadingThis: Bool {
        downloads.jobs.contains { $0.isActive && YTDLP.videoID(from: $0.pageURL) == item.id }
    }

    /// 이 영상 다운로드 시작 + 목록 열기 (이미 받는 중이면 목록만)
    private func downloadThis(audioOnly: Bool = false) {
        panel.mode = .downloads
        guard let url = URL(string: item.url) else { return }
        let title = loader.title.isEmpty ? item.title : loader.title
        Task {
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            DownloadManager.shared.start(pageURL: url, title: title, cookies: cookies, audioOnly: audioOnly)
        }
    }

    /// 플레이어 오른쪽에 붙은 판 (위아래 꽉 참, 어두운 유리)
    private func sidePanel(_ mode: PlayerPanel.Mode) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(mode.title, systemImage: mode.icon)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { panel.mode = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("닫기 (Esc)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider().opacity(0.4)
            Group {
                switch mode {
                case .comments:
                    VideoInfoPanel(page: videoPage)
                case .ai:
                    AIPanel(videoID: item.id, title: displayTitle, captionURL: loader.captionURL)
                case .downloads:
                    ScrollView { DownloadsPanel(canDownload: true) { downloadThis() } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        // 떠 있는 유리 카드: 가장 얇은 흐림 + 아주 옅은 어둠(위는 조금 진하게 → 아래로 옅게) + 빛 테두리
        .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(LinearGradient(colors: [.black.opacity(0.32), .black.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 22, y: 8)
        // 영상은 그대로 두고 오른쪽 위에 떠 있음 (위쪽 막대 아래 ~ 창 아래 여백)
        .padding(.top, 64)
        .padding(.bottom, 16)
        .padding(.trailing, 14)
        .environment(\.colorScheme, .dark)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// 지금 재생 위치 (초)
    private var currentSeconds: Double {
        if case .native(let player) = loader.mode { return player.currentTime().seconds }
        return 0
    }

    private func toggleSubtitles() {
        if subtitles.isOn { subtitles.stop(); return }
        guard case .native(let player) = loader.mode, let current = player.currentItem else {
            Toast.shared.show("영상이 재생된 뒤에 자막을 켤 수 있어요.", error: true)
            return
        }
        if let saved = SubtitleStore.load(item.id) {
            subtitles.showPrebuilt(saved, player: player)
        } else if !(current.asset is AVComposition), let level = loader.level, case .direct = level {
            // 색인 HLS로 재생 중이면 소리를 받을 수 없어서, 같은 위치에서 파일 합치기 방식으로 다시 열고 자막 켜기
            PlayerWindowController.shared.reopenForSubtitles(item, level: level, at: player.currentTime().seconds)
        } else {
            subtitles.start(item: current)
        }
    }

    /// 같은 위치에서 듣기 모드로 (재생 창은 닫히고 듣기 창이 뜸)
    private func switchToListen() {
        guard case .native(let player) = loader.mode else { return }
        var next = item
        next.startAt = max(player.currentTime().seconds, 1.5)
        next.level = nil
        Playback.open(next, listen: true)
    }

    /// 자막 미리 만들기 시작 (끝나면 바로 그 자막으로 바꿈)
    private func buildSubtitles() {
        builder.start(item) { saved in
            if case .native(let player) = loader.mode { subtitles.showPrebuilt(saved, player: player) }
        }
    }

    /// 왼쪽 위 진행 표시
    @ViewBuilder private var builderStatus: some View {
        switch builder.state {
        case .working(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("자막 만드는 중: \(message)").font(.caption)
                Button("취소") { builder.cancel() }.buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
            .padding(10)
        case .failed(let message):
            Text("자막 만들기 실패: \(message)").font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.red.opacity(0.7), in: Capsule())
                .foregroundStyle(.white)
                .padding(10)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch loader.mode {
        case .finding:
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text("최고 화질 찾는 중…").foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        case .native(let player):
            NativePlayerView(player: player, isTopBarShown: { chrome.isShown }, rotation: hub.rotation)
                .overlay { SubtitleOverlay(engine: subtitles) }
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("재생하지 못했어요").font(.headline)
                Text(message).font(.caption).multilineTextAlignment(.center).textSelection(.enabled)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
final class PlayerLoader: ObservableObject {
    enum Mode { case finding, native(AVPlayer), failed(String) }

    @Published private(set) var mode = Mode.finding
    @Published private(set) var title = ""
    @Published private(set) var subtitle = ""
    private var task: Task<Void, Never>?
    private var statusObserver: NSKeyValueObservation?
    /// 끝까지 재생됐는지 지켜보기 (끝나면 플레이어 닫기)
    private var endObserver: NSObjectProtocol?
    /// 이어 보기용: 5초마다 지금 위치를 저장
    private var positionObserver: Any?
    private var videoID = ""

    // 멈춤 감지: 소리·시간은 가는데 새 화면(프레임)이 4초 동안 안 나오면 onStall로 알림 (→ 플레이어를 통째로 새로 만듦)
    private var videoOutput: AVPlayerItemVideoOutput?
    private var healthTimer: Timer?
    private var staleSeconds = 0
    /// 멈춤(또는 처음부터 검은 화면)을 알아챘을 때: 그때 위치(초)
    var onStall: ((Double) -> Void)?
    /// 2분 동안 잘 나왔을 때(자동 화질 올리기용): 그때 위치(초)
    var onStable: ((Double) -> Void)?
    private var stableSeconds = 0
    /// 1080p로 먼저 틀었을 때 올릴 화질 (잘 나오기 시작하면 뒤에서 준비해 끊김 없이 바꿈)
    private var upgradeTarget: QualityLevel?
    private var upgradeTask: Task<Void, Never>?
    private var info: YTDLP.StreamInfo?
    /// AI 요약에 쓸 자막 주소
    var captionURL: URL? { info?.captionURL }
    /// 재생 중에 화질을 바꿔 플레이어 안의 항목이 새것이 됐을 때 (자막을 새 항목에 다시 걸기용)
    var onItemReplaced: ((AVPlayerItem) -> Void)?

    /// 이 영상의 화질 단계들과 지금 화질 (위쪽 막대 화질 메뉴용)
    @Published private(set) var levels: [QualityLevel] = []
    @Published private(set) var level: QualityLevel?
    /// 이 영상의 채널 (위쪽 막대 "채널로 가기"용)
    @Published private(set) var channel: CollectionRef?

    func start(_ item: PlayerItem, needsAudioTap: Bool = false) {
        guard task == nil, let pageURL = URL(string: item.url) else { return }
        task = Task {
            let began = Date()
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            // 유튜브가 가끔 주소를 한 번 거절(403)하므로, 실패하면 주소를 새로 받아 한 번 더 시도
            var lastError: Error?
            let windows = PlayerWindowController.shared
            for attempt in 1...2 {
                do {
                    // 화질별 주소를 한 번에 받아 두고(다음 화질 바꾸기는 바로), 고른 화질로 재생
                    let info = try await windows.streamInfo(for: item.id, pageURL: pageURL, cookies: cookies)
                    let levels = info.levels
                    let best = item.level ?? windows.startLevel(for: item.id, levels: levels) ?? .hls
                    var chosen = best
                    var quick: QualityLevel?
                    var method = "HLS"
                    let gotInfo = Date()
                    let playerItem: AVPlayerItem
                    switch best {
                    case .hls:
                        PlayerHub.shared.videoSize = nil   // HLS는 화질이 바뀌어서 화면에 나오는 크기로
                        // HLS: 맥 플레이어가 직접 다루는 방식이라 안정적 (H.264 최대 1080p)
                        // 라이브: 처음 받은 정보에 HLS 주소가 이미 있으면 그대로 (yt-dlp 한 번 덜 돌림)
                        // 그 밖: 로그인 없이 HLS 주소를 받고, 안 되면 처음 받은 주소로
                        let url: URL
                        if info.streams.isEmpty, let manifest = info.manifest {
                            url = manifest
                        } else {
                            do { url = try await windows.hlsURL(for: item.id, pageURL: pageURL) } catch {
                                guard let manifest = info.manifest else { throw error }
                                DebugLog.write("HLS 주소 받기 실패 → 처음 받은 HLS 주소로")
                                url = manifest
                            }
                        }
                        playerItem = AVPlayerItem(url: url)
                        playerItem.preferredMaximumResolution = CGSize(width: 3840, height: 2160)
                    case .direct(let height):
                        // 빠른 방법: 파일 색인으로 만든 HLS 재생목록 (4K도 첫 화면 0.3초 안팎, 길이도 정확)
                        if !needsAudioTap, let stream = info.stream(for: height), let audio = info.audio,
                           let fast = try? await LocalHLS.shared.item(video: stream.url, codec: stream.codec,
                                                                       width: stream.width, height: stream.height, audio: audio) {
                            playerItem = fast
                            method = "색인 HLS"
                            PlayerHub.shared.videoSize = CGSize(width: stream.width, height: stream.height)
                            break
                        }
                        // 색인이 없으면 예전 방법(파일을 통째로 열어 합침, 느림): 자동이면 1080p로 먼저 틀고 잘 나오면 올림
                        method = "파일 합치기"
                        quick = item.level == nil ? windows.quickLevel(for: item.id, levels: levels) : nil
                        chosen = quick ?? best
                        let start = if case .direct(let h) = chosen { h } else { height }
                        if let stream = info.stream(for: start), let audio = info.audio {
                            playerItem = try await Self.makeItem([stream.url, audio], duration: info.duration)
                            PlayerHub.shared.videoSize = CGSize(width: stream.width, height: stream.height)
                        } else if let combined = info.combined {
                            playerItem = try await Self.makeItem([combined, combined], duration: info.duration)
                        } else {
                            throw YTDLP.Failure.failed("\(chosen.label) 주소가 없어요.")
                        }
                    }
                    self.levels = levels
                    self.level = chosen
                    self.info = info
                    self.upgradeTarget = quick == nil ? nil : best
                    if let id = info.channelID {
                        self.channel = CollectionRef(kind: .channel, id: id, title: info.channelName ?? "채널")
                    }
                    let video = YTDLP.Video(title: info.title, quality: chosen.label, urls: [])
                    guard !Task.isCancelled else { return }
                    let player = AVPlayer(playerItem: playerItem)
                    // 시작 위치: 웹에서 보던 위치 → 없으면 지난번에 이 앱에서 보다 멈춘 위치
                    let resume = item.startAt > 1 ? 0 : (PlaybackMemory.position(for: item.id) ?? 0)
                    let startAt = item.startAt > 1 ? item.startAt : resume
                    if startAt > 1 {
                        await player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600),
                                          toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    watch(playerItem, id: item.id)
                    remember(player, id: item.id)
                    startHealthCheck(player)
                    title = video.title
                    let how = item.auto ? "자동" : "고정"
                    subtitle = resume > 1 ? "\(video.quality) · \(how) · \(PlaybackMemory.timeText(resume))부터 이어서"
                        : "\(video.quality) · \(how)"
                    mode = .native(player)
                    // 미디어 키·제어 센터·메뉴 막대·재생 속도(채널마다)·광고 건너뛰기·시청 시간
                    NowPlaying.shared.attach(player, id: item.id, title: video.title, channel: info.channelName ?? "",
                                             channelID: info.channelID, duration: info.duration,
                                             chapters: info.chapters ?? [], source: .video)
                    player.play()
                    DebugLog.write(String(format: "재생 준비 시간: 주소 %.1f초 + 파일 %.1f초 (%@)", gotInfo.timeIntervalSince(began), Date().timeIntervalSince(gotInfo), method)
                        + (quick != nil ? " (\(chosen.label)로 먼저, \(best.label)로 올릴 예정)" : ""))
                    DebugLog.write("기본 플레이어로 재생: \(video.title) \(video.quality) (\(safeInt(startAt))초부터\(resume > 1 ? ", 이어서" : ""), "
                        + "길이 \(safeInt(((try? await playerItem.asset.load(.duration)) ?? .zero).seconds))초 / 실제 \(safeInt(info.duration ?? -1))초)")
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    lastError = error
                    windows.forgetStreams(for: item.id)   // 주소가 거절됐을 수 있으니 다음엔 새로
                    DebugLog.write("재생 준비 실패 (\(attempt)번째, \(item.id) \(item.title)): \(error.localizedDescription)")
                }
            }
            mode = .failed(lastError?.localizedDescription ?? "알 수 없는 오류")
            subtitle = ""
        }
    }

    /// 영상·소리 주소가 따로 오면 하나로 합침
    /// duration: 실제 길이(초). 맥 플레이어가 유튜브 파일 길이를 2배로 잘못 읽어서(3분 영상을 6분으로)
    /// 끝난 뒤에도 계속 재생되는 것처럼 보이다 멈추던 문제 → 실제 길이로 자름
    private static func makeItem(_ urls: [URL], duration: Double?) async throws -> AVPlayerItem {
        guard urls.count >= 2 else { return AVPlayerItem(url: urls[0]) }

        let videoAsset = AVURLAsset(url: urls[0])
        let audioAsset = AVURLAsset(url: urls[1])
        async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
        async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
        async let videoDuration = videoAsset.load(.duration)
        async let audioDuration = audioAsset.load(.duration)

        guard let videoTrack = try await videoTracks.first,
              let audioTrack = try await audioTracks.first else {
            throw YTDLP.Failure.failed("영상 또는 소리 트랙이 없어요.")
        }
        var length = try await min(videoDuration, audioDuration)
        if let duration, duration > 0 {
            length = min(length, CMTime(seconds: duration, preferredTimescale: 600))
        }
        let range = CMTimeRange(start: .zero, duration: length)

        let composition = AVMutableComposition()
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: audioTrack, at: .zero)
        return AVPlayerItem(asset: composition)
    }

    /// 재생 항목 지켜보기: 실패·끝까지 재생·새 화면(멈춤 감지)
    private func watch(_ playerItem: AVPlayerItem, id: String) {
        watchForFailure(playerItem)
        // 끝까지 다 보면 플레이어를 알아서 닫음
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { _ in
            MainActor.assumeIsolated {
                PlaybackMemory.forget(id)   // 다 본 영상은 다음에 처음부터
                // 쇼츠: 다음 쇼츠로
                if PlayerHub.shared.item?.isShorts == true {
                    WatchMarks.shared.markWatched(id)
                    ShortsMode.shared.next()
                    return
                }
                // 대기열에 다음 영상이 있으면 이어서, 없으면 플레이어 닫음
                if !Playback.finished(id, listen: false) {
                    DebugLog.write("영상 끝까지 재생 → 플레이어 닫음")
                    PlayerWindowController.shared.closePlayer()
                }
            }
        }
        attachVideoOutput(to: playerItem)
    }

    /// 1080p로 먼저 튼 뒤: 가장 좋은 화질 항목을 뒤에서 준비해 같은 플레이어에서 끊김 없이 바꿈 (실패하면 지금 화질 그대로)
    private func upgrade(_ player: AVPlayer) {
        guard let target = upgradeTarget, let info, case .direct(let height) = target,
              let stream = info.stream(for: height), let audio = info.audio else { return }
        upgradeTarget = nil
        let id = videoID
        upgradeTask = Task {
            let began = Date()
            do {
                let newItem = try await Self.makeItem([stream.url, audio], duration: info.duration)
                guard !Task.isCancelled, case .native(let current) = mode, current === player else { return }
                let at = player.currentTime()
                let playing = player.timeControlStatus != .paused
                player.replaceCurrentItem(with: newItem)
                watch(newItem, id: id)
                await player.seek(to: at, toleranceBefore: .zero, toleranceAfter: .zero)
                if playing { player.play() }
                level = target
                PlayerHub.shared.videoSize = CGSize(width: stream.width, height: stream.height)
                if let dot = subtitle.firstIndex(of: "·") {
                    subtitle = target.label + " " + subtitle[dot...]
                }
                onItemReplaced?(newItem)
                DebugLog.write(String(format: "화질 올림: %@ (준비 %.1f초, %d초 지점)", target.label, Date().timeIntervalSince(began), safeInt(at.seconds)))
                Toast.shared.show("\(target.label)로 올렸어요", seconds: 2)
            } catch {
                DebugLog.write("화질 올리기 실패 (\(target.label)): \(error.localizedDescription) → 지금 화질 유지")
            }
        }
    }

    /// 재생 중에 파일을 못 읽게 되면(주소 만료 등) 알려 줌
    private func watchForFailure(_ playerItem: AVPlayerItem) {
        statusObserver = playerItem.observe(\.status) { [weak self] playerItem, _ in
            guard playerItem.status == .failed else { return }
            Task { @MainActor in
                DebugLog.write("기본 플레이어 재생 실패: \(String(describing: playerItem.error))")
                self?.mode = .failed(playerItem.error?.localizedDescription ?? "재생 오류")
            }
        }
    }

    /// 재생 위치를 5초마다 저장 (닫을 때도 한 번 더)
    private func remember(_ player: AVPlayer, id: String) {
        videoID = id
        positionObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak player] time in
            guard let player else { return }
            MainActor.assumeIsolated {
                PlaybackMemory.save(id: id, position: time.seconds, duration: player.currentItem?.duration.seconds ?? .nan)
            }
        }
    }

    // MARK: 멈춤 감지·복구

    private func attachVideoOutput(to item: AVPlayerItem) {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        videoOutput = output
        staleSeconds = 0
    }

    /// 1초마다: 재생 중인데 새 프레임이 4초 동안 없으면 멈춘 것으로 보고 한 번만 알림
    private func startHealthCheck(_ player: AVPlayer) {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak player] timer in
            MainActor.assumeIsolated {
                guard let self, let player, let output = self.videoOutput else { return }
                guard player.timeControlStatus == .playing else { self.staleSeconds = 0; return }
                let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
                if output.hasNewPixelBuffer(forItemTime: itemTime) {
                    _ = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)   // 받아 두어야 다음 새 프레임을 알 수 있음
                    self.staleSeconds = 0
                    self.stableSeconds += 1
                    if self.stableSeconds == 3, self.upgradeTarget != nil { self.upgrade(player) }
                    if self.stableSeconds == 120 { self.onStable?(player.currentTime().seconds) }
                } else {
                    self.staleSeconds += 1
                    if self.staleSeconds >= 4 {
                        timer.invalidate()
                        let at = player.currentTime().seconds
                        DebugLog.write("화면 멈춤 감지 (\(safeInt(at))초): 소리는 가는데 새 화면이 4초 동안 없음")
                        self.onStall?(at)
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        upgradeTask?.cancel()
        healthTimer?.invalidate()
        healthTimer = nil
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if case .native(let player) = mode {
            player.pause()
            PlaybackMemory.save(id: videoID, position: player.currentTime().seconds,
                                duration: player.currentItem?.duration.seconds ?? .nan)
            if let positionObserver { player.removeTimeObserver(positionObserver) }
            NowPlaying.shared.detach(player)
            WatchMarks.shared.refresh()   // 목록 카드의 이어 보기 막대 새로
        }
        positionObserver = nil
    }
}

/// 이어 보기: 영상마다 마지막으로 본 위치 (~/Library/Application Support/MyTube/positions.json, 최근 500개)
@MainActor
enum PlaybackMemory {
    private struct Entry: Codable {
        let position: Double
        let saved: Date
        var duration: Double? = nil
    }

    private static let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyTube/positions.json")
    private static var entries: [String: Entry] = {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }()

    static func position(for id: String) -> Double? { entries[id]?.position }

    /// 이어 보기 진행 정도 0~1 (목록 카드의 빨간 막대용, 길이를 알 때만)
    static func progress(for id: String) -> Double? {
        guard let entry = entries[id], let duration = entry.duration, duration > 0 else { return nil }
        return min(1, entry.position / duration)
    }

    /// 다 본 영상: 다음엔 처음부터
    static func forget(_ id: String) {
        guard entries[id] != nil else { return }
        entries[id] = nil
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// 처음 10초 안이거나 끝 20초 안(다 본 것)이면 지움, 라이브(길이 모름)는 저장 안 함
    static func save(id: String, position: Double, duration: Double) {
        guard !id.isEmpty, position.isFinite, duration.isFinite, duration > 0 else { return }
        if position < 10 || duration - position < 20 {
            if duration - position < 20 { WatchMarks.shared.markWatched(id) }   // 거의 끝까지 봄
            guard entries[id] != nil else { return }
            entries[id] = nil
        } else {
            entries[id] = Entry(position: position, saved: Date(), duration: duration)
        }
        // 오래된 것부터 정리
        if entries.count > 500 {
            for key in entries.sorted(by: { $0.value.saved < $1.value.saved }).prefix(entries.count - 500).map(\.key) {
                entries[key] = nil
            }
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// 201초 → "3:21"
    static func timeText(_ seconds: Double) -> String {
        let t = safeInt(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// 재생 창 위쪽 막대 보이기·숨기기 (창 버튼 빨강·노랑·초록도 같이)
@MainActor
final class PlayerChrome: ObservableObject {
    @Published private(set) var isShown = true
    /// 창 너비에 따라 위쪽 막대 줄이기: 0 = 다 보임, 1 = 채널은 아이콘만, 2 = 제목 아래 줄도 숨김
    @Published private(set) var compact = 0

    func setWidth(_ width: CGFloat) {
        let next = width >= 900 ? 0 : width >= 720 ? 1 : 2
        if next != compact { compact = next }
    }
    /// 다운로드 목록 등이 열려 있으면 숨기지 않음
    var keepOpen = false
    private weak var window: NSWindow?
    private var hideTask: Task<Void, Never>?

    func attach(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // 더블클릭·초록 단추로 전체 화면이 되게 (전체 화면 허용)
        window.collectionBehavior.insert(.fullScreenPrimary)
        hideSystemWindowButtons()
        if !pendingTitle.isEmpty { setTitle(pendingTitle) }
        hideSoon(after: 2)   // 처음 열 때 잠깐 보여 주고 숨김
    }

    /// 창 제목: 글자는 숨긴 채 값만 바꿈
    private var pendingTitle = ""
    func setTitle(_ title: String) {
        pendingTitle = title
        guard let window else { return }
        window.title = title
        window.titleVisibility = .hidden
    }

    func close() { window?.performClose(nil) }
    func minimize() { window?.miniaturize(nil) }
    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    func hover(_ inside: Bool) {
        if inside {
            hideTask?.cancel()
            setShown(true)
        } else {
            hideSoon()
        }
    }

    func hideSoon(after seconds: Double = 0.8) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.keepOpen else { return }
            self.setShown(false)
        }
    }

    private func setShown(_ shown: Bool) {
        guard isShown != shown else { return }
        isShown = shown
        hideSystemWindowButtons()   // 전체 화면 전환 뒤 다시 나타나는 경우 대비
    }

    /// 시스템 창 버튼은 숨기고 판 안의 WindowLights로 대신함 (판과 위치를 맞추려고)
    private func hideSystemWindowButtons() {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = true
        }
    }
}

/// 켜고 끄는 버튼 아이콘: 켜지면 밝은 동그라미 배경으로 확실히 표시
struct ToggleIcon: View {
    let systemName: String
    let isOn: Bool

    var body: some View {
        Image(systemName: systemName)
            .frame(width: 28, height: 28)
            .foregroundStyle(isOn ? Color.black : Color.white.opacity(0.9))
            .background(Circle().fill(isOn ? Color.white.opacity(0.9) : Color.clear))
            .contentShape(Circle())
    }
}

/// 판 안의 창 버튼 (빨강 닫기 · 노랑 내리기 · 초록 전체 화면), 마우스를 올리면 기호가 보임
struct WindowLights: View {
    let chrome: PlayerChrome
    @StateObject private var hover = PopoverState()

    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1, green: 0.37, blue: 0.34), symbol: "xmark") { chrome.close() }
            light(Color(red: 1, green: 0.74, blue: 0.18), symbol: "minus") { chrome.minimize() }
            light(Color(red: 0.16, green: 0.79, blue: 0.25), symbol: "arrow.up.left.and.arrow.down.right") { chrome.toggleFullScreen() }
        }
        .onHover { hover.isShown = $0 }
    }

    private func light(_ color: Color, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay {
                    if hover.isShown {
                        Image(systemName: symbol)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.black.opacity(0.6))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// 팝업 열림 여부 (이 환경에서는 @State를 못 써서 작은 상태 객체로 대신함)
@MainActor
final class PopoverState: ObservableObject {
    @Published var isShown = false
}

/// 재생 창을 다른 창들 위에 늘 띄움 (설정은 다음 재생 창·다음 실행에도 유지, 기본 꺼짐)
@MainActor
final class WindowPin: ObservableObject {
    private static let key = "playerAlwaysOnTop"

    @Published var isOn: Bool = UserDefaults.standard.object(forKey: WindowPin.key) as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(isOn, forKey: Self.key)
            apply()
        }
    }
    private weak var window: NSWindow?

    func attach(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        apply()
    }

    private func apply() {
        guard let window else { return }
        window.level = isOn ? .floating : .normal
        // 앱이 뒤로 가도 숨지 않고 위에 남게
        window.hidesOnDeactivate = false
    }
}

/// 이 재생 창이 전체 화면인지 알려 줌
@MainActor
final class FullScreenState: ObservableObject {
    @Published private(set) var isOn = false
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func attach(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        isOn = window.styleMask.contains(.fullScreen)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isOn = true }
            },
            center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isOn = false }
            },
        ]
    }
}

/// SwiftUI 화면이 들어 있는 창을 알아냄
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}

/// 영상 위 더블클릭 → 전체 화면 켜기, 다시 더블클릭 → 원래 창으로
/// (macOS 플레이어가 클릭을 먼저 가져가서 일반 제스처로는 안 잡히는 경우가 있어, 창에 오는 클릭을 먼저 봄)
final class DoubleClickFullScreen {
    /// 영상 크기 변화 지켜보기 (회전 크기 맞춤용)
    var sizeObserver: NSKeyValueObservation?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    /// 쇼츠 스크롤로 넘기기: 쌓인 스크롤 양과 마지막으로 넘긴 때
    private var scrollSum: CGFloat = 0
    private var lastFlip = Date.distantPast
    private weak var view: NSView?
    /// 위쪽 막대가 보이는지 (보일 때는 막대 자리 클릭을 막대 단추에 넘김)
    var isTopBarShown: () -> Bool = { false }
    /// 한 번의 더블클릭에 전환이 두 번 일어나(켜졌다 바로 꺼짐) 아무 일 없는 것처럼 보이던 문제 →
    /// 전환하고 2초 안에 오는 더블클릭은 무시
    nonisolated(unsafe) private static var lastToggle = Date.distantPast

    func install(on view: NSView) {
        self.view = view
        // 영상 위 마우스: 더블클릭 → 전체 화면 켜기·끄기, 누르고 끌기 → 창 옮기기
        // 누른 곳이 "영상 화면" 부품일 때만 가로채고, 조작 막대·위쪽 막대 등 나머지는 원래대로 넘김
        // (예전엔 창 아래 110pt만 조작 막대로 봤는데, 큰 창에서는 조작 막대가 더 위에 떠서 단추가 안 눌렸음)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let view = self.view, let window = view.window, event.window === window,
                  let content = window.contentView else { return event }
            let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
            var chain: [NSView] = []
            var cur = hit
            while let v = cur, chain.count < 8 { chain.append(v); cur = v.superview }

            // 조작 막대의 ◀◀ ▶▶: 단추 이름이 부품에 없어서(유리 판 안 그림) 손쉬운 사용으로 그 자리 단추 이름을 물어봄
            if event.clickCount == 1, let direction = Self.skipDirection(at: NSEvent.mouseLocation, in: content) {
                self.skip(direction * 15)
                return nil
            }
            // 영상 화면인지: 영상 부품(멈췄을 때 덮이는 부분 포함) 안이고, 조작 막대(유리 판) 위가 아님
            let names = chain.map { "\(type(of: $0))" }
            // (부품 이름은 macOS 버전·라이브 텍스트 설정에 따라 달라서, "플레이어 안 + 조작 막대 유리 판이 아님"으로만 봄)
            let onVideo = chain.contains(where: { $0 === view }) && !names.contains(where: { $0.contains("Glass") })
            guard onVideo else { return event }

            if event.clickCount == 2 {
                guard Date().timeIntervalSince(Self.lastToggle) > 2 else { return nil }
                Self.lastToggle = Date()
                window.collectionBehavior.insert(.fullScreenPrimary)   // 전체 화면이 꺼져 있는 창이면 켬
                DebugLog.write("더블클릭: 전체 화면 \(window.styleMask.contains(.fullScreen) ? "끄기" : "켜기")")
                window.toggleFullScreen(nil)
                return nil   // 플레이어에는 넘기지 않음 (재생/멈춤이 같이 바뀌지 않게)
            }
            // 한 번 누름: 끌면 창이 따라 움직임 (전체 화면에서는 옮길 수 없으니 플레이어에 그대로)
            if event.clickCount == 1, !window.styleMask.contains(.fullScreen) {
                window.performDrag(with: event)
                return nil
            }
            return event
        }
        // 키보드: Esc → 플레이어를 완전히 끝냄 (전체 화면이어도 바로), ← → → 15초 뒤로·앞으로
        // 쇼츠: 스크롤로 다음·이전 (트랙패드 한 번 쓸기 = 한 개)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.view?.window, event.window === window,
                  MainActor.assumeIsolated({ PlayerHub.shared.item?.isShorts == true }) else { return event }
            if event.phase == .began { self.scrollSum = 0 }
            self.scrollSum += event.scrollingDeltaY
            guard abs(self.scrollSum) > 60, Date().timeIntervalSince(self.lastFlip) > 0.7 else { return nil }
            let down = self.scrollSum < 0
            self.scrollSum = 0
            self.lastFlip = Date()
            MainActor.assumeIsolated { down ? ShortsMode.shared.next() : ShortsMode.shared.previous() }
            return nil
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.view?.window, event.window === window else { return event }
            // 오른쪽 판이 열려 있으면 Esc는 판만 닫음
            if event.keyCode == 53, MainActor.assumeIsolated({ PlayerPanel.shared.mode != nil }) {
                MainActor.assumeIsolated { PlayerPanel.shared.mode = nil }
                return nil
            }
            // 질문 칸 등에 글을 쓰는 중이면 단축키(R·1~4·←→ 등)를 쓰지 않고 글자로 넘김
            if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
            switch event.keyCode {
            case 53:   // Esc
                DebugLog.write("Esc: 플레이어 종료")
                window.close()   // windowWillClose에서 재생을 멈추고 창을 버림
                return nil
            case 123:  // ←
                self.skip(-15)
                return nil
            case 124:  // →
                self.skip(15)
                return nil
            // 쇼츠: ↓ 다음, ↑ 이전
            case 125, 126 where MainActor.assumeIsolated({ PlayerHub.shared.item?.isShorts == true }):
                MainActor.assumeIsolated { event.keyCode == 125 ? ShortsMode.shared.next() : ShortsMode.shared.previous() }
                return nil
            // ⇧. 빠르게 / ⇧, 느리게 (유튜브와 같음)
            case 47 where event.modifierFlags.intersection([.command, .option, .control, .shift]) == .shift:
                MainActor.assumeIsolated { NowPlaying.shared.faster() }
                return nil
            case 43 where event.modifierFlags.intersection([.command, .option, .control, .shift]) == .shift:
                MainActor.assumeIsolated { NowPlaying.shared.slower() }
                return nil
            case 15 where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:  // R: 90도 돌리기
                MainActor.assumeIsolated { PlayerHub.shared.rotate() }
                return nil
            // 1·2·3·4 (윗줄 숫자 18·19·20·21, 숫자 키패드 83·84·85·86): 창 크기 영상 1배 / 0.5배 / 가로 1920 / 0.25배
            case 18, 19, 20, 21, 83, 84, 85, 86:
                // ⌘·⌥·⌃·⇧와 함께 누르면 원래대로 (다른 단축키)
                guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
                let scale: PlayerHub.WindowScale = [18, 83].contains(event.keyCode) ? .actual
                    : [19, 84].contains(event.keyCode) ? .half
                    : [20, 85].contains(event.keyCode) ? .width1920 : .quarter
                let shown = (self.view as? AVPlayerView)?.player?.currentItem?.presentationSize ?? .zero
                MainActor.assumeIsolated { PlayerHub.shared.resizeWindow(window, scale: scale, fallback: shown) }
                return nil
            default:
                return event
            }
        }
    }

    /// 지금 위치에서 seconds만큼 이동 (처음·끝을 넘지 않게, 라이브는 앞쪽만 막음)
    private func skip(_ seconds: Double) {
        guard let player = (view as? AVPlayerView)?.player, let item = player.currentItem else { return }
        var target = player.currentTime().seconds + seconds
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 { target = min(target, duration - 0.5) }
        target = max(target, 0)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.3, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.3, preferredTimescale: 600))
        DebugLog.write("\(seconds > 0 ? "앞으로" : "뒤로") \(safeInt(abs(seconds)))초 → \(safeInt(target))초")
    }

    /// 누른 곳이 ◀◀(뒤로 -1) / ▶▶(앞으로 +1) 단추인지: 그 자리의 손쉬운 사용 이름으로 알아봄 (영어·한국어)
    private static func skipDirection(at screenPoint: NSPoint, in content: NSView) -> Double? {
        guard let element = content.accessibilityHitTest(screenPoint) as? NSAccessibilityProtocol else { return nil }
        let name = [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityIdentifier()]
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        guard !name.isEmpty, !name.contains("live") else { return nil }   // "라이브로 건너뛰기"는 원래대로
        if ["rewind", "skip back", "되감기", "뒤로 건너뛰기"].contains(where: name.contains) { return -1 }
        if ["fast forward", "skip forward", "빨리 감기", "앞으로 건너뛰기"].contains(where: name.contains) { return 1 }
        return nil
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }
}

/// 제목 막대 자리(안전 영역)를 비워 두지 않고 창 맨 위까지 영상을 그리는 플레이어
final class EdgeToEdgePlayerView: AVPlayerView {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// 영상 회전 각도 (시계 방향). 조작 막대는 그대로 두고 영상 부분만 돌림
    var rotation = 0 {
        didSet { if oldValue != rotation { applyRotation(animated: true) } }
    }

    override func layout() {
        super.layout()
        applyRotation(animated: false)   // 창 크기가 바뀌면 다시 맞춤
    }

    /// 영상 화면 부품(조작 막대와 따로 있음)을 찾음
    private func videoContent() -> NSView? {
        var queue: [NSView] = subviews
        var fallback: NSView?
        while !queue.isEmpty {
            let v = queue.removeFirst()
            let name = "\(type(of: v))"
            if name.contains("PlaybackContentContainerView") { return v }
            if fallback == nil, name.contains("VideoContentView") { fallback = v }
            queue += v.subviews
        }
        return fallback
    }

    /// 가운데를 축으로 돌리고, 옆으로 눕혔을 때(90·270도)는 창 안에 꽉 차게 크기 조절
    func applyRotation(animated: Bool) {
        guard let target = videoContent() else { return }
        target.wantsLayer = true
        guard let layer = target.layer else { return }
        let w = target.bounds.width, h = target.bounds.height
        guard w > 0, h > 0 else { return }

        var scale: CGFloat = 1
        if rotation % 180 != 0 {
            let video = player?.currentItem?.presentationSize ?? .zero
            if video.width > 0, video.height > 0 {
                // 지금 창 안에 맞춰 보이는 영상 크기 → 돌린 뒤 창에 맞는 배율
                let fit = min(w / video.width, h / video.height)
                let shownW = video.width * fit, shownH = video.height * fit
                scale = min(w / shownH, h / shownW)
            } else {
                scale = min(w / h, h / w)
            }
        }
        // 레이어의 기준점에서 가운데까지 거리만큼 옮겼다가 돌리고 다시 제자리로
        let px = w / 2 - layer.anchorPoint.x * w
        let py = h / 2 - layer.anchorPoint.y * h
        var t = CATransform3DMakeTranslation(-px, -py, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(scale, scale, 1))
        // 아래→위 좌표라 시계 방향은 음수 각도
        let flip: CGFloat = target.isFlipped ? 1 : -1
        t = CATransform3DConcat(t, CATransform3DMakeRotation(flip * CGFloat(rotation) * .pi / 180, 0, 0, 1))
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(px, py, 0))

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.25)
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.transform = t
        CATransaction.commit()
    }
}

/// macOS 기본 영상 플레이어 (전체 화면, 화면 속 화면 지원)
struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    /// 위쪽 막대가 보이는지 (막대 자리 클릭은 창 끌기 대신 막대 단추로)
    var isTopBarShown: () -> Bool = { false }
    /// 영상 회전 각도 (시계 방향)
    var rotation = 0

    func makeCoordinator() -> DoubleClickFullScreen { DoubleClickFullScreen() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = EdgeToEdgePlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        view.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        // 멈췄을 때 영상 위를 덮는 "라이브 텍스트(글자·사물 찾기)"를 끔 → 멈춘 상태에서도 끌기·더블클릭이 됨
        view.allowsVideoFrameAnalysis = false
        // "지금 재생 중"은 NowPlaying이 직접 관리 (플레이어 화면이 따로 올리면 서로 덮어씀)
        view.updatesNowPlayingInfoCenter = false
        // 자체 전체 화면은 자막이 안 보이는 별도 창이라 끔 (더블클릭하면 창 전체 화면)
        view.showsFullScreenToggleButton = false
        // 화면 아무 곳이나 더블클릭하면 전체 화면 켜기·끄기 (아래쪽 조작 막대 위는 제외)
        context.coordinator.isTopBarShown = isTopBarShown
        context.coordinator.install(on: view)
        view.rotation = rotation
        // 영상 크기를 알게 되면(처음 불러온 뒤) 돌린 화면 크기를 다시 맞춤
        context.coordinator.sizeObserver = player.currentItem?.observe(\.presentationSize) { [weak view] _, _ in
            DispatchQueue.main.async { view?.applyRotation(animated: false) }
        }
        // 진단: 3초 뒤 화면 상태 기록 (검은 화면 원인 확인용)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak view, weak player] in
            guard let view, let player else { return }
            DebugLog.write("재생 화면 진단: 창 \(view.window != nil ? "있음" : "없음"), 보임 \(view.window?.isVisible == true), "
                + "크기 \(Int(view.bounds.width))×\(Int(view.bounds.height)), 영상 크기 \(player.currentItem?.presentationSize ?? .zero), "
                + "상태 \(player.timeControlStatus.rawValue), 위치 \(safeInt(player.currentTime().seconds))초, 화면 준비 \(view.isReadyForDisplay)")
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        (view as? EdgeToEdgePlayerView)?.rotation = rotation
    }
}

/// 화면 아래에 잠깐 뜨는 알림
@MainActor
final class Toast: ObservableObject {
    static let shared = Toast()
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, error: Bool = false, seconds: Double = 3) {
        message = text
        isError = error
        hideTask?.cancel()
        guard seconds > 0 else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { message = nil }
        }
    }
}

struct ToastView: View {
    @ObservedObject var toast = Toast.shared

    var body: some View {
        if let message = toast.message {
            Label(message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(toast.isError ? .orange : .green)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}


/// 시간(초)을 정수로: 라이브처럼 길이가 "끝없음"이거나 아직 모르는 값이면 앱이 죽지 않게 -1
/// (예전에 라이브 영상을 열면 Int(무한대)로 앱이 꺼졌음)
func safeInt(_ value: Double) -> Int {
    value.isFinite ? Int(value) : -1
}

/// 영상 주소 저장소: 앱을 다시 켜도 5시간 안에 받은 주소는 그대로 씀 (유튜브 주소는 6시간 동안 쓸 수 있음)
@MainActor
enum StreamCache {
    struct Entry: Codable {
        let info: YTDLP.StreamInfo
        let at: Date
    }

    private static let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyTube/streams.json")

    static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return all.filter { Date().timeIntervalSince($0.value.at) < 5 * 3600 }
    }

    /// 만료된 것은 빼고 최근 80개만 저장 (파일 쓰기는 뒤에서)
    static func save(_ entries: [String: Entry]) {
        let fresh = entries.filter { Date().timeIntervalSince($0.value.at) < 5 * 3600 }
            .sorted { $0.value.at > $1.value.at }.prefix(80)
        let keep = Dictionary(uniqueKeysWithValues: fresh.map { ($0.key, $0.value) })
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(keep) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// 쇼츠 재생 창 오른쪽: ▲ 이전 / 몇 번째 / ▼ 다음
struct ShortsSideBar: View {
    @ObservedObject private var mode = ShortsMode.shared

    var body: some View {
        VStack(spacing: 12) {
            Button { mode.previous() } label: { Image(systemName: "chevron.up") }
                .disabled(mode.index == 0)
                .help("이전 쇼츠 (↑)")
            Text(mode.positionText)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
            Button { mode.next() } label: { Image(systemName: "chevron.down") }
                .help("다음 쇼츠 (↓)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.vertical, 14)
        .frame(width: 44)
        .background(.ultraThinMaterial.opacity(0.7), in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(.trailing, 12)
    }
}

/// 재생 창 위쪽 막대에서 여는 팝업(댓글·질문하기·다운로드): 위쪽 막대와 같은 어두운 유리
/// 팝업 창 자체를 어둡게 바꿔(preferredColorScheme) 뒤가 흐리게 비치는 반투명 판 + 흰 글자로 잘 보이게
struct ReadablePopover: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            // 밝은 영상 위에서도 글자가 묻히지 않게 아주 옅게 어둡게
            .background(Color.black.opacity(0.18))
    }
}

extension View {
    func readablePopover() -> some View { modifier(ReadablePopover()) }
}

/// 재생 창 안 오른쪽 판에 무엇을 보여 줄지
@MainActor
final class PlayerPanel: ObservableObject {
    static let shared = PlayerPanel()
    enum Mode: Equatable {
        case comments, ai, downloads
        var title: String { self == .comments ? "댓글 · 설명" : self == .ai ? "이 동영상에 대해 물어보기" : "다운로드" }
        var icon: String { self == .comments ? "text.bubble" : self == .ai ? "sparkle" : "arrow.down.circle" }
    }
    @Published var mode: Mode?

    func toggle(_ next: Mode) { mode = mode == next ? nil : next }
}
