import Foundation

/// Grok's sessions: `sessions/<cwd>/<session id>/updates.jsonl`, the session's append-only event log.
/// Usage is only logged per turn (`turn_completed`), split by model. A parent's turn already includes
/// its subagents' usage, so their nested sessions aren't read.
public enum GrokTranscripts: TranscriptFormat {
    public static let provider = Provider.grok
    public static let cacheName = "grok-index.json"
    /// 2: turns record the cost Grok logs.
    public static let cacheVersion = 2
    public static let upgradableCacheVersion = 1

    public static var defaultRoot: URL {
        (URL.environment("GROK_HOME") ?? .home.appendingPathComponent(".grok")).appendingPathComponent("sessions")
    }

    public static func discover(in root: URL) -> [String: TranscriptInfo] {
        TranscriptFolders.files(in: root, depth: 2) { $0 == "updates.jsonl" }
    }

    public static func ingest(_ line: UnsafeRawBufferPointer, lineOffset: UInt64, pathHash: UInt64, into record: inout FileRecord) -> Bool {
        let isTurn = JSONLine.contains(line, "\"turn_completed\"")
        guard isTurn || JSONLine.contains(line, "\"user_message_chunk\"") else { return true }
        guard let event = JSONLine.object(line) else { return false }
        guard let params = event["params"] as? [String: Any], let update = params["update"] as? [String: Any] else { return true }
        let session = params["sessionId"] as? String ?? String(pathHash)
        let milliseconds = (params[path: "_meta", "agentTimestampMs"] as? NSNumber)?.doubleValue
        guard let rawTime = milliseconds.map({ $0 / 1000 }) ?? (event["timestamp"] as? NSNumber)?.doubleValue,
              let time = Timestamp.seconds(rawTime)
        else { return true }
        let bucket = FileRecord.bucket(time)

        switch update["sessionUpdate"] as? String {
        case "user_message_chunk":
            // One prompt arrives in several chunks; Grok's own follow-ups are marked synthetic.
            guard update[path: "_meta", "syntheticPrompt"] as? Bool != true else { break }
            record.sessionStart = min(record.sessionStart ?? time, time)
            let prompt = (update[path: "_meta", "promptIndex"] as? NSNumber)?.stringValue ?? String(lineOffset)
            let key = JSONLine.key(session, "prompt", prompt)
            if record.messages[key] == nil { record.messages[key] = bucket }
        case "turn_completed":
            guard let usage = update["usage"] as? [String: Any] else { break }
            let prompt = update["prompt_id"] as? String ?? String(lineOffset)
            let byModel = usage["modelUsage"] as? [String: [String: Any]] ?? [record.model ?? "grok": usage]
            var parsed: [(model: String, counts: [String: Any], tokens: TokenCounts, calls: Int)] = []
            for (model, counts) in byModel {
                guard let tokens = tokens(counts), let calls = counts.int("modelCalls"), calls <= 10_000 else { return true }
                parsed.append((model, counts, tokens, Int(calls)))
            }
            record.sessionStart = min(record.sessionStart ?? time, time)
            for (model, counts, tokens, calls) in parsed {
                let key = JSONLine.key(session, prompt, model)
                // Grok logs cost in ticks of 1e-10 dollars.
                let ticks = (counts["costUsdTicks"] as? NSNumber) ?? (byModel.count == 1 ? usage["costUsdTicks"] as? NSNumber : nil)
                record.usage[key] = UsageRecord(bucket: bucket, model: model, tokens: tokens, cost: ticks.map { $0.doubleValue / 1e10 })
                // Each model call is one reply.
                for call in 0..<max(1, calls) {
                    let reply = JSONLine.key(session, prompt, model, String(call))
                    if record.messages[reply] == nil { record.messages[reply] = bucket }
                }
            }
            record.model = byModel.keys.first ?? record.model
        default:
            break
        }
        return true
    }

    /// `inputTokens` includes cached tokens and `outputTokens` includes reasoning.
    private static func tokens(_ usage: [String: Any]) -> TokenCounts? {
        guard let input = usage.int("inputTokens"), let output = usage.int("outputTokens"),
              let cacheRead = usage.int("cachedReadTokens"), let cacheWrite = usage.int("cacheCreationTokens")
        else { return nil }
        return TokenCounts(input: max(0, input - cacheRead - cacheWrite), output: output,
                           cacheRead: cacheRead, cacheWrite: cacheWrite)
    }
}
