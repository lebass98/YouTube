import AppKit
import SwiftUI

/// 영상 다운로드: yt-dlp로 4K까지 최고 화질을 받아 ffmpeg로 mp4 하나로 합침 → ~/Downloads
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    struct Job: Identifiable {
        enum State: Equatable {
            case running(String)   // 진행 설명 (예: "영상 42% · 12MiB/s · 남은 시간 00:31")
            case merging
            case done(URL)
            case failed(String)
            case cancelled
        }
        let id = UUID()
        let title: String
        let pageURL: URL
        var progress: Double = 0
        var state = State.running("준비 중…")

        var isActive: Bool {
            switch state {
            case .running, .merging: true
            default: false
            }
        }
    }

    @Published private(set) var jobs: [Job] = []
    private var processes: [UUID: Process] = [:]

    var activeCount: Int { jobs.filter(\.isActive).count }

    /// 기본 저장 폴더: ~/Downloads
    static let defaultFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private static let folderKey = "downloadFolder"

    /// 영상 저장 폴더 (설정에서 바꿈, 다음 실행에도 유지). 고른 폴더가 없어졌으면 기본 폴더로
    static var folder: URL {
        guard let path = UserDefaults.standard.string(forKey: folderKey) else { return defaultFolder }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return defaultFolder }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// nil이면 기본 폴더로 되돌림
    static func setFolder(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path, forKey: folderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: folderKey)
        }
        DebugLog.write("다운로드 저장 폴더: \(folder.path)")
    }

    /// 화질 규칙(재생과 같음): 4K까지 가장 높은 화질, 8K 제외. 같은 화질이면 Mac에서 바로 열리는 AV1·H.264 + AAC를 먼저
    private static let sort = "res,fps,vcodec:av01,acodec:m4a"

    /// 끝날 때까지 기다리는 받기 (자동 받기용): 받은 파일, 실패하면 nil
    private var waiters: [UUID: CheckedContinuation<URL?, Never>] = [:]

    func download(pageURL: URL, title: String, cookies: [HTTPCookie], audioOnly: Bool, maxHeight: Int) async -> URL? {
        guard let id = start(pageURL: pageURL, title: title, cookies: cookies, audioOnly: audioOnly, maxHeight: maxHeight) else { return nil }
        return await withCheckedContinuation { waiters[id] = $0 }
    }

    /// audioOnly: 소리만 m4a로 (듣기용), maxHeight: 영상 화질 상한
    @discardableResult
    func start(pageURL: URL, title: String, cookies: [HTTPCookie], audioOnly: Bool = false, maxHeight: Int = 2160) -> UUID? {
        guard let exe = YTDLP.executable else {
            jobs.insert(Job(title: title, pageURL: pageURL, state: .failed(YTDLP.Failure.notInstalled.localizedDescription)), at: 0)
            return nil
        }
        if jobs.contains(where: { $0.pageURL == pageURL && $0.isActive }) { return nil }   // 같은 영상은 한 번만

        let job = Job(title: (audioOnly ? "🎧 " : "") + title, pageURL: pageURL)
        jobs.insert(job, at: 0)

        let format = audioOnly ? "ba[ext=m4a]/ba"
            : "bv*[height<=\(maxHeight)]+ba/b[height<=\(maxHeight)]/bv*+ba/b"
        var args = [
            "--no-warnings", "--no-playlist", "--newline", "--progress", "--no-mtime",
            "-f", format, "-S", Self.sort,
        ]
        if !audioOnly { args += ["--merge-output-format", "mp4"] }
        args += [
            "-P", Self.folder.path, "-o", "%(title)s [%(id)s].%(ext)s",
            "--progress-template", "download:MYTUBE|%(info.vcodec)s|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print", "after_move:MYTUBEFILE|%(filepath)s",
        ]
        if let cookieFile = try? YTDLP.writeCookies(cookies) {
            args += ["--cookies", cookieFile.path]
        }
        args.append(pageURL.absoluteString)

        let process = Process()
        process.executableURL = exe
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        // 합치기에 쓰는 ffmpeg, 암호 풀이에 쓰는 deno가 Homebrew 경로에 있음
        env["PATH"] = (YTDLP.searchPaths + ["/bin"]).joined(separator: ":")
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let errBox = LineBuffer()
        let outBox = LineBuffer()
        let id = job.id

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in outBox.lines(adding: data) {
                Task { @MainActor in DownloadManager.shared.handle(line, for: id) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            _ = errBox.lines(adding: data)
        }
        process.terminationHandler = { process in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let status = process.terminationStatus
            let reason = process.terminationReason
            let message = errBox.all.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                DownloadManager.shared.finished(id, status: status, killed: reason == .uncaughtSignal, error: message)
            }
        }

        do {
            try process.run()
            processes[id] = process
            DebugLog.write("다운로드 시작\(audioOnly ? " (소리만)" : ""): \(title) \(pageURL)")
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
            return nil
        }
        return id
    }

    func cancel(_ id: UUID) {
        processes[id]?.terminate()
        update(id) { $0.state = .cancelled }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    // MARK: yt-dlp 출력 읽기

    private func handle(_ line: String, for id: UUID) {
        if line.hasPrefix("MYTUBEFILE|") {
            let path = String(line.dropFirst("MYTUBEFILE|".count))
            update(id) { $0.state = .done(URL(fileURLWithPath: path)); $0.progress = 1 }
            return
        }
        if line.hasPrefix("MYTUBE|") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count >= 5 else { return }
            let kind = parts[1] == "none" ? "소리" : "영상"
            let percent = Double(parts[2].replacingOccurrences(of: "%", with: "")) ?? 0
            var text = "\(kind) \(Int(percent))%"
            // 처음엔 속도·남은 시간을 모르면 "Unknown"/"NA"로 옴 → 숨김
            func known(_ v: String) -> Bool { !v.isEmpty && !v.contains("Unknown") && v != "NA" }
            if known(parts[3]) { text += " · \(parts[3])" }
            if known(parts[4]) { text += " · 남은 시간 \(parts[4])" }
            update(id) {
                // 영상(전체의 90%)을 받은 뒤 소리(10%)를 받음
                $0.progress = kind == "영상" ? percent / 100 * 0.9 : 0.9 + percent / 100 * 0.1
                $0.state = percent >= 100 && kind == "소리" ? .merging : .running(text)
            }
        }
    }

    private func finished(_ id: UUID, status: Int32, killed: Bool, error: String) {
        processes[id] = nil
        defer {
            if let waiter = waiters.removeValue(forKey: id) {
                if case .done(let url) = jobs.first(where: { $0.id == id })?.state { waiter.resume(returning: url) } else { waiter.resume(returning: nil) }
            }
        }
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        switch job.state {
        case .done(let url):
            DebugLog.write("다운로드 완료: \(url.path)")
            Toast.shared.show("다운로드 완료: \(url.lastPathComponent)")
        case .cancelled:
            DebugLog.write("다운로드 취소: \(job.title)")
        default:
            let message = killed ? "중단됐어요." : (error.isEmpty ? "yt-dlp 종료 코드 \(status)" : String(error.suffix(400)))
            DebugLog.write("다운로드 실패: \(job.title) — \(message)")
            update(id) { $0.state = .failed(message) }
        }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }
}

