import AVFoundation
import Speech
import SwiftUI
import Translation
import WebKit

// MARK: - 저장되는 자막

/// 영상 하나의 미리 만든 자막
struct SavedSubtitles: Codable {
    struct Cue: Codable {
        let start: Double
        let end: Double
        let orig: String
        var ko: String
    }
    let language: String   // 원래 말 (예: ja_JP)
    let created: Date
    var cues: [Cue]
}

/// 저장 위치: ~/Library/Application Support/MyTube/Subtitles/<영상코드>.json (+ .ko.srt, .orig.srt)
enum SubtitleStore {
    static let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTube/Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func jsonURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }
    static func srtURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).ko.srt") }

    static func load(_ id: String) -> SavedSubtitles? {
        guard let data = try? Data(contentsOf: jsonURL(id)) else { return nil }
        return try? JSONDecoder().decode(SavedSubtitles.self, from: data)
    }

    static func save(_ subs: SavedSubtitles, id: String) throws {
        try JSONEncoder().encode(subs).write(to: jsonURL(id), options: .atomic)
        try srt(subs.cues.map { ($0.start, $0.end, $0.ko) }).write(to: srtURL(id), atomically: true, encoding: .utf8)
        try srt(subs.cues.map { ($0.start, $0.end, $0.orig) })
            .write(to: folder.appendingPathComponent("\(id).orig.srt"), atomically: true, encoding: .utf8)
    }

    static func delete(_ id: String) {
        for name in ["\(id).json", "\(id).ko.srt", "\(id).orig.srt"] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// 일반 자막 파일(SRT) 형식
    private static func srt(_ lines: [(Double, Double, String)]) -> String {
        func time(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return lines.enumerated().map { i, l in "\(i + 1)\n\(time(l.0)) --> \(time(l.1))\n\(l.2)\n" }.joined(separator: "\n")
    }
}

// MARK: - 자막 미리 만들기

@MainActor
final class SubtitleBuilder: ObservableObject {
    enum State: Equatable { case idle, working(String), done, failed(String) }

    @Published private(set) var state = State.idle
    /// 번역 연결: 받아쓰기가 끝나면 설정되고, 화면의 .translationTask 가 번역 세션을 줌
    @Published private(set) var translationConfig: TranslationSession.Configuration?

    var isWorking: Bool { if case .working = state { true } else { false } }

    private var task: Task<Void, Never>?
    private var pending: (id: String, language: Locale, cues: [SavedSubtitles.Cue])?
    private var onFinished: ((SavedSubtitles) -> Void)?
    private static let candidateIDs = ["ja-JP", "en-US", "zh-CN", "ru-RU", "ko-KR"]

    func start(_ item: PlayerItem, onFinished: @escaping (SavedSubtitles) -> Void) {
        guard !isWorking else { return }
        self.onFinished = onFinished
        state = .working("준비 중…")
        task = Task { await run(item) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        translationConfig = nil
        pending = nil
        state = .idle
    }

    private func run(_ item: PlayerItem) async {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MyTubeSubs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            // 1~2. 소리만 필요하니 yt-dlp로 소리(m4a)만 받기
            state = .working("소리 받는 중…")
            let audio = work.appendingPathComponent("audio.m4a")
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            try await YTDLP.downloadAudio(URL(string: item.url)!, cookies: cookies, to: audio)
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: audio)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            DebugLog.write("자막 만들기: 소리 \(Int(duration))초")

            // 3. 언어 판단 (중간쯤 90초를 4개 언어로 들어 봄)
            let locale = try await detectLanguage(file: audio, duration: duration)
            try Task.checkCancellation()

            // 4. 처음부터 끝까지 받아쓰기
            let cues = try await transcribe(audio, locale: locale, duration: duration)
            try Task.checkCancellation()
            guard !cues.isEmpty else { state = .failed("알아들은 말이 없어요."); return }

            // 5. 번역 (원래 한국어면 그대로)
            if locale.language.languageCode == .korean {
                finish(id: item.id, language: locale, cues: cues)
            } else {
                pending = (item.id, locale, cues)
                state = .working("한국어로 번역 중… (\(cues.count)줄)")
                translationConfig = TranslationSession.Configuration(source: locale.language, target: Locale.Language(identifier: "ko"))
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            DebugLog.write("자막 만들기 실패: \(error)")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: 언어 판단

    private func detectLanguage(file url: URL, duration: Double) async throws -> Locale {
        var locales: [Locale] = []
        for id in Self.candidateIDs {
            if let l = await Recognizer.supported(id) { locales.append(l) }
        }
        guard !locales.isEmpty else { throw NSError(domain: "MyTube", code: 2, userInfo: [NSLocalizedDescriptionKey: "지원하는 인식 언어가 없어요."]) }
        if locales.count == 1 { return locales[0] }

        // 인식 자료가 없으면 받기
        for l in locales {
            let t = await Recognizer.make(l, confidence: false, timeRange: false).module
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                state = .working("\(SubtitleEngine.name(l)) 인식 자료 받는 중…")
                try await request.downloadAndInstall()
            }
        }

        state = .working("언어 확인 중…")
        let excerpt = 90.0
        let start = duration > excerpt * 2 ? min(duration * 0.15, duration - excerpt) : 0
        var best: (Locale, Double) = (locales[0], -1)
        for l in locales {
            try Task.checkCancellation()
            let (text, confidences) = try await transcribeExcerpt(url, locale: l, start: start, seconds: excerpt)
            let score = SubtitleEngine.languageScore(text: text, confidences: confidences, locale: l)
            DebugLog.write("자막 만들기 언어 점수 \(l.identifier)=\(String(format: "%.3f", score))")
            if score > best.1 { best = (l, score) }
        }
        state = .working("\(SubtitleEngine.name(best.0))로 판단했어요")
        return best.0
    }

    /// 소리의 일부만 받아써 봄 (언어 판단용)
    private func transcribeExcerpt(_ url: URL, locale: Locale, start: Double, seconds: Double) async throws -> (String, [Double]) {
        let (transcriber, results) = await Recognizer.make(locale, confidence: true, timeRange: false)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return ("", []) }
        try await analyzer.prepareToAnalyze(in: format)

        let collector = Task { () -> (String, [Double]) in
            var text = "", conf: [Double] = []
            do {
                for try await r in results where r.isFinal {
                    text += " " + String(r.text.characters)
                    for run in r.text.runs { if let c = run.transcriptionConfidence { conf.append(c) } }
                }
            } catch {}
            return (text, conf)
        }

        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let feeding = Task.detached { () throws in
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            file.framePosition = AVAudioFramePosition(start * rate)
            var remaining = AVAudioFrameCount(seconds * rate)
            let converter = AVAudioConverter(from: file.processingFormat, to: format)
            while remaining > 0 {
                let n = min(remaining, AVAudioFrameCount(rate))
                guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { break }
                try file.read(into: buf, frameCount: n)
                if buf.frameLength == 0 { break }
                remaining -= buf.frameLength
                if let out = Self.convert(buf, with: converter, to: format) { cont.yield(AnalyzerInput(buffer: out)) }
            }
            cont.finish()
        }
        _ = try await analyzer.analyzeSequence(stream)
        try await feeding.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return await collector.value
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var used = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    // MARK: 전체 받아쓰기

    private func transcribe(_ url: URL, locale: Locale, duration: Double) async throws -> [SavedSubtitles.Cue] {
        let (transcriber, results) = await Recognizer.make(locale, confidence: false, timeRange: true)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            state = .working("\(SubtitleEngine.name(locale)) 인식 자료 받는 중…")
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        _ = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)

        var cues: [SavedSubtitles.Cue] = []
        state = .working("받아쓰는 중… 0%")
        for try await result in results where result.isFinal {
            try Task.checkCancellation()
            cues += Self.cues(from: result)
            let percent = min(99, safeInt(result.range.end.seconds / max(duration, 1) * 100))
            state = .working("받아쓰는 중… \(percent)%")
        }
        DebugLog.write("자막 만들기: \(cues.count)줄 받아씀")
        return cues
    }

    /// 단어마다 붙은 시간을 써서 읽기 좋은 길이의 줄로 나눔
    nonisolated private static func cues(from result: any TranscriptResultLike) -> [SavedSubtitles.Cue] {
        var out: [SavedSubtitles.Cue] = []
        var text = "", start: Double?, end = result.range.end.seconds
        func flush() {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, let s = start { out.append(.init(start: s, end: max(end, s + 0.8), orig: t, ko: t)) }
            text = ""; start = nil
        }
        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
            let range = run.audioTimeRange
            if start == nil { start = range?.start.seconds ?? result.range.start.seconds }
            end = range?.end.seconds ?? result.range.end.seconds
            text += piece
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 28 || piece.contains(where: { "。！？.!?".contains($0) }) { flush() }
        }
        flush()
        return out
    }

    // MARK: 번역 (화면의 .translationTask 에서 부름)

    func translateAll(_ session: TranslationSession) async {
        guard var job = pending else { return }
        do {
            try? await session.prepareTranslation()
            let chunk = 40
            for startIndex in stride(from: 0, to: job.cues.count, by: chunk) {
                try Task.checkCancellation()
                let range = startIndex..<min(startIndex + chunk, job.cues.count)
                let requests = range.map { TranslationSession.Request(sourceText: job.cues[$0].orig, clientIdentifier: "\($0)") }
                for response in try await session.translations(from: requests) {
                    if let id = response.clientIdentifier, let i = Int(id) { job.cues[i].ko = response.targetText }
                }
                state = .working("한국어로 번역 중… \(min(100, range.upperBound * 100 / job.cues.count))%")
            }
            finish(id: job.id, language: job.language, cues: job.cues)
        } catch {
            DebugLog.write("자막 번역 실패: \(error)")
            state = .failed("번역 실패: \(error.localizedDescription)")
        }
        pending = nil
        translationConfig = nil
    }

    private func finish(id: String, language: Locale, cues: [SavedSubtitles.Cue]) {
        let subs = SavedSubtitles(language: language.identifier, created: Date(), cues: cues)
        do {
            try SubtitleStore.save(subs, id: id)
            state = .done
            DebugLog.write("자막 만들기 완료: \(cues.count)줄 → \(SubtitleStore.srtURL(id).path)")
            onFinished?(subs)
            Toast.shared.show("자막을 만들었어요 (\(cues.count)줄)")
        } catch {
            state = .failed("저장 실패: \(error.localizedDescription)")
        }
    }
}

