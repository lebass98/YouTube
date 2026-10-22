import AppKit

/// 재미나이로 "말로 한 요청 → 유튜브 검색어 + 필터" 바꾸기
/// 안티그래비티 CLI(agy)를 씀: 재미나이 구독 계정으로 로그인돼 있고, 답을 정해진 JSON 모양으로 받을 수 있음
/// (재미나이 CLI(gemini)는 이 계정 종류에서 더 이상 지원되지 않아 "안티그래비티로 옮기라"는 오류가 남)
enum GeminiCLI {
    /// 재미나이가 정해 주는 검색 계획
    struct Plan: Decodable {
        let query: String
        let uploadDate: String?
        let sort: String?
        let kind: String?
        let feature: String?
        let note: String?
    }

    enum Failure: LocalizedError {
        case notInstalled
        case notLoggedIn
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "안티그래비티 CLI(agy)가 없어요. 안티그래비티 앱에서 CLI를 설치해 주세요 (~/.local/bin/agy)."
            case .notLoggedIn:
                return "안티그래비티 CLI에 로그인이 필요해요. 터미널에서 agy 를 한 번 실행해 재미나이 구독 계정으로 로그인해 주세요."
            case .failed(let message):
                return "재미나이가 답하지 못했어요.\n\(message)"
            }
        }
    }

    private static let searchPaths = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static var executable: URL? {
        searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent("agy") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 답의 모양: 이 값들만 고를 수 있게 강제 (엉뚱한 값이 나오지 않게)
    private static let schema = """
    {"type":"object","properties":{"query":{"type":"string"},\
    "uploadDate":{"type":"string","enum":["all","today","week","month","year"]},\
    "sort":{"type":"string","enum":["relevance","popularity"]},\
    "kind":{"type":"string","enum":["all","video","channel","playlist","movie"]},\
    "feature":{"type":"string","enum":["all","hd720","fhd1080","qhd1440","uhd4k","vr","live"]},\
    "note":{"type":"string"}},"required":["query","uploadDate","sort","kind","feature","note"]}
    """

    /// agy --output-format json 의 겉 모양 (structured_output에 위 모양의 답이 들어 있음)
    private struct Envelope: Decodable {
        let status: String?
        let structuredOutput: Plan?
        enum CodingKeys: String, CodingKey {
            case status
            case structuredOutput = "structured_output"
        }
    }

    private static func prompt(for request: String) -> String {
        """
        너는 유튜브 영상 검색 도우미야. 아래 [요청]을 유튜브에서 찾기 좋은 검색어 하나와 검색 필터로 바꿔.
        note는 어떻게 찾았는지 한국어 한 줄. 파일이나 도구는 쓰지 말고 바로 답해.
        규칙: 요청에 기간·인기·화질(4K 등)·라이브 방송·채널·재생목록 같은 말이 없으면 all/relevance로 둬.
        "라이브"가 공연 실황을 뜻하면 feature는 all로 두고 검색어에 넣어. 실시간 방송을 찾을 때만 live.
        검색어는 요청의 언어를 따르되, 영어로 찾는 게 훨씬 나은 주제면 영어로 해도 돼.
        [요청] \(request)
        """
    }

    static func plan(for request: String) async throws -> Plan {
        guard let exe = executable else { throw Failure.notInstalled }

        // CLI는 실행한 폴더의 파일을 읽을 수 있어서, 빈 폴더에서 실행
        let workDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTube/gemini", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 생각 수준을 낮춰야 빠름 (보통 수준이면 40초, 낮음이면 8초 안팎)
        let args = ["-p", prompt(for: request), "--output-format", "json", "--json-schema", schema,
                    "--effort", "low", "--print-timeout", "60s"]
        let result = try await run(exe, args, in: workDir)
        DebugLog.write("재미나이(agy) 종료 코드 \(result.status) \(result.stderr.prefix(200))")

        let all = result.stdout + "\n" + result.stderr
        if result.status != 0, all.localizedCaseInsensitiveContains("login") || all.localizedCaseInsensitiveContains("auth") {
            throw Failure.notLoggedIn
        }
        // 겉 JSON에서 structured_output만 꺼냄 (앞뒤에 다른 줄이 붙어도 되게 { ... } 부분만)
        guard let start = result.stdout.firstIndex(of: "{"), let end = result.stdout.lastIndex(of: "}"),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(result.stdout[start...end].utf8)),
              let plan = envelope.structuredOutput,
              !plan.query.trimmingCharacters(in: .whitespaces).isEmpty else {
            let message = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(String(message.suffix(400)))
        }
        DebugLog.write("재미나이 검색 계획: \(plan.query) / \(plan.uploadDate ?? "-") \(plan.sort ?? "-") \(plan.kind ?? "-") \(plan.feature ?? "-")")
        return plan
    }

    /// 아무 질문 + 답 모양(JSON 스키마) → 답 JSON (structured_output 부분)
    static func ask(_ prompt: String, schema: String, timeout: Int = 90) async throws -> Data {
        guard let exe = executable else { throw Failure.notInstalled }
        let workDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTube/gemini", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let args = ["-p", prompt, "--output-format", "json", "--json-schema", schema,
                    "--effort", "low", "--print-timeout", "\(timeout)s"]
        let result = try await run(exe, args, in: workDir)
        DebugLog.write("재미나이(agy) 질문 종료 코드 \(result.status)")
        let all = result.stdout + "\n" + result.stderr
        if result.status != 0, all.localizedCaseInsensitiveContains("login") || all.localizedCaseInsensitiveContains("auth") {
            throw Failure.notLoggedIn
        }
        guard let start = result.stdout.firstIndex(of: "{"), let end = result.stdout.lastIndex(of: "}"),
              let envelope = try? JSONSerialization.jsonObject(with: Data(result.stdout[start...end].utf8)) as? [String: Any],
              let answer = envelope["structured_output"],
              let data = try? JSONSerialization.data(withJSONObject: answer) else {
            let message = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(String(message.suffix(400)))
        }
        return data
    }

    private final class Output: @unchecked Sendable {
        var stderr = Data()
    }

    private static func run(_ exe: URL, _ args: [String], in dir: URL) async throws -> (status: Int32, stdout: String, stderr: String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = exe
                process.arguments = args
                process.currentDirectoryURL = dir
                // CLI가 다른 도구를 찾을 수 있게 기본 경로를 넣어 줌
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (searchPaths + ["/bin"]).joined(separator: ":")
                process.environment = env
                process.standardInput = FileHandle.nullDevice

                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    cont.resume(throwing: error)
                    return
                }
                // 70초가 넘으면 멈춤
                DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                    if process.isRunning { process.terminate() }
                }
                let box = Output()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    box.stderr = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                cont.resume(returning: (process.terminationStatus,
                                        String(decoding: stdout, as: UTF8.self),
                                        String(decoding: box.stderr, as: UTF8.self)))
            }
        }
    }
}

