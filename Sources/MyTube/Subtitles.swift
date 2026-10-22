import AVFoundation
import MediaToolbox
import NaturalLanguage
import Speech
import SwiftUI
import Translation

// MARK: - 재생 중인 소리 받기

/// 앱 플레이어의 소리를 실시간으로 받는 오디오 탭 (소리는 그대로 나오고 복사본만 받음)
enum AudioTap {
    final class Context {
        var format: AVAudioFormat?
        let onBuffer: (AVAudioPCMBuffer) -> Void
        init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) { self.onBuffer = onBuffer }
    }

    static func audioMix(track: AVAssetTrack, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> AVAudioMix? {
        let context = Context(onBuffer: onBuffer)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, asbd in
                let ctx = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                ctx.format = AVAudioFormat(streamDescription: asbd)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let ctx = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard let format = ctx.format, framesOut.pointee > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesOut.pointee))
                else { return }
                buffer.frameLength = AVAudioFrameCount(framesOut.pointee)
                let src = UnsafeMutableAudioBufferListPointer(bufferList)
                let dst = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for i in 0..<min(src.count, dst.count) {
                    guard let s = src[i].mData, let d = dst[i].mData else { continue }
                    memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
                }
                ctx.onBuffer(buffer)
            })

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            DebugLog.write("오디오 탭 만들기 실패: \(status)")
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

/// 여러 인식기에 같은 소리를 나눠 줌 (오디오 쪽 스레드에서도 안전하게)
final class AudioFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String: AsyncStream<AnalyzerInput>.Continuation] = [:]
    /// 진단용: 탭에서 받은 소리 묶음 수, 인식기로 보낸 수
    private(set) var rawCount = 0
    private(set) var sentCount = 0
    func countRaw() { lock.lock(); rawCount += 1; lock.unlock() }

    func add(_ id: String, _ c: AsyncStream<AnalyzerInput>.Continuation) { lock.lock(); outputs[id] = c; lock.unlock() }

    func remove(_ id: String) {
        lock.lock(); let c = outputs.removeValue(forKey: id); lock.unlock()
        c?.finish()
    }

    func removeAll() {
        lock.lock(); let all = outputs.values; outputs = [:]; lock.unlock()
        all.forEach { $0.finish() }
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let all = Array(outputs.values); sentCount += 1; lock.unlock()
        for c in all { c.yield(AnalyzerInput(buffer: buffer)) }
    }
}

// MARK: - 받아쓰기 + 언어 자동 인식 + 한국어 번역

@MainActor
final class SubtitleEngine: ObservableObject {
    @Published private(set) var isOn = false
    /// 한국어 자막
    /// 자막 한 줄 (한국어 + 원문)
    struct SubLine: Equatable, Identifiable {
        let id: UUID
        var ko: String
        var orig: String
    }
    /// 두 줄 자막: [윗줄, 아랫줄]. 새 자막은 늘 아랫줄에 나오고, 있던 아랫줄은 윗줄로 올라감 (윗줄은 사라짐)
    @Published private(set) var lines: [SubLine?] = [nil, nil]
    /// 아직 번역되기 전 받아쓰는 중인 원문 (실시간 자막에서 작게 표시)
    @Published private(set) var liveOriginal = ""
    /// 진행 상황 (예: "언어 확인 중…", "일본어 → 한국어")
    @Published private(set) var status = ""
    @Published var showOriginal = true
    /// 영상을 열면 자막을 자동으로 켬 (기본: 꺼짐 — 자막 버튼을 눌러야 켜짐), 다음 실행에도 유지
    @Published var autoOn: Bool = UserDefaults.standard.object(forKey: "subtitleAutoOn") as? Bool ?? false {
        didSet { UserDefaults.standard.set(autoOn, forKey: "subtitleAutoOn") }
    }
    /// 한국어 자막 글자 크기 (원문은 이것보다 작게 따라감), 다음 실행에도 유지
    @Published var fontSize: Double = SubtitleEngine.savedFontSize {
        didSet { UserDefaults.standard.set(fontSize, forKey: "subtitleFontSize") }
    }
    static let fontSizes: [(label: String, size: Double)] = [
        ("작게", 20), ("보통", 28), ("크게", 36), ("아주 크게", 48), ("최대", 64),
    ]
    static let fontRange: ClosedRange<Double> = 14...80
    private static var savedFontSize: Double {
        let v = UserDefaults.standard.double(forKey: "subtitleFontSize")
        return v == 0 ? 28 : min(max(v, fontRange.lowerBound), fontRange.upperBound)
    }

