import AppKit
import WebKit

/// 유튜브를 띄우는 웹 화면과 그 상태(뒤로 가기 가능 여부, 제목 등)를 들고 있음
@MainActor
final class Browser: NSObject, ObservableObject {
    static let homeURL = URL(string: "https://www.youtube.com/")!
    static let subscriptionsURL = URL(string: "https://www.youtube.com/feed/subscriptions")!
    static let watchLaterURL = URL(string: "https://www.youtube.com/playlist?list=WL")!

    /// 앱 안에서 열어 둘 주소 (나머지는 기본 브라우저로 보냄)
    private static let allowedHostSuffixes = [
        "youtube.com", "youtu.be", "google.com", "google.co.kr",
        "gstatic.com", "googleusercontent.com", "googlevideo.com", "ytimg.com",
    ]

    let webView: WKWebView

    @Published var title = "MyTube"
    @Published var currentURL = Browser.homeURL
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var focusAddressBar = false
    /// 다운로드 목록 열림 여부
    @Published var showDownloads = false
    /// 재생 창을 열어 달라는 요청 (ContentView가 받아서 창을 열고 비움)
    @Published var playerRequest: PlayerItem?
    /// 위쪽 검색·주소 칸에 입력 중인 글
    @Published var address = ""
    /// 바로 재생 모드 (다음 실행에도 유지)
    @Published var directPlay: Bool = UserDefaults.standard.bool(forKey: Browser.directPlayKey) {
        didSet {
            UserDefaults.standard.set(directPlay, forKey: Self.directPlayKey)
            installDirectPlayScripts()
        }
    }
    @Published var isPinned = false {
        didSet { applyPin() }
    }

    private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        // 기본 저장소 = 앱을 껐다 켜도 로그인이 유지됨
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.allowsAirPlayForMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: config)
        // 구글 로그인이 "안전하지 않은 브라우저"로 막지 않도록 Safari로 표시
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self

        observations = [
            webView.observe(\.title) { [weak self] view, _ in
                Task { @MainActor in
                    // "(370) 제목 - YouTube" → "제목" (앞의 숫자는 유튜브 알림 개수)
                    let t = (view.title ?? "")
                        .replacingOccurrences(of: " - YouTube", with: "")
                        .replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
                    self?.title = t.isEmpty ? "MyTube" : t
                }
            },
            webView.observe(\.url) { [weak self] view, _ in
                Task { @MainActor in if let url = view.url { self?.currentURL = url } }
            },
            webView.observe(\.canGoBack) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] view, _ in
                Task { @MainActor in self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
        ]

        setUpDirectPlay()
        BrowserLink.browser = self
        goHome()
    }

    func goHome() { open(Self.homeURL) }

    func open(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// 주소 칸에 넣은 글: 링크면 그 주소로, 아니면 유튜브 검색
    func submit(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        if let url = Self.youtubeURL(from: input) {
            open(url)
        } else {
            var comps = URLComponents(string: "https://www.youtube.com/results")!
            comps.queryItems = [URLQueryItem(name: "search_query", value: input)]
            open(comps.url!)
        }
    }

    /// "youtu.be/abc", "www.youtube.com/watch?v=abc" 같은 글을 주소로 바꿈 (유튜브 주소가 아니면 nil)
    nonisolated static func youtubeURL(from input: String) -> URL? {
        guard !input.contains(" ") else { return nil }
        let withScheme = input.lowercased().hasPrefix("http") ? input : "https://\(input)"
        guard let url = URL(string: withScheme), let host = url.host?.lowercased(),
              host == "youtu.be" || host.hasSuffix("youtube.com") else { return nil }
        return url
    }

    /// 지금 보는 영상이 영상 페이지인지 (홈·검색 화면이면 맥 플레이어로 열 게 없음)
    var isOnVideoPage: Bool {
        guard currentURL.host?.hasSuffix("youtube.com") == true else { return false }
        let path = currentURL.path
        return path == "/watch" || path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
    }

    /// 지금 영상을 맥 기본 플레이어로: 웹 영상은 멈추고, 보던 위치부터 이어서 재생
    func openInNativePlayer() {
        guard isOnVideoPage else {
            NSSound.beep()
            return
        }
        let pageURL = currentURL
        guard let id = YTDLP.videoID(from: pageURL) else {
            NSSound.beep()
            return
        }
        let pageTitle = title
        Task {
            let script = "(() => { const v = document.querySelector('video'); if (!v) return 0; v.pause(); return v.currentTime; })()"
            let seconds = (try? await webView.evaluateJavaScript(script)) as? Double ?? 0
            // 화면(ContentView)이 이 값을 보고 재생 창을 엶
            playerRequest = PlayerItem(id: id, title: pageTitle, url: pageURL.absoluteString, startAt: seconds)
        }
    }

    /// 지금 영상을 최고 화질로 다운로드 (목록도 열어서 진행률을 보여 줌)
    func downloadCurrent() {
        guard isOnVideoPage else {
            NSSound.beep()
            return
        }
        let pageURL = currentURL
        let pageTitle = title
        showDownloads = true
        Task {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            DownloadManager.shared.start(pageURL: pageURL, title: pageTitle, cookies: cookies)
        }
    }

    func copyCurrentURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentURL.absoluteString, forType: .string)
    }

    /// 항상 위에 띄우기: 다른 앱 위에도, 모든 데스크탑(Space)에도 보이게
    private func applyPin() {
        guard let window = webView.window else { return }
        window.level = isPinned ? .floating : .normal
        window.collectionBehavior = isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.managed]
        DebugLog.write("항상 위에 띄우기: \(isPinned)")
    }

    private static func isAllowedInApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme, ["http", "https", "about", "blob", "data"].contains(scheme) else { return false }
        guard let host = url.host?.lowercased() else { return true }
        return allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

extension Browser: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }

        // 유튜브·구글 밖의 링크(영상 설명란의 링크 등)를 누르면 기본 브라우저로
        if navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.navigationType == .linkActivated,
           !Self.isAllowedInApp(url) {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        // 유튜브는 바깥 링크를 youtube.com/redirect?q=<진짜 주소>로 감싸서 보냄
        if url.host?.hasSuffix("youtube.com") == true, url.path == "/redirect",
           let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "q" })?.value,
           let targetURL = URL(string: target) {
            NSWorkspace.shared.open(targetURL)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLog.write("페이지 불러오기 실패: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DebugLog.write("페이지 연결 실패: \(error.localizedDescription)")
    }

    // 웹 화면 프로세스가 죽으면(메모리 부족 등) 다시 불러옴
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DebugLog.write("웹 화면 프로세스 종료 → 다시 불러오기")
        webView.reload()
    }
}

extension Browser: WKUIDelegate {
    /// 새 창으로 열기(target=_blank): 유튜브면 지금 창에서, 아니면 기본 브라우저에서
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            if Self.isAllowedInApp(url) {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }
}
