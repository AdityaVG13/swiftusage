import Foundation

/// Muse Code's session logs: `sessions/YYYY/MM/DD/<session id>/session.jsonl`, with subagents in
/// `<session dir>/subagent/<id>/session.jsonl`. Each line is one event record. The two that carry what a
/// usage reading needs are `run.model.configured` (`record.model_id`) and `goal_usage_attribution`
/// (`record.usage_id` with `record.quantity`), timestamped by `recorded_at` in microseconds.
public enum MuseTranscripts: TranscriptFormat {
    public static let provider = Provider.muse
    public static let cacheName = "muse-index.json"
    public static let cacheVersion = 3

    public static var defaultRoot: URL {
        let data = URL.environment("XDG_DATA_HOME") ?? .home.appendingPathComponent(".local/share")
        return data.appendingPathComponent("muse/sessions")
    }

    public static func discover(in root: URL) -> [String: TranscriptInfo] {
        var found = TranscriptFolders.files(in: root, depth: 4) { $0 == "session.jsonl" }
        for (relative, _) in found {
            let subagents = root.appendingPathComponent((relative as NSString).deletingLastPathComponent).appendingPathComponent("subagent")
            for (child, info) in TranscriptFolders.files(in: subagents, depth: 1, isSubagent: true, include: { $0 == "session.jsonl" }) {
                found[(relative as NSString).deletingLastPathComponent + "/subagent/" + child] = info
            }
        }
        return found
    }

    public static func ingest(_ line: UnsafeRawBufferPointer, lineOffset: UInt64, pathHash: UInt64, into record: inout FileRecord) -> Bool {
        // Most of a session is streamed text and tool output; only these two record kinds can add anything,
        // so a line that names neither is skipped without being parsed.
        guard JSONLine.contains(line, "\"goal_usage_attribution\"") || JSONLine.contains(line, "\"model_id\"")
        else { return false }
        guard let entry = JSONLine.object(line),
              let payload = entry["payload"] as? [String: Any] else { return true }
        // A run's events carry their record under `event`; a `run.model.configured` payload carries it directly.
        let body = (payload["event"] as? [String: Any])?["record"] as? [String: Any]
            ?? payload["record"] as? [String: Any]
        guard let body else { return true }

        if let model = body["model_id"] as? String {
            record.model = model
            return true
        }

        guard let quantity = body["quantity"] as? [String: Any], let time = recordedTime(entry) else { return true }
        // Tool and reminder records attribute a call again with no counts of their own, and an unreported
        // quantity is Muse saying it doesn't know: neither is a message or a token.
        // A record that names no family is still a call: dropping an unknown shape would lose tokens
        // silently, which is worse than counting a record with no counts.
        if let family = body["usage_family"] as? String, family != "provider", family != "compaction" { return true }
        if let reported = quantity["reported"] as? Bool, !reported { return true }
        if !record.isSubagent { record.sessionStart = min(record.sessionStart ?? time, time) }

        let bucket = FileRecord.bucket(time)
        let lineKey = pathHash ^ (lineOffset &* 0x9E37_79B9_7F4A_7C15)
        let key = (body["usage_id"] as? String).map { JSONLine.key("usage", $0) } ?? lineKey

        // Muse reports the whole prompt as input, cache included, so the cached share is taken back out.
        let prompt = (quantity["input_tokens"] as? NSNumber)?.int64Value ?? 0
        let cached = (quantity["cached_tokens"] as? NSNumber)?.int64Value ?? 0
        let output = (quantity["output_tokens"] as? NSNumber)?.int64Value ?? 0
        let tokens = TokenCounts(input: max(0, prompt - cached), output: output, cacheRead: cached, cacheWrite: 0)
        record.usage[key] = UsageRecord(bucket: bucket, model: record.model ?? "muse", tokens: tokens)
        record.messages[key] = bucket
        return true
    }

    private static func recordedTime(_ entry: [String: Any]) -> Double? {
        guard let raw = entry["recorded_at"] as? NSNumber else { return nil }
        return Timestamp.seconds(raw.doubleValue / 1_000_000)
    }
}