    /// 자막 위치: 0 = 맨 아래(재생 막대 위), 1 = 맨 위. 창 크기가 바뀌어도 같은 비율, 다음 실행에도 유지
    @Published var position: Double = UserDefaults.standard.object(forKey: "subtitlePosition") as? Double ?? 0 {
        didSet { UserDefaults.standard.set(position, forKey: "subtitlePosition") }
    }
    static let positions: [(label: String, value: Double)] = [
        ("아래 (기본)", 0), ("조금 위", 0.25), ("가운데", 0.5), ("위쪽", 1),
    ]
    func moveUp() { position = min(1, ((position + 0.05) * 100).rounded() / 100) }
    func moveDown() { position = max(0, ((position - 0.05) * 100).rounded() / 100) }

    func biggerFont() { fontSize = min(fontSize + 4, Self.fontRange.upperBound) }
    func smallerFont() { fontSize = max(fontSize - 4, Self.fontRange.lowerBound) }
    /// 번역 연결: 바뀌면 화면의 .translationTask 가 새 번역 세션을 줌
    @Published private(set) var translationConfig: TranslationSession.Configuration?

    /// 처음에 함께 들어 볼 언어
    /// (러시아어는 SpeechTranscriber가 지원하지 않아서 DictationTranscriber로 들음)
    private static let candidateIDs = ["ja-JP", "en-US", "zh-CN", "ru-RU", "ko-KR"]

    /// 인식 결과 한 개 (두 가지 인식기 결과를 같은 모양으로)
    struct Heard: Sendable {
        let text: String
        let isFinal: Bool
        let confidences: [Double]
    }

    private final class Candidate: @unchecked Sendable {
        let id: String
        let locale: Locale
        let module: any SpeechModule
        /// 인식 결과 흐름 (인식기 종류와 관계없이 같은 모양)
        let heard: AsyncThrowingStream<Heard, Error>
        let analyzer: SpeechAnalyzer
        var finalText = ""
        var confidences: [Double] = []
        var finalCount = 0
        var resultCount = 0   // 진단용: 받은 결과 수 (임시 결과 포함)
        var lastText = ""     // 진단용: 마지막으로 받은 글
        var tasks: [Task<Void, Never>] = []

