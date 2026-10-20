import Foundation

/// Cursor keeps token usage on its servers, so locally only conversations and messages can be counted
/// (plus tokens on IDE messages that happen to record them).
///
/// - The CLI keeps each chat in `~/.cursor/chats/<hash>/<agent id>/store.db`: `meta` row `0` is hex-encoded
///   JSON with the chat's `createdAt`; `blobs` holds messages as JSON and the conversation's root as
///   protobuf, whose field 1 lists the ids of the messages still in the conversation. Messages carry no
///   time of their own, so they're dated to the chat.
/// - The IDE keeps composers and their messages ("bubbles") as JSON in `state.vscdb`'s `cursorDiskKV`.
public actor CursorSource: UsageSource {
    public nonisolated let provider = Provider.cursor
    public nonisolated let chatsURL: URL
    public nonisolated let ideStateURL: URL
    private var chats: [String: Chat] = [:]
    private var ide = Chat(id: "ide")
    /// The IDE's database is read whole, so while Cursor keeps writing to it, it's read at most once a
    /// minute; the next refresh after that picks up the rest.
    private var ideReadAt: Date?

    public init(chatsURL: URL = URL.home.appendingPathComponent(".cursor/chats"),
                ideStateURL: URL = URL.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")) {
        self.chatsURL = chatsURL
        self.ideStateURL = ideStateURL
    }

    public nonisolated var watchedPaths: [String] { [chatsURL.path, ideStateURL.deletingLastPathComponent().path] }

    public func refresh(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        for (relative, _) in TranscriptFolders.files(in: chatsURL, depth: 2, include: { $0 == "store.db" }) {
            let path = chatsURL.path + "/" + relative
            guard let stamp = DatabaseStamp(path: path) else { continue }
            if chats[path]?.stamp == stamp { continue }
            guard let reader = SQLiteReader(path: path) else { continue }
            var chat = Chat.readCLI(reader, id: (relative as NSString).deletingLastPathComponent)
            chat.stamp = stamp
            chats[path] = chat
        }
        if let stamp = DatabaseStamp(path: ideStateURL.path), ide.stamp != stamp,
           ideReadAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true,
           let reader = SQLiteReader(path: ideStateURL.path) {
            ide = Chat.readIDE(reader)
            ide.stamp = stamp
            ideReadAt = Date()
        }
        return aggregate()
    }

    public func rebuild(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        chats = [:]
        ide = Chat(id: "ide")
        ideReadAt = nil
        return await refresh(progress: progress)
    }

    public func save() {}

    private func aggregate() -> UsageData {
        var data = UsageData()
        for chat in Array(chats.values) + [ide] {
            data.sessionStarts += chat.sessions
            for bucket in chat.messages.values { data.messageBuckets[bucket, default: 0] += 1 }
            data.usage += chat.usage.values
        }
        data.transcriptCount = chats.count
        data.scannedAt = Date()
        return data
    }

    struct Chat: Sendable {
        var id: String
        var stamp: DatabaseStamp?
        var sessions: [Double] = []
        var messages: [UInt64: Int32] = [:]
        var usage: [UInt64: UsageRecord] = [:]

        static func readCLI(_ db: SQLiteReader, id: String) -> Chat {
            var chat = Chat(id: id)
            guard db.hasTable("meta"), db.hasTable("blobs") else { return chat }
            var meta: [String: Any]?
            db.rows("SELECT value FROM meta WHERE key = '0'") { row in
                guard let hex = row.text(0), let json = Data(hex: hex) else { return }
                meta = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
            }
            guard let meta, let created = (meta["createdAt"] as? NSNumber)?.doubleValue else { return chat }
            let start = created / 1000
            chat.sessions = [start]
            let bucket = FileRecord.bucket(start)

            // Only messages the conversation still points to: edits and retries leave old ones behind.
            guard let rootID = meta["latestRootBlobId"] as? String else { return chat }
            var ids: [String] = []
            db.rows("SELECT data FROM blobs WHERE id = ?", [rootID]) { row in
                ids = row.blob(0).flatMap(ProtoMessage.init)?.allBytes(1).map(\.hexString) ?? []
            }
            for blobID in ids {
                db.rows("SELECT data FROM blobs WHERE id = ?", [blobID]) { row in
                    guard let data = row.blob(0), data.first == UInt8(ascii: "{"),
                          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let role = message["role"] as? String, role == "user" || role == "assistant"
                    else { return }
                    chat.messages[JSONLine.key("cursor", id, blobID)] = bucket
                }
            }
            return chat
        }

        static func readIDE(_ db: SQLiteReader) -> Chat {
            var chat = Chat(id: "ide")
            guard db.hasTable("cursorDiskKV") else { return chat }
            var composers: [String: (start: Double, model: String?)] = [:]
            // Key ranges rather than LIKE, which can't use the key's index and would scan the whole table.
            db.rows("""
                SELECT key, json_extract(CAST(value AS TEXT), '$.createdAt'), json_extract(CAST(value AS TEXT), '$.modelConfig.modelName'),
                       json_array_length(json_extract(CAST(value AS TEXT), '$.fullConversationHeadersOnly'))
                FROM cursorDiskKV WHERE key >= 'composerData:' AND key < 'composerData;' AND json_valid(CAST(value AS TEXT))
                """) { row in
                guard let key = row.text(0), let start = Self.time(row, 1), row.int(3) > 0 else { return }
                composers[String(key.dropFirst("composerData:".count))] = (start, row.text(2))
            }
            chat.sessions = composers.values.map(\.start)
            db.rows("""
                SELECT key, json_extract(CAST(value AS TEXT), '$.type'), json_extract(CAST(value AS TEXT), '$.createdAt'),
                       json_extract(CAST(value AS TEXT), '$.tokenCount.inputTokens'), json_extract(CAST(value AS TEXT), '$.tokenCount.outputTokens'),
                       json_extract(CAST(value AS TEXT), '$.modelInfo.modelName')
                FROM cursorDiskKV WHERE key >= 'bubbleId:' AND key < 'bubbleId;' AND json_valid(CAST(value AS TEXT))
                """) { row in
                // bubbleId:<composer>:<bubble>; type 1 is the user, 2 the assistant.
                guard let key = row.text(0), row.int(1) == 1 || row.int(1) == 2 else { return }
                let composer = key.split(separator: ":").dropFirst().first.map(String.init) ?? ""
                guard let time = Self.time(row, 2) ?? composers[composer]?.start else { return }
                let bucket = FileRecord.bucket(time)
                let messageKey = JSONLine.key("cursor-ide", key)
                chat.messages[messageKey] = bucket
                let tokens = TokenCounts(input: row.int(3), output: row.int(4))
                if tokens.total > 0 {
                    let model = row.text(5) ?? composers[composer]?.model ?? "cursor"
                    chat.usage[messageKey] = UsageRecord(bucket: bucket, model: model, tokens: tokens)
                }
            }
            return chat
        }

        /// Milliseconds since 1970, or an ISO 8601 string.
        private static func time(_ row: SQLiteReader.Row, _ column: Int32) -> Double? {
            if row.isNull(column) { return nil }
            if let text = row.text(column), let parsed = Timestamp.parse(text) { return parsed }
            let value = row.double(column)
            return value > 1e12 ? value / 1000 : value > 1e9 ? value : nil
        }
    }
}

extension Data {
    init?(hex: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8?
        for c in hex.utf8 {
            let nibble: UInt8
            switch c {
            case 48...57: nibble = c - 48
            case 97...102: nibble = c - 87
            case 65...70: nibble = c - 55
            default: return nil
            }
            if let h = high {
                bytes.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        guard high == nil else { return nil }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