// MARK: - 두 가지 인식기를 같은 모양으로 (러시아어는 SpeechTranscriber가 지원하지 않아 DictationTranscriber로)

/// 인식 결과 공통 모양
protocol TranscriptResultLike: Sendable {
    var text: AttributedString { get }
    var isFinal: Bool { get }
    var range: CMTimeRange { get }
}
extension SpeechTranscriber.Result: TranscriptResultLike {}
extension DictationTranscriber.Result: TranscriptResultLike {}

enum Recognizer {
    /// 이 언어를 받아쓸 수 있으면 그 언어 (먼저 SpeechTranscriber, 안 되면 DictationTranscriber)
    static func supported(_ id: String) async -> Locale? {
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) { return l }
        return await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: id))
    }

    /// 인식기와 결과 흐름
    static func make(_ locale: Locale, confidence: Bool, timeRange: Bool) async
        -> (module: any SpeechModule, results: AsyncThrowingStream<any TranscriptResultLike, Error>) {
        if await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil {
            var options: Set<SpeechTranscriber.ResultAttributeOption> = []
            if confidence { options.insert(.transcriptionConfidence) }
            if timeRange { options.insert(.audioTimeRange) }
            let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: options)
            return (t, stream(t.results))
        }
        var options: Set<DictationTranscriber.ResultAttributeOption> = []
        if confidence { options.insert(.transcriptionConfidence) }
        if timeRange { options.insert(.audioTimeRange) }
        let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [], reportingOptions: [], attributeOptions: options)
        return (t, stream(t.results))
    }

    private static func stream<S: AsyncSequence & Sendable>(_ results: S) -> AsyncThrowingStream<any TranscriptResultLike, Error>
        where S.Element: TranscriptResultLike {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await r in results { cont.yield(r) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