/// 파이프에서 조각조각 들어오는 글을 줄 단위로 자름 (다른 스레드에서 불림)
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private(set) var all = ""

    func lines(adding data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: data, as: UTF8.self)
        all += text
        if all.count > 20_000 { all = String(all.suffix(10_000)) }
        pending += text
        var parts = pending.components(separatedBy: CharacterSet.newlines)
        pending = parts.removeLast()
        return parts.filter { !$0.isEmpty }
    }
}

/// 위쪽 막대 다운로드 버튼을 누르면 뜨는 목록
struct DownloadsPanel: View {
    @ObservedObject var manager = DownloadManager.shared
    let canDownload: Bool
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onDownload) {
                Label("지금 영상 최고 화질로 받기", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canDownload)
            .help("단축키 ⌘⇧D")
            if !canDownload {
                Text("영상 페이지에서 받을 수 있어요").font(.caption).foregroundStyle(.secondary)
            }

            if manager.jobs.isEmpty {
                Text("받은 영상은 \(DownloadManager.folder.lastPathComponent) 폴더에 저장돼요 (4K까지 최고 화질, mp4 · 설정에서 바꿀 수 있어요)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(manager.jobs) { job in
                            DownloadRow(job: job)
                        }
                    }
                }
                .frame(maxHeight: 320)
                HStack {
                    Button("저장 폴더 열기") { NSWorkspace.shared.open(DownloadManager.folder) }
                    Spacer()
                    Button("끝난 항목 지우기") { manager.clearFinished() }
                        .disabled(manager.jobs.allSatisfy(\.isActive))
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

private struct DownloadRow: View {
    let job: DownloadManager.Job

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.title).font(.callout.weight(.medium)).lineLimit(2)
            switch job.state {
            case .running(let text):
                ProgressView(value: job.progress)
                HStack {
                    Text(text).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("취소") { DownloadManager.shared.cancel(job.id) }.buttonStyle(.link).font(.caption)
                }
            case .merging:
                ProgressView()
                    .progressViewStyle(.linear)
                Text("영상·소리 합치는 중…").font(.caption).foregroundStyle(.secondary)
            case .done(let url):
                HStack {
                    Label("완료", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    Spacer()
                    Button("Finder에서 보기") { DownloadManager.shared.reveal(url) }.buttonStyle(.link).font(.caption)
                    Button("열기") { NSWorkspace.shared.open(url) }.buttonStyle(.link).font(.caption)
                }
            case .failed(let message):
                Label("실패: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(4).textSelection(.enabled)
            case .cancelled:
                Text("취소됨").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
