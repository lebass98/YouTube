import AppKit
import SwiftUI
import WebKit

/// 유튜브 로그인 상태: 앱의 웹 저장소(쿠키)에 구글 로그인 정보가 있는지 + 계정 이름·사진
/// 로그인해야 홈·구독·기록·재생목록·좋아요 같은 내 목록을 받을 수 있음
@MainActor
final class YouTubeAccount: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    static let shared = YouTubeAccount()

    enum Status: Equatable {
        case unknown, loggedOut
        case loggedIn(name: String, handle: String, avatar: URL?)
    }

    @Published private(set) var status = Status.unknown
    var isLoggedIn: Bool { if case .loggedIn = status { true } else { false } }
    private var checkTask: Task<Void, Never>?
    private var wasLoggedIn = false

    private override init() {
        super.init()
        WKWebsiteDataStore.default().httpCookieStore.add(self)
        check()
    }

    // 쿠키가 바뀌면(로그인·로그아웃) 잠깐 뒤 다시 확인
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in YouTubeAccount.shared.check(after: 1) }
    }

    func check(after delay: Double = 0) {
        checkTask?.cancel()
        checkTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                .filter { $0.domain.hasSuffix("youtube.com") }
            let names = Set(cookies.map(\.name))
            guard names.contains("SAPISID") || names.contains("__Secure-3PAPISID"), names.contains("LOGIN_INFO") else {
                setStatus(.loggedOut)
                return
            }
            // 계정 이름·핸들·사진 (유튜브 웹의 계정 메뉴와 같은 정보)
            var name = "", handle = "", avatar: URL?
            if let r = try? await YouTubeHome.post("account/account_menu", [:], cookies: cookies) {
                var headers: [Any] = []
                YouTubeHome.collect(r, key: "activeAccountHeaderRenderer", into: &headers)
                if let h = headers.first as? [String: Any] {
                    name = YouTubeHome.text(h["accountName"])
                    handle = YouTubeHome.text(h["channelHandle"])
                    if let thumbs = (h["accountPhoto"] as? [String: Any])?["thumbnails"] as? [[String: Any]],
                       let url = thumbs.last?["url"] as? String { avatar = URL(string: url) }
                }
            }
            setStatus(.loggedIn(name: name.isEmpty ? "유튜브 계정" : name, handle: handle, avatar: avatar))
        }
    }

    private func setStatus(_ next: Status) {
        guard next != status else { return }
        let before = status
        status = next
        let now = isLoggedIn
        // 로그아웃 상태에서 로그인이 되면 목록을 새로 받음 (앱을 켤 때 이미 로그인돼 있던 건 그대로)
        if now, !wasLoggedIn, before == .loggedOut {
            DebugLog.write("유튜브 로그인 확인됨")
            FeedStore.shared.reloadAll()
        }
        wasLoggedIn = now
        // 처음 켠 Mac에서 로그인이 안 돼 있으면 로그인 창을 한 번 띄워 줌
        if next == .loggedOut, !UserDefaults.standard.bool(forKey: "askedYouTubeLogin") {
            UserDefaults.standard.set(true, forKey: "askedYouTubeLogin")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.signIn() }
        }
    }

    // MARK: 로그인·로그아웃

    func signIn() {
        LoginWindow.shared.show()
    }

    /// 앱에 저장된 구글·유튜브 로그인 정보를 지움 (내 구글 계정 자체에는 영향 없음)
    func signOut() {
        let alert = NSAlert()
        alert.messageText = "유튜브에서 로그아웃할까요?"
        alert.informativeText = "이 앱에 저장된 로그인 정보만 지워요. 다시 쓰려면 로그인해야 해요."
        alert.addButton(withTitle: "로그아웃")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let targets = records.filter { r in ["youtube", "google"].contains { r.displayName.contains($0) } }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: targets) {
                Task { @MainActor in
                    DebugLog.write("유튜브 로그아웃")
                    YouTubeAccount.shared.check()
                    FeedStore.shared.reloadAll()
                    Toast.shared.show("로그아웃했어요")
                }
            }
        }
    }
}

// MARK: - 로그인 창 (구글 로그인 페이지 → 끝나면 유튜브로 돌아오며 저절로 닫힘)

@MainActor
final class LoginWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    static let shared = LoginWindow()
    private var window: NSWindow?
    private var webView: WKWebView?

    private static let loginURL = URL(string:
        "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&hl=ko"
        + "&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Dko%26next%3D%252F")!

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 앱 전체와 같은 저장소 → 여기서 로그인하면 앱 전체가 로그인됨
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: config)
        // 구글이 "안전하지 않은 브라우저"로 막지 않게 Safari로 표시 (기본 웹 화면과 같음)
        web.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.navigationDelegate = self
        web.load(URLRequest(url: Self.loginURL))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "유튜브 로그인 (구글 계정)"
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.webView = web
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DebugLog.write("유튜브 로그인 창 열기")
    }

    // 로그인이 끝나 유튜브로 돌아오면 확인 후 창을 닫음
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard let host = webView.url?.host, host.hasSuffix("youtube.com") else { return }
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let names = Set(cookies.filter { $0.domain.hasSuffix("youtube.com") }.map(\.name))
            guard names.contains("LOGIN_INFO") else { return }
            YouTubeAccount.shared.check()
            Toast.shared.show("유튜브에 로그인했어요. 목록을 새로 받아요", seconds: 3)
            self.window?.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        webView = nil
        YouTubeAccount.shared.check()
    }
}

// MARK: - 필요한 도구 (yt-dlp·deno·ffmpeg)

enum ToolCheck {
    static let command = "brew install yt-dlp deno ffmpeg"

    /// 없는 도구 이름들
    static var missing: [String] {
        ["yt-dlp", "deno", "ffmpeg"].filter { name in
            !YTDLP.searchPaths.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
        }
    }
}

// MARK: - 사이드바 맨 위 계정 줄

struct AccountRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var account = YouTubeAccount.shared

    var body: some View {
        switch account.status {
        case .loggedIn(let name, let handle, let avatar):
            HStack(spacing: 10) {
                AsyncImage(url: avatar) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { ChannelAvatar(name: name, size: 30) }
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(handle.isEmpty ? "로그인됨" : handle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("로그인 상태 다시 확인") { account.check() }
                    Button("다른 계정으로 로그인…") { account.signIn() }
                    Divider()
                    Button("로그아웃…") { account.signOut() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("계정")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        case .loggedOut:
            VStack(alignment: .leading, spacing: 6) {
                Button { account.signIn() } label: {
                    Label("유튜브 로그인", systemImage: "person.crop.circle.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .foregroundStyle(.white)
                        .background(theme.style, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                Text("로그인해야 홈·구독·기록·재생목록이 보여요")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        case .unknown:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("로그인 확인 중…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
