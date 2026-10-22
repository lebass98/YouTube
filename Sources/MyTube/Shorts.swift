import SwiftUI
import WebKit

/// 쇼츠 모드: 쇼츠만 모아 보고, 세로로 긴 재생 창에서 ↑↓(또는 스크롤)로 넘겨 보기
@MainActor
final class ShortsMode: ObservableObject {
    static let shared = ShortsMode()

    struct Short: Identifiable, Hashable {
        let id: String
        let title: String
        let views: String
        let thumbnail: URL?

        var playerItem: PlayerItem {
            var item = PlayerItem(id: id, title: title, url: "https://www.youtube.com/shorts/\(id)")
            item.shorts = true
            return item
        }
    }

    @Published var isOn = false {
        didSet {
            if isOn, shorts.isEmpty { load() }
            Toast.shared.show(isOn ? "쇼츠 모드: 쇼츠만 보여 줘요 (재생 창은 세로로, ↑↓로 넘기기)" : "쇼츠 모드를 껐어요", seconds: 3)
        }
    }
    @Published private(set) var shorts: [Short] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    /// 지금 재생 중인 쇼츠 위치
    @Published private(set) var index = 0
    private var reachedEnd = false

    /// 쇼츠를 받는 곳: 구독 채널 쇼츠, 홈 추천 쇼츠(있을 때만 나옴), 모자라면 인기 쇼츠 검색
    private var tokens: [String: String] = [:]
    private var started = false

