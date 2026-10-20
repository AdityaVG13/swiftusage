import Foundation

/// Muse Code's session logs: `sessions/YYYY/MM/DD/<session id>/session.jsonl`, with subagents in
/// `<session dir>/subagent/<id>/session.jsonl`.
///
/// Muse Code wasn't installed when this was written, so the line format is inferred from the events its
/// SDK sends (as T3 Code reads them): a token-usage event per model completion with `promptTokens`
/// (input including cache, counted once) and `usage {outputTokens, cacheReadTokens, cacheWriteTokens,
/// cachedTokens}`, a `modelId`, and `turnId`s. Records are found wherever they sit in a line, so the
/// reader doesn't depend on the envelope around them. A turn's completion event repeats the turn's
/// usage and is skipped.
public enum MuseTranscripts: TranscriptFormat {
    public static let provider = Provider.muse
    public static let cacheName = "muse-index.json"
    public static let cacheVersion = 1

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
        guard let entry = JSONLine.object(line) else { return false }
        let time = timestamp(in: entry)
        if let time { record.sessionStart = min(record.sessionStart ?? time, time) }
        if let model = find("modelId", in: entry) as? String { record.model = model }
        guard let time else { return true }
        let bucket = FileRecord.bucket(time)
        let lineKey = pathHash ^ (lineOffset &* 0x9E37_79B9_7F4A_7C15)

        // A prompt starts a turn: count each turn once, as the user's message.
        if let turn = find("turnId", in: entry) as? String {
            let key = JSONLine.key("turn", turn)
            if record.messages[key] == nil { record.messages[key] = bucket }
        }
        if let event = usageEvent(in: entry), let usage = event["usage"] as? [String: Any] {
            let id = (event["id"] as? String) ?? (entry["id"] as? String)
            let key = id.map { JSONLine.key("usage", $0) } ?? lineKey
            let cacheRead = usage.int("cacheReadTokens") > 0 ? usage.int("cacheReadTokens") : usage.int("cachedTokens")
            let cacheWrite = usage.int("cacheWriteTokens")
            let prompt = event.int("promptTokens")
            let tokens = TokenCounts(input: max(0, prompt - cacheRead - cacheWrite), output: usage.int("outputTokens"),
                                     cacheRead: cacheRead, cacheWrite: cacheWrite)
            record.usage[key] = UsageRecord(bucket: bucket, model: event["modelId"] as? String ?? record.model ?? "muse", tokens: tokens)
            if record.messages[key] == nil { record.messages[key] = bucket }
        }
        return true
    }

    /// The first object (breadth first, a few levels deep) with both `promptTokens` and `usage`.
    private static func usageEvent(in object: [String: Any], depth: Int = 0) -> [String: Any]? {
        if object["promptTokens"] != nil, object["usage"] is [String: Any] { return object }
        guard depth < 4 else { return nil }
        for value in object.values {
            if let child = value as? [String: Any], let found = usageEvent(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func find(_ key: String, in object: [String: Any], depth: Int = 0) -> Any? {
        if let value = object[key] { return value }
        guard depth < 4 else { return nil }
        for value in object.values {
            if let child = value as? [String: Any], let found = find(key, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// An ISO 8601 string or epoch number (seconds or milliseconds) under a usual name.
    private static func timestamp(in object: [String: Any]) -> Double? {
        for key in ["timestamp", "createdAt", "time", "ts"] {
            guard let value = find(key, in: object) else { continue }
            if let string = value as? String, let parsed = Timestamp.parse(string) { return parsed }
            if let number = value as? NSNumber {
                let seconds = number.doubleValue > 1e12 ? number.doubleValue / 1000 : number.doubleValue
                if seconds > 1e9 { return seconds }
            }
        }
        return nil
    }
}
