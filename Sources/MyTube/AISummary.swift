import SwiftUI

/// AI 영상 요약: 영상 자막을 재미나이(agy)에 보내 3줄 요약 + 핵심 시간대를 받음 (영상마다 저장해서 다시 묻지 않음)
@MainActor
final class AISummaryStore: ObservableObject {
    static let shared = AISummaryStore()

    struct Summary: Codable {
        struct Point: Codable, Hashable {
            let seconds: Double
            let text: String
        }
        let lines: [String]
        let points: [Point]
    }

    enum State { case idle, working, done(Summary), failed(String) }

    @Published private(set) var states: [String: State] = [:]

    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyTube/summaries", isDirectory: true)

    /// 파일에서 읽은 요약 (화면을 그리는 중에 불려서 @Published는 건드리지 않음)
    private var fromDisk: [String: Summary] = [:]

    func state(_ id: String) -> State {
        if let state = states[id] { return state }
        if let saved = fromDisk[id] { return .done(saved) }
        if let data = try? Data(contentsOf: Self.folder.appendingPathComponent("\(id).json")),
           let saved = try? JSONDecoder().decode(Summary.self, from: data) {
            fromDisk[id] = saved
            return .done(saved)
        }
        return .idle
    }

    func summarize(id: String, title: String, captionURL: URL?) {
        if case .working = state(id) { return }
        guard let captionURL else {
            states[id] = .failed("이 영상에는 자막(자동 자막 포함)이 없어서 요약할 수 없어요.")
            return
        }
        states[id] = .working
        Task {
            do {
                let transcript = try await Self.transcript(from: captionURL)
                guard transcript.count > 80 else { throw GeminiCLI.Failure.failed("자막 내용이 너무 짧아요.") }
                let prompt = """
                아래는 유튜브 영상 "\(title)"의 자막이야. [분:초] 다음에 그때 하는 말이 있어.
                한국어로 답해. lines는 영상 전체를 3줄로 요약 (한 줄에 한 문장).
                points는 볼 만한 핵심 장면 3~6개: seconds는 그 장면이 시작하는 초(숫자), text는 한 줄 설명.
                파일이나 도구는 쓰지 말고 바로 답해.
                [자막]
                \(transcript)
                """
                let schema = """
                {"type":"object","properties":{"lines":{"type":"array","items":{"type":"string"}},\
                "points":{"type":"array","items":{"type":"object","properties":{"seconds":{"type":"number"},"text":{"type":"string"}},\
                "required":["seconds","text"]}}},"required":["lines","points"]}
                """
                let data = try await GeminiCLI.ask(prompt, schema: schema)
                let summary = try JSONDecoder().decode(Summary.self, from: data)
                try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try? JSONEncoder().encode(summary).write(to: Self.folder.appendingPathComponent("\(id).json"))
                states[id] = .done(summary)
                DebugLog.write("AI 요약 완료: \(title)")
            } catch {
                states[id] = .failed(error.localizedDescription)
                DebugLog.write("AI 요약 실패: \(error.localizedDescription)")
            }
        }
    }

    func forget(_ id: String) {
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(id).json"))
        fromDisk[id] = nil
        states[id] = nil
    }

    /// 자막(json3)을 "[분:초] 말" 줄로 (30초마다 한 줄, 너무 길면 앞뒤를 고르게 줄임)
    static func transcript(from url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        struct Caption: Decodable {
            struct Event: Decodable {
                struct Seg: Decodable { let utf8: String? }
                let tStartMs: Double?
                let segs: [Seg]?
            }
            let events: [Event]?
        }
        let caption = try JSONDecoder().decode(Caption.self, from: data)
        var lines: [String] = []
        var bucket = -1
        var current = ""
        for event in caption.events ?? [] {
            let text = (event.segs ?? []).compactMap(\.utf8).joined().replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let ms = event.tStartMs else { continue }
            let b = Int(ms / 30_000)
            if b != bucket {
                if !current.isEmpty { lines.append(current) }
                bucket = b
                let s = Int(ms / 1000)
                current = String(format: "[%d:%02d] ", s / 60, s % 60) + text
            } else {
                current += " " + text
            }
        }
        if !current.isEmpty { lines.append(current) }
        var joined = lines.joined(separator: "\n")
        // 약 2만 자까지: 넘으면 줄을 고르게 건너뜀
        if joined.count > 20_000 {
            let keepEvery = Int(ceil(Double(joined.count) / 20_000))
            joined = lines.enumerated().filter { $0.offset % keepEvery == 0 }.map(\.element).joined(separator: "\n")
        }
        return joined
    }
}

/// 요약 보기 (재생 창·듣기 창의 ✨ 단추)
struct SummaryView: View {
    @Environment(\.theme) private var theme
    let videoID: String
    let title: String
    let captionURL: URL?
    @ObservedObject private var store = AISummaryStore.shared
    @ObservedObject private var now = NowPlaying.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI 요약", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(theme.style)
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Divider()
            switch store.state(videoID) {
            case .idle:
                Text("영상 자막을 재미나이에 보내 3줄 요약과 핵심 장면을 만들어요 (10~30초)")
                    .font(.callout).foregroundStyle(.secondary)
                Button("요약 만들기") { store.summarize(id: videoID, title: title, captionURL: captionURL) }
                    .buttonStyle(.borderedProminent)
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("재미나이가 영상을 읽는 중…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                Button("다시 시도") { store.summarize(id: videoID, title: title, captionURL: captionURL) }
            case .done(let summary):
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(summary.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(theme.style)
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
                if !summary.points.isEmpty {
                    Divider()
                    Text("핵심 장면 (누르면 그 장면으로)").font(.caption).foregroundStyle(.secondary)
                    ForEach(summary.points, id: \.self) { point in
                        Button {
                            if now.id == videoID { now.seek(to: point.seconds) }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(PlaybackMemory.timeText(point.seconds))
                                    .font(.callout.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(theme.style)
                                    .frame(width: 52, alignment: .leading)
                                Text(point.text).font(.callout).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("다시 만들기") {
                    store.forget(videoID)
                    store.summarize(id: videoID, title: title, captionURL: captionURL)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // 처음 열면 바로 만들기 시작
            if case .idle = store.state(videoID) {
                DispatchQueue.main.async { store.summarize(id: videoID, title: title, captionURL: captionURL) }
            }
        }
    }
}
