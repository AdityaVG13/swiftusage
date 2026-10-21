import Foundation

/// Codex's rollouts: `sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl`, plus `archived_sessions/`.
/// Finished rollouts may be zstd-compressed in place (`.jsonl.zst`). Files are keyed by name alone, so a
/// rollout that's archived or compressed is still the same transcript.
///
/// Every line is `{timestamp, type, payload}`. Usage comes from `token_usage_record` (newer builds,
/// one per response with an ID) or else `token_count` events, whose `last_token_usage` is one response
/// and which repeat whenever nothing changed. A forked or subagent rollout starts with a replay of its
/// parent's history; turn IDs are UUIDv7, so the replayed turns are the ones older than the thread.
public enum CodexTranscripts: TranscriptFormat {
    public static let provider = Provider.codex
    public static let cacheName = "codex-index.json"
    /// 3: responses record their service tier, for pricing.
    public static let cacheVersion = 3
    public static let upgradableCacheVersion = 2

    public static var defaultRoot: URL {
        URL.environment("CODEX_HOME") ?? .home.appendingPathComponent(".codex")
    }

    public static func watchedPaths(root: URL) -> [String] {
        [root.appendingPathComponent("sessions").path, root.appendingPathComponent("archived_sessions").path]
    }

    public static func discover(in root: URL) -> [String: TranscriptInfo] {
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
        add(TranscriptFolders.files(in: root.appendingPathComponent("sessions"), depth: 3, include: isRollout))
        add(TranscriptFolders.files(in: root.appendingPathComponent("archived_sessions"), depth: 0, include: isRollout))
        return found
    }

