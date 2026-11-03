import Foundation

/// Kimi Code writes a `usage.record` for every model call in a session's `wire.jsonl`, under
/// `sessions/`. `inputOther` is the uncached input, `inputCacheRead` the cache it read,
/// `inputCacheCreation` the cache it wrote, and `time` is milliseconds. The records are the
/// session's calls, so each counts as a response, and a session starts at its first call.
public actor KimiSource: UsageSource {
    public nonisolated let provider = Provider.kimi
    public nonisolated let root: URL

    public init(root: URL = KimiSource.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        if let directory = URL.environment("KIMI_CODE_SESSION_DIR") { return directory }
        return URL.home.appendingPathComponent(".kimi-code/sessions")
    }

    public nonisolated var watchedPaths: [String] { [root.path] }

    public func refresh(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        read()
    }

    public func rebuild(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        read()
    }

    public func save() {}

    private func read() -> UsageData {
        var data = UsageData()
        var transcripts = 0
        for path in files() {
            guard let contents = FileManager.default.contents(atPath: path) else { continue }
            var started: Double?
            for line in contents.split(separator: UInt8(ascii: "\n")) {
                guard line.count > 2,
                      let parsed = try? JSONSerialization.jsonObject(with: Data(line)),
                      let entry = parsed as? [String: Any],
                      entry["type"] as? String == "usage.record",
                      let model = entry["model"] as? String,
                      let usage = entry["usage"] as? [String: Any],
                      let milliseconds = (entry["time"] as? NSNumber)?.doubleValue,
                      let time = Timestamp.seconds(milliseconds / 1000),
                      let input = TokenCount.parse(usage["inputOther"]),
                      let output = TokenCount.parse(usage["output"]),
                      let cacheRead = TokenCount.parse(usage["inputCacheRead"]),
                      let cacheWrite = TokenCount.parse(usage["inputCacheCreation"]),
                      input + output + cacheRead + cacheWrite > 0
                else { continue }
                started = started ?? time
                let bucket = FileRecord.bucket(time)
                data.usage.append(UsageRecord(bucket: bucket, model: model,
                                              tokens: TokenCounts(input: input, output: output,
                                                                  cacheRead: cacheRead, cacheWrite: cacheWrite)))
                data.messageBuckets[bucket, default: 0] += 1
            }
            if let started {
                data.sessionStarts.append(started)
                transcripts += 1
            }
        }
        data.transcriptCount = transcripts
        data.scannedAt = Date()
        return data
    }

    private func files() -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [String] = []
        for case let url as URL in walker where url.lastPathComponent == "wire.jsonl" {
            found.append(url.path)
        }
        return found.sorted()
    }
}
