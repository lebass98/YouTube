import AppKit
import SwiftUI
import UserNotifications
import WebKit

private let supportFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MyTube", isDirectory: true)

private func loadJSON<T: Decodable>(_ name: String, as type: T.Type) -> T? {
    guard let data = try? Data(contentsOf: supportFolder.appendingPathComponent(name)) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

private func saveJSON<T: Encodable>(_ value: T, _ name: String) {
    try? FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(value) { try? data.write(to: supportFolder.appendingPathComponent(name), options: .atomic) }
}

// MARK: - 본 영상·이어 보기 표시

/// 목록 카드에 "봤음"·"이어 보기 진행 막대"를 보여 주기 위한 기록
@MainActor
final class WatchMarks: ObservableObject {
    static let shared = WatchMarks()
    @Published private(set) var watched: Set<String> = Set(loadJSON("watched.json", as: [String].self) ?? [])
    /// 이어 보기 위치가 바뀌었을 때 카드를 다시 그리게 (재생 창을 닫을 때 한 번)
    @Published private(set) var version = 0

    func markWatched(_ id: String) {
        guard !watched.contains(id) else { return }
        watched.insert(id)
        if watched.count > 5000 { watched.removeFirst() }
        saveJSON(Array(watched), "watched.json")
    }

    func unmark(_ id: String) {
        guard watched.remove(id) != nil else { return }
        saveJSON(Array(watched), "watched.json")
    }

    func refresh() { version += 1 }

    /// 0~1 (이어 볼 위치가 있을 때만)
    func progress(_ id: String) -> Double? { PlaybackMemory.progress(for: id) }
}

// MARK: - 목록 정리 (쇼츠·채널·키워드 숨기기)

@MainActor
final class ContentFilter: ObservableObject {
    static let shared = ContentFilter()

    /// 쇼츠 숨기기 (기본: 켜짐)
    @Published var hideShorts = UserDefaults.standard.object(forKey: "hideShorts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideShorts, forKey: "hideShorts") }
    }
    /// 본 영상 숨기기
    @Published var hideWatched = UserDefaults.standard.bool(forKey: "hideWatched") {
        didSet { UserDefaults.standard.set(hideWatched, forKey: "hideWatched") }
    }
    @Published private(set) var blockedChannels: [String] = UserDefaults.standard.stringArray(forKey: "blockedChannels") ?? []
    @Published private(set) var keywords: [String] = UserDefaults.standard.stringArray(forKey: "blockedKeywords") ?? []
    @Published var keywordDraft = ""

    func allows(_ video: FeedVideo) -> Bool {
        if hideShorts, Self.looksLikeShorts(video) { return false }
        if hideWatched, WatchMarks.shared.watched.contains(video.id) { return false }
        if !blockedChannels.isEmpty, blockedChannels.contains(video.channelName) { return false }
        if !keywords.isEmpty {
            let title = video.displayTitle.lowercased()
            if keywords.contains(where: { title.contains($0.lowercased()) }) { return false }
        }
        return true
    }

    /// 쇼츠 알아보기: 쇼츠 주소이거나, 60초 이하이거나, 세로 영상 (목록에서는 쇼츠도 일반 영상 주소로 와서 길이·모양으로 봄)
    static func looksLikeShorts(_ video: FeedVideo) -> Bool {
        if video.isShorts { return true }
        if let duration = video.duration, duration > 0, duration <= 60 { return true }
        return QualityStore.shared.known[video.id]?.isVertical == true
    }

    func block(channel: String) {
        guard !channel.isEmpty, !blockedChannels.contains(channel) else { return }
        blockedChannels.append(channel)
        UserDefaults.standard.set(blockedChannels, forKey: "blockedChannels")
        Toast.shared.show("\(channel) 채널을 목록에서 숨겼어요 (설정에서 되돌릴 수 있어요)", seconds: 4)
    }

    func unblock(channel: String) {
        blockedChannels.removeAll { $0 == channel }
        UserDefaults.standard.set(blockedChannels, forKey: "blockedChannels")
    }

    func addKeyword() {
        let word = keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        keywordDraft = ""
        guard !word.isEmpty, !keywords.contains(word) else { return }
        keywords.append(word)
        UserDefaults.standard.set(keywords, forKey: "blockedKeywords")
    }

    func removeKeyword(_ word: String) {
        keywords.removeAll { $0 == word }
        UserDefaults.standard.set(keywords, forKey: "blockedKeywords")
    }
}

// MARK: - 시청 시간 통계

@MainActor
final class WatchStats: ObservableObject {
    static let shared = WatchStats()

    /// "2026-10-18" → 채널 → 초
    @Published private(set) var days: [String: [String: Double]] = loadJSON("stats.json", as: [String: [String: Double]].self) ?? [:]
    private var unsaved = 0.0

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date) -> String { dayFormat.string(from: date) }

    func add(seconds: Double, channel: String) {
        guard seconds > 0 else { return }
        let day = Self.key(Date())
        days[day, default: [:]][channel.isEmpty ? "(알 수 없음)" : channel, default: 0] += seconds
        unsaved += seconds
        if unsaved >= 30 { save() }
    }

    func save() {
        unsaved = 0
        // 60일 넘은 날은 정리
        let cutoff = Self.key(Date().addingTimeInterval(-60 * 86400))
        days = days.filter { $0.key >= cutoff }
        saveJSON(days, "stats.json")
    }

    func total(on date: Date) -> Double { days[Self.key(date)]?.values.reduce(0, +) ?? 0 }

    /// 최근 7일 (오래된 날부터)
    var lastWeek: [(label: String, seconds: Double)] {
        (0..<7).reversed().map { back in
            let date = Calendar.current.date(byAdding: .day, value: -back, to: Date())!
            let label = back == 0 ? "오늘" : date.formatted(.dateTime.weekday(.abbreviated))
            return (label, total(on: date))
        }
    }

    /// 최근 7일 많이 본 채널
    var topChannels: [(name: String, seconds: Double)] {
        var sum: [String: Double] = [:]
        for back in 0..<7 {
            let date = Calendar.current.date(byAdding: .day, value: -back, to: Date())!
            for (name, seconds) in days[Self.key(date)] ?? [:] { sum[name, default: 0] += seconds }
        }
        return sum.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }
    }

    static func text(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if seconds > 0, minutes == 0 { return "1분 미만" }
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }
}

