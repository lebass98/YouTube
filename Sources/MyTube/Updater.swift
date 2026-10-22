import AppKit
import SwiftUI

/// 업데이트: GitHub 릴리즈(lebass98/YouTube)의 최신 버전을 확인하고, 새 버전이면 설치 파일을 받아 설치 프로그램으로 엶
/// (설치가 끝나면 설치 파일의 postinstall이 앱을 다시 켬)
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "lebass98/YouTube"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }

    struct Release: Equatable {
        let version: String
        let notes: String
        let pkgURL: URL?
        let page: URL
        let published: Date?
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release)
        case downloading(Double), failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var lastChecked: Date?
    @Published var autoCheck = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck") }
    }
    private var started = false
    private var download: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 앱을 켜고 10초 뒤, 그다음 6시간마다 (자동 확인이 켜져 있을 때)
    func start() {
        guard !started else { return }
        started = true
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            while true {
                if autoCheck { await check(userInitiated: false) }
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    /// userInitiated: 메뉴·설정에서 직접 누른 경우 (최신이어도 알려 주고, "이 버전 건너뛰기"도 무시)
    func check(userInitiated: Bool) async {
        if case .downloading = state { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            lastChecked = Date()
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 {   // 아직 릴리즈가 하나도 없음
                state = .upToDate
                if userInitiated { Toast.shared.show("지금 버전(\(Self.currentVersion))이 최신이에요") }
                return
            }
            guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "MyTube", code: code, userInfo: [NSLocalizedDescriptionKey: "GitHub 응답 \(code)"])
            }
            let tag = (json["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let assets = json["assets"] as? [[String: Any]] ?? []
            let pkg = assets.first { ($0["name"] as? String ?? "").hasSuffix(".pkg") }
            let release = Release(version: tag,
                                  notes: json["body"] as? String ?? "",
                                  pkgURL: (pkg?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                                  page: (json["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesPage,
                                  published: (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
            guard Self.isNewer(tag, than: Self.currentVersion) else {
                state = .upToDate
                if userInitiated { Toast.shared.show("지금 버전(\(Self.currentVersion))이 최신이에요") }
                DebugLog.write("업데이트 확인: 최신 (\(Self.currentVersion), 릴리즈 \(tag))")
                return
            }
            state = .available(release)
            DebugLog.write("업데이트 확인: 새 버전 \(tag) (지금 \(Self.currentVersion))")
            let skipped = UserDefaults.standard.string(forKey: "skippedUpdateVersion")
            if userInitiated || skipped != tag { askToInstall(release) }
        } catch {
            state = .failed(error.localizedDescription)
            DebugLog.write("업데이트 확인 실패: \(error.localizedDescription)")
            if userInitiated { Toast.shared.show("업데이트를 확인하지 못했어요: \(error.localizedDescription)", error: true, seconds: 4) }
        }
    }

    /// "1.10" > "1.9" 처럼 숫자로 비교
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// 새 버전 알림: 업데이트 / 나중에 / 이 버전 건너뛰기
    func askToInstall(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "MyTube \(release.version) 업데이트가 있어요"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "지금 버전: \(Self.currentVersion)\n\n"
            + (notes.isEmpty ? "" : String(notes.prefix(600)) + (notes.count > 600 ? "…" : "") + "\n\n")
            + "업데이트를 누르면 설치 파일을 받아 설치 프로그램을 열어요. 설치가 끝나면 앱이 다시 켜져요."
        alert.addButton(withTitle: "업데이트")
        alert.addButton(withTitle: "나중에")
        alert.addButton(withTitle: "이 버전 건너뛰기")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.version, forKey: "skippedUpdateVersion")
        default: break
        }
    }

    /// 설치 파일 받기 → 설치 프로그램으로 열기 (설치 파일이 없는 릴리즈면 릴리즈 페이지를 엶)
    func install(_ release: Release) {
        guard let url = release.pkgURL else {
            NSWorkspace.shared.open(release.page)
            return
        }
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            let result: Result<URL, Error>
            if let tempURL {
                // 다운로드 폴더에 MyTube-<버전>.pkg로 옮김
                let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    result = .success(dest)
                } catch { result = .failure(error) }
            } else {
                result = .failure(error ?? URLError(.unknown))
            }
            Task { @MainActor in self?.finished(result, release: release) }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading = self?.state { self?.state = .downloading(value) }
            }
        }
        download = task
        task.resume()
        DebugLog.write("업데이트 받기 시작: \(url.absoluteString)")
        Toast.shared.show("MyTube \(release.version) 받는 중…", seconds: 3)
    }

    private func finished(_ result: Result<URL, Error>, release: Release) {
        progressObservation = nil
        download = nil
        switch result {
        case .success(let file):
            state = .available(release)
            DebugLog.write("업데이트 받음: \(file.path) → 설치 프로그램 열기")
            NSWorkspace.shared.open(file)   // macOS 설치 프로그램이 열림 (관리자 암호는 사용자가 입력)
            Toast.shared.show("설치 프로그램을 열었어요. 안내대로 설치하면 앱이 다시 켜져요", seconds: 6)
        case .failure(let error):
            state = .failed(error.localizedDescription)
            DebugLog.write("업데이트 받기 실패: \(error.localizedDescription)")
            Toast.shared.show("업데이트를 받지 못했어요: \(error.localizedDescription)", error: true, seconds: 5)
        }
    }
}

/// 설정 화면의 "업데이트" 묶음
struct UpdateSettingsView: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("지금 버전 \(Updater.currentVersion)").font(.system(size: 14, weight: .semibold))
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if case .checking = updater.state { ProgressView().controlSize(.small) }
                if case .downloading(let p) = updater.state {
                    ProgressView(value: p).frame(width: 120)
                }
            }
            HStack(spacing: 10) {
                if case .available(let release) = updater.state {
                    Button("\(release.version)로 업데이트") { updater.install(release) }
                        .buttonStyle(.borderedProminent)
                }
                Button("지금 확인") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.state == .checking)
                Button("릴리즈 페이지 열기") { NSWorkspace.shared.open(Updater.releasesPage) }
            }
            Toggle("앱을 켤 때·6시간마다 새 버전 자동 확인", isOn: $updater.autoCheck)
            Text("새 버전은 GitHub(\(Updater.repo)) 릴리즈에서 확인해요. 업데이트를 누르면 설치 파일을 다운로드 폴더에 받아 설치 프로그램을 열어요.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        let when = updater.lastChecked.map { " · \($0.formatted(date: .omitted, time: .shortened)) 확인" } ?? ""
        switch updater.state {
        case .idle: return "아직 확인하지 않았어요"
        case .checking: return "확인 중…"
        case .upToDate: return "최신 버전이에요" + when
        case .available(let r): return "새 버전 \(r.version)이 있어요" + when
        case .downloading(let p): return "받는 중… \(Int(p * 100))%"
        case .failed(let m): return "확인 실패: \(m)"
        }
    }
}
