import Foundation

/// Codex's rollouts: `sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl`, plus `archived_sessions/`.
/// Finished rollouts may be zstd-compressed in place (`.jsonl.zst`). Files are keyed by name alone, so a
/// rollout that's archived or compressed is still the same transcript.
///
/// Every line is `{timestamp, type, payload}`. Usage comes from `token_usage_record` (newer builds,
/// one per response with an ID) or else `token_count` events, whose `last_token_usage` is one response
/// and which repeat whenever nothing changed. A forked or subagent rollout may start with a replay of its
/// parent's history. A turn whose ID is a UUIDv7 dates itself, so a replayed one is older than the thread;
/// other turn IDs (`rollout-2`, UUIDv4) can't tell, so counts are keyed by their thread tree and what they
/// count, and a replayed copy is the response its parent already counted.
public enum CodexTranscripts: TranscriptFormat {
    public static let provider = Provider.codex
    public static let cacheName = "codex-index.json"
    /// 4: counts are keyed by what they count, turns that don't date themselves are no longer taken for
    /// replays, and responses are dated no earlier than their turn.
    public static let cacheVersion = 4
    public static let upgradableCacheVersion = 2

    public static var defaultRoot: URL {
        URL.environment("CODEX_HOME") ?? .home.appendingPathComponent(".codex")
    }

    public static func watchedPaths(root: URL) -> [String] {
        ([root] + otherHomes(of: root)).flatMap {
            [$0.appendingPathComponent("sessions").path, $0.appendingPathComponent("archived_sessions").path]
        }
    }

    /// Rollouts in `root` and, when it's the default home, in every other home, as the limits are read.
    public static func discover(in root: URL) -> [String: TranscriptInfo] {
        discover(in: root, others: otherHomes(of: root))
    }