// MARK: - 구독 새 영상 알림

@MainActor
final class NewVideoWatcher: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NewVideoWatcher()

    @Published var isOn = UserDefaults.standard.object(forKey: "notifyNewVideos") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "notifyNewVideos")
            if isOn { requestPermission() }
        }
    }
    /// 사이드바 "구독" 옆에 보여 줄 새 영상 수 (구독을 열면 0)
    @Published var newCount = 0
    private var seen: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "seenSubscriptionIDs") ?? [])
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().delegate = self
        if isOn { requestPermission() }
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)   // 앱을 켜고 1분 뒤 처음 확인
            while true {
                await check()
                try? await Task.sleep(nanoseconds: 15 * 60_000_000_000)   // 15분마다
            }
        }
    }

    private func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if !granted { DebugLog.write("알림 권한 없음") }
        }
    }

    func check() async {
        guard isOn else { return }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        guard let videos = try? await YTDLP.listFeed(":ytsubs", from: 1, to: 20, cookies: cookies) else { return }
        let ids = videos.filter(\.isVideo).map(\.id)
        guard !ids.isEmpty else { return }
        let firstTime = seen.isEmpty
        let fresh = videos.filter { $0.isVideo && !seen.contains($0.id) && !$0.isLive }
        seen.formUnion(ids)
        if seen.count > 2000 { seen = Set(ids) }
        UserDefaults.standard.set(Array(seen), forKey: "seenSubscriptionIDs")
        guard !firstTime, !fresh.isEmpty else { return }   // 처음에는 지금 목록을 "본 것"으로만 기록
        newCount += fresh.count
        DebugLog.write("구독 새 영상 \(fresh.count)개")

        let content = UNMutableNotificationContent()
        content.title = fresh.count == 1 ? "\(fresh[0].channelName) 새 영상" : "구독 채널 새 영상 \(fresh.count)개"
        content.body = fresh.prefix(3).map { fresh.count == 1 ? $0.displayTitle : "\($0.channelName): \($0.displayTitle)" }.joined(separator: "\n")
        content.sound = .default
        content.userInfo = fresh.count == 1 ? ["videoID": fresh[0].id, "title": fresh[0].displayTitle] : [:]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // 알림을 누르면: 영상 하나면 바로 재생, 여러 개면 구독 목록
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let id = info["videoID"] as? String
        let title = info["title"] as? String ?? ""
        await MainActor.run {
            NSApp.activate()
            if let id {
                Playback.open(PlayerItem(id: id, title: title, url: "https://www.youtube.com/watch?v=\(id)"))
            } else {
                FeedStore.shared.selection = .subscriptions
                FeedStore.shared.reloadCurrent()
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - 나중에 볼 동영상 자동 받기 + 오래된 파일 정리

@MainActor
final class AutoDownloader: ObservableObject {
    static let shared = AutoDownloader()

    enum Kind: String, CaseIterable, Identifiable {
        case video1080, audio
        var id: String { rawValue }
        var label: String { self == .video1080 ? "영상 (1080p까지)" : "소리만 (m4a)" }
    }

    @Published var isOn = UserDefaults.standard.bool(forKey: "autoDownloadWatchLater") {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "autoDownloadWatchLater")
            if isOn { Task { await run() } }
        }
    }
    @Published var kind = Kind(rawValue: UserDefaults.standard.string(forKey: "autoDownloadKind") ?? "") ?? .video1080 {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: "autoDownloadKind") }
    }
    @Published var cleanupOn = UserDefaults.standard.bool(forKey: "autoCleanup") {
        didSet { UserDefaults.standard.set(cleanupOn, forKey: "autoCleanup") }
    }
    @Published var cleanupDays = UserDefaults.standard.object(forKey: "autoCleanupDays") as? Int ?? 14 {
        didSet { UserDefaults.standard.set(cleanupDays, forKey: "autoCleanupDays") }
    }
    @Published private(set) var lastRun: Date?

    /// 자동으로 받은 파일: 영상 코드 → (파일 경로, 받은 날)
    private struct Record: Codable { let path: String; let date: Date }
    private var records: [String: Record] = loadJSON("autodownloads.json", as: [String: Record].self) ?? [:]
    private var started = false

    var downloadedCount: Int { records.values.filter { !$0.path.isEmpty }.count }

    func start() {
        guard !started else { return }
        started = true
        Task {
            try? await Task.sleep(nanoseconds: 90_000_000_000)   // 앱을 켜고 1분 30초 뒤
            while true {
                await run()
                try? await Task.sleep(nanoseconds: 60 * 60_000_000_000)   // 1시간마다
            }
        }
    }

    func run() async {
        if cleanupOn { cleanup() }
        guard isOn else { return }
        lastRun = Date()
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        guard let videos = try? await YTDLP.listFeed(":ytwatchlater", from: 1, to: 10, cookies: cookies) else { return }
        let todo = videos.filter { $0.isVideo && !$0.isLive && records[$0.id] == nil }
        guard !todo.isEmpty else { return }
        DebugLog.write("나중에 볼 동영상 자동 받기: \(todo.count)개")
        // 한 번에 하나씩 (네트워크·디스크를 한꺼번에 쓰지 않게)
        for video in todo {
            guard isOn, let url = URL(string: video.watchURL) else { return }
            let file = await DownloadManager.shared.download(pageURL: url, title: video.displayTitle, cookies: cookies,
                                                             audioOnly: kind == .audio, maxHeight: 1080)
            if let file {
                records[video.id] = Record(path: file.path, date: Date())
                saveJSON(records, "autodownloads.json")
            }
        }
    }

    /// 자동으로 받은 지 N일 지난 파일을 휴지통으로 (직접 받은 파일은 건드리지 않음)
    func cleanup() {
        let cutoff = Date().addingTimeInterval(-Double(cleanupDays) * 86400)
        var removed = 0
        for (id, record) in records where record.date < cutoff && !record.path.isEmpty {
            let url = URL(fileURLWithPath: record.path)
            if FileManager.default.fileExists(atPath: url.path) {
                guard (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil else { continue }
                removed += 1
            }
            // 기록은 남김 (아직 "나중에 볼"에 있어도 다시 받지 않게), 경로만 비움
            records[id] = Record(path: "", date: record.date)
        }
        if removed > 0 {
            saveJSON(records, "autodownloads.json")
            DebugLog.write("자동 받은 파일 \(removed)개 휴지통으로")
        }
    }
}
