import Foundation

/// Cursor keeps token usage on its servers. Conversations and messages are counted from this Mac, and tokens
/// from Cursor's usage events when one of its logins can read them (else from the IDE messages that happen
/// to record them).
///
/// - The CLI keeps each chat in `~/.cursor/chats/<hash>/<agent id>/store.db`: `meta` row `0` is hex-encoded
///   JSON with the chat's `createdAt`; `blobs` holds messages as JSON and the conversation's root as
///   protobuf, whose field 1 lists the ids of the messages still in the conversation. Messages carry no
///   time of their own, so they're dated to the chat.
/// - The IDE keeps composers and their messages ("bubbles") as JSON in `state.vscdb`'s `cursorDiskKV`.
public actor CursorSource: UsageSource {
    public nonisolated let provider = Provider.cursor
    public nonisolated let chatsURL: URL
    public nonisolated let acpSessionsURL: URL
    public nonisolated let ideStateURL: URL
    /// Where Cursor's usage events come from, or nil to count only what's on this Mac.
    private nonisolated let server: CursorServerUsage?
    private var serverAccounts: [String: CursorServerUsage.Account]?
    private var serverFetch: Task<Void, Never>?
    private var serverFetchedAt: Date?
    private var chats: [String: Chat] = [:]
    private var ide = Chat(id: "ide")
    /// The IDE's database is read whole, so while Cursor keeps writing to it, it's read at most once a
    /// minute; the next refresh after that picks up the rest.
    private var ideReadAt: Date?

    /// Posted by the source when a fetch of Cursor's usage events brought something new, so Cursor is read again.
    public static let serverUsageDidChange = Notification.Name("CursorSource.serverUsageDidChange")

    public init(chatsURL: URL = URL.home.appendingPathComponent(".cursor/chats"),
                acpSessionsURL: URL? = nil,
                ideStateURL: URL = URL.home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
                server: CursorServerUsage? = nil) {
        self.chatsURL = chatsURL
        self.acpSessionsURL = acpSessionsURL ?? chatsURL.deletingLastPathComponent().appendingPathComponent("acp-sessions")
        self.ideStateURL = ideStateURL
        self.server = server
    }

    public nonisolated var watchedPaths: [String] { [chatsURL.path, acpSessionsURL.path, ideStateURL.deletingLastPathComponent().path] }

    public func refresh(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        var seen: Set<String> = []
        for root in [chatsURL, acpSessionsURL] {
            for relative in TranscriptFolders.files(in: root, depth: 2, include: { $0 == "store.db" }).keys.sorted() {
                let path = root.path + "/" + relative
                guard seen.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path).inserted else { continue }
                guard let stamp = DatabaseStamp(path: path) else { continue }
                if chats[path]?.stamp == stamp { continue }
                guard let reader = SQLiteReader(path: path),
                      var chat = Chat.readCLI(reader, id: (relative as NSString).deletingLastPathComponent)
                else { continue }
                chat.stamp = stamp
                chats[path] = chat
            }
        }
        if let stamp = DatabaseStamp(path: ideStateURL.path), ide.stamp != stamp,
           ideReadAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true,
           let reader = SQLiteReader(path: ideStateURL.path),
           var chat = Chat.readIDE(reader) {
            chat.stamp = stamp
            ide = chat
            ideReadAt = Date()
        }
        if let server {
            if serverAccounts == nil { serverAccounts = server.load() }
            if serverFetch == nil, serverFetchedAt.map({ Date().timeIntervalSince($0) >= CursorServerUsage.interval }) ?? true {
                serverFetchedAt = Date()
                serverFetch = Task { await fetchServerUsage(server) }
            }
            if server.waits, let serverFetch { await serverFetch.value }
        }
        return aggregate()
    }

    private func fetchServerUsage(_ server: CursorServerUsage) async {
        defer { serverFetch = nil }
        var accounts = serverAccounts ?? [:]
        var changed = false
        for login in server.logins() {
            guard let updated = await CursorServerUsage.update(accounts[login.id], login: login, now: Date().timeIntervalSince1970),
                  updated != accounts[login.id] else { continue }
            accounts[login.id] = updated
            changed = true
        }
        guard changed else { return }
        serverAccounts = accounts
        server.save(accounts)
        NotificationCenter.default.post(name: Self.serverUsageDidChange, object: self)
    }

    public func rebuild(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        chats = [:]
        ide = Chat(id: "ide")
        ideReadAt = nil
        serverAccounts = nil
        serverFetchedAt = nil
        return await refresh(progress: progress)
    }

    public func save() {}

    private func aggregate() -> UsageData {
        var data = UsageData()
        // Cursor's own events cover what the IDE's messages record, and much more.
        let events = (serverAccounts ?? [:]).values.flatMap(\.events)
        for chat in Array(chats.values) + [ide] {
            data.sessionStarts += chat.sessions
            for bucket in chat.messages.values { data.messageBuckets[bucket, default: 0] += 1 }
            if events.isEmpty { data.usage += chat.usage.values }
        }
        data.usage += events.map { UsageRecord(bucket: FileRecord.bucket($0.time), model: $0.model, tokens: $0.tokens, cost: $0.cost) }
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

        static func readCLI(_ db: SQLiteReader, id: String) -> Chat? {
            var chat = Chat(id: id)
            guard let hasMeta = db.hasTable("meta"), let hasBlobs = db.hasTable("blobs") else { return nil }
            guard hasMeta, hasBlobs else { return chat }
            var meta: [String: Any]?
            guard db.rows("SELECT value FROM meta WHERE key = '0'", [], { row in
                guard let hex = row.text(0), let json = Data(hex: hex) else { return }
                meta = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
            }) else { return nil }
            guard let meta, let created = (meta["createdAt"] as? NSNumber)?.doubleValue,
                  let start = Timestamp.seconds(created / 1000)
            else { return chat }
            chat.sessions = [start]
            let bucket = FileRecord.bucket(start)

            // Only messages the conversation still points to: edits and retries leave old ones behind.
            guard let rootID = meta["latestRootBlobId"] as? String else { return chat }
            var ids: [String] = []
            guard db.rows("SELECT data FROM blobs WHERE id = ?", [rootID], { row in
                ids = row.blob(0).flatMap(ProtoMessage.init)?.allBytes(1).map(\.hexString) ?? []
            }) else { return nil }
            for blobID in ids {
                guard db.rows("SELECT data FROM blobs WHERE id = ?", [blobID], { row in
                    guard let data = row.blob(0), data.first == UInt8(ascii: "{"),
                          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let role = message["role"] as? String, role == "user" || role == "assistant"
                    else { return }
                    chat.messages[JSONLine.key("cursor", id, blobID)] = bucket
                }) else { return nil }
            }
            return chat
        }

        static func readIDE(_ db: SQLiteReader) -> Chat? {
            var chat = Chat(id: "ide")
            guard let hasTable = db.hasTable("cursorDiskKV") else { return nil }
            guard hasTable else { return chat }
            var composers: [String: (start: Double, model: String?)] = [:]
            // Key ranges rather than LIKE, which can't use the key's index and would scan the whole table.
            guard db.rows("""
                SELECT key, json_extract(CAST(value AS TEXT), '$.createdAt'), json_extract(CAST(value AS TEXT), '$.modelConfig.modelName'),
                       json_array_length(json_extract(CAST(value AS TEXT), '$.fullConversationHeadersOnly'))
                FROM cursorDiskKV WHERE key >= 'composerData:' AND key < 'composerData;' AND json_valid(CAST(value AS TEXT))
                """, [], { row in
                guard let key = row.text(0), let start = Self.time(row, 1), row.int(3) > 0 else { return }
                composers[String(key.dropFirst("composerData:".count))] = (start, row.text(2))
            }) else { return nil }
            chat.sessions = composers.values.map(\.start)
            guard db.rows("""
                SELECT key, json_extract(CAST(value AS TEXT), '$.type'), json_extract(CAST(value AS TEXT), '$.createdAt'),
                       json_extract(CAST(value AS TEXT), '$.tokenCount.inputTokens'), json_extract(CAST(value AS TEXT), '$.tokenCount.outputTokens'),
                       json_extract(CAST(value AS TEXT), '$.modelInfo.modelName')
                FROM cursorDiskKV WHERE key >= 'bubbleId:' AND key < 'bubbleId;' AND json_valid(CAST(value AS TEXT))
                """, [], { row in
                // bubbleId:<composer>:<bubble>; type 1 is the user, 2 the assistant.
                guard let key = row.text(0), row.int(1) == 1 || row.int(1) == 2 else { return }
                let composer = key.split(separator: ":").dropFirst().first.map(String.init) ?? ""
                guard let time = Self.time(row, 2) ?? composers[composer]?.start,
                      let input = row.tokenCount(3), let output = row.tokenCount(4)
                else { return }
                let bucket = FileRecord.bucket(time)
                let messageKey = JSONLine.key("cursor-ide", key)
                chat.messages[messageKey] = bucket
                let tokens = TokenCounts(input: input, output: output)
                if tokens.total > 0 {
                    let model = row.text(5) ?? composers[composer]?.model ?? "cursor"
                    chat.usage[messageKey] = UsageRecord(bucket: bucket, model: model, tokens: tokens)
                }
            }) else { return nil }
            return chat
        }

        /// Milliseconds since 1970, or an ISO 8601 string.
        private static func time(_ row: SQLiteReader.Row, _ column: Int32) -> Double? {
            if row.isNull(column) { return nil }
            if let text = row.text(column), let parsed = Timestamp.parse(text) { return parsed }
            let value = row.double(column)
            let seconds = value > 1e12 ? value / 1000 : value > 1e9 ? value : nil
            return seconds.flatMap(Timestamp.seconds)
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
