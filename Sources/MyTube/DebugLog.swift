import Foundation

/// 문제 확인용 기록: ~/Library/Logs/MyTube.log (이 Mac에만 저장, 어디로도 보내지 않음)
/// 1MB가 넘으면 오래된 앞부분을 지우고 최근 약 500KB만 남김
enum DebugLog {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/MyTube.log")

    private static let maxSize = 1_000_000
    private static let keepSize = 500_000
    private static let lock = NSLock()

    static func write(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            let size = handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
            if size + UInt64(data.count) > UInt64(maxSize) { trim() }
        } else {
            try? data.write(to: url)
        }
    }

    /// 뒤쪽(최근) 약 500KB만 남기고, 잘린 첫 줄은 버림
    private static func trim() {
        guard let all = try? Data(contentsOf: url), all.count > keepSize else { return }
        var tail = all.suffix(keepSize)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[tail.index(after: newline)...] }
        try? Data(tail).write(to: url, options: .atomic)
    }
}