    public static func ingest(_ line: UnsafeRawBufferPointer, lineOffset: UInt64, pathHash: UInt64, into record: inout FileRecord) -> Bool {
        // A line's type comes first (`{"timestamp":…,"type":…,"payload":{"type":…`), within its first 120 bytes
        // in every rollout on hand, so only its start is searched, not the rest, often hundreds of kilobytes.
        let head = UnsafeRawBufferPointer(rebasing: line.prefix(1024))
        guard JSONLine.contains(head, "\"token_count\"") || JSONLine.contains(head, "\"token_usage_record\"")
            || JSONLine.contains(head, "\"turn_context\"") || JSONLine.contains(head, "\"session_meta\"")
            || JSONLine.contains(head, "\"task_started\"") || JSONLine.contains(head, "\"item_completed\"")
            || JSONLine.contains(head, "\"user_message\"") || JSONLine.contains(head, "\"agent_message\"")
            || JSONLine.contains(head, "\"thread_settings_applied\"")
        else { return true }
        guard let entry = JSONLine.object(line) else { return false }
        guard let payload = entry["payload"] as? [String: Any], let type = entry["type"] as? String else { return true }
        let time = (entry["timestamp"] as? String).flatMap(Timestamp.parse)
        let kind = type == "event_msg" ? payload["type"] as? String ?? "" : type
        var context = record.context ?? [:]
        defer { record.context = context }
        let lineKey = pathHash ^ (lineOffset &* 0x9E37_79B9_7F4A_7C15)

        // Forked and subagent threads replay older turns first; only this thread's own turns count.
        var isOwnTurn: Bool {
            guard context["fork"] != nil, let thread = context["thread"] else { return true }
            guard let turn = context["turn"], turn.count >= 13, turn.contains("-") else { return false }
            return turn.prefix(13) >= thread.prefix(13)
        }

        switch kind {
        case "session_meta":
            // A fork's file also carries its parent's header after its own.
            guard context["thread"] == nil else { break }
            context["thread"] = payload["id"] as? String
            let start = (payload["timestamp"] as? String).flatMap(Timestamp.parse) ?? time
            record.sessionStart = start
            record.model = record.model ?? payload[path: "base_instructions", "provenance", "model"] as? String
            let source = payload["source"]
            let subagent = (source as? [String: Any])?["subagent"] != nil
                || ["subagent", "guardian_review"].contains(payload["thread_source"] as? String ?? "")
            if subagent { record.isSubagent = true }
            if subagent || payload["forked_from_id"] as? String != nil { context["fork"] = "1" }
        case "turn_context":
            context["turn"] = payload["turn_id"] as? String ?? context["turn"]
            context["counted"] = nil
            record.model = payload["model"] as? String ?? payload[path: "collaboration_mode", "settings", "model"] as? String ?? record.model
        case "task_started":
            context["turn"] = payload["turn_id"] as? String ?? context["turn"]
        case "thread_settings_applied":
            // Fast mode runs on the priority tier, billed at a multiple of the standard rate.
            if let thread = payload["thread_id"] as? String, let own = context["thread"], thread != own { break }
            guard let settings = payload["thread_settings"] as? [String: Any] else { break }
            context["tier"] = settings["service_tier"] as? String
        case "token_usage_record":
            context["records"] = "1"
            guard let usage = payload["usage"] as? [String: Any], let counts = tokens(usage), let time, isOwnTurn else { break }
            // The turn's `token_count`s logged before the file's first record may be these responses, counted
            // until now.
            var counted = (context["counted"] ?? "").split(separator: " ").compactMap { UInt64($0) }
            if let index = counted.firstIndex(where: { record.usage[$0]?.tokens == counts }) {
                record.usage[counted.remove(at: index)] = nil
                context["counted"] = counted.isEmpty ? nil : counted.map(String.init).joined(separator: " ")
            }
            if let thread = payload["thread_id"] as? String, let own = context["thread"], thread != own { break }
            let key = (payload["response_id"] as? String).map { JSONLine.key("codex", $0) } ?? lineKey
            record.usage[key] = UsageRecord(bucket: FileRecord.bucket(time), model: record.model ?? "unknown", tokens: counts,
                                            speed: speed(context["tier"]))
        case "token_count":
            // Superseded by per-response records once a file has them.
            guard context["records"] == nil, let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any],
                  let running = tokens(total), let counts = tokens(last), let time
            else { break }
            guard running != record.runningTotal else { break }
            record.runningTotal = running
            guard isOwnTurn else { break }
            record.usage[lineKey] = UsageRecord(bucket: FileRecord.bucket(time), model: record.model ?? "unknown", tokens: counts,
                                                speed: speed(context["tier"]))
            // A response's record comes soon after its count, so the last few are enough to look through.
            context["counted"] = ((context["counted"] ?? "").split(separator: " ").suffix(15) + [Substring(String(lineKey))]).joined(separator: " ")
        case "item_completed":
            guard let item = payload["item"] as? [String: Any], let itemType = item["type"] as? String,
                  itemType == "UserMessage" || itemType == "AgentMessage", isOwnTurn
            else { break }
            let started = (item["started_at_ms"] as? NSNumber).map { $0.doubleValue / 1000 }
            guard let rawAt = started ?? time, let at = Timestamp.seconds(rawAt) else { break }
            // Migrated rollouts number items per thread (`item-1`), so IDs are only unique within one.
            let key = (item["id"] as? String).map { JSONLine.key("codex-item", context["thread"] ?? "", $0) } ?? lineKey
            if record.messages[key] == nil { record.messages[key] = FileRecord.bucket(at) }
        case "user_message", "agent_message":
            // Rollouts not yet migrated to items.
            guard type == "event_msg", let time, isOwnTurn else { break }
            if record.messages[lineKey] == nil { record.messages[lineKey] = FileRecord.bucket(time) }
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

    /// `input_tokens` includes cache reads and writes; `output_tokens` includes reasoning.
    private static func tokens(_ usage: [String: Any]) -> TokenCounts? {
        guard let input = usage.int("input_tokens"), let output = usage.int("output_tokens"),
              let cacheRead = usage.int("cached_input_tokens"), let cacheWrite = usage.int("cache_write_input_tokens")
        else { return nil }
        return TokenCounts(input: max(0, input - cacheRead - cacheWrite), output: output,
                           cacheRead: cacheRead, cacheWrite: cacheWrite)
    }
}
