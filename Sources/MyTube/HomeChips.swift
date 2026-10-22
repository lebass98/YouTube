import CryptoKit
import Foundation

/// 유튜브 홈 위쪽의 고르기 칩(새로운 맞춤 동영상·감상한 동영상·최근에 업로드된 동영상 …)
/// yt-dlp가 지원하지 않아서, 유튜브 웹이 쓰는 방식(youtubei browse)으로 로그인 정보와 함께 직접 받음
enum YouTubeHome {
    enum Failure: LocalizedError {
        case notLoggedIn, noChip(String), bad(String)
        var errorDescription: String? {
            switch self {
            case .notLoggedIn: "유튜브 로그인이 필요해요 (이동 → 유튜브 사이트 열기에서 로그인)"
            case .noChip(let title): "지금 유튜브 홈에 \"\(title)\" 항목이 없어요. 잠시 뒤 새로고침해 보세요."
            case .bad(let message): "유튜브 홈을 받지 못했어요: \(message)"
            }
        }
    }

    /// 칩 하나의 영상들. continuation이 있으면 그다음 묶음. next = 더 받을 표 (없으면 끝)
    static func chip(_ title: String, continuation: String?, cookies: [HTTPCookie]) async throws -> (videos: [FeedVideo], next: String?) {
        let token: String
        if let continuation {
            token = continuation
        } else {
            // 홈을 받아 칩 목록에서 이름이 같은 칩의 표를 찾음 (표는 홈을 받을 때마다 바뀜)
            let home = try await browse(["browseId": "FEwhat_to_watch"], cookies: cookies)
            var chips: [Any] = []
            collect(home, key: "chipCloudChipRenderer", into: &chips)
            let found = chips.compactMap { $0 as? [String: Any] }.first { text($0["text"]) == title }
            guard let found,
                  let command = (found["navigationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any],
                  let chipToken = command["token"] as? String else { throw Failure.noChip(title) }
            token = chipToken
        }
        let result = try await browse(["continuation": token], cookies: cookies)
        var lockups: [Any] = []
        collect(result, key: "lockupViewModel", into: &lockups)
        let videos = lockups.compactMap { $0 as? [String: Any] }.compactMap(video)
        // 다음 묶음 표: 마지막 continuationItemRenderer 안의 것
        var items: [Any] = []
        collect(result, key: "continuationItemRenderer", into: &items)
        var next: String?
        if let last = items.last {
            var commands: [Any] = []
            collect(last, key: "continuationCommand", into: &commands)
            next = (commands.first as? [String: Any])?["token"] as? String
        }
        return (videos, videos.isEmpty ? nil : next)
    }

    // MARK: 요청

    private static func browse(_ body: [String: Any], cookies: [HTTPCookie]) async throws -> Any {
        try await post("browse", body, cookies: cookies)
    }

    /// 유튜브 웹이 쓰는 요청 (browse·next·like/like 등), 로그인 정보와 함께
    static func post(_ path: String, _ body: [String: Any], cookies: [HTTPCookie]) async throws -> Any {
        let youtube = cookies.filter { $0.domain.hasSuffix("youtube.com") }
        guard let sapisid = youtube.first(where: { $0.name == "SAPISID" })?.value
                ?? youtube.first(where: { $0.name == "__Secure-3PAPISID" })?.value else { throw Failure.notLoggedIn }
        var payload = body
        payload["context"] = ["client": ["clientName": "WEB", "clientVersion": "2.20261015.00.00", "hl": "ko", "gl": "KR"]]
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/\(path)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 20
        // 로그인 정보: 쿠키 + SAPISIDHASH (유튜브 웹과 같은 방식)
        let time = String(Int(Date().timeIntervalSince1970))
        let hash = Insecure.SHA1.hash(data: Data("\(time) \(sapisid) https://www.youtube.com".utf8))
            .map { String(format: "%02x", $0) }.joined()
        request.setValue("SAPISIDHASH \(time)_\(hash)", forHTTPHeaderField: "Authorization")
        for (key, value) in HTTPCookie.requestHeaderFields(with: youtube) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "X-Origin")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.bad("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: 읽기

    /// 영상 항목 하나 → FeedVideo (영상만, 쇼츠·재생목록 묶음은 뺌)
    private static func video(_ lockup: [String: Any]) -> FeedVideo? {
        guard lockup["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO",
              let id = lockup["contentId"] as? String, id.count == 11,
              let metadata = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any] else { return nil }
        let title = text(metadata["title"])
        // 줄: [채널] / [조회수, 올린 때]
        var rows: [Any] = []
        collect(metadata, key: "metadataRows", into: &rows)
        let parts: [[String]] = ((rows.first as? [Any]) ?? []).map { row in
            ((row as? [String: Any])?["metadataParts"] as? [Any] ?? []).map { text(($0 as? [String: Any])?["text"]) }
        }
        let channel = parts.first?.first
        let views = parts.dropFirst().flatMap { $0 }.first { $0.contains("조회수") }
        // 썸네일 위 표시: 길이 "16:02" 또는 라이브
        var badges: [Any] = []
        collect(lockup["contentImage"] as Any, key: "thumbnailBadgeViewModel", into: &badges)
        let badgeTexts = badges.compactMap { ($0 as? [String: Any])?["text"] as? String }
        let isLive = badgeTexts.contains { $0.contains("실시간") || $0.uppercased().contains("LIVE") }
        let duration = badgeTexts.lazy.compactMap(seconds).first
        var sources: [Any] = []
        collect(lockup["contentImage"] as Any, key: "sources", into: &sources)
        let thumbs = ((sources.first as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.compactMap { s -> FeedVideo.Thumbnail? in
            guard let url = s["url"] as? String else { return nil }
            return FeedVideo.Thumbnail(url: url, width: s["width"] as? Int)
        }
        return FeedVideo(id: id, title: title.isEmpty ? nil : title, channel: channel, uploader: nil,
                         duration: duration, viewCount: views.flatMap(viewCount),
                         liveStatus: isLive ? "is_live" : nil,
                         url: "https://www.youtube.com/watch?v=\(id)", thumbnails: thumbs.isEmpty ? nil : thumbs, ieKey: "Youtube")
    }

    static func collect(_ object: Any, key: String, into out: inout [Any]) {
        if let dict = object as? [String: Any] {
            if let value = dict[key] { out.append(value) }
            for value in dict.values { collect(value, key: key, into: &out) }
        } else if let list = object as? [Any] {
            for value in list { collect(value, key: key, into: &out) }
        }
    }

    /// {"content": "…"} / {"simpleText": "…"} / {"runs": [{"text": "…"}]}
    static func text(_ value: Any?) -> String {
        guard let dict = value as? [String: Any] else { return "" }
        if let content = dict["content"] as? String { return content }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] { return runs.compactMap { $0["text"] as? String }.joined() }
        return ""
    }

    /// "16:02" / "1:04:36" → 초
    private static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        return Double(parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 })
    }

    /// "조회수 4.4만회" → 44000, "조회수 6.2천회" → 6200, "조회수 1.2억회", "조회수 512회"
    private static func viewCount(_ text: String) -> Int? {
        let digits = text.replacingOccurrences(of: "조회수", with: "").replacingOccurrences(of: "회", with: "")
            .replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("억", 100_000_000), ("만", 10_000), ("천", 1_000)]
        for (unit, scale) in units where digits.hasSuffix(unit) {
            return Double(digits.dropLast()).map { Int($0 * scale) }
        }
        return Int(digits)
    }
}
