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
        return ["antigravity", "antigravity-cli", "antigravity-ide", "antigravity-backup", "antigravity-acp"].map { gemini.appendingPathComponent($0) }
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
        for path in conversations.keys.sorted() {
            guard let conversation = conversations[path] else { continue }
            if let start = conversation.start { starts[conversation.id] = min(starts[conversation.id] ?? start, start) }
            messages.merge(conversation.messages) { kept, _ in kept }
            usage.merge(conversation.usage) { kept, candidate in kept.tokens.total >= candidate.tokens.total ? kept : candidate }
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
            guard let hasTrajectory = db.hasTable("trajectory_metadata_blob"),
                  let hasSteps = db.hasTable("steps"),
                  let hasMetadata = db.hasTable("gen_metadata")
            else { return nil }

            var trajectoryTime: Double?
            if hasTrajectory {
                guard db.rows("SELECT data FROM trajectory_metadata_blob ORDER BY rowid", [], { row in
                    if trajectoryTime == nil {
                        trajectoryTime = row.blob(0).flatMap(ProtoMessage.init)?.message(2)?.timestamp
                    }
                }) else { return nil }
                if let trajectoryTime { conversation.start = min(conversation.start ?? trajectoryTime, trajectoryTime) }
            }

            var responseTimes: [Double?] = []
            var stepRetries: [(stepIdx: Int64, retryIndex: Int, time: Double?, model: String?, counts: ProtoMessage)] = []
            if hasSteps {
                guard db.rows("SELECT idx, step_type, metadata FROM steps ORDER BY idx", [], { row in
                    let type = row.int(1)
                    let meta = row.blob(2).flatMap(ProtoMessage.init)
                    let time = meta?.message(8)?.timestamp ?? meta?.message(1)?.timestamp
                    if let time { conversation.start = min(conversation.start ?? time, time) }
                    if type == 15 { responseTimes.append(time) }
                    if let meta {
                        let model = meta.message(24)?.string(12) ?? meta.message(24)?.string(8)
                        for (retryIndex, data) in meta.allBytes(28).enumerated() {
                            if let counts = ProtoMessage(data)?.message(2) {
                                stepRetries.append((row.int(0), retryIndex, time, model, counts))
                            }
                        }
                    }
                    guard type == 14 || type == 15, let time else { return }
                    conversation.messages[JSONLine.key("antigravity", id, String(row.int(0)))] = FileRecord.bucket(time)
                }) else { return nil }
            }

            var keyByIdentity: [UInt64: UInt64] = [:]
            func addUsage(_ counts: ProtoMessage, time: Double, model: String, fallbackKey: UInt64) {
                // Input excludes cached tokens; output includes thinking.
                guard let input = TokenCount.parse(counts.int(2) ?? 0),
                      let output = TokenCount.parse(counts.int(3) ?? 0),
                      let cacheRead = TokenCount.parse(counts.int(5) ?? 0),
                      let cacheWrite = TokenCount.parse(counts.int(4) ?? 0)
                else { return }
                let tokens = TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
                guard tokens.total > 0 else { return }
                let identities: [UInt64] = [
                    counts.string(11).flatMap { $0.isEmpty ? nil : JSONLine.key("antigravity-response", $0) },
                    counts.string(12).flatMap { $0.isEmpty ? nil : JSONLine.key("antigravity-provider-message", $0) },
                    counts.string(7).flatMap { $0.isEmpty ? nil : JSONLine.key("antigravity-message", $0) },
                ].compactMap { $0 }
                let key = identities.compactMap({ keyByIdentity[$0] }).first ?? identities.first ?? fallbackKey
                for identity in identities { keyByIdentity[identity] = key }
                if let existing = conversation.usage[key], existing.tokens.total >= tokens.total { return }
                conversation.usage[key] = UsageRecord(bucket: FileRecord.bucket(time), model: model, tokens: tokens)
            }

            var lastModel: String?
            if hasMetadata {
                var position = 0
                guard db.rows("SELECT idx, data FROM gen_metadata ORDER BY idx", [], { row in
                    defer { position += 1 }
                    guard let generation = row.blob(1).flatMap(ProtoMessage.init)?.message(1) else { return }
                    if let ownModel = generation.string(19) { lastModel = ownModel }
                    let model = generation.string(19) ?? lastModel ?? "gemini"
                    let stepTime = position < responseTimes.count ? responseTimes[position] : nil
                    guard let time = stepTime ?? generation.message(9)?.message(4)?.timestamp ?? trajectoryTime else { return }
                    conversation.start = min(conversation.start ?? time, time)
                    if let counts = generation.message(4) {
                        addUsage(counts, time: time, model: model,
                                 fallbackKey: JSONLine.key("antigravity", id, "generation", String(row.int(0))))
                    }
                    for (retryIndex, data) in generation.allBytes(17).enumerated() {
                        if let counts = ProtoMessage(data)?.message(2) {
                            addUsage(counts, time: time, model: model,
                                     fallbackKey: JSONLine.key("antigravity", id, "generation-retry", String(row.int(0)), String(retryIndex)))
                        }
                    }
                }) else { return nil }
            }

            for retry in stepRetries {
                guard let time = retry.time ?? trajectoryTime ?? conversation.start else { continue }
                addUsage(retry.counts, time: time, model: retry.model ?? lastModel ?? "gemini",
                         fallbackKey: JSONLine.key("antigravity", id, "step-retry", String(retry.stepIdx), String(retry.retryIndex)))
            }
            return conversation
        }
    }
}
