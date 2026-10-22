import SwiftUI
import WebKit

// 앱이 직접 그리는 영상 목록: 홈·구독·검색·기록·재생목록·나중에 볼 동영상·좋아요·내 동영상 (yt-dlp로 목록만 받아 옴)

/// 목록의 영상 하나 (yt-dlp --flat-playlist -j 한 줄)
struct FeedVideo: Identifiable, Hashable, Decodable {
    struct Thumbnail: Hashable, Decodable {
        let url: String
        let width: Int?
    }

    let id: String
    let title: String?
    let channel: String?
    let uploader: String?
    let duration: Double?
    let viewCount: Int?
    let liveStatus: String?
    let url: String?
    let thumbnails: [Thumbnail]?
    /// "Youtube" = 영상, "YoutubeTab" = 재생목록·채널
    let ieKey: String?

    var displayTitle: String { title ?? "제목 없음" }
    var channelName: String { channel ?? uploader ?? "" }
    var isLive: Bool { liveStatus == "is_live" }
    var isShorts: Bool { url?.contains("/shorts/") == true }
    /// 영상 코드는 11자리 ("Mix" 같은 자동 재생목록은 RD로 시작하는 긴 코드라 빠짐)
    var isVideo: Bool { ieKey != "YoutubeTab" && id.count == 11 }
    var isPlaylist: Bool { ieKey == "YoutubeTab" }

    var watchURL: String {
        if let url, url.contains("youtube.com/") { return url }
        return "https://www.youtube.com/watch?v=\(id)"
    }

    /// 가장 큰 썸네일, 없으면 유튜브 기본 썸네일 주소
    /// 믹스 재생목록(RD…)의 첫 영상 코드: RD 뒤 11자, 아니면 썸네일 주소의 /vi/<코드>/
    var mixSeed: String? {
        guard CollectionRef.isMix(id) else { return nil }
        let rest = String(id.dropFirst(2))
        if rest.count == 11 { return rest }
        guard let path = thumbnailURL?.path, let range = path.range(of: #"/vi/[A-Za-z0-9_-]{11}/"#, options: .regularExpression) else { return nil }
        return String(path[range].dropFirst(4).dropLast())
    }

    var thumbnailURL: URL? {
        guard var best = thumbnails?.max(by: { ($0.width ?? 0) < ($1.width ?? 0) })?.url else {
            return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }
        if best.hasPrefix("//") { best = "https:" + best }   // 채널 사진은 "//yt3..."처럼 https: 없이 옴
        return URL(string: best)
    }

    /// 3:45, 1:02:03
    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let t = Int(duration)
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// 조회수 1.2만회, 3.4억회
    var viewText: String? { viewCount.map(Self.viewText) }

    static func viewText(_ v: Int) -> String {
        func short(_ x: Double) -> String { x >= 10 ? String(Int(x)) : String(format: "%.1f", x).replacingOccurrences(of: ".0", with: "") }
        if v >= 100_000_000 { return "조회수 \(short(Double(v) / 100_000_000))억회" }
        if v >= 10_000 { return "조회수 \(short(Double(v) / 10_000))만회" }
        return "조회수 \(v)회"
    }

    var playerItem: PlayerItem { PlayerItem(id: id, title: displayTitle, url: watchURL) }
}

/// 사이드바 항목
enum FeedTab: String, CaseIterable, Identifiable, Codable {
    case home, newToYou, watchedAgain, recentUploads, subscriptions, search, history, playlists, watchLater, liked, myVideos, queue, web, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "홈"
        case .newToYou: "새로운 맞춤 동영상"
        case .watchedAgain: "감상한 동영상"
        case .recentUploads: "최근에 업로드된 동영상"
        case .subscriptions: "구독"
        case .search: "검색"
        case .history: "기록"
        case .playlists: "재생목록"
        case .watchLater: "나중에 볼 동영상"
        case .liked: "좋아요 표시한 동영상"
        case .myVideos: "내 동영상"
        case .queue: "재생 대기열"
        case .web: "유튜브 사이트"
        case .settings: "설정"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .newToYou: "sparkles.tv"
        case .watchedAgain: "eye"
        case .recentUploads: "clock.badge"
        case .subscriptions: "rectangle.stack.badge.play"
        case .search: "magnifyingglass"
        case .history: "clock.arrow.circlepath"
        case .playlists: "list.bullet.rectangle"
        case .watchLater: "clock"
        case .liked: "hand.thumbsup"
        case .myVideos: "play.square.stack"
        case .queue: "list.number"
        case .web: "globe"
        case .settings: "gearshape"
        }
    }

    /// 유튜브 홈 위쪽 칩 이름 (이 메뉴는 그 칩을 누른 결과)
    var homeChip: String? {
        switch self {
        case .newToYou: "새로운 맞춤 동영상"
        case .watchedAgain: "감상한 동영상"
        case .recentUploads: "최근에 업로드된 동영상"
        default: nil
        }
    }
}

/// 화질 선택: 이 화질 이상인 영상만 보여 줌 (짧은 변 기준이라 세로 영상도 같게)
enum QualityFilter: String, CaseIterable, Identifiable {
    case all, hd720, fhd1080, qhd1440, uhd4k, vr, live
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "전체"
        case .hd720: "720p+"
        case .fhd1080: "1080p+"
        case .qhd1440: "2K+"
        case .uhd4k: "4K"
        case .vr: "VR"
        case .live: "라이브"
        }
    }

    /// 영상마다 화질을 따로 확인해야 하는지 (라이브는 목록 정보만으로 앎)
    var needsProbe: Bool { self != .all && self != .live }

    func accepts(_ q: VideoQuality) -> Bool {
        switch self {
        case .all: true
        case .hd720: q.shortSide >= 720
        case .fhd1080: q.shortSide >= 1080
        case .qhd1440: q.shortSide >= 1440
        case .uhd4k: q.shortSide >= 2160
        case .vr: q.isVR
        case .live: true
        }
    }

    /// 검색할 때 유튜브 자체 필터의 "기능" 값 (HD·4K·360°·라이브)
    var searchFeatureBytes: [UInt8] {
        switch self {
        case .all: []
        case .hd720, .fhd1080, .qhd1440: [0x20, 0x01]
        case .uhd4k: [0x70, 0x01]
        case .vr: [0x78, 0x01]
        case .live: [0x40, 0x01]
        }
    }
}

/// 업로드 날짜 (검색에 적용)
enum UploadDate: UInt8, CaseIterable, Identifiable {
    case all = 0, today = 2, week = 3, month = 4, year = 5
    var id: UInt8 { rawValue }
    var label: String {
        switch self {
        case .all: "전체"
        case .today: "오늘"
        case .week: "이번 주"
        case .month: "이번 달"
        case .year: "올해"
        }
    }
}