    func load(reset: Bool = false) {
        if reset {
            shorts = []
            tokens = [:]
            started = false
            reachedEnd = false
        }
        guard !loading, !reachedEnd else { return }
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                var found: [Short] = []
                // 처음: 구독 + 홈, 다음부터: 각자 받은 "다음 묶음 표"로
                let requests: [(String, String, [String: Any])] = started
                    ? tokens.map { ($0.key, "browse", ["continuation": $0.value]) }
                    : [("subs", "browse", ["browseId": "FEsubscriptions"]), ("home", "browse", ["browseId": "FEwhat_to_watch"])]
                started = true
                tokens = [:]
                for (source, path, body) in requests {
                    guard let r = try? await YouTubeHome.post(path, body, cookies: cookies) else { continue }
                    found += Self.shorts(in: r)
                    if let next = Self.nextToken(r) { tokens[source] = next }
                }
                // 모자라면 인기 쇼츠 검색 (쇼츠만 고르기)
                if found.count < 12 {
                    let body: [String: Any] = tokens["search"].map { ["continuation": $0] } ?? ["query": "인기 쇼츠", "params": "EgIQCQ%3D%3D"]
                    let r = try await YouTubeHome.post("search", body, cookies: cookies)
                    found += Self.shorts(in: r)
                    if let next = Self.nextToken(r) { tokens["search"] = next }
                }
                let known = Set(shorts.map(\.id))
                var seen = Set<String>()
                shorts += found.filter { !known.contains($0.id) && seen.insert($0.id).inserted }
                if tokens.isEmpty { reachedEnd = true }
                DebugLog.write("쇼츠 \(found.count)개 받음 (모두 \(shorts.count)개)")
                if shorts.isEmpty { error = "지금 받을 수 있는 쇼츠가 없어요." }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private static func shorts(in response: Any) -> [Short] {
        var lockups: [Any] = []
        YouTubeHome.collect(response, key: "shortsLockupViewModel", into: &lockups)
        return lockups.compactMap { $0 as? [String: Any] }.compactMap(short)
    }

    private static func nextToken(_ response: Any) -> String? {
        var items: [Any] = []
        YouTubeHome.collect(response, key: "continuationItemRenderer", into: &items)
        var tokens: [Any] = []
        if let last = items.last { YouTubeHome.collect(last, key: "token", into: &tokens) }
        return tokens.first as? String
    }

    private static func short(_ lockup: [String: Any]) -> Short? {
        var ids: [Any] = []
        YouTubeHome.collect(lockup, key: "reelWatchEndpoint", into: &ids)
        guard let id = (ids.first as? [String: Any])?["videoId"] as? String, id.count == 11 else { return nil }
        let overlay = lockup["overlayMetadata"] as? [String: Any] ?? [:]
        var sources: [Any] = []
        YouTubeHome.collect(lockup["thumbnailViewModel"] as Any, key: "sources", into: &sources)
        let thumb = ((sources.first as? [Any])?.first as? [String: Any])?["url"] as? String
        return Short(id: id, title: YouTubeHome.text(overlay["primaryText"]),
                     views: YouTubeHome.text(overlay["secondaryText"]),
                     thumbnail: (thumb ?? "https://i.ytimg.com/vi/\(id)/oar2.jpg").flatMap(URL.init(string:)))
    }

    // MARK: 재생·넘기기

    func play(at position: Int) {
        guard shorts.indices.contains(position) else { return }
        index = position
        Playback.open(shorts[position].playerItem, listen: false)
        // 다음 두 개는 주소를 미리 받아 둠 (넘길 때 바로 재생)
        for next in shorts.dropFirst(position + 1).prefix(2) {
            if let url = URL(string: next.playerItem.url) { PlayerWindowController.shared.prefetch(id: next.id, pageURL: url) }
        }
        // 끝에 가까워지면 더 받아 둠
        if position >= shorts.count - 4 { load() }
    }

    func next() {
        if index + 1 < shorts.count { play(at: index + 1) } else { load(); Toast.shared.show("쇼츠를 더 받는 중…", seconds: 2) }
    }

    func previous() {
        if index > 0 { play(at: index - 1) }
    }

    var positionText: String { shorts.isEmpty ? "" : "\(index + 1) / \(shorts.count)" }
}

/// 쇼츠 모드 화면: 세로 카드 격자
struct ShortsBrowser: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var mode = ShortsMode.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.style)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("쇼츠").font(.title2.bold())
                        Text("누르면 세로 창에서 재생 · ↑↓ 키나 스크롤로 다음·이전 쇼츠").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { mode.load(reset: true) } label: { Label("새로 받기", systemImage: "arrow.clockwise") }
                    Button { mode.isOn = false } label: { Label("쇼츠 모드 끄기", systemImage: "xmark") }
                }
                .controlSize(.small)

                if mode.shorts.isEmpty, mode.loading {
                    SkeletonShorts()
                } else if mode.shorts.isEmpty, let error = mode.error {
                    EmptyStateView(icon: "rectangle.portrait.slash", title: "쇼츠를 받지 못했어요", message: error) {
                        Button("다시 시도") { mode.load(reset: true) }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 14, alignment: .top)], spacing: 18) {
                    ForEach(Array(mode.shorts.enumerated()), id: \.element.id) { position, short in
                        Button { mode.play(at: position) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Color.black.opacity(0.08)
                                    .aspectRatio(9 / 16, contentMode: .fit)
                                    .overlay {
                                        AsyncImage(url: short.thumbnail) { phase in
                                            if let image = phase.image { image.resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
                                        }
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(alignment: .bottomLeading) {
                                        Text(short.views)
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .background(.black.opacity(0.6), in: Capsule())
                                            .foregroundStyle(.white)
                                            .padding(8)
                                    }
                                Text(short.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .onAppear { if position >= mode.shorts.count - 6 { mode.load() } }
                    }
                }
                if mode.loading, !mode.shorts.isEmpty {
                    ProgressView("더 받는 중…").controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .onAppear { if mode.shorts.isEmpty { mode.load() } }
    }
}

private struct SkeletonShorts: View {
    var body: some View {
        PhaseAnimator([0.45, 0.85]) { phase in
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 14)], spacing: 18) {
                ForEach(0..<10, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .aspectRatio(9 / 16, contentMode: .fit)
                }
            }
            .opacity(phase)
        } animation: { _ in .easeInOut(duration: 0.9) }
    }
}
