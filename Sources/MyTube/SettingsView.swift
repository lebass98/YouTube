import AppKit
import SwiftUI

/// 설정 값 (화면이 바뀐 값을 바로 보여 주도록)
@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var downloadFolder = DownloadManager.folder

    var isDefaultFolder: Bool { downloadFolder.standardizedFileURL == DownloadManager.defaultFolder.standardizedFileURL }

    /// 폴더 고르기 창
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloadFolder
        panel.prompt = "이 폴더에 저장"
        panel.message = "다운로드한 영상을 저장할 폴더를 골라 주세요"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            Toast.shared.show("이 폴더에는 저장할 수 없어요 (쓰기 권한 없음)", error: true, seconds: 4)
            return
        }
        DownloadManager.setFolder(url)
        downloadFolder = DownloadManager.folder
        Toast.shared.show("저장 폴더를 \(url.lastPathComponent)(으)로 바꿨어요")
    }

    func resetFolder() {
        DownloadManager.setFolder(nil)
        downloadFolder = DownloadManager.folder
        Toast.shared.show("저장 폴더를 다운로드로 되돌렸어요")
    }
}

/// 버그 리포트: 설정에서 적어 두면 시각·앱 버전·최근 앱 기록과 함께 저장
/// ~/Library/Application Support/MyTube/bugreports.json (+ 읽기 쉬운 bugreports.md)
@MainActor
final class BugReportStore: ObservableObject {
    struct Report: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let text: String
        let appVersion: String
        let recentLog: String
    }

    @Published private(set) var reports: [Report] = []
    /// 쓰고 있는 글 (이 환경에서는 @State를 못 써서 여기 둠)
    @Published var draft = ""

    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MyTube", isDirectory: true)
    private var jsonURL: URL { folder.appendingPathComponent("bugreports.json") }
    var markdownURL: URL { folder.appendingPathComponent("bugreports.md") }

    init() {
        if let data = try? Data(contentsOf: jsonURL),
           let saved = try? JSONDecoder().decode([Report].self, from: data) {
            reports = saved
        }
    }

    func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        // 최근 앱 기록 40줄을 같이 남겨 원인 찾기에 씀
        let log = (try? String(contentsOf: DebugLog.url, encoding: .utf8)) ?? ""
        let recent = log.split(separator: "\n").suffix(40).joined(separator: "\n")
        reports.insert(Report(date: Date(), text: text, appVersion: version, recentLog: recent), at: 0)
        draft = ""
        save()
        DebugLog.write("버그 리포트 기록: \(text.prefix(60))")
        Toast.shared.show("버그 리포트를 기록했어요")
    }

    func delete(_ report: Report) {
        reports.removeAll { $0.id == report.id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(reports) { try? data.write(to: jsonURL, options: .atomic) }
        // 사람이 읽기 쉬운 글 파일 (최신이 위)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let md = "# MyTube 버그 리포트\n\n" + reports.map { r in
            "## \(formatter.string(from: r.date)) · 버전 \(r.appVersion)\n\n\(r.text)\n\n<details><summary>최근 앱 기록</summary>\n\n```\n\(r.recentLog)\n```\n</details>\n"
        }.joined(separator: "\n")
        try? md.write(to: markdownURL, atomically: true, encoding: .utf8)
    }
}

