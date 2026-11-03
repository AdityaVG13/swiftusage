import Foundation

/// Empryo writes one JSON line per model call to `usage-YYYY-MM.jsonl`. The call's `modelId` names
/// the plan it was billed to (`subscriptions/claude-…`, `subscriptions/gpt-…`, `subscriptions/kimi-code/…`),
/// and `cost` is what Empryo priced it at. Every plan's usage comes from the same files, so one
/// reader parses them once and each plan's source takes its share.
public actor EmpryoSource: UsageSource {
    public nonisolated let provider: Provider
    private nonisolated let root: URL
    private nonisolated let reader: EmpryoReader

    public init(provider: Provider, reader: EmpryoReader, root: URL = EmpryoSource.defaultRoot) {
        self.provider = provider
        self.reader = reader
        self.root = root
    }

    public static var defaultRoot: URL {
        if let directory = URL.environment("EMPRYO_USAGE_DIR") { return directory }
        return URL.home.appendingPathComponent(".empryo/usage")
    }

    public nonisolated var watchedPaths: [String] { [root.path] }

    public func refresh(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        await reader.read(root: root)[provider] ?? UsageData()
    }

    public func rebuild(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        await reader.rebuild(root: root)[provider] ?? UsageData()
    }

    public func save() {}
}

/// Reads Empryo's monthly usage files once for every plan, and again only when one of them changes.
public actor EmpryoReader {
    private struct Stamp: Equatable {
        var size: UInt64
        var modified: Double
    }

    private var stamps: [String: Stamp]?
    private var cached: [Provider: UsageData] = [:]

    public init() {}

    func read(root: URL) -> [Provider: UsageData] {
        let paths = Self.files(root: root)
        var current: [String: Stamp] = [:]
        for path in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
            else { continue }
            current[path] = Stamp(size: size, modified: modified)
        }
        if current == stamps { return cached }

        // Accumulate into arrays and buckets directly: assigning `split[plan]` back after each append
        // copies the plan's whole array every line, which is quadratic over a month of calls.
        var usage: [Provider: [UsageRecord]] = [:]
        var buckets: [Provider: [Int32: Int]] = [:]
        var contributors: [Provider: Int] = [:]
        for path in paths {
            guard let contents = FileManager.default.contents(atPath: path) else { continue }
            var plans: Set<Provider> = []
            for line in contents.split(separator: UInt8(ascii: "\n")) {
                guard line.count > 2,
                      let parsed = try? JSONSerialization.jsonObject(with: Data(line)),
                      let record = parsed as? [String: Any],
                      let model = record["modelId"] as? String,
                      let plan = Self.plan(for: model),
                      let milliseconds = (record["ts"] as? NSNumber)?.doubleValue,
                      let time = Timestamp.seconds(milliseconds / 1000),
                      let input = TokenCount.parse(record["input"]),
                      let output = TokenCount.parse(record["output"]),
                      let cacheRead = TokenCount.parse(record["cacheRead"]),
                      let cacheWrite = TokenCount.parse(record["cacheWrite"]),
                      input + output + cacheRead + cacheWrite > 0
                else { continue }
                let bucket = FileRecord.bucket(time)
                let cost = (record["cost"] as? NSNumber)?.doubleValue
                usage[plan, default: []].append(UsageRecord(bucket: bucket, model: model,
                                                            tokens: TokenCounts(input: input, output: output,
                                                                                cacheRead: cacheRead, cacheWrite: cacheWrite),
                                                            cost: cost))
                buckets[plan, default: [:]][bucket, default: 0] += 1
                plans.insert(plan)
            }
            for plan in plans { contributors[plan, default: 0] += 1 }
        }
        var split: [Provider: UsageData] = [:]
        for (plan, records) in usage {
            var data = UsageData()
            data.usage = records
            data.messageBuckets = buckets[plan] ?? [:]
            data.transcriptCount = contributors[plan] ?? 0
            data.scannedAt = Date()
            split[plan] = data
        }
        stamps = current
        cached = split
        return split
    }

    func rebuild(root: URL) -> [Provider: UsageData] {
        stamps = nil
        cached = [:]
        return read(root: root)
    }

    /// The plan a call was billed to, named by its `modelId`; nil for a call the app has no card for
    /// (`deepseek/…`, `openrouter/…`).
    static func plan(for model: String) -> Provider? {
        guard model.hasPrefix("subscriptions/") else { return nil }
        let plan = model.dropFirst("subscriptions/".count)
        for (prefix, provider) in [("claude", Provider.claude), ("gpt", .codex), ("grok", .grok),
                                   ("kimi", .kimi), ("cursor", .cursor), ("devin", .devin), ("meta", .muse)]
        where plan.hasPrefix(prefix) {
            return provider
        }
        return nil
    }

    private static func files(root: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("usage-") && $0.hasSuffix(".jsonl") }.sorted().map { root.path + "/" + $0 }
    }
}