/// 우선순위 = 정렬 (검색에 적용)
enum SortOrder: UInt8, CaseIterable, Identifiable {
    case relevance = 0, popularity = 3
    var id: UInt8 { rawValue }
    var label: String { self == .relevance ? "관련성" : "인기도" }
}

/// 구분 (검색에 적용, Shorts는 뺌)
enum ResultKind: UInt8, CaseIterable, Identifiable {
    case all = 0, video = 1, channel = 2, playlist = 3, movie = 4
    var id: UInt8 { rawValue }
    var label: String {
        switch self {
        case .all: "전체"
        case .video: "동영상"
        case .channel: "채널"
        case .playlist: "재생목록"
        case .movie: "영화"
        }
    }
}

/// 유튜브 검색 필터 값(sp) 만들기: 정렬 + (날짜·구분·기능)을 유튜브 형식(protobuf)으로 묶어 base64
enum SearchFilter {
    static func param(date: UploadDate, sort: SortOrder, kind: ResultKind, feature: QualityFilter) -> String? {
        var inner: [UInt8] = []
        if date != .all { inner += [0x08, date.rawValue] }
        if kind != .all { inner += [0x10, kind.rawValue] }
        inner += feature.searchFeatureBytes
        var bytes: [UInt8] = []
        if sort != .relevance { bytes += [0x08, sort.rawValue] }
        if !inner.isEmpty { bytes += [0x12, UInt8(inner.count)] + inner }
        guard !bytes.isEmpty else { return nil }
        // yt-dlp에 넘길 때는 두 번 인코딩해야 유튜브가 필터로 알아들음 (시험으로 확인)
        let once = Data(bytes).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return once.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    }
}

/// 영상별 최고 화질 확인 (영상 하나에 약 3초 → 몇 개씩 묶어 동시에, 결과는 파일에 저장해 다시 묻지 않음)
@MainActor
final class QualityStore: ObservableObject {
    static let shared = QualityStore()

    @Published private(set) var known: [String: VideoQuality] = [:]
    /// 영상 등록 정보 (날짜·올린 시각·조회수) — 목록 정보에는 없어서 영상마다 따로 확인
    @Published private(set) var metas: [String: VideoMeta] = [:]
    private var queued: [String] = []
    private var inFlight: Set<String> = []
    private var running = 0
    private let maxWorkers = 4
    private let batchSize = 4

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("quality.json")
    }()
    private var metaURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("meta.json") }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: VideoQuality].self, from: data) {
            known = saved
        }
        if let data = try? Data(contentsOf: metaURL),
           let saved = try? JSONDecoder().decode([String: VideoMeta].self, from: data) {
            metas = saved
        }
    }

    /// 화질이나 등록 날짜를 아직 모르는 영상만 확인 줄에 세움
    func request(_ ids: [String]) {
        for id in ids where (known[id] == nil || metas[id] == nil) && !inFlight.contains(id) && !queued.contains(id) {
            queued.append(id)
        }
        pump()
    }

    /// 화면에서 사라진 카드는 아직 시작 안 했으면 줄에서 뺌 (보이는 것 먼저)
    func forget(_ id: String) {
        queued.removeAll { $0 == id }
    }

    /// 화질 선택을 "전체"로 돌리면 기다리던 확인은 취소
    func cancelQueued() { queued.removeAll() }

    private func pump() {
        while running < maxWorkers, !queued.isEmpty {
            let batch = Array(queued.prefix(batchSize))
            queued.removeFirst(batch.count)
            inFlight.formUnion(batch)
            running += 1
            Task {
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                let found = await YTDLP.probeQuality(batch, cookies: cookies)
                for (id, info) in found {
                    known[id] = info.quality
                    metas[id] = info.meta
                }
                inFlight.subtract(batch)
                running -= 1
                save()
                pump()
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(known) { try? data.write(to: fileURL, options: .atomic) }
        if let data = try? JSONEncoder().encode(metas) { try? data.write(to: metaURL, options: .atomic) }
    }
}

/// 위쪽 검색 방식
enum SearchMode: String, CaseIterable, Identifiable {
    case ai, basic, url
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ai: "AI"
        case .basic: "기본"
        case .url: "URL"
        }
    }
    var icon: String {
        switch self {
        case .ai: "sparkles"
        case .basic: "magnifyingglass"
        case .url: "link"
        }
    }
    var placeholder: String {
        switch self {
        case .ai: "보고 싶은 영상을 말로 설명해 주세요 (재미나이)"
        case .basic: "유튜브 검색"
        case .url: "유튜브 링크 붙여넣기 (영상·재생목록·채널)"
        }
    }
}

/// URL 칸에 넣은 링크가 무엇인지
enum LinkTarget {
    case video(PlayerItem)
    case collection(CollectionRef)
    case invalid

    static func parse(_ text: String) -> LinkTarget {
        guard let url = Browser.youtubeURL(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .invalid }
        let list = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "list" }?.value
        if url.path == "/playlist", let list {
            return .collection(CollectionRef(kind: .playlist, id: list, title: "재생목록"))
        }
        if let id = YTDLP.videoID(from: url) {
            return .video(PlayerItem(id: id, title: "유튜브 영상", url: "https://www.youtube.com/watch?v=\(id)"))
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, parts[0] == "channel" {
            return .collection(CollectionRef(kind: .channel, id: parts[1], title: "채널"))
        }
        if let handle = parts.first, handle.hasPrefix("@") {
            return .collection(CollectionRef(kind: .channel, id: handle, title: handle))
        }
        return .invalid
    }
}

/// 열어 본 재생목록·채널
struct CollectionRef: Hashable, Codable {
    enum Kind: String, Codable { case playlist, channel }
    let kind: Kind
    let id: String
    let title: String
    /// 믹스(RD…)의 첫 영상: 믹스는 재생목록 주소로는 못 열고 "첫 영상 + 목록" 주소로만 열림
    var seed: String? = nil

    var key: String { seed.map { "\(kind.rawValue):\(id)|\($0)" } ?? "\(kind.rawValue):\(id)" }

    /// 유튜브가 자동으로 만든 믹스 재생목록인지 (RD로 시작)
    static func isMix(_ id: String) -> Bool { id.hasPrefix("RD") }
}

/// 목록 상태: 목록마다 받아 온 항목과 불러오는 중·오류를 들고 있음
@MainActor
final class FeedStore: ObservableObject {
    static let shared = FeedStore()
    static let pageSize = 30

    init() { restoreTabs() }

    struct Page {
        var items: [FeedVideo] = []
        var isLoading = false
        var error: String?
        var reachedEnd = false
    }