/// 왼쪽 메뉴 "설정" 화면
/// 재생·광고 건너뛰기 설정 (UserDefaults를 화면에 바로 반영)
@MainActor
final class PlaybackSettings: ObservableObject {
    @Published var pauseOnUnplug = UserDefaults.standard.object(forKey: "pauseOnUnplug") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pauseOnUnplug, forKey: "pauseOnUnplug") }
    }
    @Published var sponsorOn = SponsorBlock.isOn {
        didSet { SponsorBlock.isOn = sponsorOn }
    }
    @Published private(set) var version = 0

    func binding(_ category: String) -> Binding<Bool> {
        Binding(get: { SponsorBlock.isEnabled(category) },
                set: { SponsorBlock.setEnabled(category, $0); self.version += 1 })
    }
}

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @StateObject private var model = SettingsModel()
    @StateObject private var bugs = BugReportStore()
    @StateObject private var playback = PlaybackSettings()
    @ObservedObject private var listen = ListenMode.shared
    @ObservedObject private var queue = PlayQueue.shared
    @ObservedObject private var filter = ContentFilter.shared
    @ObservedObject private var watcher = NewVideoWatcher.shared
    @ObservedObject private var auto = AutoDownloader.shared
    @ObservedObject private var stats = WatchStats.shared
    @ObservedObject private var gemini = GeminiAccount.shared
    @ObservedObject private var themes = ThemeStore.shared
    @ObservedObject private var account = YouTubeAccount.shared

    /// 위쪽 목차 (누르면 그 구역으로)
    private static let toc: [(title: String, icon: String)] = [
        ("유튜브 계정", "person.crop.circle"), ("업데이트", "arrow.down.app"), ("색상 테마", "paintpalette"), ("AI (재미나이)", "sparkles"), ("시청 통계", "chart.bar"),
        ("듣기·재생", "headphones"), ("광고·인트로 건너뛰기", "forward.frame"), ("목록 정리", "line.3.horizontal.decrease.circle"),
        ("알림", "bell"), ("자동 받기·정리", "tray.and.arrow.down"), ("영상 다운로드", "arrow.down.circle"), ("버그 리포트", "ladybug"),
    ]

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("설정")
                    .font(.system(size: 26, weight: .bold))

                section(title: "유튜브 계정", icon: "person.crop.circle") {
                    AccountRow().padding(.horizontal, -14)
                    HStack(spacing: 10) {
                        if account.isLoggedIn {
                            Button("다른 계정으로 로그인…") { account.signIn() }
                            Button("로그아웃…") { account.signOut() }
                        } else {
                            Button("유튜브 로그인") { account.signIn() }.buttonStyle(.borderedProminent)
                        }
                        Button("상태 다시 확인") { account.check() }
                    }
                    let missing = ToolCheck.missing
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: missing.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(missing.isEmpty ? Color.green : Color.orange)
                        Text(missing.isEmpty ? "필요한 도구(yt-dlp·deno·ffmpeg)가 모두 있어요" : "없는 도구: " + missing.joined(separator: ", "))
                            .font(.callout)
                    }
                    if !missing.isEmpty {
                        HStack {
                            Text(ToolCheck.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button("복사") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ToolCheck.command, forType: .string)
                                Toast.shared.show("복사했어요. 터미널에 붙여 넣어 실행해 주세요")
                            }
                        }
                    }
                }

                section(title: "업데이트", icon: "arrow.down.app") {
                    UpdateSettingsView()
                }

                section(title: "색상 테마", icon: "paintpalette") {
                    themePicker
                }

                section(title: "AI (재미나이)", icon: "sparkles") {
                    geminiView
                }

                section(title: "시청 통계", icon: "chart.bar") {
                    statsView
                }

                section(title: "듣기·재생", icon: "headphones") {
                    Toggle("듣기 모드: 영상을 누르면 소리만 재생 (⌘⇧L)", isOn: $listen.isOn)
                    Toggle("영상이 끝나면 대기열의 다음 영상 이어서 재생", isOn: $queue.autoAdvance)
                    Toggle("이어폰(AirPods 등)을 빼면 재생 멈추기", isOn: $playback.pauseOnUnplug)
                    Text("재생 속도는 재생 창·듣기 창의 \"1배\" 단추나 ⇧. ⇧, 로 바꾸고, 채널마다 기억해요. 키보드 ⏯ ⏭ 키와 제어 센터에서도 조작할 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section(title: "광고·인트로 건너뛰기", icon: "forward.frame") {
                    Toggle("건너뛰기 켜기 (SponsorBlock: 사람들이 함께 표시한 구간)", isOn: $playback.sponsorOn)
                    if playback.sponsorOn {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(SponsorBlock.categories, id: \.id) { category in
                                Toggle(category.label, isOn: playback.binding(category.id))
                            }
                        }
                        .padding(.leading, 18)
                        .id(playback.version)
                    }
                    Text("영상 코드는 그대로 보내지 않고 일부(해시 앞 4글자)만 보내서, 어떤 영상을 보는지 서버가 알 수 없어요.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section(title: "목록 정리", icon: "line.3.horizontal.decrease.circle") {
                    Toggle("쇼츠 숨기기", isOn: $filter.hideShorts)
                    Toggle("본 영상 숨기기", isOn: $filter.hideWatched)
                    Text("숨긴 채널 (영상 카드 오른쪽 클릭 → 채널 숨기기)").font(.system(size: 13, weight: .semibold))
                    if filter.blockedChannels.isEmpty {
                        Text("없음").font(.caption).foregroundStyle(.secondary)
                    } else {
                        chips(filter.blockedChannels) { filter.unblock(channel: $0) }
                    }
                    Text("숨길 낱말 (제목에 들어 있으면 숨김)").font(.system(size: 13, weight: .semibold))
                    HStack {
                        TextField("예: 광고, 리액션", text: $filter.keywordDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { filter.addKeyword() }
                        Button("추가") { filter.addKeyword() }
                            .disabled(filter.keywordDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !filter.keywords.isEmpty {
                        chips(filter.keywords) { filter.removeKeyword($0) }
                    }
                    Text("직접 연 채널 화면에는 적용하지 않아요.").font(.caption).foregroundStyle(.secondary)
                }

                section(title: "알림", icon: "bell") {
                    Toggle("구독 채널에 새 영상이 올라오면 알림 (15분마다 확인)", isOn: $watcher.isOn)
                    Text("알림을 누르면 바로 재생해요. 처음 한 번 맥에서 알림 허용을 물어봐요.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section(title: "자동 받기·정리", icon: "tray.and.arrow.down") {
                    Toggle("\"나중에 볼 동영상\" 최근 10개를 자동으로 받아 두기 (1시간마다 확인)", isOn: $auto.isOn)
                    Picker("받는 방식", selection: $auto.kind) {
                        ForEach(AutoDownloader.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!auto.isOn)
                    .frame(maxWidth: 320)
                    Toggle(isOn: $auto.cleanupOn) {
                        HStack(spacing: 6) {
                            Text("자동으로 받은 파일은")
                            Picker("", selection: $auto.cleanupDays) {
                                ForEach([3, 7, 14, 30], id: \.self) { Text("\($0)일").tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Text("지나면 휴지통으로")
                        }
                    }
                    Text("직접 받은 파일은 건드리지 않아요. 자동으로 받은 파일 \(auto.downloadedCount)개 · 저장 폴더는 아래 \"영상 다운로드\"와 같아요.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section(title: "영상 다운로드", icon: "arrow.down.circle") {
                    Text("저장 폴더").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: model.downloadFolder.path))
                            .resizable()
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.downloadFolder.lastPathComponent)
                                .font(.system(size: 14, weight: .semibold))
                            Text(model.downloadFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack(spacing: 10) {
                        Button("폴더 바꾸기…") { model.chooseFolder() }
                            .buttonStyle(.borderedProminent)
                        Button("Finder에서 열기") { NSWorkspace.shared.open(model.downloadFolder) }
                        if !model.isDefaultFolder {
                            Button("기본(다운로드)으로 되돌리기") { model.resetFolder() }
                        }
                    }
                    Text("새로 받는 영상부터 이 폴더에 저장돼요. 이미 받는 중인 영상은 원래 폴더에 저장돼요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section(title: "버그 리포트", icon: "ladybug") {
                    Text("문제가 생기면 무슨 일이 있었는지 적어 주세요. 시각·앱 버전·최근 앱 기록이 같이 저장돼요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $bugs.draft)
                        .font(.system(size: 13))
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack(spacing: 10) {
                        Button("기록하기") { bugs.submit() }
                            .buttonStyle(.borderedProminent)
                            .disabled(bugs.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("기록 파일 Finder에서 보기") {
                            NSWorkspace.shared.activateFileViewerSelecting([bugs.markdownURL])
                        }
                        .disabled(bugs.reports.isEmpty)
                        Button("앱 기록(로그) 열기") { NSWorkspace.shared.open(DebugLog.url) }
                    }

                    if !bugs.reports.isEmpty {
                        Divider()
                        Text("기록한 리포트 \(bugs.reports.count)개").font(.system(size: 12, weight: .semibold))
                        ForEach(bugs.reports) { report in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(report.date.formatted(date: .abbreviated, time: .shortened) + " · 버전 \(report.appVersion)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(report.text)
                                        .font(.system(size: 13))
                                        .lineLimit(4)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button {
                                    bugs.delete(report)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("이 리포트 지우기")
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 목차: 위쪽에 늘 떠 있는 작은 단추들
        .safeAreaInset(edge: .top, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.toc, id: \.title) { entry in
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(entry.title, anchor: .top) }
                        } label: {
                            Label(entry.title, systemImage: entry.icon)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
        }
    }

    /// 테마 고르기: 색 견본 카드 7개 (단색 5 + 그라데이션 2)
    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                ForEach(AppTheme.allCases) { item in
                    let selected = themes.current == item
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { themes.current = item }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(item.style)
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                                    .shadow(color: item.accent.opacity(0.35), radius: 4, y: 1)
                                if item.isGradient {
                                    Text("그라데이션")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(item.style, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                                Spacer()
                                if selected {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(item.style)
                                }
                            }
                            // 미리 보기: 고른 단추처럼
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(item.style)
                                .frame(height: 6)
                            Text(item.name).font(.system(size: 12, weight: .semibold))
                            Text(item.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selected ? item.accent.opacity(0.10) : Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(selected ? item.style : AnyShapeStyle(Color.primary.opacity(0.08)), lineWidth: selected ? 1.5 : 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("고른 단추·제목·재생 단추·화질 표시 같은 강조색이 바뀌어요. 열려 있는 재생 창·듣기 창에도 바로 적용돼요.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("화면 모드").font(.system(size: 13, weight: .semibold))
                Picker("화면 모드", selection: $themes.appearance) {
                    ForEach(ThemeStore.Appearance.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.top, 4)
        }
    }

    /// 재미나이 로그인 상태 + 로그인 단추
    private var geminiView: some View {
        let (color, icon, title, detail) = geminiStatusText
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(color)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                    }
                }
                Spacer()
                if gemini.status == .checking { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 10) {
                switch gemini.status {
                case .signedIn:
                    Button("다른 계정으로 바꾸기…") { gemini.switchAccount() }
                    Button("로그아웃…") { gemini.signOut() }
                case .notInstalled:
                    Button("안티그래비티 받는 곳 열기") { NSWorkspace.shared.open(URL(string: "https://antigravity.google")!) }
                        .buttonStyle(.borderedProminent)
                default:
                    Button("재미나이 로그인하기…") { gemini.signIn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(gemini.status == .checking)
                }
                Button("상태 다시 확인") { gemini.check() }
                    .disabled(gemini.status == .checking)
            }
            if let previous = gemini.backupEmail, !gemini.isSignedIn || {
                if case .signedIn(let now) = gemini.status { return now != previous } else { return true }
            }() {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                    Text("이전 계정 \(previous)").font(.caption).foregroundStyle(.secondary)
                    Button("이전 계정으로 되돌리기") { gemini.restoreBackup() }
                        .controlSize(.small)
                }
            }
            Label("유튜브 계정과는 따로 로그인해요. 유튜브와 다른 구글 계정(재미나이 구독 계정)을 써도 돼요.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
            Text("AI 검색(위쪽 검색의 AI)과 AI 요약(✨)에 써요. 로그인하기를 누르면 터미널이 열리고 브라우저에서 재미나이 구독 계정(구글)으로 로그인해요. 끝나고 MyTube로 돌아오면 저절로 다시 확인해요.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if gemini.status == .unknown { gemini.check() } }
    }

    private var geminiStatusText: (Color, String, String, String) {
        let when = gemini.checkedAt.map { " · \($0.formatted(date: .omitted, time: .shortened)) 확인" } ?? ""
        switch gemini.status {
        case .unknown, .checking:
            return (.secondary, "hourglass", "로그인 상태 확인 중…", "")
        case .signedIn(let email):
            return (.green, "checkmark.circle.fill", "로그인됨", (email ?? "계정 확인됨") + when)
        case .signedOut:
            return (.orange, "person.crop.circle.badge.exclamationmark", "로그인 필요", "AI 검색·AI 요약을 쓰려면 로그인해 주세요" + when)
        case .notInstalled:
            return (.red, "xmark.octagon.fill", "안티그래비티 CLI(agy)가 없어요", "안티그래비티 앱에서 CLI를 설치해 주세요 (~/.local/bin/agy)")
        case .failed(let message):
            return (.red, "exclamationmark.triangle.fill", "확인하지 못했어요", message)
        }
    }

    /// 시청 통계: 오늘·이번 주 + 7일 막대 + 많이 본 채널
    private var statsView: some View {
        let week = stats.lastWeek
        let maxSeconds = max(week.map(\.seconds).max() ?? 1, 60)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("오늘").font(.caption).foregroundStyle(.secondary)
                    Text(WatchStats.text(stats.total(on: Date()))).font(.system(size: 20, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("최근 7일").font(.caption).foregroundStyle(.secondary)
                    Text(WatchStats.text(week.map(\.seconds).reduce(0, +))).font(.system(size: 20, weight: .bold))
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(day.label == "오늘" ? theme.style : AnyShapeStyle(theme.accent.opacity(0.45)))
                            .frame(width: 28, height: max(3, 80 * day.seconds / maxSeconds))
                        Text(day.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    .help(WatchStats.text(day.seconds))
                }
            }
            .frame(height: 100, alignment: .bottom)
            if !stats.topChannels.isEmpty {
                Text("최근 7일 많이 본 채널").font(.system(size: 13, weight: .semibold))
                ForEach(stats.topChannels, id: \.name) { item in
                    HStack {
                        Text(item.name).lineLimit(1)
                        Spacer()
                        Text(WatchStats.text(item.seconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// 지울 수 있는 작은 이름표들
    private func chips(_ items: [String], remove: @escaping (String) -> Void) -> some View {
        FlowRow(items: items) { item in
            HStack(spacing: 4) {
                Text(item).lineLimit(1)
                Button { remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
    }

    /// 설정 묶음 (제목 + 둥근 판)
    private func section(title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.style)
                .id(title)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// 줄이 넘치면 다음 줄로 넘어가는 가로 배치
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
