import SwiftUI

@main
struct MyTubeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var browser = Browser()

    @ObservedObject private var now = NowPlaying.shared
    @ObservedObject private var listen = ListenMode.shared
    @ObservedObject private var shorts = ShortsMode.shared

    init() {
        DebugLog.write("앱 시작 — 위치: \(Bundle.main.bundlePath)")
        // 미디어 키·이어폰 감지 준비, 구독 새 영상 확인, 나중에 볼 동영상 자동 받기
        _ = NowPlaying.shared
        _ = YouTubeAccount.shared   // 로그인 상태 확인 (쿠키가 바뀌면 다시)
        DispatchQueue.main.async { ThemeStore.shared.applyAppearance() }   // 화면 모드 (밝게·어둡게)
        NewVideoWatcher.shared.start()
        AutoDownloader.shared.start()
        Updater.shared.start()   // 새 버전 확인 (GitHub 릴리즈)
    }

    var body: some Scene {
        // 창은 하나만 (WindowGroup이면 ⌘N으로 창이 여러 개 생김)
        Window("MyTube", id: "main") {
            ContentView()
                .environmentObject(browser)
                .themed()
                .frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 1280, height: 800)
        // 재생 창은 SwiftUI 장면 대신 PlayerWindowController가 직접 만들고 닫음
        // (장면으로 두면 Esc 등으로 닫은 뒤 "아직 열려 있다"고 여겨 다시 열리지 않는 문제가 있었음)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("업데이트 확인…") { Task { await Updater.shared.check(userInitiated: true) } }
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("재생") {
                Toggle("듣기 모드 (영상 누르면 소리만)", isOn: $listen.isOn)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Toggle("쇼츠 모드 (쇼츠만 세로 창으로)", isOn: $shorts.isOn)
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button(now.isPlaying ? "일시정지" : "재생") { NowPlaying.shared.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [.command, .option])
                    .disabled(!now.isActive)
                Button("15초 뒤로") { NowPlaying.shared.skip(-15) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(!now.isActive)
                Button("15초 앞으로") { NowPlaying.shared.skip(15) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(!now.isActive)
                Button("다음 영상 (대기열)") { NowPlaying.shared.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
                    .disabled(!now.isActive)
                Divider()
                Button("빠르게") { NowPlaying.shared.faster() }
                    .keyboardShortcut(".", modifiers: [.command, .option])
                    .disabled(!now.isActive)
                Button("느리게") { NowPlaying.shared.slower() }
                    .keyboardShortcut(",", modifiers: [.command, .option])
                    .disabled(!now.isActive)
                Divider()
                Button("재생 대기열 보기") { FeedStore.shared.selection = .queue }
                Button("듣기 창 보이기") { MiniPlayerWindow.shared.show() }
                    .disabled(!ListenPlayer.shared.isActive)
            }
            CommandMenu("탭") {
                Button("새 탭") { FeedStore.shared.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("탭 닫기") { FeedStore.shared.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                Divider()
                Button("다음 탭") { FeedStore.shared.cycleTab(1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("이전 탭") { FeedStore.shared.cycleTab(-1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Divider()
                ForEach(1..<10) { number in
                    Button("\(number)번째 탭") { FeedStore.shared.selectTab(at: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
            }
            CommandMenu("이동") {
                Button("뒤로") { browser.webView.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("앞으로") { browser.webView.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("새로고침") {
                    let feeds = FeedStore.shared
                    if feeds.selection == .web { browser.webView.reload() } else { feeds.reloadCurrent() }
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                // 앱이 직접 그리는 목록
                Button("홈") { FeedStore.shared.selection = .home }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("구독") { FeedStore.shared.selection = .subscriptions }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("기록") { FeedStore.shared.selection = .history }
                Button("재생목록") { FeedStore.shared.selection = .playlists }
                Button("나중에 볼 동영상") { FeedStore.shared.selection = .watchLater }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("좋아요 표시한 동영상") { FeedStore.shared.selection = .liked }
                Button("내 동영상") { FeedStore.shared.selection = .myVideos }
                Divider()
                // 왼쪽 메뉴에서는 뺐고, 로그인 등이 필요할 때만 여기서 엶
                Button("유튜브 로그인…") { YouTubeAccount.shared.signIn() }
                Button("유튜브 사이트 열기") { FeedStore.shared.selection = .web }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
                Divider()
                Button("주소·검색 칸으로") { browser.focusAddressBar.toggle() }
                    .keyboardShortcut("l", modifiers: .command)
                Toggle("바로 재생 (영상 누르면 재생 창)", isOn: $browser.directPlay)
                Button("지금 영상을 맥 플레이어로 열기") { browser.openInNativePlayer() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("최고 화질로 다운로드") { browser.downloadCurrent() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("현재 영상 링크 복사") { browser.copyCurrentURL() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                Button(browser.isPinned ? "항상 위에 띄우기 끄기" : "항상 위에 띄우기") {
                    browser.isPinned.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        // 메뉴 막대 미니 플레이어 (재생 중이면 🎧 또는 ▶ 아이콘)
        MenuBarExtra {
            MenuBarView().themed()
        } label: {
            Image(systemName: now.isActive ? (now.source == .listen ? "headphones" : "play.rectangle.fill") : "play.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 창을 닫으면 앱도 끝냄 (안 그러면 창 없이 영상 소리만 계속 남)
    // 단, 듣기 모드로 듣는 중이면(듣기 창을 숨기고 메뉴 막대로 조작) 계속 켜 둠
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !ListenPlayer.shared.isActive }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            WatchStats.shared.save()
            ListenPlayer.shared.stop()
        }
    }
}
