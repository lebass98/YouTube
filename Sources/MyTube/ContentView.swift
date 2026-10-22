import SwiftUI
import WebKit

/// 기본 창: 왼쪽 사이드바(홈·구독·나중에 볼 영상·검색·유튜브 웹) + 오른쪽 영상 목록 또는 유튜브 웹 화면
struct ContentView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var browser: Browser
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var feeds = FeedStore.shared
    @ObservedObject private var listen = ListenMode.shared
    @ObservedObject private var shorts = ShortsMode.shared
    @FocusState private var addressFocused: Bool
    @StateObject private var layout = ContentWidth()

    private var isWeb: Bool { feeds.selection == .web }

    var body: some View {
        NavigationSplitView(columnVisibility: $layout.columns) {
            FeedSidebar(store: feeds)
                .navigationSplitViewColumnWidth(min: 215, ideal: 230, max: 300)
        } detail: {
            // 화면마다 따로 만든다(.id): 쇼츠 ↔ 목록처럼 바뀔 때 스크롤 영역이 재사용되면
            // 보이는 범위를 잘못 계산해 카드·썸네일 일부만 그려지던 문제가 있었음
            // 바깥은 ZStack 하나로 두어 너비 재기·탭 막대가 화면이 바뀌어도 그대로 이어지게
            ZStack {
                if isWeb {
                    WebView(webView: browser.webView)
                        .ignoresSafeArea()
                        .id("web")
                } else if feeds.selection == .settings {
                    SettingsView().id("settings")
                } else if shorts.isOn {
                    ShortsBrowser().id("shorts")
                } else if feeds.selection == .queue {
                    QueueView().id("queue")
                } else {
                    // 목록(홈·채널·검색…)마다 따로: 이전 목록에서 많이 내려 둔 스크롤 위치가 짧은 새 목록에 남아
                    // 끝보다 아래를 보여 주면서 화면이 텅 비던 문제 → 새 목록은 늘 맨 위부터
                    FeedGridView(store: feeds).id("feed:" + feeds.currentKey)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 맨 위: 탭 막대 (지금 어디를 보고 있는지)
            // 좁을 때는 그 아래에 검색 막대 (위쪽 막대에 두면 자리가 모자라 ">>" 안으로 숨음)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    FeedTabBar(store: feeds)
                    if !isWeb, layout.size == .narrow {
                        searchBar
                            .frame(height: 30)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                }
            }
            .overlay(alignment: .bottom) { ToastView() }
            // 사이드바가 접혀 있을 때만: 썸네일 크기 단추를 목록 오른쪽 아래에 (평소에는 사이드바 맨 아래)
            .overlay(alignment: .bottomTrailing) {
                if !isWeb, feeds.selection != .settings, layout.columns == .detailOnly { cardSizeButtons }
            }
            // 오른쪽 화면 너비에 따라 위쪽 막대를 줄임 (좁아져도 검색 칸이 ">>" 안으로 숨지 않게)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { layout.width = $0 }
        }
        // 창이 좁아지면 사이드바를 접고, 다시 넓어지면 펼침
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { layout.windowWidth = $0 }
        .navigationTitle(isWeb ? browser.title : feeds.currentTitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if isWeb {
                    Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!browser.canGoBack)
                        .help("뒤로 (⌘[)")
                    Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!browser.canGoForward)
                        .help("앞으로 (⌘])")
                }
                Button {
                    if isWeb {
                        if browser.isLoading { browser.webView.stopLoading() } else { browser.webView.reload() }
                    } else {
                        feeds.reloadCurrent()
                    }
                } label: {
                    Image(systemName: isWeb && browser.isLoading ? "xmark" : "arrow.clockwise")
                }
                .help("새로고침 (⌘R)")
                // 듣기 모드: 켜져 있으면 영상을 누를 때 소리만 (회사에서 화면 없이 듣기)
                if !isWeb {
                    Button { listen.isOn.toggle() } label: {
                        Image(systemName: listen.isOn ? "headphones.circle.fill" : "headphones")
                            .foregroundStyle(listen.isOn ? theme.style : AnyShapeStyle(Color.primary))
                    }
                    .help(listen.isOn ? "듣기 모드 켜짐: 영상을 누르면 소리만 재생 (누르면 끄기, ⌘⇧L)" : "듣기 모드 켜기: 영상을 누르면 소리만 재생 (⌘⇧L)")
                    // 쇼츠 모드: 쇼츠만 모아 보고 세로 창에서 넘겨 보기
                    Button { shorts.isOn.toggle() } label: {
                        Image(systemName: shorts.isOn ? "rectangle.portrait.on.rectangle.portrait.angled.fill" : "rectangle.portrait.on.rectangle.portrait.angled")
                            .foregroundStyle(shorts.isOn ? theme.style : AnyShapeStyle(Color.primary))
                    }
                    .help(shorts.isOn ? "쇼츠 모드 켜짐 (누르면 끄기, ⌘⇧K)" : "쇼츠 모드: 쇼츠만 세로 창으로 보기 (⌘⇧K)")
                }
            }

            // 검색: [AI | 기본 | URL] + 아이콘 + 입력 칸을 한 줄 둥근 막대로
            // 넓으면 가운데, 좁으면 오른쪽에 (가운데는 양쪽에 같은 빈자리가 있어야 해서 좁은 창에서 숨겨짐)
            // 막대는 칸 크기를 처음 만들 때만 재서, 너비 단계가 바뀌면 칸을 새로 만들게 함 (.id)
            if isWeb || layout.size != .narrow {
                ToolbarItem(placement: layout.size == .wide ? .principal : .primaryAction) {
                    searchBar.id(layout.size)
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // 받는 중이거나 받은 영상이 있으면 다운로드 목록
                if (isWeb && browser.isOnVideoPage) || !downloads.jobs.isEmpty {
                    Button {
                        if isWeb && browser.isOnVideoPage { browser.downloadCurrent() } else { browser.showDownloads.toggle() }
                    } label: {
                        Image(systemName: downloads.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                    .help(isWeb && browser.isOnVideoPage ? "이 영상을 최고 화질로 다운로드 (⌘⇧D)" : "다운로드 목록 — 받는 중 \(downloads.activeCount)개")
                    .popover(isPresented: $browser.showDownloads, arrowEdge: .bottom) {
                        DownloadsPanel(canDownload: isWeb && browser.isOnVideoPage) { browser.downloadCurrent() }
                    }
                }
                if isWeb {
                    Button { browser.directPlay.toggle() } label: {
                        Image(systemName: browser.directPlay ? "play.rectangle.on.rectangle.fill" : "play.rectangle.on.rectangle")
                    }
                    .help(browser.directPlay ? "바로 재생 켜짐 (누르면 끄기)" : "바로 재생 켜기: 영상을 누르면 재생 창이 바로 떠요")
                }
            }

        }
        .onChange(of: browser.playerRequest) { _, item in
            guard let item else { return }
            play(item)
            browser.playerRequest = nil
        }
        .onChange(of: browser.focusAddressBar) {
            addressFocused = true
        }
        .onChange(of: addressFocused) { _, focused in
            // 칸을 누르면 웹은 지금 주소, 목록은 지금 검색어를 보여 주고, 벗어나면 비움
            if focused {
                browser.address = isWeb ? browser.currentURL.absoluteString
                    : (feeds.selection == .search && feeds.searchMode == .basic ? feeds.query : browser.address)
            } else if isWeb {
                browser.address = ""
            }
        }
    }

    /// 좁은 창의 썸네일 크기 단추 (목록 위에 떠 있는 작은 유리 판)
    private var cardSizeButtons: some View {
        HStack(spacing: 2) {
            Button { feeds.cardWidth = max(160, feeds.cardWidth - 60) } label: {
                Image(systemName: "minus").frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .help("썸네일 작게")
            Divider().frame(height: 14)
            Button { feeds.cardWidth = min(520, feeds.cardWidth + 60) } label: {
                Image(systemName: "plus").frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .help("썸네일 크게")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(14)
    }

    /// 위쪽 검색 막대: [AI | 기본 | URL] 고르기 + 아이콘 + 입력 칸 + 지우기
    private var searchBar: some View {
        HStack(spacing: 10) {
            if !isWeb, layout.size == .wide {
                Picker("검색 방식", selection: $feeds.searchMode) {
                    ForEach(SearchMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if !isWeb, layout.size != .wide {
                // 좁을 때: [AI | 기본 | URL] 대신 지금 방식 아이콘(+이름)을 누르면 고르는 메뉴
                Menu {
                    Picker("검색 방식", selection: $feeds.searchMode) {
                        ForEach(SearchMode.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: feeds.searchMode.icon)
                        Text(feeds.searchMode.label)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(feeds.searchMode == .ai ? theme.style : AnyShapeStyle(Color.secondary))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .help("검색 방식: \(feeds.searchMode.label) (누르면 바꾸기)")
            } else {
                Image(systemName: isWeb ? "globe" : feeds.searchMode.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(feeds.searchMode == .ai && !isWeb ? theme.style : AnyShapeStyle(Color.secondary))
                    .frame(width: 16)
            }
            TextField(isWeb ? "검색하거나 유튜브 링크 붙여넣기 (⌘L)" : feeds.searchMode.placeholder, text: $browser.address)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addressFocused)
                .onSubmit {
                    if isWeb { browser.submit(browser.address) } else { submitInList(browser.address) }
                    addressFocused = false
                }
            if feeds.aiBusy {
                ProgressView().controlSize(.small)
            } else if !browser.address.isEmpty {
                Button { browser.address = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("지우기")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        // 최소 너비를 화면 너비에 맞게: 너무 크면 macOS가 검색 칸을 통째로 ">>" 안으로 숨김
        // (막대는 '알맞은 너비'로 자리를 재므로 그것도 화면 너비에 맞춤)
        .frame(minWidth: layout.size == .wide ? 300 : layout.size == .medium ? 200 : 120,
               idealWidth: layout.searchWidth, maxWidth: layout.size == .narrow ? .infinity : 660)
    }

    /// 목록 화면의 검색 칸: 고른 방식(AI·기본·URL)대로 처리
    private func submitInList(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        // 어느 방식이든 유튜브 영상 링크를 붙여 넣으면 바로 재생
        if case .video(let item) = LinkTarget.parse(input) {
            play(item)
            return
        }
        switch feeds.searchMode {
        case .ai:
            feeds.aiSearch(input)
        case .basic:
            feeds.search(input)
        case .url:
            switch LinkTarget.parse(input) {
            case .video(let item): play(item)
            case .collection(let ref): feeds.opened = ref
            case .invalid: Toast.shared.show("유튜브 링크가 아니에요", error: true)
            }
        }
    }

    /// 재생 창은 하나: 이미 떠 있으면 그 창의 영상만 바꾸고 앞으로 가져옴
    private func play(_ item: PlayerItem) {
        Playback.open(item)
    }
}

/// AppKit의 WKWebView를 SwiftUI 화면에 넣는 다리
struct WebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// 기본 창 오른쪽 화면의 너비 단계 (위쪽 막대를 얼마나 줄일지)
@MainActor
final class ContentWidth: ObservableObject {
    enum Size { case wide, medium, narrow }
    @Published private(set) var size: Size = .wide
    /// 검색 막대의 알맞은 너비: 오른쪽 화면에서 제목·단추 자리(약 300)를 뺀 만큼, 130~560
    @Published private(set) var searchWidth: CGFloat = 560
    /// 사이드바 보이기 (창이 좁아지면 저절로 접힘)
    @Published var columns: NavigationSplitViewVisibility = .all
    private var autoHidden = false
    var windowWidth: CGFloat = 1000 {
        didSet {
            // 기준선을 넘을 때만 바꿈 (좁은 창에서 직접 펼친 사이드바는 그대로 둠)
            if oldValue >= 720, windowWidth < 720, columns != .detailOnly {
                columns = .detailOnly
                autoHidden = true
            } else if oldValue < 760, windowWidth >= 760, autoHidden {
                columns = .all
                autoHidden = false
            }
        }
    }
    var width: CGFloat = 1000 {
        didSet {
            let next: Size = width >= 860 ? .wide : width >= 700 ? .medium : .narrow
            if next != size { size = next }
            let fit = min(560, max(120, (width - 330).rounded()))
            if abs(fit - searchWidth) >= 10 { searchWidth = fit }
        }
    }
}

/// 위쪽 탭 막대: 탭마다 "보고 있는 곳"(홈·구독·검색어·채널…)을 기억, 눌러서 오가기
struct FeedTabBar: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: FeedStore
    @StateObject private var hover = TabHover()

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.tabs) { tab in
                            chip(tab).id(tab.id)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                // 새 탭을 열거나 고르면 그 탭이 보이게
                .onChange(of: store.activeTab) { _, id in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }
            Button { store.newTab() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("새 탭 (⌘T)")
            .padding(.trailing, 8)
        }
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chip(_ tab: FeedStore.Place) -> some View {
        let active = tab.id == store.activeTab
        let hovered = hover.id == tab.id
        return HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? theme.style : AnyShapeStyle(Color.secondary))
                .frame(width: 14)
            Text(tab.title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 닫기: 지금 탭이거나 마우스를 올렸을 때만 (탭이 하나면 없음)
            if store.tabs.count > 1 {
                Button { store.closeTab(tab.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.primary.opacity(hovered ? 0.08 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(active || hovered ? 1 : 0)
                .help("탭 닫기")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 168, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(active ? 0.10 : hovered ? 0.05 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(active ? Color.primary.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectTab(tab.id) }
        .onHover { inside in
            if inside { hover.id = tab.id } else if hover.id == tab.id { hover.id = nil }
        }
        .help(tab.title)
        .contextMenu {
            Button("새 탭") { store.newTab() }
            Button("탭 복제") { store.duplicateTab(tab.id) }
            Divider()
            Button("탭 닫기") { store.closeTab(tab.id) }
                .disabled(store.tabs.count < 2)
            Button("다른 탭 모두 닫기") { store.closeOtherTabs(tab.id) }
                .disabled(store.tabs.count < 2)
        }
    }
}

/// 마우스가 올라가 있는 탭
@MainActor
final class TabHover: ObservableObject {
    @Published var id: UUID?
}
