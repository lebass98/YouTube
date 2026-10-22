import AppKit
import SwiftUI
import WebKit

/// 재생 중인 영상의 유튜브 정보·행동: 좋아요/싫어요, 댓글, 설명, 나중에 볼 동영상에 저장
/// (유튜브 웹과 같은 방식으로 로그인 정보와 함께 요청 → 내 계정에 그대로 반영)
@MainActor
final class VideoPage: ObservableObject {
    enum Like: String { case like = "LIKE", dislike = "DISLIKE", none = "INDIFFERENT" }

    struct Comment: Identifiable, Hashable {
        let id: String
        let author: String
        let avatar: URL?
        let text: String
        let when: String
        let likes: String
        let replies: String
    }

    let videoID: String
    @Published private(set) var loaded = false
    @Published private(set) var status = Like.none
    @Published private(set) var likeCount: String?
    @Published private(set) var channel = ""
    @Published private(set) var channelAvatar: URL?
    @Published private(set) var subscribers = ""
    @Published private(set) var views = ""
    @Published private(set) var date = ""
    @Published private(set) var descriptionText = ""
    @Published private(set) var commentCount: String?
    @Published private(set) var comments: [Comment] = []
    @Published private(set) var commentsLoading = false
    @Published private(set) var commentsError: String?
    private var commentsToken: String?
    private var nextCommentsToken: String?
    private var baseLikeCount: Int?

    init(videoID: String) {
        self.videoID = videoID
    }

    private func cookies() async -> [HTTPCookie] {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies()
    }

    /// 처음 한 번: 좋아요 상태·개수, 채널·구독자, 조회수·날짜·설명, 댓글 수
    func load() {
        guard !loaded else { return }
        loaded = true
        Task {
            do {
                let r = try await YouTubeHome.post("next", ["videoId": videoID], cookies: await cookies())
                func all(_ key: String) -> [Any] { var out: [Any] = []; YouTubeHome.collect(r, key: key, into: &out); return out }
                if let entity = all("likeStatusEntity").first as? [String: Any], let s = entity["likeStatus"] as? String {
                    status = Like(rawValue: s) ?? .none
                }
                if let count = all("likeCountIfIndifferent").first {
                    likeCount = YouTubeHome.text(count)
                    baseLikeCount = Self.number(likeCount ?? "")
                }
                if let owner = all("videoOwnerRenderer").first as? [String: Any] {
                    channel = YouTubeHome.text(owner["title"])
                    subscribers = YouTubeHome.text(owner["subscriberCountText"])
                    if let thumbs = (owner["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]],
                       let url = thumbs.last?["url"] as? String {
                        channelAvatar = URL(string: url.hasPrefix("//") ? "https:" + url : url)
                    }
                }
                if let primary = all("videoPrimaryInfoRenderer").first as? [String: Any] {
                    let viewRenderer = ((primary["viewCount"] as? [String: Any])?["videoViewCountRenderer"] as? [String: Any])
                    views = YouTubeHome.text(viewRenderer?["viewCount"])
                    date = YouTubeHome.text(primary["dateText"])
                }
                if let secondary = all("videoSecondaryInfoRenderer").first as? [String: Any] {
                    descriptionText = YouTubeHome.text(secondary["attributedDescription"])
                }
                for header in all("engagementPanelTitleHeaderRenderer").compactMap({ $0 as? [String: Any] })
                where YouTubeHome.text(header["title"]) == "댓글" {
                    commentCount = YouTubeHome.text(header["contextualInfo"])
                }
                // 댓글 첫 묶음 표: comment-item-section 안의 것
                for section in all("itemSectionRenderer").compactMap({ $0 as? [String: Any] })
                where section["sectionIdentifier"] as? String == "comment-item-section" {
                    var tokens: [Any] = []
                    YouTubeHome.collect(section, key: "token", into: &tokens)
                    commentsToken = tokens.first as? String
                }
            } catch {
                DebugLog.write("영상 정보 받기 실패: \(error.localizedDescription)")
            }
        }
    }

    // MARK: 좋아요·싫어요

    func toggleLike() { set(status == .like ? .none : .like) }
    func toggleDislike() { set(status == .dislike ? .none : .dislike) }

    private func set(_ next: Like) {
        let before = status
        status = next   // 먼저 바꿔 보여 주고, 실패하면 되돌림
        updateCount(from: before, to: next)
        let path = next == .like ? "like/like" : next == .dislike ? "like/dislike" : "like/removelike"
        Task {
            do {
                _ = try await YouTubeHome.post(path, ["target": ["videoId": videoID]], cookies: await cookies())
                DebugLog.write("유튜브 \(next == .like ? "좋아요" : next == .dislike ? "싫어요" : "평가 취소"): \(videoID)")
                Toast.shared.show(next == .like ? "좋아요 표시했어요" : next == .dislike ? "싫어요 표시했어요" : "표시를 지웠어요", seconds: 2)
            } catch {
                status = before
                updateCount(from: next, to: before)
                Toast.shared.show("유튜브에 반영하지 못했어요: \(error.localizedDescription)", error: true, seconds: 4)
            }
        }
    }

    private func updateCount(from: Like, to: Like) {
        guard let base = baseLikeCount, base < 10_000 else { return }   // 1만이 넘으면 "1.2만"처럼 줄여 보여서 그대로 둠
        likeCount = "\(base + (to == .like ? 1 : 0))"
    }

    /// "5.8천" → 5800, "123" → 123
    private static func number(_ text: String) -> Int? {
        let t = text.replacingOccurrences(of: ",", with: "")
        for (unit, scale) in [("억", 100_000_000.0), ("만", 10_000.0), ("천", 1_000.0)] where t.hasSuffix(unit) {
            return Double(t.dropLast()).map { Int($0 * scale) }
        }
        return Int(t)
    }

    // MARK: 댓글

    func loadComments() {
        guard !commentsLoading else { return }
        let token = comments.isEmpty ? commentsToken : nextCommentsToken
        guard let token else {
            if comments.isEmpty { commentsError = loaded ? "댓글을 볼 수 없는 영상이에요." : nil }
            return
        }
        commentsLoading = true
        Task {
            defer { commentsLoading = false }
            do {
                let r = try await YouTubeHome.post("next", ["continuation": token], cookies: await cookies())
                var payloads: [Any] = []
                YouTubeHome.collect(r, key: "commentEntityPayload", into: &payloads)
                let fresh = payloads.compactMap { $0 as? [String: Any] }.compactMap { p -> Comment? in
                    let props = p["properties"] as? [String: Any] ?? [:]
                    let author = p["author"] as? [String: Any] ?? [:]
                    let toolbar = p["toolbar"] as? [String: Any] ?? [:]
                    guard let id = props["commentId"] as? String else { return nil }
                    return Comment(id: id,
                                   author: author["displayName"] as? String ?? "",
                                   avatar: (author["avatarThumbnailUrl"] as? String).flatMap(URL.init(string:)),
                                   text: YouTubeHome.text(props["content"]),
                                   when: props["publishedTime"] as? String ?? "",
                                   likes: toolbar["likeCountNotliked"] as? String ?? "",
                                   replies: toolbar["replyCount"] as? String ?? "")
                }
                let known = Set(comments.map(\.id))
                comments += fresh.filter { !known.contains($0.id) }
                // 다음 묶음
                var items: [Any] = []
                YouTubeHome.collect(r, key: "continuationItemRenderer", into: &items)
                var next: [Any] = []
                if let last = items.last { YouTubeHome.collect(last, key: "token", into: &next) }
                nextCommentsToken = fresh.isEmpty ? nil : next.first as? String
                commentsError = comments.isEmpty ? "아직 댓글이 없어요." : nil
            } catch {
                commentsError = "댓글을 받지 못했어요: \(error.localizedDescription)"
            }
        }
    }

    var hasMoreComments: Bool { nextCommentsToken != nil }

    // MARK: 저장·공유

    func saveToWatchLater() {
        Task {
            do {
                _ = try await YouTubeHome.post("browse/edit_playlist", [
                    "playlistId": "WL",
                    "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": videoID]],
                ], cookies: await cookies())
                Toast.shared.show("나중에 볼 동영상에 저장했어요", seconds: 2)
            } catch {
                Toast.shared.show("저장하지 못했어요: \(error.localizedDescription)", error: true, seconds: 4)
            }
        }
    }