    @Published var selection: FeedTab = FeedStore.savedTab {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: "feedTab")
            opened = nil
            if selection == .subscriptions { NewVideoWatcher.shared.newCount = 0 }
            syncTab()
        }
    }
    @Published private(set) var query = "" { didSet { syncTab() } }

    // MARK: 탭 (브라우저처럼 위쪽에 "지금 어디를 보고 있는지"를 여러 개 열어 두기)

    /// 탭 하나 = 보고 있는 곳 (메뉴 + 열어 본 채널·재생목록 + 검색어)
    struct Place: Codable, Identifiable, Equatable {
        var id = UUID()
        var selection: FeedTab
        var opened: CollectionRef?
        var query: String
        var aiNote: String?

        var title: String {
            if let opened { return opened.title }
            if selection == .search { return query.isEmpty ? "검색" : query }
            return selection.title
        }
        var icon: String {
            if let opened { return opened.kind == .channel ? "person.crop.square" : "list.bullet.rectangle" }
            return selection.icon
        }
    }

    @Published private(set) var tabs: [Place] = []
    @Published private(set) var activeTab = UUID()
    /// 탭을 바꾸는 중 (그동안은 지금 상태를 탭에 다시 써넣지 않음)
    private var switching = false

    /// 처음: 저장해 둔 탭들을 되살림 (없으면 지금 화면 하나)
    private func restoreTabs() {
        if let data = UserDefaults.standard.data(forKey: "feedTabs"),
           let saved = try? JSONDecoder().decode([Place].self, from: data), !saved.isEmpty {
            tabs = saved.map { var p = $0; if p.selection == .web { p.selection = .home }; return p }
            let id = UUID(uuidString: UserDefaults.standard.string(forKey: "feedActiveTab") ?? "")
            show(tabs.first { $0.id == id } ?? tabs[0])
        } else {
            let first = Place(selection: selection, opened: opened, query: query, aiNote: aiNote)
            tabs = [first]
            activeTab = first.id
        }
    }

    /// 지금 보이는 곳을 지금 탭에 적어 둠 (메뉴·검색·채널 열기가 바뀔 때마다)
    private func syncTab() {
        guard !switching, let index = tabs.firstIndex(where: { $0.id == activeTab }) else { return }
        let now = Place(id: activeTab, selection: selection, opened: opened, query: query, aiNote: aiNote)
        if tabs[index] != now {
            tabs[index] = now
            saveTabs()
        }
    }

    private func saveTabs() {
        if let data = try? JSONEncoder().encode(tabs) { UserDefaults.standard.set(data, forKey: "feedTabs") }
        UserDefaults.standard.set(activeTab.uuidString, forKey: "feedActiveTab")
    }

    /// 그 탭의 곳을 화면에 보여 줌 (받아 둔 목록은 그대로라 바로 보임)
    private func show(_ place: Place) {
        switching = true
        activeTab = place.id
        selection = place.selection
        opened = place.opened
        query = place.query
        aiNote = place.aiNote
        switching = false
        saveTabs()
    }

    func selectTab(_ id: UUID) {
        guard id != activeTab, let place = tabs.first(where: { $0.id == id }) else { return }
        show(place)
    }

    /// 새 탭 (기본: 홈). 지금 탭 바로 오른쪽에
    func newTab(_ place: Place? = nil) {
        let next = place ?? Place(selection: .home, opened: nil, query: "", aiNote: nil)
        let index = (tabs.firstIndex { $0.id == activeTab } ?? tabs.count - 1) + 1
        tabs.insert(next, at: min(index, tabs.count))
        show(next)
    }

    /// 채널·재생목록을 새 탭으로 (재생 창의 "채널로 가기" 등)
    func openInNewTab(_ ref: CollectionRef) {
        // 이미 그 채널을 연 탭이 있으면 그 탭으로
        if let existing = tabs.first(where: { $0.opened == ref }) {
            selectTab(existing.id)
            return
        }
        newTab(Place(selection: selection == .web || selection == .settings ? .home : selection,
                     opened: ref, query: query, aiNote: nil))
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if id == activeTab {
            show(tabs[min(index, tabs.count - 1)])   // 오른쪽 탭으로 (마지막이면 왼쪽)
        } else {
            saveTabs()
        }
    }

    func closeActiveTab() { closeTab(activeTab) }

    func closeOtherTabs(_ id: UUID) {
        guard let keep = tabs.first(where: { $0.id == id }) else { return }
        tabs = [keep]
        show(keep)
    }

    func duplicateTab(_ id: UUID) {
        guard var copy = tabs.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        selectTab(id)
        newTab(copy)
    }

    /// 다음·이전 탭 (끝에서는 반대쪽 끝으로)
    func cycleTab(_ step: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == activeTab }) else { return }
        selectTab(tabs[(index + step + tabs.count) % tabs.count].id)
    }

    func selectTab(at number: Int) {
        guard tabs.indices.contains(number) else { return }
        selectTab(tabs[number].id)
    }
    @Published var quality: QualityFilter = QualityFilter(rawValue: UserDefaults.standard.string(forKey: "qualityFilter") ?? "") ?? .all {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "qualityFilter")
        }
    }
    /// 썸네일 카드 너비 (오른쪽 위 막대로 조절, 다음 실행에도 유지)
    @Published var cardWidth: Double = UserDefaults.standard.object(forKey: "cardWidth") as? Double ?? 260 {
        didSet { UserDefaults.standard.set(cardWidth, forKey: "cardWidth") }
    }
    /// 보기 방식: 격자(false) / 목록형(true)
    @Published var listMode = UserDefaults.standard.bool(forKey: "listMode") {
        didSet { UserDefaults.standard.set(listMode, forKey: "listMode") }
    }
    /// 열어 본 재생목록·채널 (재생목록 탭, 또는 검색에서 채널·재생목록을 눌렀을 때)
    @Published var opened: CollectionRef? { didSet { syncTab() } }
    /// 검색 필터 (업로드 날짜·우선순위·구분). 바뀌면 검색 결과를 새로 받음
    @Published var uploadDate = UploadDate.all { didSet { filtersChanged() } }
    @Published var sort = SortOrder.relevance { didSet { filtersChanged() } }
    @Published var kind = ResultKind.all { didSet { filtersChanged() } }

    /// 위쪽 검색 방식 (다음 실행에도 유지)
    @Published var searchMode: SearchMode = SearchMode(rawValue: UserDefaults.standard.string(forKey: "searchMode") ?? "") ?? .basic {
        didSet { UserDefaults.standard.set(searchMode.rawValue, forKey: "searchMode") }
    }
    /// 재미나이가 생각 중
    @Published private(set) var aiBusy = false
    /// AI 검색이 어떻게 찾았는지 한 줄 (검색 결과 위에 보여 줌)
    @Published private(set) var aiNote: String? { didSet { syncTab() } }

    /// AI 검색: 재미나이가 검색어·필터를 정하면 그대로 검색
    func aiSearch(_ request: String) {
        guard !aiBusy else { return }
        aiBusy = true
        Task {
            defer { aiBusy = false }
            do {
                let plan = try await GeminiCLI.plan(for: request)
                uploadDate = ["today": .today, "week": .week, "month": .month, "year": .year][plan.uploadDate ?? ""] ?? .all
                sort = plan.sort == "popularity" ? .popularity : .relevance
                kind = ["video": .video, "channel": .channel, "playlist": .playlist, "movie": .movie][plan.kind ?? ""] ?? .all
                quality = QualityFilter(rawValue: plan.feature ?? "") ?? .all
                search(plan.query)
                aiNote = plan.note ?? "재미나이가 정한 검색어로 찾았어요"
            } catch {
                DebugLog.write("AI 검색 실패: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "AI 검색을 하지 못했어요"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// 검색 필터는 검색 결과에만 적용: 검색어가 있으면 검색 결과로 이동
    private func filtersChanged() {
        opened = nil
        if !query.isEmpty, selection != .search { selection = .search }
    }

    private var searchParam: String? {
        SearchFilter.param(date: uploadDate, sort: sort, kind: kind, feature: quality)
    }
    @Published private(set) var pages: [String: Page] = [:]
    /// 다시 불러오면 이전 요청 결과는 버리려고 세는 번호
    private var generation: [String: Int] = [:]
    private var myChannelID: String?
    /// 홈 칩 목록의 다음 묶음 표
    private var chipTokens: [String: String] = [:]

    private static var savedTab: FeedTab {
        let tab = FeedTab(rawValue: UserDefaults.standard.string(forKey: "feedTab") ?? "") ?? .home
        return tab == .web ? .home : tab   // 유튜브 사이트는 메뉴에서만 열므로 시작은 홈
    }

    /// 지금 보이는 목록의 이름표
    var currentKey: String {
        if let opened { return opened.key }
        switch selection {
        case .search: return "search:\(searchParam ?? "")|\(query)"
        default: return selection.rawValue
        }
    }

    var currentTitle: String {
        if let opened { return opened.title }
        if selection == .search { return "검색: \(query)" }
        return selection.title
    }

    /// 영상 대신 재생목록·채널 카드를 보여 주는지
    var showsCollectionCards: Bool {
        guard opened == nil else { return false }
        return selection == .playlists || (selection == .search && (kind == .channel || kind == .playlist))
    }

    func page(_ key: String) -> Page { pages[key] ?? Page() }

    func loadIfNeeded(_ key: String) {
        guard selection != .web, selection != .settings, selection != .queue, pages[key] == nil else { return }
        reload(key)
    }

    func reload(_ key: String) {
        generation[key, default: 0] += 1
        pages[key] = Page()
        loadMore(key)
    }

    func reloadCurrent() { reload(currentKey) }

    /// 로그인·로그아웃 뒤: 받아 둔 목록을 모두 버리고 지금 화면부터 새로
    func reloadAll() {
        for key in pages.keys { generation[key, default: 0] += 1 }
        pages = [:]
        chipTokens = [:]
        myChannelID = nil
        loadIfNeeded(currentKey)
    }

    func search(_ text: String) {
        aiNote = nil
        opened = nil
        query = text
        selection = .search
        reload(currentKey)
    }

    /// 다음 묶음 불러오기 (맨 아래까지 내리면 자동으로)
    func loadMore(_ key: String) {
        var page = self.page(key)
        guard !page.isLoading, !page.reachedEnd else { return }
        let start = page.items.count + 1
        let end = page.items.count + Self.pageSize
        page.isLoading = true
        page.error = nil
        pages[key] = page
        let gen = generation[key, default: 0]

        Task {
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            // 홈 칩(새로운 맞춤·감상한·최근 업로드): 유튜브에서 직접, 다음 묶음은 받은 표로
            if let chip = FeedTab(rawValue: key)?.homeChip {
                do {
                    let first = start == 1
                    guard first || chipTokens[key] != nil else {
                        finish(key, gen) { $0.reachedEnd = true }
                        return
                    }
                    let (items, next) = try await YouTubeHome.chip(chip, continuation: first ? nil : chipTokens[key], cookies: cookies)
                    chipTokens[key] = next
                    finish(key, gen) { page in
                        let known = Set(page.items.map(\.id))
                        page.items += items.filter { !known.contains($0.id) }
                        page.reachedEnd = next == nil
                    }
                    DebugLog.write("목록 \(key): \(items.count)개 받음 (모두 \(self.page(key).items.count)개)")
                } catch {
                    finish(key, gen) { $0.error = error.localizedDescription }
                }
                return
            }
            do {
                guard let source = await source(for: key, upTo: end, cookies: cookies) else {
                    finish(key, gen) { $0.reachedEnd = true }
                    return
                }
                let items = try await YTDLP.listFeed(source, from: start, to: end, cookies: cookies)
                finish(key, gen) { page in
                    let known = Set(page.items.map(\.id))
                    page.items += items.filter { !known.contains($0.id) }
                    page.reachedEnd = items.count < Self.pageSize / 2
                }
                DebugLog.write("목록 \(key): \(items.count)개 받음 (모두 \(self.page(key).items.count)개)")
            } catch {
                let message = error.localizedDescription
                // 올린 영상이 없는 채널은 "영상 탭 없음" 오류가 남 → 빈 목록으로
                if message.contains("does not have a videos tab") {
                    finish(key, gen) { $0.reachedEnd = true }
                } else {
                    finish(key, gen) { $0.error = message }
                }
            }
        }
    }

    private func finish(_ key: String, _ gen: Int, _ change: (inout Page) -> Void) {
        guard generation[key, default: 0] == gen else { return }
        var page = self.page(key)
        page.isLoading = false
        change(&page)
        pages[key] = page
    }

    private func source(for key: String, upTo end: Int, cookies: [HTTPCookie]) async -> String? {
        if key.hasPrefix("playlist:") {
            let rest = key.dropFirst("playlist:".count)
            // 믹스: "목록|첫 영상" → 첫 영상 주소에 목록을 붙여 받음 (재생목록 주소로는 "볼 수 없는 종류"라고 거절됨)
            let parts = rest.split(separator: "|", maxSplits: 1)
            if parts.count == 2 { return "https://www.youtube.com/watch?v=\(parts[1])&list=\(parts[0])" }
            if CollectionRef.isMix(String(rest)), rest.count == 13 {
                return "https://www.youtube.com/watch?v=\(rest.dropFirst(2))&list=\(rest)"
            }
            return "https://www.youtube.com/playlist?list=\(rest)"
        }
        if key.hasPrefix("channel:") {
            let id = key.dropFirst("channel:".count)
            // 채널 코드(UC…) 또는 @이름
            return id.hasPrefix("UC") ? "https://www.youtube.com/channel/\(id)/videos" : "https://www.youtube.com/\(id)/videos"
        }
        if key.hasPrefix("search:") {
            guard !query.isEmpty else { return nil }
            if let sp = searchParam,
               let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                return "https://www.youtube.com/results?search_query=\(q)&sp=\(sp)"
            }
            return "ytsearch\(end):\(query)"
        }
        switch FeedTab(rawValue: key) {
        case .home: return ":ytrec"
        case .subscriptions: return ":ytsubs"
        case .history: return ":ythistory"
        case .playlists: return "https://www.youtube.com/feed/playlists"
        case .watchLater: return ":ytwatchlater"
        case .liked: return "https://www.youtube.com/playlist?list=LL"
        case .myVideos:
            if myChannelID == nil { myChannelID = await YTDLP.myChannelID(cookies: cookies) }
            return myChannelID.map { "https://www.youtube.com/channel/\($0)/videos" }
        default: return nil
        }
    }
}

// MARK: - 화면

struct FeedSidebar: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: FeedStore
    @ObservedObject private var queue = PlayQueue.shared
    @ObservedObject private var watcher = NewVideoWatcher.shared

    var body: some View {
        List(selection: Binding(get: { store.selection }, set: { if let tab = $0 { store.selection = tab } })) {
            Section("MyTube") {
                row(.home)
                // 홈 칩: 유튜브 홈 위쪽의 고르기와 같은 결과
                ForEach([FeedTab.newToYou, .watchedAgain, .recentUploads]) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .padding(.leading, 12)
                        .tag(tab)
                }
                // 구독: 새 영상 알림이 오면 옆에 개수
                Label(FeedTab.subscriptions.title, systemImage: FeedTab.subscriptions.icon)
                    .badge(watcher.newCount)
                    .tag(FeedTab.subscriptions)
                // 재생 대기열 (개수)
                Label(FeedTab.queue.title, systemImage: FeedTab.queue.icon)
                    .badge(queue.entries.count)
                    .tag(FeedTab.queue)
                if !store.query.isEmpty {
                    Label("검색: \(store.query)", systemImage: FeedTab.search.icon)
                        .lineLimit(1)
                        .tag(FeedTab.search)
                }
            }
            Section("나") {
                ForEach([FeedTab.history, .playlists, .watchLater, .liked, .myVideos]) { row($0) }
            }
            // 맨 아래: 설정
            Section {
                row(.settings)
            }
        }
        .listStyle(.sidebar)
        // 맨 위: 유튜브 계정 (로그인 안 돼 있으면 로그인 단추)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                AccountRow()
                Divider()
            }
        }
        // 썸네일 크기: 사이드바 맨 아래에 늘 떠 있게 (목록을 내려도 보임)
        .safeAreaInset(edge: .bottom, spacing: 0) { cardSize }
    }

    private var cardSize: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("썸네일 크기")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { store.cardWidth = max(160, store.cardWidth - 60) } label: {
                    Image(systemName: "square.grid.3x3")
                }
                .help("썸네일 작게")
                Slider(value: $store.cardWidth, in: 160...520)
                    .controlSize(.mini)
                Button { store.cardWidth = min(520, store.cardWidth + 60) } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .help("썸네일 크게")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func row(_ tab: FeedTab) -> some View {
        Label(tab.title, systemImage: tab.icon).tag(tab)
    }

    /// 주황 제목 + 단추 격자 + (있으면) 아래쪽 회색 설명
    private func filterSection(_ title: String, note: String?, @ViewBuilder content: () -> some View) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                content()
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 6)
            .selectionDisabled()
            .listRowBackground(Color.clear)
        } header: {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(theme.style)
                .textCase(nil)
                .padding(.top, 6)
        }
    }
}