        init(locale: Locale, dictation: Bool) {
            self.locale = locale
            id = locale.identifier
            if dictation {
                let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [],
                                             reportingOptions: [.volatileResults],
                                             attributeOptions: [.transcriptionConfidence])
                module = t
                heard = Self.map(t.results) { Heard(text: String($0.text.characters), isFinal: $0.isFinal,
                                                    confidences: $0.text.runs.compactMap(\.transcriptionConfidence)) }
            } else {
                let t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                          reportingOptions: [.volatileResults],
                                          attributeOptions: [.transcriptionConfidence])
                module = t
                heard = Self.map(t.results) { Heard(text: String($0.text.characters), isFinal: $0.isFinal,
                                                    confidences: $0.text.runs.compactMap(\.transcriptionConfidence)) }
            }
            analyzer = SpeechAnalyzer(modules: [module])
        }

        private static func map<S: AsyncSequence & Sendable>(_ results: S, _ make: @escaping @Sendable (S.Element) -> Heard)
            -> AsyncThrowingStream<Heard, Error> where S.Element: Sendable {
            AsyncThrowingStream { cont in
                let task = Task {
                    do {
                        for try await r in results { cont.yield(make(r)) }
                        cont.finish()
                    } catch {
                        cont.finish(throwing: error)
                    }
                }
                cont.onTermination = { _ in task.cancel() }
            }
        }
    }

    private var candidates: [Candidate] = []
    private var chosen: Candidate?
    private let fanout = AudioFanout()
    private var pumpTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    /// 줄마다 사라질 때를 재는 작업 (줄이 위로 올라가도 그 줄을 따라감)
    private var lineTasks: [UUID: Task<Void, Never>] = [:]
    private var lastCueStart: Double?
    private var lastCueTime: Double = 0
    private var diagTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    private var lastDelivered = ""
    private var detectStart = Date()
    private weak var item: AVPlayerItem?
    private var sentences: AsyncStream<String>.Continuation?

    // MARK: 미리 만든 자막 (재생 시간에 맞춰 표시)

    @Published private(set) var usingPrebuilt = false
    private var timeObserver: Any?
    private weak var observedPlayer: AVPlayer?

    func showPrebuilt(_ saved: SavedSubtitles, player: AVPlayer) {
        stop()
        isOn = true
        usingPrebuilt = true
        status = ""
        let cues = saved.cues
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.showCue(in: cues, at: time.seconds) }
        }
        DebugLog.write("미리 만든 자막 사용: \(cues.count)줄")
    }

    private func showCue(in cues: [SavedSubtitles.Cue], at t: Double) {
        // 시간순으로 정렬돼 있어서 이진 탐색
        var lo = 0, hi = cues.count - 1, found: SavedSubtitles.Cue?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = cues[mid]
            if t < c.start { hi = mid - 1 } else if t >= c.end { lo = mid + 1 } else { found = c; break }
        }
        // 앞뒤로 크게 옮기면 두 줄을 비우고 새로 시작
        if abs(t - lastCueTime) > 2.5 { clearLines(); lastCueStart = nil }
        lastCueTime = t
        guard let found, found.start != lastCueStart else { return }
        lastCueStart = found.start
        push(ko: found.ko, orig: found.orig, hold: max(2.5, found.end - t + 2))
    }

    /// 새 자막 넣기: 같은 문장이 길어진 거면 아랫줄을 고치고, 아니면 아랫줄을 윗줄로 올리고 새 문장을 아랫줄에
    private func push(ko rawKo: String, orig rawOrig: String, hold: Double) {
        let ko = rawKo.trimmingCharacters(in: .whitespacesAndNewlines)
        let orig = rawOrig.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ko.isEmpty else { return }
        let id: UUID
        if let cur = lines[1], !cur.orig.isEmpty, !orig.isEmpty,
           orig.hasPrefix(cur.orig) || cur.orig.hasPrefix(orig) {
            id = cur.id
            lines[1] = SubLine(id: id, ko: ko, orig: orig)
        } else {
            // 윗줄은 사라지고, 아랫줄이 윗줄로, 새 문장이 아랫줄로
            if let gone = lines[0] { lineTasks[gone.id]?.cancel(); lineTasks[gone.id] = nil }
            id = UUID()
            lines = [lines[1], SubLine(id: id, ko: ko, orig: orig)]
        }
        lineTasks[id]?.cancel()
        lineTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.lineTasks[id] = nil
            // 이 줄이 어디에 있든 지움 (아랫줄이 먼저 사라지면 윗줄을 아랫줄로 내려 늘 아래부터 채움)
            if self.lines[0]?.id == id { self.lines[0] = nil }
            if self.lines[1]?.id == id { self.lines = [nil, self.lines[0]] }
        }
    }

    private func clearLines() {
        lineTasks.values.forEach { $0.cancel() }
        lineTasks = [:]
        lines = [nil, nil]
        liveOriginal = ""
    }

    // MARK: 켜기·끄기

    func start(item: AVPlayerItem) {
        guard !isOn else { return }
        isOn = true
        self.item = item
        status = "자막 준비 중…"
        setupTask = Task { await setUp(item: item) }
    }

    func stop() {
        isOn = false
        usingPrebuilt = false
        if let timeObserver, let observedPlayer { observedPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observedPlayer = nil
        setupTask?.cancel()
        pumpTask?.cancel()
        diagTask?.cancel()
        pendingTask?.cancel()
        lastDelivered = ""
        fanout.removeAll()
        for c in candidates {
            c.tasks.forEach { $0.cancel() }
            let analyzer = c.analyzer
            Task { await analyzer.cancelAndFinishNow() }
        }
        candidates = []
        chosen = nil
        item?.audioMix = nil
        translationConfig = nil
        sentences?.finish()
        clearLines(); status = ""
        lastCueStart = nil
    }

    /// 언어를 처음부터 다시 찾기
    func restart() {
        guard let item else { return }
        stop()
        start(item: item)
    }

    private func setUp(item: AVPlayerItem) async {
        do {
            guard SpeechTranscriber.isAvailable else { status = "이 맥에서는 음성 인식을 쓸 수 없어요."; return }

            // 들어 볼 언어 (이 맥이 지원하는 것만)
            var found: [Candidate] = []
            for id in Self.candidateIDs {
                if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) {
                    found.append(Candidate(locale: l, dictation: false))
                } else if let l = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) {
                    found.append(Candidate(locale: l, dictation: true))   // 러시아어 등
                }
            }
            guard !found.isEmpty else { status = "지원하는 인식 언어가 없어요."; return }
            candidates = found

            // 언어별 인식 자료가 없으면 받기 (처음 한 번)
            for c in candidates {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [c.module]) {
                    status = "\(Self.name(c.locale)) 인식 자료 받는 중… (처음 한 번)"
                    try await request.downloadAndInstall()
                }
            }
            guard isOn else { return }

            let modules = candidates.map(\.module)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                status = "음성 인식 형식을 정하지 못했어요."; return
            }

            // 인식기 시작
            for c in candidates {
                let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(400))
                fanout.add(c.id, cont)
                try await c.analyzer.prepareToAnalyze(in: format)
                let analyzer = c.analyzer
                c.tasks.append(Task { _ = try? await analyzer.analyzeSequence(stream) })
                // 인식 결과는 다른 스레드에서 받아서 화면 쪽으로 넘김
                let heard = c.heard
                c.tasks.append(Task.detached { [weak self] in
                    do {
                        for try await result in heard {
                            await self?.handle(result, from: c)
                        }
                    } catch {
                        DebugLog.write("인식 중단 \(c.id): \(error)")
                    }
                })
            }

            // 소리 받기 → 인식 형식으로 바꿔서 나눠 주기
            let tracks = try await item.asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { status = "이 영상에는 소리가 없어요."; return }
            let (raw, rawCont) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(200))
            guard let mix = AudioTap.audioMix(track: track, onBuffer: { [fanout] in fanout.countRaw(); rawCont.yield($0) }) else {
                status = "소리를 받지 못했어요."; return
            }
            item.audioMix = mix
            let fanout = self.fanout
            pumpTask = Task.detached {
                var converter: AVAudioConverter?
                for await buffer in raw {
                    if Task.isCancelled { break }
                    if buffer.format == format { fanout.send(buffer); continue }
                    if converter == nil || converter?.inputFormat != buffer.format {
                        converter = AVAudioConverter(from: buffer.format, to: format)
                    }
                    guard let converter else { continue }
                    let ratio = format.sampleRate / buffer.format.sampleRate
                    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
                    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { continue }
                    var used = false
                    var error: NSError?
                    converter.convert(to: out, error: &error) { _, inputStatus in
                        if used { inputStatus.pointee = .noDataNow; return nil }
                        used = true
                        inputStatus.pointee = .haveData
                        return buffer
                    }
                    if error == nil, out.frameLength > 0 { fanout.send(out) }
                }
            }

            // 진단: 10초마다 소리·결과가 오가는지 기록
            diagTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard let self, self.isOn else { return }
                    DebugLog.write("자막 진단: 받은 소리 \(self.fanout.rawCount), 보낸 소리 \(self.fanout.sentCount), 결과 "
                        + self.candidates.map { "\($0.id)=\($0.resultCount)/\($0.finalCount) 「\($0.lastText.prefix(30))」" }.joined(separator: " ")
                        + ", 형식 \(format.sampleRate)Hz \(format.channelCount)ch")
                }
            }
            detectStart = Date()
            status = candidates.count > 1 ? "언어 확인 중… (말소리를 듣고 있어요)" : "\(Self.name(candidates[0].locale)) → 한국어"
            if candidates.count == 1 { choose(candidates[0]) }
            DebugLog.write("자막 시작: 후보 \(candidates.map(\.id))")
        } catch {
            DebugLog.write("자막 준비 실패: \(error)")
            status = "자막을 켜지 못했어요: \(error.localizedDescription)"
        }
    }

    // MARK: 인식 결과

    private func handle(_ result: Heard, from c: Candidate) {
        guard isOn else { return }
        c.resultCount += 1
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { c.lastText = text }

        if let chosen {
            guard chosen === c, !text.isEmpty else { return }
            liveOriginal = text
            if result.isFinal {
                pendingTask?.cancel()
                deliver(text)
            } else {
                // 확정이 늦게 오는 경우가 많아서, 같은 글이 1초 동안 그대로면 먼저 번역
                pendingTask?.cancel()
                pendingTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.deliver(text)
                }
            }
            scheduleClear()
            return
        }

        // 아직 언어를 고르는 중: 확정된 글과 확신도를 모아 둠
        guard result.isFinal, !text.isEmpty else { return }
        c.finalText += " " + text
        c.finalCount += 1
        c.confidences += result.confidences
        decideIfReady()
    }

    /// 번역으로 보내기 (같은 글은 한 번만)
    private func deliver(_ text: String) {
        guard text != lastDelivered, let chosen else { return }
        lastDelivered = text
        if chosen.locale.language.languageCode == .korean {
            push(ko: text, orig: text, hold: 7)   // 원래 한국어면 번역 없이
            liveOriginal = ""
        } else {
            sentences?.yield(text)
        }
    }

    /// 충분히 들었으면 가장 잘 맞는 언어 하나만 남김
    private func decideIfReady() {
        let elapsed = Date().timeIntervalSince(detectStart)
        let enough = candidates.contains { $0.finalCount >= 2 && $0.finalText.count >= 10 }
        guard (enough && elapsed >= 5) || elapsed >= 40 else { return }
        let scored = candidates.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 > 0.05 else { return }
        DebugLog.write("언어 판단: " + scored.map { "\($0.0.id)=\(String(format: "%.3f", $0.1))" }.joined(separator: ", "))
        choose(best.0)
    }

    /// 점수 = 그 언어처럼 보이는 정도 × 인식 확신도 × 글 양
    private func score(_ c: Candidate) -> Double {
        Self.languageScore(text: c.finalText, confidences: c.confidences, locale: c.locale)
    }

    /// 점수 = 그 언어처럼 보이는 정도 × 인식 확신도 × 글 양 (미리 만들기에서도 같이 씀)
    nonisolated static func languageScore(text raw: String, confidences: [Double], locale: Locale) -> Double {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3 else { return 0 }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 8)
        let p = nlLanguages(for: locale).map { hypotheses[$0] ?? 0 }.max() ?? 0
        let confidence = confidences.isEmpty ? 0.5 : confidences.reduce(0, +) / Double(confidences.count)
        return p * confidence * log(Double(text.count) + 1)
    }

    private func choose(_ c: Candidate) {
        chosen = c
        for other in candidates where other !== c {
            fanout.remove(other.id)
            other.tasks.forEach { $0.cancel() }
            let analyzer = other.analyzer
            Task { await analyzer.cancelAndFinishNow() }
        }
        candidates = [c]
        let name = Self.name(c.locale)
        if c.locale.language.languageCode == .korean {
            status = "한국어 (번역 없이 표시)"
        } else {
            status = "\(name) → 한국어"
            translationConfig = TranslationSession.Configuration(source: c.locale.language, target: Locale.Language(identifier: "ko"))
        }
        DebugLog.write("자막 언어: \(c.id)")
    }

    // MARK: 번역 (화면의 .translationTask 에서 부름)

    func runTranslation(_ session: TranslationSession) async {
        let (stream, cont) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(5))
        sentences = cont
        do {
            try await session.prepareTranslation()   // 번역 자료가 없으면 받기 안내가 뜸
        } catch {
            DebugLog.write("번역 준비 실패: \(error)")
        }
        for await sentence in stream {
            do {
                let response = try await session.translate(sentence)
                push(ko: response.targetText, orig: sentence, hold: 7)
                if sentence.hasPrefix(liveOriginal) || liveOriginal.hasPrefix(sentence) { liveOriginal = "" }
            } catch {
                DebugLog.write("번역 실패: \(error)")
                status = "번역 실패: \(error.localizedDescription)"
            }
        }
    }

    /// 말이 한동안 없으면 자막 지우기
    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.liveOriginal = ""
        }
    }

    // MARK: 언어 이름

    nonisolated static func name(_ locale: Locale) -> String {
        Locale(identifier: "ko").localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? locale.identifier
    }

    nonisolated private static func nlLanguages(for locale: Locale) -> [NLLanguage] {
        switch locale.language.languageCode?.identifier {
        case "ja": [.japanese]
        case "en": [.english]
        case "zh": [.simplifiedChinese, .traditionalChinese]
        case "ru": [.russian]
        case "ko": [.korean]
        default: [NLLanguage(locale.language.languageCode?.identifier ?? "")]
        }
    }
}