    var link: String { "https://youtu.be/\(videoID)" }

    func copyLink(at seconds: Double? = nil) {
        var text = link
        if let seconds, seconds >= 1 { text += "?t=\(Int(seconds))" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.shared.show(seconds == nil ? "링크를 복사했어요" : "지금 위치(\(PlaybackMemory.timeText(seconds ?? 0))) 링크를 복사했어요", seconds: 2)
    }

    /// 맥 공유 메뉴 (메시지·메일·메모·AirDrop 등)
    func share(from view: NSView?) {
        guard let url = URL(string: link) else { return }
        let picker = NSSharingServicePicker(items: [url])
        if let view {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}

// MARK: - 설명·댓글 판 (💬)

struct VideoInfoPanel: View {
    @Environment(\.theme) private var theme
    @ObservedObject var page: VideoPage
    @StateObject private var tab = PanelTab()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 채널·구독자 + 조회수·날짜
            HStack(spacing: 10) {
                AsyncImage(url: page.channelAvatar) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { ChannelAvatar(name: page.channel, size: 36) }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.channel).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(page.subscribers).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(page.views).font(.caption.monospacedDigit())
                    Text(page.date).font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $tab.index) {
                Text("댓글 \(page.commentCount ?? "")").tag(0)
                Text("설명").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab.index == 1 {
                ScrollView {
                    Text(page.descriptionText.isEmpty ? "설명이 없어요." : page.descriptionText)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(page.comments) { comment in
                            HStack(alignment: .top, spacing: 10) {
                                AsyncImage(url: comment.avatar) { phase in
                                    if let image = phase.image { image.resizable().scaledToFill() } else { ChannelAvatar(name: comment.author, size: 28) }
                                }
                                .frame(width: 28, height: 28)
                                .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(comment.author).font(.caption.weight(.semibold))
                                        Text(comment.when).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(comment.text).font(.callout).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 12) {
                                        if !comment.likes.isEmpty { Label(comment.likes, systemImage: "hand.thumbsup") }
                                        if !comment.replies.isEmpty { Label("답글 \(comment.replies)", systemImage: "arrowshape.turn.up.left") }
                                    }
                                    .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if page.commentsLoading {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        } else if let error = page.commentsError {
                            Text(error).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        } else if page.hasMoreComments {
                            // 맨 아래가 보이면 다음 댓글
                            Color.clear.frame(height: 1).onAppear { page.loadComments() }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            page.load()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { page.loadComments() }
        }
    }
}

@MainActor
final class PanelTab: ObservableObject {
    @Published var index = 0
}

// MARK: - ✦ AI 판: 요약 + 이 영상에 대해 물어보기

@MainActor
final class AskStore: ObservableObject {
    static let shared = AskStore()
    struct QA: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var failed = false
    }
    @Published private(set) var threads: [String: [QA]] = [:]
    @Published var draft = ""
    private var transcripts: [String: String] = [:]

    func ask(videoID: String, title: String, captionURL: URL?) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        let qa = QA(question: question)
        threads[videoID, default: []].append(qa)
        Task {
            do {
                guard let captionURL else { throw GeminiCLI.Failure.failed("이 영상에는 자막이 없어서 내용을 알 수 없어요.") }
                if transcripts[videoID] == nil { transcripts[videoID] = try await AISummaryStore.transcript(from: captionURL) }
                let earlier = (threads[videoID] ?? []).dropLast().compactMap { q in q.answer.map { "Q: \(q.question)\nA: \($0)" } }.joined(separator: "\n")
                let prompt = """
                아래는 유튜브 영상 "\(title)"의 자막이야. [분:초] 다음에 그때 하는 말이 있어.
                이 영상에 대한 질문에 한국어로 짧고 정확하게 답해. 관련 장면이 있으면 [분:초]로 알려 줘.
                영상에 없는 내용이면 영상에는 그 내용이 없다고 말해. 파일이나 도구는 쓰지 말고 바로 답해.
                \(earlier.isEmpty ? "" : "[앞선 대화]\n\(earlier)\n")
                [질문] \(question)
                [자막]
                \(transcripts[videoID] ?? "")
                """
                let schema = #"{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"]}"#
                let data = try await GeminiCLI.ask(prompt, schema: schema)
                let answer = (try? JSONDecoder().decode([String: String].self, from: data))?["answer"] ?? ""
                update(videoID, qa.id) { $0.answer = answer.isEmpty ? "답을 받지 못했어요." : answer }
            } catch {
                update(videoID, qa.id) { $0.answer = error.localizedDescription; $0.failed = true }
            }
        }
    }

    private func update(_ videoID: String, _ id: UUID, _ change: (inout QA) -> Void) {
        guard let i = threads[videoID]?.firstIndex(where: { $0.id == id }) else { return }
        change(&threads[videoID]![i])
    }
}

struct AIPanel: View {
    @Environment(\.theme) private var theme
    let videoID: String
    let title: String
    let captionURL: URL?
    @ObservedObject private var ask = AskStore.shared
    @StateObject private var tab = PanelTab()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab.index) {
                Label("질문하기", systemImage: "bubble.left.and.text.bubble.right").tag(0)
                Label("요약", systemImage: "text.alignleft").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)

            if tab.index == 1 {
                ScrollView { SummaryView(videoID: videoID, title: title, captionURL: captionURL) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if (ask.threads[videoID] ?? []).isEmpty {
                            Label("이 동영상에 대해 물어보세요", systemImage: "sparkle")
                                .font(.headline).foregroundStyle(theme.style)
                            Text("예: \"핵심만 알려 줘\", \"추천하는 제품이 뭐야?\", \"몇 분에 결론이 나와?\"")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(ask.threads[videoID] ?? []) { qa in
                            Text(qa.question)
                                .font(.callout.weight(.semibold))
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            if let answer = qa.answer {
                                // **굵게** 같은 표시를 글자 꾸밈으로 (줄바꿈은 그대로)
                                Text((try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer))
                                    .font(.callout)
                                    .foregroundStyle(qa.failed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.primary))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("영상을 보며 답을 찾는 중…").foregroundStyle(.secondary) }
                                    .font(.callout)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                HStack {
                    TextField("이 영상에 대해 질문하기", text: $ask.draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { ask.ask(videoID: videoID, title: title, captionURL: captionURL) }
                    Button { ask.ask(videoID: videoID, title: title, captionURL: captionURL) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(theme.style)
                    }
                    .buttonStyle(.plain)
                    .disabled(ask.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding([.horizontal, .bottom], 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