/// 고르는 단추 격자 (두 칸씩, 고른 것은 주황 테두리·글자)
/// none이 있으면 고른 단추를 다시 눌러 해제할 수 있음 (해제 = none 값, 보통 "전체")
struct ChipGrid<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    let options: [(Value, String)]
    @Binding var selection: Value
    let none: Value?

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(options, id: \.0) { value, label in
                let selected = selection == value
                Button {
                    if selected, let none { selection = none } else { selection = value }
                } label: {
                    // 고르지 않은 것은 가늘고 옅게, 고른 것만 주황으로 조금 굵게
                    Text(label)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .foregroundStyle(selected ? theme.style : AnyShapeStyle(Color.secondary))
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(selected ? theme.accent.opacity(0.10) : Color.primary.opacity(0.045)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected ? theme.style : AnyShapeStyle(Color.clear), lineWidth: 1.2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 썸네일 카드 격자 (영상 또는 재생목록)
struct FeedGridView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: FeedStore
    @ObservedObject private var qualities = QualityStore.shared
    @ObservedObject private var filter = ContentFilter.shared
    @ObservedObject private var marks = WatchMarks.shared

    var body: some View {
        let key = store.currentKey
        let page = store.page(key)
        let cards = store.showsCollectionCards
        let filtering = store.quality != .all && !cards
        let probing = filtering && store.quality.needsProbe
        let videos = page.items.filter(\.isVideo)
        let pending = probing ? videos.filter { qualities.known[$0.id] == nil }.count : 0
        // 목록 정리(쇼츠·숨긴 채널·키워드·본 영상)는 직접 연 채널에서는 빼고 적용
        let cleaned = store.opened?.kind == .channel ? videos : videos.filter(filter.allows)
        let shown: [FeedVideo] = cards
            ? page.items.filter { $0.isPlaylist && !["LL", "WL"].contains($0.id) }   // 좋아요·나중에 볼은 메뉴에 따로 있음
            : !filtering ? cleaned
            : store.quality == .live ? cleaned.filter(\.isLive)
            : cleaned.filter { qualities.known[$0.id].map(store.quality.accepts) ?? false }

        ScrollView {
          // 게으른 묶음: 맨 아래 "더 불러오기"가 실제로 화면에 보일 때만 나타나게
          // (그냥 묶으면 안 보여도 바로 나타나서 끝없이 더 불러오며 네트워크를 잡아먹었음)
          LazyVStack(spacing: 0) {
            if store.selection == .search, store.opened == nil, let note = store.aiNote {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(theme.style)
                    Text(note).lineLimit(2)
                    Text("· 검색어: \(store.query)").foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
            if let opened = store.opened {
                HStack {
                    Button { store.opened = nil } label: { Label("뒤로", systemImage: "chevron.left") }
                    .buttonStyle(.link)
                    Text(opened.title).font(.headline).lineLimit(1)
                    Spacer()
                    // 재생목록·채널 전체를 차례로 (듣기 모드면 소리만)
                    if !shown.isEmpty {
                        Button { PlayQueue.shared.playAll(shown, listen: false) } label: { Label("모두 재생", systemImage: "play.fill") }
                        Button { PlayQueue.shared.playAll(shown, listen: true) } label: { Label("모두 듣기", systemImage: "headphones") }
                        Button { PlayQueue.shared.add(shown) } label: { Label("대기열에 추가", systemImage: "text.badge.plus") }
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            // 처음 불러오는 동안: 카드 모양 자리 (반짝임)
            if shown.isEmpty, page.isLoading {
                SkeletonGrid(width: store.cardWidth, rows: store.listMode && !cards)
                    .padding(20)
            }

            if store.listMode && !cards {
                LazyVStack(spacing: 6) {
                    ForEach(shown) { item in
                        VideoCard(video: item, quality: qualities.known[item.id], meta: qualities.metas[item.id], rowLayout: true)
                            .onAppear { qualities.request([item.id]) }
                            .onDisappear { qualities.forget(item.id) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: store.cardWidth, maximum: store.cardWidth * 1.5), spacing: 18, alignment: .top)],
                      spacing: 24) {
                ForEach(shown) { item in
                    if cards {
                        PlaylistCard(playlist: item) {
                            // 채널 코드는 UC로 시작
                            let kind: CollectionRef.Kind = item.id.hasPrefix("UC") ? .channel : .playlist
                            store.opened = CollectionRef(kind: kind, id: item.id, title: item.displayTitle,
                                                         seed: kind == .playlist ? item.mixSeed : nil)
                        }
                    } else {
                        VideoCard(video: item, quality: qualities.known[item.id], meta: qualities.metas[item.id])
                            .onAppear { qualities.request([item.id]) }   // 보이는 카드만 화질·등록 날짜 확인
                            .onDisappear { qualities.forget(item.id) }
                    }
                }
            }
            .padding(20)
            }

            footer(page, key: key, pending: pending, shownCount: shown.count)
                .padding(.bottom, 30)
          }
        }
        // 맨 위: 고르기 줄 (기능별·화질, 검색이면 날짜·정렬·구분, 격자/목록)
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterBar(store: store)
        }
        .overlay(alignment: .top) {
            if store.aiBusy {
                Label("재미나이가 찾는 중…", systemImage: "sparkles")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
            }
        }
        .overlay {
            if shown.isEmpty, !page.isLoading, pending == 0, page.reachedEnd || page.error != nil || (store.selection == .search && store.query.isEmpty) {
                emptyState(page, key: key, filtering: filtering, hiddenByCleanup: !videos.isEmpty && cleaned.isEmpty)
            }
        }
        .task(id: key) { store.loadIfNeeded(key) }
        // 화질을 골랐으면 받아 온 영상들의 화질을 확인 (이미 아는 건 건너뜀)
        .task(id: "\(key)|\(store.quality.rawValue)|\(page.items.count)") {
            if probing { qualities.request(videos.map(\.id)) }
        }
    }

    @ViewBuilder private func footer(_ page: FeedStore.Page, key: String, pending: Int, shownCount: Int) -> some View {
        if page.isLoading, !page.items.isEmpty {
            ProgressView("더 불러오는 중…")
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else if pending > 0 {
            ProgressView("화질 확인 중… \(pending)개 남음 (\(store.quality.label) \(shownCount)개 찾음)")
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        } else if !page.items.isEmpty, !page.reachedEnd, page.error == nil {
            // 맨 아래가 보이면 자동으로 다음 묶음 불러오기 (600개가 넘으면 단추로만)
            Button("더 불러오기") { store.loadMore(key) }
                .onAppear { if page.items.count < 600 { store.loadMore(key) } }
                .frame(maxWidth: .infinity)
        } else if let error = page.error, !page.items.isEmpty {
            VStack(spacing: 6) {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button("다시 시도") { store.loadMore(key) }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 빈 화면·오류 화면: 큰 아이콘 + 한 줄 설명 + 바로 할 일 단추
    @ViewBuilder private func emptyState(_ page: FeedStore.Page, key: String, filtering: Bool, hiddenByCleanup: Bool) -> some View {
        let missingTools = ToolCheck.missing
        // 로그인이 필요한 목록 (검색·직접 연 채널/재생목록은 로그인 없이도 됨)
        let needsAccount = store.opened == nil && store.selection != .search
        if !missingTools.isEmpty {
            EmptyStateView(icon: "wrench.and.screwdriver", title: "필요한 도구가 없어요: " + missingTools.joined(separator: ", "),
                           message: "영상 목록·재생에 yt-dlp·deno·ffmpeg가 필요해요. 터미널에서 아래 명령으로 설치한 뒤 앱을 다시 켜 주세요.\n\(ToolCheck.command)") {
                Button("명령 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ToolCheck.command, forType: .string)
                    Toast.shared.show("복사했어요. 터미널에 붙여 넣어 실행해 주세요")
                }
                .buttonStyle(.borderedProminent)
                Button("Homebrew 안내 열기") { NSWorkspace.shared.open(URL(string: "https://brew.sh/ko/")!) }
            }
        } else if needsAccount, YouTubeAccount.shared.status == .loggedOut {
            EmptyStateView(icon: "person.crop.circle.badge.plus", title: "유튜브에 로그인해 주세요",
                           message: "홈·구독·기록·재생목록·좋아요는 내 유튜브 계정으로 로그인해야 보여요. 검색은 로그인 없이도 돼요.") {
                Button("유튜브 로그인") { YouTubeAccount.shared.signIn() }
                    .buttonStyle(.borderedProminent)
            }
        } else if let error = page.error {
            let needsLogin = error.contains("로그인") || error.lowercased().contains("sign in") || error.contains("cookies")
            EmptyStateView(icon: needsLogin ? "person.crop.circle.badge.exclamationmark" : "wifi.exclamationmark",
                           title: needsLogin ? "유튜브 로그인이 필요해요" : "목록을 불러오지 못했어요",
                           message: error) {
                Button("다시 시도") { store.reload(key) }
                    .buttonStyle(.borderedProminent)
                if needsLogin { Button("유튜브 로그인하기") { store.selection = .web } }
            }
        } else if store.selection == .search, store.query.isEmpty {
            EmptyStateView(icon: "magnifyingglass", title: "무엇을 볼까요?",
                           message: "위쪽 검색 칸에 검색어를 넣어 주세요. AI를 고르면 말로 설명해도 찾아 줘요.") { EmptyView() }
        } else if filtering {
            EmptyStateView(icon: "line.3.horizontal.decrease.circle", title: "\(store.quality.label) 영상이 없어요",
                           message: "지금 받아 온 영상 중에는 고른 조건에 맞는 영상이 없어요.") {
                Button("조건 끄기") { store.quality = .all }.buttonStyle(.borderedProminent)
            }
        } else if hiddenByCleanup {
            EmptyStateView(icon: "eye.slash", title: "모두 숨겨졌어요",
                           message: "목록 정리(쇼츠·본 영상·숨긴 채널·낱말) 설정 때문에 보이는 영상이 없어요.") {
                Button("설정에서 목록 정리 보기") { store.selection = .settings }.buttonStyle(.borderedProminent)
            }
        } else {
            EmptyStateView(icon: store.selection == .queue ? "list.number" : "tray",
                           title: store.selection == .myVideos ? "올린 영상이 없어요" : "영상이 없어요",
                           message: "새로고침(⌘R)으로 다시 받아 볼 수 있어요.") {
                Button("새로고침") { store.reload(key) }
            }
        }
    }
}

/// 재생목록 카드: 누르면 그 재생목록의 영상들을 보여 줌
struct PlaylistCard: View {
    let playlist: FeedVideo
    let open: () -> Void

    private var isChannel: Bool { playlist.id.hasPrefix("UC") }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                Color.black.opacity(0.08)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: playlist.thumbnailURL) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Label(isChannel ? "채널" : "재생목록", systemImage: isChannel ? "person.crop.square" : "list.bullet")
                            .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
                            .padding(6)
                    }
                Text(playlist.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}

/// 영상 카드: 누르면 재생 창에서 바로 재생, 오른쪽 클릭으로 다운로드·링크 복사·웹에서 열기
struct VideoCard: View {
    @Environment(\.theme) private var theme
    let video: FeedVideo
    /// 확인된 최고 화질 (화면에 보이면 확인)
    var quality: VideoQuality? = nil
    /// 등록 정보: 날짜·올린 시각·조회수 (화면에 보이면 확인, 모르면 nil)
    var meta: VideoMeta? = nil
    @ObservedObject private var preview = HoverPreview.shared
    @ObservedObject private var marks = WatchMarks.shared
    /// 목록형(가로 한 줄) 모양
    var rowLayout = false
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: play) {
            Group {
                if rowLayout {
                    HStack(alignment: .top, spacing: 16) {
                        thumbnail.frame(width: 260)
                        rowInfo
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.primary.opacity(hover.isOn ? 0.05 : 0))
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        thumbnail
                            // 마우스를 올리면 썸네일이 살짝 떠오름
                            .shadow(color: .black.opacity(hover.isOn ? 0.22 : 0), radius: hover.isOn ? 10 : 0, y: hover.isOn ? 5 : 0)
                            .scaleEffect(hover.isOn ? 1.02 : 1)
                        gridInfo
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: hover.isOn)
            .onHover { hover.isOn = $0 }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        // 제목 말풍선은 미리 보기를 가려서 두지 않음 (제목은 카드 아래에 있음)
        .contextMenu {
            Button("재생 창에서 보기") { Playback.open(video.playerItem, listen: false) }
            Button("소리만 듣기 (듣기 모드)") { Playback.open(video.playerItem, listen: true) }
            Divider()
            Button("다음에 재생") { PlayQueue.shared.playNext(video) }
            Button("대기열에 추가") { PlayQueue.shared.add([video]) }
            Divider()
            Button("소리만 받기 (m4a)") {
                guard let url = URL(string: video.watchURL) else { return }
                Task {
                    let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                    DownloadManager.shared.start(pageURL: url, title: video.displayTitle, cookies: cookies, audioOnly: true)
                    Toast.shared.show("소리 받기를 시작했어요")
                }
            }
            Button("최고 화질로 다운로드") {
                guard let url = URL(string: video.watchURL) else { return }
                Task {
                    let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                    DownloadManager.shared.start(pageURL: url, title: video.displayTitle, cookies: cookies)
                    Toast.shared.show("다운로드를 시작했어요")
                }
            }
            Button("링크 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(video.watchURL, forType: .string)
            }
            Divider()
            if marks.watched.contains(video.id) {
                Button("본 영상 표시 지우기") { marks.unmark(video.id) }
            } else {
                Button("본 영상으로 표시") { marks.markWatched(video.id) }
            }
            if !video.channelName.isEmpty {
                Button("\(video.channelName) 채널 숨기기") { ContentFilter.shared.block(channel: video.channelName) }
            }
            Divider()
            Button("유튜브 웹에서 열기") {
                FeedStore.shared.selection = .web
                if let url = URL(string: video.watchURL) { BrowserLink.open(url) }
            }
        }
    }

    private var thumbnail: some View {
        let watched = marks.watched.contains(video.id)
        let progress = marks.progress(video.id)
        return Color.black.opacity(0.08)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: video.thumbnailURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
            }
            // 마우스를 올려 두면 썸네일 자리에서 미리 보기 (소리 없이)
            .overlay {
                if preview.playingID == video.id, let player = preview.player {
                    PreviewVideoView(player: player)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: preview.playingID == video.id)
            .overlay(alignment: .bottomLeading) {
                if preview.hoveredID == video.id, preview.playingID != video.id, !video.isLive {
                    ProgressView().controlSize(.mini).tint(.white)
                        .padding(5)
                        .background(.black.opacity(0.5), in: Circle())
                        .padding(6)
                }
            }
            // 본 영상: 살짝 어둡게 + "봤음", 보다 만 영상: 아래에 빨간 진행 막대
            .overlay {
                if watched, preview.playingID != video.id { Color.black.opacity(0.35) }
            }
            .overlay(alignment: .topTrailing) {
                if watched {
                    Label("봤음", systemImage: "checkmark")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                if let progress, !watched {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.35))
                            Rectangle().fill(.red).frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { inside in preview.hover(video, inside: inside) }
            .overlay(alignment: .bottomTrailing) { badge.padding(6) }
            .overlay(alignment: .topLeading) {
                if let label = quality?.label {
                    Text(label).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(theme.style, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
                        .padding(6)
                }
            }
    }

    private var viewsAndWhen: String {
        let views = video.viewText ?? meta?.views.map(FeedVideo.viewText)
        return [views, meta?.whenText].compactMap { $0 }.joined(separator: " · ")
    }

    /// 격자 카드 아래: 제목 2줄 + (채널 사진·채널 ···· 조회수 · 날짜)
    private var gridInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(video.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                ChannelAvatar(name: video.channelName, size: 16)
                Text(video.channelName).lineLimit(1)
                Spacer(minLength: 4)
                if !viewsAndWhen.isEmpty {
                    Text(viewsAndWhen).monospacedDigit().lineLimit(1).fixedSize()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// 목록형 오른쪽: 큰 제목 + 채널 + 조회수·날짜 + 표시들
    private var rowInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(video.displayTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                ChannelAvatar(name: video.channelName, size: 20)
                Text(video.channelName).lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if !viewsAndWhen.isEmpty {
                Text(viewsAndWhen).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let progress = marks.progress(video.id), !marks.watched.contains(video.id) {
                Text("\(Int(progress * 100))% 보는 중").font(.caption2.bold()).foregroundStyle(.red)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var badge: some View {
        if video.isLive {
            LiveBadge()
        } else if let text = video.isShorts ? "Shorts" : video.durationText {
            Text(text).font(.caption2.weight(.semibold).monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
        }
    }

    private func play() {
        // 듣기 모드가 켜져 있으면 소리만, 아니면 재생 창 (재생 창은 하나: 떠 있으면 영상만 바뀜)
        Playback.open(video.playerItem)
    }
}

/// 목록에서 "유튜브 웹에서 열기"를 누를 때 웹 화면(Browser)에 주소를 넘기는 통로
@MainActor
enum BrowserLink {
    static weak var browser: Browser?
    static func open(_ url: URL) { browser?.open(url) }
}

/// 영상의 최고 화질 (화질 선택용): 짧은 변 길이(가로·세로 영상 모두 같은 기준)와 360° VR 여부
struct VideoQuality: Codable, Hashable {
    let shortSide: Int
    let isVR: Bool
    /// 세로 영상 (쇼츠 알아보기용, 예전에 저장한 값은 모름 = nil)
    var isVertical: Bool? = nil

    /// 카드에 붙일 표시 (720p 미만은 표시 안 함)
    var label: String? {
        if isVR { return "VR" }
        switch shortSide {
        case 2160...: return "4K"
        case 1440...: return "2K"
        case 1080...: return "1080p"
        case 720...: return "720p"
        default: return nil
        }
    }
}


/// 재생 창 화질 단계: 영상·소리 파일을 합친 화질(짧은 변 기준), 또는 HLS(애플 방식 스트리밍, 최대 1080p 안정)
enum QualityLevel: Hashable, Codable {
    case direct(Int)
    case hls

    var label: String {
        switch self {
        case .hls: return "안정 (HLS)"
        case .direct(let h):
            switch h {
            case 2160...: return "4K"
            case 1440...: return "1440p"
            default: return "\(h)p"
            }
        }
    }
}


/// 영상 등록 정보 (목록 정보에는 없어서 영상마다 따로 확인)
struct VideoMeta: Codable, Hashable {
    /// "20261015" (모르면 "")
    var date: String
    /// 올린 시각 (초, 1970년부터)
    var timestamp: Double? = nil
    var views: Int? = nil

    /// 24시간 안이면 "N시간 전"(1시간 안이면 "N분 전"), 그 뒤면 "2026.10.15"
    var whenText: String? {
        if let timestamp {
            let ago = Date().timeIntervalSince1970 - timestamp
            if ago >= 0, ago < 3600 { return "\(max(1, Int(ago / 60)))분 전" }
            if ago >= 0, ago < 86_400 { return "\(Int(ago / 3600))시간 전" }
        }
        guard date.count == 8 else { return nil }
        let c = Array(date)
        return "\(String(c[0..<4])).\(String(c[4..<6])).\(String(c[6..<8]))"
    }
}

/// 마우스가 올라가 있는지 (카드마다)
@MainActor
final class HoverFlag: ObservableObject {
    @Published var isOn = false
}

/// 채널 사진 대신: 채널 이름 첫 글자 + 이름에서 정한 색의 동그라미
struct ChannelAvatar: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        let initial = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        let hue = Double(abs(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 })) / 360
        Circle()
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85),
                                          Color(hue: hue, saturation: 0.7, brightness: 0.65)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Text(initial).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
    }
}

/// 라이브 표시: 깜빡이는 빨간 점 + LIVE
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            PhaseAnimator([0.35, 1.0]) { phase in
                Circle().fill(.white).frame(width: 6, height: 6).opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.8) }
            Text("LIVE")
        }
        .font(.caption2.bold())
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.red, in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(.white)
    }
}

/// 빈 화면 공통 모양
struct EmptyStateView<Actions: View>: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(theme.accent.opacity(0.12)).frame(width: 92, height: 92)
                Image(systemName: icon).font(.system(size: 38, weight: .medium)).foregroundStyle(theme.style)
            }
            Text(title).font(.system(size: 18, weight: .bold))
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            HStack(spacing: 10) { actions() }
                .padding(.top, 4)
        }
        .padding(40)
    }
}

/// 처음 불러오는 동안 보여 주는 빈 카드들 (옅게 반짝임)
struct SkeletonGrid: View {
    let width: Double
    var rows = false

    var body: some View {
        PhaseAnimator([0.45, 0.85]) { phase in
            Group {
                if rows {
                    VStack(spacing: 14) {
                        ForEach(0..<6, id: \.self) { _ in
                            HStack(alignment: .top, spacing: 16) {
                                block.frame(width: 260).aspectRatio(16 / 9, contentMode: .fit)
                                VStack(alignment: .leading, spacing: 10) {
                                    line(width: 320, height: 14)
                                    line(width: 200, height: 12)
                                    line(width: 120, height: 10)
                                }
                                Spacer()
                            }
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: width, maximum: width * 1.5), spacing: 18, alignment: .top)], spacing: 24) {
                        ForEach(0..<12, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                block.aspectRatio(16 / 9, contentMode: .fit)
                                line(width: nil, height: 12)
                                line(width: 140, height: 10)
                            }
                        }
                    }
                }
            }
            .opacity(phase)
        } animation: { _ in .easeInOut(duration: 0.9) }
    }

    private var block: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.08))
    }

    private func line(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(width: width, height: height)
    }
}

