import Foundation

/// Antigravity (IDE and CLI) keeps each conversation in its own SQLite file,
/// `~/.gemini/antigravity*/conversations/<cascade id>.db`, as protobuf rows: `steps` (14 is the
/// user's input, 15 a model response, each with its creation time) and `gen_metadata`, one row per
/// model response in the same order as its steps, carrying the model and usage. Older conversations are
/// encrypted `.pb` files and can't be read.
public actor AntigravitySource: UsageSource {
    public nonisolated let provider = Provider.antigravity
    public nonisolated let roots: [URL]
    private var conversations: [String: Conversation] = [:]

    public init(roots: [URL] = AntigravitySource.defaultRoots) {
        self.roots = roots
    }

    public static var defaultRoots: [URL] {
        let gemini = URL.home.appendingPathComponent(".gemini")
        return ["antigravity", "antigravity-cli", "antigravity-ide", "antigravity-backup"].map { gemini.appendingPathComponent($0) }
            + [URL.home.appendingPathComponent(".config/antigravity")]
    }

    public nonisolated var watchedPaths: [String] { roots.map { $0.appendingPathComponent("conversations").path } }

    public func refresh(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        for folder in watchedPaths {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where name.hasSuffix(".db") {
                let path = folder + "/" + name
                guard let stamp = DatabaseStamp(path: path) else { continue }
                if conversations[path]?.stamp == stamp { continue }
                guard let reader = SQLiteReader(path: path),
                      var conversation = Conversation.read(reader, id: String(name.dropLast(3)))
                else { continue }
                conversation.stamp = stamp
                conversations[path] = conversation
            }
        }
        return aggregate()
    }

    public func rebuild(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        conversations = [:]
        return await refresh(progress: progress)
    }

    public func save() {}

    private func aggregate() -> UsageData {
        // The backup folder repeats the IDE's conversations, so everything is keyed by conversation.
        var starts: [String: Double] = [:]
        var messages: [UInt64: Int32] = [:]
        var usage: [UInt64: UsageRecord] = [:]
        for conversation in conversations.values {
            if let start = conversation.start { starts[conversation.id] = min(starts[conversation.id] ?? start, start) }
            messages.merge(conversation.messages) { kept, _ in kept }
            usage.merge(conversation.usage) { kept, _ in kept }
        }
        var data = UsageData()
        data.transcriptCount = starts.count
        data.sessionStarts = Array(starts.values)
        for bucket in messages.values { data.messageBuckets[bucket, default: 0] += 1 }
        data.usage = Array(usage.values)
        data.scannedAt = Date()
        return data
    }

    struct Conversation: Sendable {
        var id: String
        var stamp: DatabaseStamp?
        var start: Double?
        var messages: [UInt64: Int32] = [:]
        var usage: [UInt64: UsageRecord] = [:]

        static func read(_ db: SQLiteReader, id: String) -> Conversation? {
            var conversation = Conversation(id: id)
            guard let hasSteps = db.hasTable("steps") else { return nil }
            guard hasSteps else { return conversation }
            var responseTimes: [Double?] = []
            guard db.rows("SELECT idx, step_type, metadata FROM steps ORDER BY idx", [], { row in
                let type = row.int(1)
                let time = row.blob(2).flatMap(ProtoMessage.init)?.message(1)?.timestamp
                if let time { conversation.start = min(conversation.start ?? time, time) }
                if type == 15 { responseTimes.append(time) }
                guard type == 14 || type == 15, let time else { return }
                conversation.messages[JSONLine.key("antigravity", id, String(row.int(0)))] = FileRecord.bucket(time)
            }), let hasMetadata = db.hasTable("gen_metadata") else { return nil }
            guard hasMetadata else { return conversation }
            var position = 0
            guard db.rows("SELECT idx, data FROM gen_metadata ORDER BY idx", [], { row in
                defer { position += 1 }
                guard let generation = row.blob(1).flatMap(ProtoMessage.init)?.message(1),
                      let counts = generation.message(4)
                else { return }
                // The matching response step's time; IDE rows also carry their own.
                let stepTime = position < responseTimes.count ? responseTimes[position] : nil
                guard let time = stepTime ?? generation.message(9)?.message(4)?.timestamp else { return }
                // Input excludes cached tokens; output includes thinking.
                guard let input = TokenCount.parse(counts.int(2) ?? 0),
                      let output = TokenCount.parse(counts.int(3) ?? 0),
                      let cacheRead = TokenCount.parse(counts.int(5) ?? 0),
                      let cacheWrite = TokenCount.parse(counts.int(4) ?? 0)
                else { return }
                let tokens = TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
                guard tokens.total > 0 else { return }
                let key = counts.string(11).map { JSONLine.key("antigravity-response", $0) }
                    ?? JSONLine.key("antigravity", id, "generation", String(row.int(0)))
                conversation.usage[key] = UsageRecord(bucket: FileRecord.bucket(time), model: generation.string(19) ?? "gemini", tokens: tokens)
            }) else { return nil }
            return conversation
        }
    }
}