    static func discover(in root: URL, others: [URL]) -> [String: TranscriptInfo] {
        var found: [String: TranscriptInfo] = [:]
        func add(_ files: [String: TranscriptInfo]) {
            for (relative, info) in files {
                let name = relative.split(separator: "/").last.map(String.init) ?? relative
                let key = name.hasSuffix(".zst") ? String(name.dropLast(4)) : name
                // While a rollout is being compressed both copies exist; the plain one is complete.
                if let existing = found[key], !existing.path.hasSuffix(".zst") { continue }
                found[key] = info
            }
        }
        let isRollout = { (name: String) in name.hasPrefix("rollout-") && (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")) }
        for home in [root] + others {
            add(TranscriptFolders.files(in: home.appendingPathComponent("sessions"), depth: 3, include: isRollout))
            add(TranscriptFolders.files(in: home.appendingPathComponent("archived_sessions"), depth: 0, include: isRollout))
        }
        return found
    }

    /// The other Codex homes, when `root` is the default one and `CODEX_HOME` isn't set.
    static func otherHomes(of root: URL) -> [URL] {
        guard ProcessInfo.processInfo.environment["CODEX_HOME"]?.isEmpty ?? true,
              root.standardizedFileURL == defaultRoot.standardizedFileURL else { return [] }
        return otherHomes(of: root, home: .home, remembered: EnvironmentFolders.seen("CODEX_HOME"))
    }

    /// Every other home with rollouts: the folders `CODEX_HOME` has named, `~/.config/codex`, and side-by-side
    /// homes such as `~/.codex-work`. One that's another's through a symlink is left out.
    static func otherHomes(of root: URL, home: URL, remembered: [String]) -> [URL] {
        var homes = remembered.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        homes.append(home.appendingPathComponent(".config/codex"))
        for (parent, prefix) in [(home, ".codex-"), (home.appendingPathComponent(".config"), "codex-")] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            homes += names.sorted().filter { $0.hasPrefix(prefix) }.map { parent.appendingPathComponent($0) }
        }
        var seen: Set<String> = [root.resolvingSymlinksInPath().path]
        return homes.filter { folder in
            ["sessions", "archived_sessions"].contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
                && seen.insert(folder.resolvingSymlinksInPath().path).inserted
        }
    }

    public static func ingest(_ line: UnsafeRawBufferPointer, lineOffset: UInt64, pathHash: UInt64, into record: inout FileRecord) -> Bool {
        // A line's type comes first (`{"timestamp":…,"type":…,"payload":{"type":…`), within its first 120 bytes
        // in every rollout on hand, so only its start is searched, not the rest, often hundreds of kilobytes.
        let head = UnsafeRawBufferPointer(rebasing: line.prefix(1024))
        guard JSONLine.contains(head, "\"token_count\"") || JSONLine.contains(head, "\"token_usage_record\"")
            || JSONLine.contains(head, "\"turn_context\"") || JSONLine.contains(head, "\"session_meta\"")
            || JSONLine.contains(head, "\"task_started\"") || JSONLine.contains(head, "\"item_completed\"")
            || JSONLine.contains(head, "\"user_message\"") || JSONLine.contains(head, "\"agent_message\"")
            || JSONLine.contains(head, "\"thread_settings_applied\"") || JSONLine.contains(head, "\"compacted\"")
        else { return true }
        guard let entry = JSONLine.object(line) else { return false }
        guard let payload = entry["payload"] as? [String: Any], let type = entry["type"] as? String else { return true }
        let time = (entry["timestamp"] as? String).flatMap(Timestamp.parse)
        let kind = type == "event_msg" ? payload["type"] as? String ?? "" : type
        var context = record.context ?? [:]
        defer { record.context = context }
        let lineKey = pathHash ^ (lineOffset &* 0x9E37_79B9_7F4A_7C15)

        // A turn that started before its forked or subagent thread is a replay of the parent's.
        var replayed: Bool {
            guard context["fork"] != nil, let thread = context["thread"].flatMap(uuidTime),
                  let turn = context["turn"].flatMap(uuidTime) else { return false }
            return turn < thread
        }
        // Messages count only in turns known to be the thread's own: a replayed message is keyed by this thread, so
        // it wouldn't land on its parent's copy.
        var ownTurn: Bool {
            guard context["fork"] != nil else { return true }
            guard let thread = context["thread"].flatMap(uuidTime), let turn = context["turn"].flatMap(uuidTime) else { return false }
            return turn >= thread
        }
        // Some rollouts are written out in one go with every line stamped when the thread started, days before
        // the turns in them, so a response is dated no earlier than its turn, and no later than the file was written.
        let modified = record.modified
        let at = time.map { stamped in
            guard let started = context["turnTime"].flatMap(Double.init), started > stamped else { return stamped }
            return modified > 0 ? min(started, max(stamped, modified)) : started
        }
        func enter(turn: String?) {
            guard let turn else { return }
            context["turn"] = turn
            if let started = uuidTime(turn) { context["turnTime"] = String(started) }
        }
        // A count logged before any turn named the model takes the model of the turn after.
        func name(_ key: UInt64) {
            guard record.model == nil else { return }
            context["unnamed"] = (context["unnamed"].map { $0 + " " } ?? "") + String(key)
        }
        // Codex Desktop can rewrite a thread's early history down to its compaction markers. Its first count then
        // starts from a total the file no longer itemizes, which is spread over the compactions that replaced it.
        func recoverRewrittenHistory(total: TokenCounts?, own: TokenCounts) {
            guard context["started"] == nil else { return }
            context["started"] = "1"
            guard let marks = context.removeValue(forKey: "rewritten")?.split(separator: " ").compactMap({ Double($0) }),
                  !marks.isEmpty, let total else { return }
            let missing = TokenCounts(input: max(0, total.input - own.input), output: max(0, total.output - own.output),
                                      cacheRead: max(0, total.cacheRead - own.cacheRead), cacheWrite: max(0, total.cacheWrite - own.cacheWrite))
            guard missing.total > 0 else { return }
            let count = Int64(marks.count)
            for (index, mark) in marks.enumerated() {
                let share = { (value: Int64) in value / count + (index == marks.count - 1 ? value % count : 0) }
                let key = JSONLine.key("codex-rewritten", context["thread"] ?? "", String(index))
                record.usage[key] = UsageRecord(bucket: FileRecord.bucket(mark), model: record.model ?? "unknown",
                                                tokens: TokenCounts(input: share(missing.input), output: share(missing.output),
                                                                    cacheRead: share(missing.cacheRead), cacheWrite: share(missing.cacheWrite)),
                                                speed: speed(context["tier"]))
                name(key)
            }
        }

        switch kind {
        case "session_meta":
            // A fork's file also carries its parent's header after its own.
            guard context["thread"] == nil else { break }
            context["thread"] = payload["id"] as? String
            // The thread tree's root: a subagent's or fork's names the session it came from.
            context["tree"] = payload["session_id"] as? String
            // A later segment of a thread, which starts from the total its earlier one ended on.
            if payload["history_base"] != nil { context["segment"] = "1" }
            let start = (payload["timestamp"] as? String).flatMap(Timestamp.parse) ?? time
            record.sessionStart = start
            record.model = record.model ?? payload[path: "base_instructions", "provenance", "model"] as? String
            let source = payload["source"]
            let subagent = (source as? [String: Any])?["subagent"] != nil
                || ["subagent", "guardian_review"].contains(payload["thread_source"] as? String ?? "")
            if subagent { record.isSubagent = true }
            if subagent || payload["forked_from_id"] as? String != nil { context["fork"] = "1" }
        case "turn_context":
            enter(turn: payload["turn_id"] as? String)
            context["counted"] = nil
            record.model = payload["model"] as? String ?? payload[path: "collaboration_mode", "settings", "model"] as? String ?? record.model
            if let unnamed = context["unnamed"], let model = record.model {
                for key in unnamed.split(separator: " ").compactMap({ UInt64($0) }) { record.usage[key]?.model = model }
                context["unnamed"] = nil
            }
        case "compacted":
            // A subagent's or fork's first count starts from what it inherited instead.
            guard context["started"] == nil, context["fork"] == nil, context["segment"] == nil, let time else { break }
            context["rewritten"] = (context["rewritten"].map { $0 + " " } ?? "") + String(time)
        case "task_started":
            enter(turn: payload["turn_id"] as? String)
        case "thread_settings_applied":
            // Fast mode runs on the priority tier, billed at a multiple of the standard rate.
            if let thread = payload["thread_id"] as? String, let own = context["thread"], thread != own { break }
            guard let settings = payload["thread_settings"] as? [String: Any] else { break }
            context["tier"] = settings["service_tier"] as? String
        case "token_usage_record":
            context["records"] = "1"
            guard let usage = payload["usage"] as? [String: Any], let counts = tokens(usage), let at, !replayed else { break }
            recoverRewrittenHistory(total: (payload["thread_token_usage"] as? [String: Any]).flatMap(tokens), own: counts)
            // The turn's `token_count`s logged before the file's first record may be these responses, counted
            // until now.
            var counted = (context["counted"] ?? "").split(separator: " ").compactMap { UInt64($0) }
            if let index = counted.firstIndex(where: { record.usage[$0]?.tokens == counts }) {
                record.usage[counted.remove(at: index)] = nil
                context["counted"] = counted.isEmpty ? nil : counted.map(String.init).joined(separator: " ")
            }
            if let thread = payload["thread_id"] as? String, let own = context["thread"], thread != own { break }
            let key = (payload["response_id"] as? String).map { JSONLine.key("codex", $0) } ?? lineKey
            record.usage[key] = UsageRecord(bucket: FileRecord.bucket(at), model: record.model ?? "unknown", tokens: counts,
                                            speed: speed(context["tier"]))
            name(key)
        case "token_count":
            // Superseded by per-response records once a file has them.
            guard context["records"] == nil, let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any],
                  let running = tokens(total), let counts = tokens(last), let at
            else { break }
            guard running != record.runningTotal else { break }
            record.runningTotal = running
            guard !replayed else { break }
            recoverRewrittenHistory(total: running, own: counts)
            // The running total makes the count one of a kind within its thread tree, and the same in a fork's copy.
            let key = (context["tree"] ?? context["thread"]).map { JSONLine.key("codex-count", $0, signature(total), signature(last)) } ?? lineKey
            record.usage[key] = UsageRecord(bucket: FileRecord.bucket(at), model: record.model ?? "unknown", tokens: counts,
                                            speed: speed(context["tier"]))
            name(key)
            // A response's record comes soon after its count, so the last few are enough to look through.
            context["counted"] = ((context["counted"] ?? "").split(separator: " ").suffix(15) + [Substring(String(key))]).joined(separator: " ")
        case "item_completed":
            guard let item = payload["item"] as? [String: Any], let itemType = item["type"] as? String,
                  itemType == "UserMessage" || itemType == "AgentMessage", ownTurn
            else { break }
            let started = (item["started_at_ms"] as? NSNumber).map { $0.doubleValue / 1000 }
            guard let sent = (started ?? at).flatMap(Timestamp.seconds) else { break }
            // Migrated rollouts number items per thread (`item-1`), so IDs are only unique within one.
            let key = (item["id"] as? String).map { JSONLine.key("codex-item", context["thread"] ?? "", $0) } ?? lineKey
            if record.messages[key] == nil { record.messages[key] = FileRecord.bucket(sent) }
        case "user_message", "agent_message":
            // Rollouts not yet migrated to items.
            guard type == "event_msg", let at, ownTurn else { break }
            if record.messages[lineKey] == nil { record.messages[lineKey] = FileRecord.bucket(at) }
        default:
            break
        }
        return true
    }

