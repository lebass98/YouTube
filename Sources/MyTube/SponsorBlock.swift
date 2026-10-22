import AVFoundation
import CryptoKit
import Foundation

/// 광고·인트로 등 건너뛸 구간 (SponsorBlock: 사람들이 함께 표시한 구간 공개 자료)
/// 영상 코드를 그대로 보내지 않고 해시 앞 4글자만 보내서, 어떤 영상을 보는지 서버가 알 수 없게 함
enum SponsorBlock {
    struct Segment: Hashable {
        let start: Double
        let end: Double
        let category: String
    }

    /// 고를 수 있는 종류 (이름, 기본 켜짐)
    static let categories: [(id: String, label: String, defaultOn: Bool)] = [
        ("sponsor", "협찬 광고", true),
        ("selfpromo", "자기 홍보 (자기 상품·채널 홍보)", true),
        ("interaction", "\"구독·좋아요\" 부탁", true),
        ("intro", "인트로 (시작 화면)", false),
        ("outro", "아웃트로 (끝 화면·엔딩)", false),
        ("preview", "미리 보기·지난 내용", false),
        ("music_offtopic", "음악 영상의 음악 아닌 부분", false),
    ]

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "sponsorBlockOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sponsorBlockOn") }
    }

    static func isEnabled(_ category: String) -> Bool {
        let saved = UserDefaults.standard.dictionary(forKey: "sponsorBlockCategories") as? [String: Bool] ?? [:]
        return saved[category] ?? categories.first { $0.id == category }?.defaultOn ?? false
    }

    static func setEnabled(_ category: String, _ on: Bool) {
        var saved = UserDefaults.standard.dictionary(forKey: "sponsorBlockCategories") as? [String: Bool] ?? [:]
        saved[category] = on
        UserDefaults.standard.set(saved, forKey: "sponsorBlockCategories")
    }

    static func label(_ category: String) -> String {
        categories.first { $0.id == category }?.label ?? category
    }

    private static let cache = SegmentCache()

    static func segments(for videoID: String) async -> [Segment] {
        if let cached = await cache.get(videoID) { return cached }
        let hash = SHA256.hash(data: Data(videoID.utf8)).map { String(format: "%02x", $0) }.joined()
        let all = categories.map { "\"\($0.id)\"" }.joined(separator: ",")
        var parts = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(hash.prefix(4))")!
        parts.queryItems = [URLQueryItem(name: "categories", value: "[\(all)]")]
        guard let url = parts.url else { return [] }
        struct Entry: Decodable {
            struct Item: Decodable {
                let segment: [Double]
                let category: String
                let actionType: String?
            }
            let videoID: String
            let segments: [Item]
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            await cache.set(videoID, [])
            return []
        }
        let found = entries.first { $0.videoID == videoID }?.segments
            .filter { ($0.actionType ?? "skip") == "skip" && $0.segment.count == 2 && $0.segment[1] - $0.segment[0] >= 1 }
            .map { Segment(start: $0.segment[0], end: $0.segment[1], category: $0.category) } ?? []
        await cache.set(videoID, found)
        if !found.isEmpty { DebugLog.write("건너뛸 구간 \(found.count)개: \(videoID)") }
        return found
    }
}

private actor SegmentCache {
    private var store: [String: [SponsorBlock.Segment]] = [:]
    func get(_ id: String) -> [SponsorBlock.Segment]? { store[id] }
    func set(_ id: String, _ value: [SponsorBlock.Segment]) {
        if store.count > 200 { store.removeAll() }
        store[id] = value
    }
}

/// 재생 중에 건너뛸 구간에 들어가면 그 끝으로 넘김 (구간마다 한 번만 → 되감아 보고 싶으면 볼 수 있음)
@MainActor
final class SegmentSkipper {
    private weak var player: AVPlayer?
    private var segments: [SponsorBlock.Segment] = []
    private var skipped: Set<SponsorBlock.Segment> = []

    init(player: AVPlayer, videoID: String) {
        self.player = player
        guard SponsorBlock.isOn else { return }
        Task { [weak self] in
            let found = await SponsorBlock.segments(for: videoID)
            self?.segments = found
        }
    }

    func check(_ position: Double) {
        guard let player, !segments.isEmpty else { return }
        for segment in segments where !skipped.contains(segment) && SponsorBlock.isEnabled(segment.category)
            && position >= segment.start && position < segment.end - 0.5 {
            skipped.insert(segment)
            player.seek(to: CMTime(seconds: segment.end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            let length = Int(segment.end - max(position, segment.start))
            DebugLog.write("구간 건너뜀: \(segment.category) \(Int(segment.start))~\(Int(segment.end))초")
            Toast.shared.show("\(SponsorBlock.label(segment.category)) 건너뜀 (\(length)초)", seconds: 3)
            return
        }
    }
}