/// 재미나이(안티그래비티 CLI) 로그인 상태: 설정 화면에서 보여 주고 로그인 창을 엶
@MainActor
final class GeminiAccount: ObservableObject {
    static let shared = GeminiAccount()

    enum Status: Equatable {
        case unknown, checking, notInstalled, signedOut
        case signedIn(String?)   // 계정 이메일 (모르면 nil)
        case failed(String)
    }

    @Published private(set) var status = Status.unknown
    @Published private(set) var checkedAt: Date?
    /// 로그인 창을 열어 둔 뒤 앱으로 돌아오면 다시 확인
    private var waitingForSignIn = false
    private var activeObserver: NSObjectProtocol?

    private init() {
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let account = GeminiAccount.shared
                if account.waitingForSignIn { account.check() }
            }
        }
    }

    var isSignedIn: Bool { if case .signedIn = status { true } else { false } }

    /// "agy models"로 확인: 로그인돼 있으면 모델 목록, 아니면 "Please sign in"
    func check() {
        guard status != .checking else { return }
        guard let exe = GeminiCLI.executable else {
            status = .notInstalled
            return
        }
        status = .checking
        Task {
            let output = await Self.run(exe, ["models"])
            checkedAt = Date()
            let lower = output.lowercased()
            if lower.contains("sign in") || lower.contains("log in") || lower.contains("login") {
                status = .signedOut
            } else if output.contains("\t") || lower.contains("gemini") {
                status = .signedIn(Self.activeEmail())
                waitingForSignIn = false
            } else {
                status = .failed(String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)))
            }
            DebugLog.write("재미나이 로그인 확인: \(status)")
        }
    }

    /// 터미널에서 agy를 열어 로그인 (브라우저로 구글 계정 로그인 → 끝나면 창 닫기)
    func signIn() {
        objectWillChange.send()
        guard let exe = GeminiCLI.executable else {
            status = .notInstalled
            return
        }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("재미나이 로그인.command")
        let text = """
        #!/bin/zsh
        clear
        echo "MyTube — 재미나이(안티그래비티) 로그인"
        echo ""
        echo "1. 브라우저가 열리면 재미나이 구독 계정(구글)으로 로그인해 주세요."
        echo "2. 로그인이 끝나 입력 칸이 보이면 /exit 를 입력하거나 이 창을 닫으면 돼요."
        echo "3. MyTube로 돌아가면 로그인 상태를 저절로 다시 확인해요."
        echo ""
        cd "\(folder.appendingPathComponent("gemini").path)" 2>/dev/null || cd ~
        "\(exe.path)"
        """
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            waitingForSignIn = true
            NSWorkspace.shared.open(script)
            DebugLog.write("재미나이 로그인 창 열기")
        } catch {
            status = .failed("로그인 창을 열지 못했어요: \(error.localizedDescription)")
        }
    }

    // MARK: 계정 바꾸기·로그아웃 (유튜브 로그인과는 따로)

    /// agy 로그인 정보 파일 (지우지 않고 백업 폴더로 옮겨서 되돌릴 수 있게)
    private static let geminiFolder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini")
    private static let authFiles = ["oauth_creds.json", "google_accounts.json"]
    private static let backupFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyTube/gemini-account-backup", isDirectory: true)

    /// 되돌릴 수 있는 이전 계정 (백업이 있으면 그 이메일)
    var backupEmail: String? {
        guard let data = try? Data(contentsOf: Self.backupFolder.appendingPathComponent("google_accounts.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["active"] as? String
    }

    /// 지금 계정 로그인 정보를 백업으로 옮김 (agy가 다음 실행 때 로그인을 다시 물어봄)
    @discardableResult
    private func moveCurrentToBackup() -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.backupFolder)
        do {
            try fm.createDirectory(at: Self.backupFolder, withIntermediateDirectories: true)
            for name in Self.authFiles {
                let from = Self.geminiFolder.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                try fm.moveItem(at: from, to: Self.backupFolder.appendingPathComponent(name))
            }
            return true
        } catch {
            status = .failed("로그인 정보를 옮기지 못했어요: \(error.localizedDescription)")
            return false
        }
    }

    /// 다른 재미나이 계정으로: 지금 계정은 백업해 두고 로그인 창(터미널)을 엶
    func switchAccount() {
        let alert = NSAlert()
        alert.messageText = "재미나이를 다른 구글 계정으로 바꿀까요?"
        alert.informativeText = "지금 계정\(Self.activeEmail().map { "(\($0))" } ?? "")의 로그인 정보는 백업해 두고, 터미널에서 새 계정으로 로그인해요. 유튜브 로그인에는 영향이 없어요. 마음이 바뀌면 설정에서 이전 계정으로 되돌릴 수 있어요."
        alert.addButton(withTitle: "바꾸기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn, moveCurrentToBackup() else { return }
        DebugLog.write("재미나이 계정 바꾸기: 지금 계정 백업 후 로그인 창")
        status = .signedOut
        signIn()
    }

    /// 재미나이 로그아웃 (로그인 정보는 백업으로 옮겨 둠)
    func signOut() {
        let alert = NSAlert()
        alert.messageText = "재미나이에서 로그아웃할까요?"
        alert.informativeText = "AI 검색·AI 요약·질문하기를 쓰려면 다시 로그인해야 해요. 유튜브 로그인에는 영향이 없어요."
        alert.addButton(withTitle: "로그아웃")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn, moveCurrentToBackup() else { return }
        DebugLog.write("재미나이 로그아웃 (로그인 정보 백업)")
        check()
    }

    /// 백업해 둔 이전 계정으로 되돌리기 (지금 로그인한 계정은 지워짐)
    func restoreBackup() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.backupFolder.path) else { return }
        for name in Self.authFiles {
            let from = Self.backupFolder.appendingPathComponent(name)
            let to = Self.geminiFolder.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.removeItem(at: to)
            try? fm.moveItem(at: from, to: to)
        }
        try? fm.removeItem(at: Self.backupFolder)
        DebugLog.write("재미나이 이전 계정으로 되돌림")
        Toast.shared.show("재미나이를 이전 계정으로 되돌렸어요")
        check()
    }

    /// 지금 로그인한 구글 계정 (~/.gemini/google_accounts.json 의 active)
    private static func activeEmail() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/google_accounts.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = json["active"] as? String, !active.isEmpty else { return nil }
        return active
    }

    private static func run(_ exe: URL, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = exe
                process.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
                process.environment = env
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch {
                    cont.resume(returning: error.localizedDescription)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 25) { if process.isRunning { process.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