// MARK: - 화면

/// 영상 아래쪽 자막
struct SubtitleOverlay: View {
    @ObservedObject var engine: SubtitleEngine

    var body: some View {
        GeometryReader { geo in
            // 아래쪽 여백 70(재생 막대 위) ~ 위쪽 끝까지 위치 비율로
            let lowest = 70.0
            let highest = max(lowest, geo.size.height - 60 - engine.fontSize * 2.5)
            subtitleStack
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, lowest + (highest - lowest) * engine.position)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.25), value: engine.lines)
        .animation(.easeOut(duration: 0.2), value: engine.position)
    }

    private var hasLines: Bool { engine.lines.contains { $0 != nil } }

    private var subtitleStack: some View {
        VStack(spacing: engine.fontSize * 0.3) {
            if engine.isOn, !hasLines, engine.liveOriginal.isEmpty, !engine.status.isEmpty {
                Text(engine.status)
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white.opacity(0.85))
            }
            // 최신 줄이 늘 아래: 새 줄이 아래에서 나타나고 있던 줄은 위로 밀려 올라감 (아랫줄 위치는 고정)
            ForEach(engine.lines.compactMap { $0 }) { line in
                lineView(line)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity))
            }
            // 실시간 자막: 번역되기 전 받아쓰는 중인 원문
            if engine.showOriginal, !engine.usingPrebuilt, !engine.liveOriginal.isEmpty {
                Text(engine.liveOriginal)
                    .font(.system(size: max(12, engine.fontSize * 0.5)))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 40)
    }

    private func lineView(_ line: SubtitleEngine.SubLine?) -> some View {
        VStack(spacing: 2) {
            // 원문은 한국어 자막의 약 60% 크기
            if engine.showOriginal {
                Text(line.map { $0.orig != $0.ko ? $0.orig : " " } ?? " ")
                    .font(.system(size: max(12, engine.fontSize * 0.6)))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            Text(line?.ko ?? " ")
                .font(.system(size: engine.fontSize, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 2)
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, engine.fontSize * 0.5).padding(.vertical, engine.fontSize * 0.15)
        .background(.black.opacity(line == nil ? 0 : 0.6), in: RoundedRectangle(cornerRadius: 8))
        .opacity(line == nil ? 0 : 1)
    }
}