/// 목록 위 고르기 줄: [기능별 칩들] | (검색이면) 날짜·정렬·구분 메뉴 | 격자/목록
struct FilterBar: View {
    @Environment(\.theme) private var theme
    @ObservedObject var store: FeedStore

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("전체", selected: store.quality == .all) { store.quality = .all }
                    ForEach(QualityFilter.allCases.filter { $0 != .all }) { item in
                        chip(item.label, selected: store.quality == item) {
                            store.quality = store.quality == item ? .all : item
                        }
                    }
                    if store.selection == .search {
                        Divider().frame(height: 18).padding(.horizontal, 4)
                        menuChip(title: "날짜", value: store.uploadDate == .all ? "전체" : store.uploadDate.label,
                                 active: store.uploadDate != .all) {
                            ForEach(UploadDate.allCases) { item in
                                Button((store.uploadDate == item ? "✓ " : "    ") + (item == .all ? "전체" : item.label)) { store.uploadDate = item }
                            }
                        }
                        menuChip(title: "정렬", value: store.sort.label, active: store.sort != .relevance) {
                            ForEach(SortOrder.allCases) { item in
                                Button((store.sort == item ? "✓ " : "    ") + item.label) { store.sort = item }
                            }
                        }
                        menuChip(title: "구분", value: store.kind.label, active: store.kind != .all) {
                            ForEach(ResultKind.allCases) { item in
                                Button((store.kind == item ? "✓ " : "    ") + item.label) { store.kind = item }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            // 격자 / 목록형
            Picker("보기", selection: $store.listMode) {
                Image(systemName: "square.grid.2x2").tag(false).help("격자로 보기")
                Image(systemName: "list.bullet").tag(true).help("목록으로 보기")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .padding(.trailing, 14)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.primary.opacity(0.75)))
                .background(Capsule().fill(selected ? theme.style : AnyShapeStyle(Color.primary.opacity(0.06))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func menuChip<Items: View>(title: String, value: String, active: Bool, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 4) {
                Text("\(title): \(value)")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: active ? .semibold : .regular))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .foregroundStyle(active ? theme.style : AnyShapeStyle(Color.primary.opacity(0.75)))
            .background(Capsule().fill(active ? theme.accent.opacity(0.12) : Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(active ? theme.style : AnyShapeStyle(Color.clear), lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
