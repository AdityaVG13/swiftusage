import Foundation

/// Devin's CLI keeps every session in `sessions.db` in its data folder (`cli/`, and `cli-next/` for the
/// preview channel): `sessions` (model, start in seconds, hidden) and `message_nodes`, one row per message
/// in each session's tree with the message as JSON in `chat_message`. Assistant messages carry their usage
/// in `metadata.metrics` (`input_tokens` excludes cache reads and writes) and their model in
/// `metadata.generation_model`. Sessions copy messages into new nodes as their history is rewritten, so
/// one message can fill several rows; each counts once by `message_id`. Rows are only ever added, so
/// every read picks up after the last `row_id` seen.
public actor DevinSource: UsageSource {
    public nonisolated let provider = Provider.devin
    public nonisolated let root: URL
    private var databases: [String: Database] = [:]

    public init(root: URL = DevinSource.defaultRoot) {
        self.root = root
    }

    public static var defaultRoot: URL {
        (URL.environment("XDG_DATA_HOME") ?? .home.appendingPathComponent(".local/share")).appendingPathComponent("devin")
    }

    public nonisolated var watchedPaths: [String] {
        ["cli", "cli-next"].map { root.appendingPathComponent($0).path }
    }

    public func refresh(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        for folder in watchedPaths {
            let path = folder + "/sessions.db"
            guard let stamp = DatabaseStamp(path: path) else { continue }
            var database = databases[path] ?? Database()
            guard database.stamp != stamp, let reader = SQLiteReader(path: path), database.read(reader) else { continue }
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

    private func aggregate() -> UsageData {
        var sessions: [String: Session] = [:]
        var messages: [String: Message] = [:]
        for database in databases.values {
            sessions.merge(database.sessions) { kept, _ in kept }
            messages.merge(database.messages) { kept, candidate in kept.tokens.total >= candidate.tokens.total ? kept : candidate }
        }
        var data = UsageData()
        data.transcriptCount = sessions.count
        // Hidden sessions are Devin's own background work: their tokens count, but not as sessions or
        // messages.
        data.sessionStarts = sessions.values.filter { !$0.hidden }.map(\.created)
        for message in messages.values {
            let session = sessions[message.session]
            let bucket = FileRecord.bucket(message.created)
            if session?.hidden != true, message.counts {
                data.messageBuckets[bucket, default: 0] += 1
            }
            if message.tokens.total > 0 {
                data.usage.append(UsageRecord(bucket: bucket, model: message.model ?? session?.model ?? "unknown", tokens: message.tokens))
            }
        }
        data.scannedAt = Date()
        return data
    }

    struct Session: Sendable {
        var created: Double
        var hidden: Bool
        var model: String
    }

    struct Message: Sendable {
        var session: String
        var created: Double
        /// A prompt the user typed or a reply, as opposed to context Devin added as a user message.
        var counts: Bool
        var model: String?
        var tokens: TokenCounts
    }

    struct Database: Sendable {
        var stamp: DatabaseStamp?
        var lastRow: Int64 = 0
        var sessions: [String: Session] = [:]
        var messages: [String: Message] = [:]

        @discardableResult
        mutating func read(_ db: SQLiteReader) -> Bool {
            guard let hasSessions = db.hasTable("sessions"), let hasNodes = db.hasTable("message_nodes") else { return false }
            guard hasSessions, hasNodes else { return true }
            var next = self
            if next.lastRow > 0 {
                var maxRow: Int64 = 0
                guard db.rows("SELECT COALESCE(MAX(row_id), 0) FROM message_nodes", [], { maxRow = $0.int(0) }) else { return false }
                if maxRow < next.lastRow {
                    next = Database()
                }
            }
            guard db.rows("SELECT id, created_at, hidden, model FROM sessions", [], { row in
                guard let id = row.text(0), let created = Timestamp.seconds(row.double(1)) else { return }
                next.sessions[id] = Session(created: created, hidden: row.int(2) != 0, model: row.text(3) ?? "unknown")
            }) else { return false }
            // Only user and assistant rows matter; the role is near the start of the JSON, so tool
            // results (often whole files) are skipped without being parsed.
            var latest = next.lastRow
            guard db.rows("""
                SELECT row_id, session_id, created_at,
                       json_extract(chat_message, '$.message_id'), json_extract(chat_message, '$.role'),
                       json_extract(chat_message, '$.metadata.is_user_input'), json_extract(chat_message, '$.metadata.created_at'),
                       json_extract(chat_message, '$.metadata.generation_model'),
                       json_extract(chat_message, '$.metadata.metrics.input_tokens'), json_extract(chat_message, '$.metadata.metrics.output_tokens'),
                       json_extract(chat_message, '$.metadata.metrics.cache_read_tokens'), json_extract(chat_message, '$.metadata.metrics.cache_creation_tokens')
                FROM message_nodes
                WHERE row_id > ? AND (substr(chat_message, 1, 200) LIKE '%"role":"assistant"%' OR substr(chat_message, 1, 200) LIKE '%"role":"user"%')
                ORDER BY row_id
                """, [next.lastRow], { row in
                latest = max(latest, row.int(0))
                guard let session = row.text(1), let role = row.text(4) else { return }
                let id = row.text(3) ?? "\(session)#\(row.int(0))"
                let isAssistant = role == "assistant"
                let tokens: TokenCounts
                if isAssistant {
                    guard let input = row.tokenCount(8), let output = row.tokenCount(9),
                          let cacheRead = row.tokenCount(10), let cacheWrite = row.tokenCount(11)
                    else { return }
                    tokens = TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
                } else {
                    tokens = TokenCounts()
                }
                if let existing = next.messages[id] {
                    if tokens.total > existing.tokens.total {
                        next.messages[id]?.tokens = tokens
                        next.messages[id]?.model = row.text(7) ?? existing.model
                    }
                    return
                }
                guard let created = row.text(6).flatMap(Timestamp.parse) ?? Timestamp.seconds(row.double(2)) else { return }
                next.messages[id] = Message(session: session, created: created, counts: isAssistant || row.int(5) != 0,
                                            model: row.text(7), tokens: tokens)
            }) else { return false }
            next.lastRow = latest
            self = next
            return true
        }
    }
}
