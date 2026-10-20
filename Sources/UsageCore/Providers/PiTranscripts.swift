import Foundation

/// Pi's sessions: `sessions/--<cwd>--/<time>_<id>.jsonl`, one file per session starting with a
/// `session` header. Forks and clones copy entries verbatim (same `id` and `timestamp`) into a new file,
/// so entries are keyed by those and counted once across files.
public enum PiTranscripts: TranscriptFormat {
    public static let provider = Provider.pi
    public static let cacheName = "pi-index.json"
    /// 2: responses record the cost Pi logs.
    public static let cacheVersion = 2
    public static let upgradableCacheVersion = 1

    public static var defaultRoot: URL {
        if let sessions = URL.environment("PI_CODING_AGENT_SESSION_DIR") {
            _ = EnvironmentFolders.seen("PI_CODING_AGENT_SESSION_DIR")
            return sessions
        }
        if let agent = URL.environment("PI_CODING_AGENT_DIR") {
            return agent.appendingPathComponent("sessions")
        }
        if let remembered = EnvironmentFolders.seen("PI_CODING_AGENT_SESSION_DIR").first {
            return URL(fileURLWithPath: (remembered as NSString).expandingTildeInPath)
        }
        return URL.home.appendingPathComponent(".pi/agent/sessions")
    }

    public static func discover(in root: URL) -> [String: TranscriptInfo] {
        var found = TranscriptFolders.files(in: root, depth: 1) { $0.hasSuffix(".jsonl") }
        let sessionDirs = EnvironmentFolders.seen("PI_CODING_AGENT_SESSION_DIR")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        if sessionDirs.contains(root.standardizedFileURL.path) {
            found.merge(TranscriptFolders.files(in: root, depth: 0) { $0.hasSuffix(".jsonl") }) { kept, _ in kept }
        }
        return found
    }

    public static func ingest(_ line: UnsafeRawBufferPointer, lineOffset: UInt64, pathHash: UInt64, into record: inout FileRecord) -> Bool {
        guard let entry = JSONLine.object(line) else { return false }
        guard let type = entry["type"] as? String,
              let timestamp = (entry["timestamp"] as? String).flatMap(Timestamp.parse)
        else { return true }
        let id = entry["id"] as? String ?? String(lineOffset ^ pathHash)
        let key = JSONLine.key(id, entry["timestamp"] as? String ?? "")

        switch type {
        case "session":
            record.sessionStart = record.sessionStart ?? timestamp
        case "model_change":
            record.model = entry["modelId"] as? String ?? record.model
        case "message":
            guard let message = entry["message"] as? [String: Any], let role = message["role"] as? String else { break }
            // The message's own time is when the request started; the entry's is when it was written.
            let rawTime = (message["timestamp"] as? NSNumber).map { $0.doubleValue / 1000 } ?? timestamp
            guard let time = Timestamp.seconds(rawTime) else { break }
            if role == "assistant", let model = message["model"] as? String { record.model = model }
            if let usage = message["usage"] as? [String: Any] {
                guard let counts = tokens(usage) else { break }
                let usageKey = (message["responseId"] as? String).map { JSONLine.key("response", $0) } ?? key
                record.usage[usageKey] = UsageRecord(bucket: FileRecord.bucket(time), model: message["model"] as? String ?? record.model ?? "unknown",
                                                     tokens: counts, cost: cost(usage))
            }
            if role == "user" || role == "assistant", record.messages[key] == nil {
                record.messages[key] = FileRecord.bucket(time)
            }
        case "compaction", "branch_summary", "usage":
            // Summaries and standalone usage entries (such as cache warming) are model calls too. A
            // compaction's retained tail repeats earlier entries and isn't read.
            if let usage = entry["usage"] as? [String: Any], let counts = tokens(usage) {
                let model = entry["model"] as? String ?? entry[path: "details", "modelId"] as? String ?? record.model ?? "unknown"
                record.usage[key] = UsageRecord(bucket: FileRecord.bucket(timestamp), model: model, tokens: counts, cost: cost(usage))
            }
        default:
            break
        }
        return true
    }

    /// Pi prices each response itself, in dollars.
    private static func cost(_ usage: [String: Any]) -> Double? {
        (usage[path: "cost", "total"] as? NSNumber)?.doubleValue
    }

    /// `input` is already uncached and `reasoning` is part of `output`.
    private static func tokens(_ usage: [String: Any]) -> TokenCounts? {
        guard let input = usage.int("input"), let output = usage.int("output"),
              let cacheRead = usage.int("cacheRead"), let cacheWrite = usage.int("cacheWrite")
        else { return nil }
        return TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }
}
