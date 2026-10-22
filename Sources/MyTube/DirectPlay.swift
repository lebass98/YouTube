import WebKit

/// 바로 재생 모드: 켜 두면 유튜브에서 영상을 눌렀을 때 상세 페이지로 가지 않고 재생 창이 바로 뜸
/// (유튜브는 페이지를 새로 불러오지 않고 화면만 바꾸므로, 페이지 안 스크립트로 클릭을 가로챔)
extension Browser: WKScriptMessageHandler {
    static let directPlayKey = "directPlay"
    private static let messageName = "mytubeOpen"

    /// 영상 링크를 누르면 앱에 주소·제목을 보내고 유튜브의 원래 이동은 막음
    private static let clickScript = """
    (() => {
      if (window.__mytubeInstalled) return;
      window.__mytubeInstalled = true;
      window.addEventListener('click', (e) => {
        // 켜져 있을 때, 그냥 왼쪽 클릭일 때만 (⌘·⇧ 클릭 등은 유튜브 그대로)
        if (!window.__mytubeDirect || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        const a = e.target && e.target.closest && e.target.closest('a[href]');
        if (!a) return;
        let u;
        try { u = new URL(a.href, location.href); } catch (_) { return; }
        if (!/(^|\\.)youtube\\.com$/.test(u.hostname)) return;
        const isVideo = (u.pathname === '/watch' && u.searchParams.get('v')) || u.pathname.startsWith('/shorts/');
        if (!isVideo) return;
        // 지금 보고 있는 영상 안의 시간 링크(댓글의 1:23 등)는 유튜브 그대로
        const cur = new URL(location.href);
        if (u.pathname === '/watch' && cur.pathname === '/watch' && u.searchParams.get('v') === cur.searchParams.get('v')) return;
        e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
        const box = a.closest('ytd-rich-item-renderer,ytd-video-renderer,ytd-compact-video-renderer,ytd-grid-video-renderer,ytd-reel-item-renderer,ytd-playlist-video-renderer,yt-lockup-view-model,ytm-shorts-lockup-view-model');
        const heading = box && box.querySelector('#video-title,h3');
        const title = (a.getAttribute('title') || (heading && heading.textContent) || a.getAttribute('aria-label') || '').trim();
        window.webkit.messageHandlers.mytubeOpen.postMessage({ url: u.href, title: title });
      }, true);
    })();
    """

    /// 처음 한 번: 스크립트를 넣고 메시지를 받을 준비
    func setUpDirectPlay() {
        webView.configuration.userContentController.add(self, name: Self.messageName)
        installDirectPlayScripts()
    }

    /// 켜기·끄기 값을 페이지에 알려 줌 (지금 페이지 + 앞으로 열 페이지)
    func installDirectPlayScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: "window.__mytubeDirect = \(directPlay);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: Self.clickScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.evaluateJavaScript("window.__mytubeDirect = \(directPlay);" + Self.clickScript, completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              let body = message.body as? [String: Any],
              let link = body["url"] as? String,
              let url = URL(string: link),
              let id = YTDLP.videoID(from: url) else { return }

        let title = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "유튜브 영상"
        // "이어서 보기" 링크의 &t=123s 위치부터
        let t = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "t" }?.value?
            .replacingOccurrences(of: "s", with: "")
        playerRequest = PlayerItem(id: id, title: title, url: "https://www.youtube.com/watch?v=\(id)",
                                   startAt: t.flatMap(Double.init) ?? 0)
        DebugLog.write("바로 재생: \(title) \(id)")
    }
}
