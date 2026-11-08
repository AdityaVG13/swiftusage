import Foundation

/// Hermes records what each session used per model and billing provider in `state.db`'s
/// `session_model_usage`: the plan is named there (`openai-codex`, `muse-code`, `xai-oauth`, `zai`,
/// `nous`, `anthropic`, …) and `last_seen` is when the row was last written. One reader serves every
/// plan's source, so the database is read once, and only when it or its WAL changes.
public actor HermesSource: UsageSource {
    public nonisolated let provider: Provider
    private nonisolated let database: URL
    private nonisolated let reader: HermesReader

    public init(provider: Provider, reader: HermesReader, database: URL = HermesSource.defaultDatabase) {
        self.provider = provider
        self.reader = reader
        self.database = database
    }

    public static var defaultDatabase: URL {
        if let home = URL.environment("HERMES_HOME") { return home.appendingPathComponent("state.db") }
        return URL.home.appendingPathComponent(".hermes/state.db")
    }

    public nonisolated var watchedPaths: [String] { [database.path, database.path + "-wal"] }

    public func refresh(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        await reader.read(database: database)[provider] ?? UsageData()
    }

    public func rebuild(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        await reader.rebuild(database: database)[provider] ?? UsageData()
    }

    public func save() {}
}

public actor HermesReader {
    private var stamp: DatabaseStamp?
    private var cached: [Provider: UsageData] = [:]
    private var loaded = false

    public init() {}

    func read(database: URL) -> [Provider: UsageData] {
        guard let stamp = DatabaseStamp(path: database.path) else { return [:] }
        if loaded, stamp == self.stamp { return cached }
        guard let db = SQLiteReader(path: database.path) else { return loaded ? cached : [:] }

        // Accumulate into arrays and buckets directly: assigning `split[plan]` back after each append
        // copies the plan's whole array every row, which is quadratic over a large database.
        var usage: [Provider: [UsageRecord]] = [:]
        var starts: [Provider: [Double]] = [:]
        var sessions: [Provider: Set<String>] = [:]
        let sql = """
            SELECT s.id, s.started_at, s.parent_session_id,
                   u.billing_provider, u.model, u.api_call_count,
                   u.input_tokens, u.output_tokens, u.cache_read_tokens, u.cache_write_tokens,
                   u.last_seen, u.first_seen
            FROM session_model_usage u JOIN sessions s ON s.id = u.session_id
            """
        let ok = db.rows(sql) { row in
            guard let session = row.text(0) else { return }
            let plan = row.text(3).flatMap(Self.plan(for:)) ?? .unattributed
            guard let input = TokenCount.parse(row.int(6)), let output = TokenCount.parse(row.int(7)),
                  let cacheRead = TokenCount.parse(row.int(8)), let cacheWrite = TokenCount.parse(row.int(9)),
                  input + output + cacheRead + cacheWrite > 0
            else { return }
            guard let seconds = row.isNull(10) ? nil : Timestamp.seconds(row.double(10)) else { return }
            let bucket = FileRecord.bucket(seconds)
            // Older databases can lack first_seen; the session start is a conservative lower bound.
            let first = (row.isNull(11) ? nil : Timestamp.seconds(row.double(11)))
                ?? (row.isNull(1) ? nil : Timestamp.seconds(row.double(1))) ?? 0
            let firstBucket = FileRecord.bucket(first <= seconds ? first : 0)
            let parent = row.text(2)
            let calls = row.int(5)
            let mainCalls = (parent == nil || parent == "") && calls > 0 && calls < Int64(Int.max) ? Int(calls) : 0
            usage[plan, default: []].append(UsageRecord(bucket: bucket, model: row.text(4) ?? "unknown",
                                                        tokens: TokenCounts(input: input, output: output,
                                                                            cacheRead: cacheRead, cacheWrite: cacheWrite),
                                                        firstBucket: firstBucket, aggregateCalls: mainCalls))
            // A subagent's calls aren't messages or sessions of their own, but their tokens count.
            if parent == nil || parent == "" {
                if !(sessions[plan]?.contains(session) ?? false), let start = row.isNull(1) ? nil : Timestamp.seconds(row.double(1)) {
                    starts[plan, default: []].append(start)
                    sessions[plan, default: []].insert(session)
                }
            }
        }
        guard ok else { return loaded ? cached : [:] }

        var split: [Provider: UsageData] = [:]
        for (plan, records) in usage {
            var data = UsageData()
            data.usage = records
            data.sessionStarts = starts[plan] ?? []
            data.transcriptCount = sessions[plan]?.count ?? 0
            data.scannedAt = Date()
            split[plan] = data
        }
        self.stamp = stamp
        loaded = true
        cached = split
        return split
    }

    func rebuild(database: URL) -> [Provider: UsageData] {
        stamp = nil
        loaded = false
        cached = [:]
        return read(database: database)
    }

    /// The plan a Hermes row was billed to. A blank provider (Hermes' own title generation) and a
    /// gateway without a card here stay unknown.
    static func plan(for billingProvider: String) -> Provider? {
        switch billingProvider {
        case "openai-codex": .codex
        case "muse-code", "meta-ai": .muse
        case "xai-oauth": .grok
        case "zai": .zai
        case "nous": .nous
        case "anthropic": .claude
        case "cursor": .cursor
        case "antigravity-oauth": .antigravity
        case "opencode-go": .opencode
        case "kimi-coding", "kimi-coding-cn": .kimi
        default: nil
        }
    }
}
