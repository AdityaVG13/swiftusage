import Foundation

/// OpenCode keeps everything in SQLite: `opencode.db` for its release channels and `opencode-<channel>.db`
/// for others, in its data folder. Messages are JSON in `message.data`; newer builds also write
/// `session_message`. Each database is re-read only when it or its WAL changes, and then only the rows
/// updated since the last read.
public actor OpenCodeSource: UsageSource {
    public nonisolated let provider = Provider.opencode
    public nonisolated let root: URL
    private var databases: [String: Database] = [:]

    public init(root: URL = OpenCodeSource.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        if let dir = URL.environment("OPENCODE_DATA_DIR") { return dir }
        return (URL.environment("XDG_DATA_HOME") ?? .home.appendingPathComponent(".local/share")).appendingPathComponent("opencode")
    }

    public nonisolated var watchedPaths: [String] { [root.path] }

    public func refresh(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        for path in databasePaths() {
            guard let stamp = DatabaseStamp(path: path) else { continue }
            var database = databases[path] ?? Database()
            guard database.stamp != stamp, let reader = SQLiteReader(path: path) else { continue }
            database.read(reader)
            database.stamp = stamp
            databases[path] = database
        }
        return aggregate()
    }

    public func rebuild(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        databases = [:]
        return await refresh(progress: progress)
    }

    public func save() {}

    private func databasePaths() -> [String] {
        if let override = URL.environment("OPENCODE_DB") { return [override.path] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }.sorted().map { root.path + "/" + $0 }
    }

    private func aggregate() -> UsageData {
        var sessions: [String: Session] = [:]
        var messages: [String: Message] = [:]
        // The main database first, so its copy of a message shared with another channel's is the one kept.
        for path in databases.keys.sorted(by: { ($0.hasSuffix("/opencode.db") ? 0 : 1, $0) < ($1.hasSuffix("/opencode.db") ? 0 : 1, $1) }) {
            guard let database = databases[path] else { continue }
            sessions.merge(database.sessions) { kept, _ in kept }
            messages.merge(database.messages) { kept, _ in kept }
        }

        var data = UsageData()
        data.transcriptCount = sessions.count
        // Subagent sessions have a parent: their tokens count, but not as sessions or messages.
        data.sessionStarts = sessions.values.filter { $0.parent == nil }.map { Double($0.created) / 1000 }
        for message in messages.values {
            let session = sessions[message.session]
            // A fork copies earlier messages under new IDs but keeps their times.
            if let session, message.created < session.created - 1000 { continue }
            let bucket = FileRecord.bucket(Double(message.created) / 1000)
            if session?.parent == nil {
                data.messageBuckets[bucket, default: 0] += 1
            }
            if message.tokens.total > 0 {
                data.usage.append(UsageRecord(bucket: bucket, model: message.model, tokens: message.tokens, cost: message.cost))
            }
        }
        data.scannedAt = Date()
        return data
    }

    struct Session: Sendable {
        var created: Int64
        var parent: String?
    }

    struct Message: Sendable {
        var session: String
        var created: Int64
        var model: String
        var tokens: TokenCounts
        /// Dollars, as OpenCode priced the response.
        var cost: Double?
    }

    struct Database: Sendable {
        var stamp: DatabaseStamp?
        /// Latest `time_updated` read, in milliseconds.
        var since: Int64 = 0
        var sessions: [String: Session] = [:]
        var messages: [String: Message] = [:]
        /// Messages the `message` table has, which wins over `session_message`'s copy.
        var inMessageTable: Set<String> = []

        mutating func read(_ db: SQLiteReader) {
            for table in ["session", "session_v2"] where db.hasTable(table) {
                db.rows("SELECT id, parent_id, time_created FROM \(table)") { row in
                    guard let id = row.text(0), sessions[id] == nil else { return }
                    sessions[id] = Session(created: row.int(2), parent: row.text(1))
                }
            }
            // Rows are updated in place when a response finishes; a minute of slack covers clock skew
            // between writes.
            let after = max(0, since - 60_000)
            var latest = since
            let tokens = """
                json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.output'),
                json_extract(data, '$.tokens.reasoning'), json_extract(data, '$.tokens.cache.read'),
                json_extract(data, '$.tokens.cache.write'), json_extract(data, '$.tokens.total'), json_extract(data, '$.cost')
                """
            if db.hasTable("message") {
                db.rows("""
                    SELECT id, session_id, time_created, time_updated, json_extract(data, '$.role'),
                           json_extract(data, '$.modelID'), json_extract(data, '$.providerID'), \(tokens)
                    FROM message WHERE time_updated >= ?
                    """, [after]) { row in
                    latest = max(latest, row.int(3))
                    if let id = row.text(0) { inMessageTable.insert(id) }
                    add(row, role: row.text(4), model: row.text(5), provider: row.text(6), reasoningAlwaysSeparate: false)
                }
            }
            // Newer builds' table. It repeats most of `message`; rows only here are added.
            if db.hasTable("session_message") {
                db.rows("""
                    SELECT id, session_id, time_created, time_updated, type,
                           json_extract(data, '$.model.id'), json_extract(data, '$.model.providerID'), \(tokens)
                    FROM session_message WHERE time_updated >= ? AND type IN ('user', 'assistant')
                    """, [after]) { row in
                    latest = max(latest, row.int(3))
                    // Rows only here are updated in place as a response streams, so a later read replaces them.
                    guard let id = row.text(0), !inMessageTable.contains(id) else { return }
                    add(row, role: row.text(4), model: row.text(5), provider: row.text(6), reasoningAlwaysSeparate: true)
                }
            }
            since = latest
        }

        private mutating func add(_ row: SQLiteReader.Row, role: String?, model: String?, provider: String?, reasoningAlwaysSeparate: Bool) {
            guard let id = row.text(0), let session = row.text(1), role == "user" || role == "assistant" else { return }
            var counts = TokenCounts()
            var cost: Double?
            if role == "assistant" {
                cost = row.isNull(13) ? nil : row.double(13)
                counts = Self.tokens(input: row.int(7), output: row.int(8), reasoning: row.int(9), cacheRead: row.int(10),
                                     cacheWrite: row.int(11), total: row.isNull(12) ? nil : row.int(12),
                                     provider: provider, reasoningAlwaysSeparate: reasoningAlwaysSeparate)
            }
            messages[id] = Message(session: session, created: row.int(2), model: model ?? "unknown", tokens: counts, cost: cost)
        }

        /// `input` is already uncached. Since OpenCode 1.3.16 `reasoning` is reported beside `output`;
        /// before, OpenAI-style providers kept it inside. When a `total` is recorded it says which: the
        /// sum including reasoning matches it only when reasoning is separate.
        static func tokens(input: Int64, output: Int64, reasoning: Int64, cacheRead: Int64, cacheWrite: Int64,
                           total: Int64?, provider: String?, reasoningAlwaysSeparate: Bool) -> TokenCounts {
            let base = input + output + cacheRead + cacheWrite
            let separate: Bool
            if reasoningAlwaysSeparate {
                separate = true
            } else if let total {
                separate = reasoning > 0 && total == base + reasoning
            } else {
                separate = reasoning > output || provider == "google"
            }
            return TokenCounts(input: input, output: output + (separate ? reasoning : 0), cacheRead: cacheRead, cacheWrite: cacheWrite)
        }
    }
}