    private static func speed(_ tier: String?) -> Speed {
        switch tier {
        case "priority", "fast": .fast
        case "ultrafast": .ultrafast
        default: .standard
        }
    }

    /// Seconds since 1970 that a UUIDv7 starts with; nil for any other ID.
    static func uuidTime(_ id: String) -> Double? {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0].count == 8, parts[1].count == 4, parts[2].count == 4, parts[2].first == "7",
              let milliseconds = UInt64(parts[0] + parts[1], radix: 16) else { return nil }
        return Timestamp.seconds(Double(milliseconds) / 1000)
    }

    /// Every count in a usage object, as written.
    private static func signature(_ usage: [String: Any]) -> String {
        ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"]
            .map { usage.int($0).map(String.init) ?? "-" }.joined(separator: " ")
    }

    /// `input_tokens` includes cache reads and writes; `output_tokens` includes reasoning.
    private static func tokens(_ usage: [String: Any]) -> TokenCounts? {
        guard let input = usage.int("input_tokens"), let output = usage.int("output_tokens"),
              let cacheRead = usage.int("cached_input_tokens"), let cacheWrite = usage.int("cache_write_input_tokens")
        else { return nil }
        return TokenCounts(input: max(0, input - cacheRead - cacheWrite), output: output,
                           cacheRead: cacheRead, cacheWrite: cacheWrite)
    }
}
