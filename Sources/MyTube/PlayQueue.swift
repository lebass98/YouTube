import SwiftUI

/// 재생 대기열: 영상이 끝나면 다음 영상을 이어서 재생 (듣기 모드와 함께 쓰면 라디오처럼)
@MainActor
final class PlayQueue: ObservableObject {
    static let shared = PlayQueue()

    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        let videoID: String
        let title: String
        let url: String
        let channel: String

        var playerItem: PlayerItem { PlayerItem(id: videoID, title: title, url: url) }
        var thumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg") }

        init(_ video: FeedVideo) {
            videoID = video.id
            title = video.displayTitle
            url = video.watchURL
            channel = video.channelName
        }
    }

    @Published private(set) var entries: [Entry] = []
    /// 끝나면 다음 영상 자동 재생
    @Published var autoAdvance = UserDefaults.standard.object(forKey: "queueAutoAdvance") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoAdvance, forKey: "queueAutoAdvance") }
    }

    private static let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyTube/queue.json")

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    /// 지금 영상 다음에 바로
    func playNext(_ video: FeedVideo) {
        entries.removeAll { $0.videoID == video.id }
        entries.insert(Entry(video), at: 0)
        save()
        Toast.shared.show("다음에 재생: \(video.displayTitle)", seconds: 2)
    }

    /// 맨 뒤에
    func add(_ videos: [FeedVideo]) {
        let fresh = videos.filter { v in v.isVideo && !entries.contains { $0.videoID == v.id } }
        guard !fresh.isEmpty else {
            Toast.shared.show("이미 대기열에 있어요", seconds: 2)
            return
        }
        entries += fresh.map(Entry.init)
        save()
        Toast.shared.show(fresh.count == 1 ? "대기열에 추가: \(fresh[0].displayTitle)" : "대기열에 \(fresh.count)개 추가", seconds: 2)
    }

    /// 목록 전체를 차례로: 첫 영상은 바로 재생, 나머지는 대기열 앞에 (원래 대기열은 그 뒤로)
    func playAll(_ videos: [FeedVideo], listen: Bool? = nil) {
        let list = videos.filter { $0.isVideo && !$0.isLive }
        guard let first = list.first else { return }
        let rest = list.dropFirst().map(Entry.init)
        entries.removeAll { e in rest.contains { $0.videoID == e.videoID } }
        entries.insert(contentsOf: rest, at: 0)
        save()
        Playback.open(first.playerItem, listen: listen)
        Toast.shared.show("\(list.count)개를 차례로 재생해요", seconds: 2)
    }

    func popNext() -> Entry? {
        guard !entries.isEmpty else { return nil }
        let next = entries.removeFirst()
        save()
        return next
    }

    /// 대기열에서 하나를 골라 바로 재생 (그 앞의 것들은 그대로 둠)
    func play(_ entry: Entry, listen: Bool? = nil) {
        entries.removeAll { $0.id == entry.id }
        save()
        Playback.open(entry.playerItem, listen: listen)
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func clear() {
        entries = []
        save()
    }
}

/// 사이드바 "재생 대기열" 화면
struct QueueView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var queue = PlayQueue.shared
    @ObservedObject private var now = NowPlaying.shared
    @ObservedObject private var listen = ListenMode.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("재생 대기열").font(.title2.bold())
                    Text(queue.entries.isEmpty ? "비어 있어요" : "\(queue.entries.count)개 · 끌어서 순서를 바꿀 수 있어요")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("끝나면 다음 영상", isOn: $queue.autoAdvance)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button("모두 지우기") { queue.clear() }
                    .disabled(queue.entries.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            if let id = now.id, now.isActive {
                nowPlayingRow(id)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            if queue.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "list.number").font(.largeTitle).foregroundStyle(.secondary)
                    Text("영상 카드를 오른쪽 클릭 → \"다음에 재생\" 또는 \"대기열에 추가\"")
                        .foregroundStyle(.secondary)
                    Text("재생목록·채널을 열면 위쪽 \"모두 재생\"으로 전부 넣을 수 있어요")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(queue.entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry, number: index + 1)
                    }
                    .onMove { queue.move(from: $0, to: $1) }
                }
                .listStyle(.inset)
            }
        }
    }

    private func nowPlayingRow(_ id: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: now.source == .listen ? "headphones" : "play.rectangle.fill")
                .foregroundStyle(theme.style)
            VStack(alignment: .leading, spacing: 2) {
                Text("지금 재생 중").font(.caption).foregroundStyle(.secondary)
                Text(now.title).font(.callout.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            Button { now.togglePlay() } label: { Image(systemName: now.isPlaying ? "pause.fill" : "play.fill") }
            Button { now.next() } label: { Image(systemName: "forward.end.fill") }
                .disabled(queue.entries.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(12)
        .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ entry: PlayQueue.Entry, number: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
            AsyncImage(url: entry.thumbnailURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.callout.weight(.medium)).lineLimit(2)
                Text(entry.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { queue.play(entry) } label: { Image(systemName: listen.isOn ? "headphones" : "play.fill") }
                .help(listen.isOn ? "지금 듣기" : "지금 재생")
            Button { queue.remove(entry) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .help("대기열에서 빼기")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { queue.play(entry) }
        .contextMenu {
            Button("지금 재생 창에서 보기") { queue.play(entry, listen: false) }
            Button("지금 듣기 (소리만)") { queue.play(entry, listen: true) }
            Divider()
            Button("대기열에서 빼기") { queue.remove(entry) }
        }
    }
}
