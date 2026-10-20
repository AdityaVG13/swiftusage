import Foundation

/// Claude Code's transcripts: `<project>/<session>.jsonl`, with subagents in
/// `<project>/<session>/subagents/agent-*.jsonl`.
public enum ClaudeTranscripts: TranscriptFormat {
    public static let provider = Provider.claude
    public static let cacheName = "transcript-index.json"
    /// 3: responses record their one-hour cache writes and speed, for pricing.
    public static let cacheVersion = 3
    public static let upgradableCacheVersion = 2
    public static let readsUnterminatedLastLine = true

    public static var defaultRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    public static func discover(in root: URL) -> [String: TranscriptInfo] {
        let fm = FileManager.default
        var found: [String: TranscriptInfo] = [:]
        guard let projects = try? fm.contentsOfDirectory(atPath: root.path) else { return found }

        for project in projects where !project.hasPrefix(".") {
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path + "/" + project) else { continue }
            for entry in entries {
                if entry.hasSuffix(".jsonl") {
                    let relative = project + "/" + entry
                    found[relative] = TranscriptInfo.of(root.path + "/" + relative)
                    continue
                }
                let subagents = project + "/" + entry + "/subagents"
                guard let agents = try? fm.contentsOfDirectory(atPath: root.path + "/" + subagents) else { continue }
                for agent in agents where agent.hasPrefix("agent-") && agent.hasSuffix(".jsonl") {
                    let relative = subagents + "/" + agent
                    found[relative] = TranscriptInfo.of(root.path + "/" + relative, isSubagent: true)
                }
                let workflows = subagents + "/workflows"
                for workflow in (try? fm.contentsOfDirectory(atPath: root.path + "/" + workflows)) ?? [] where !workflow.hasPrefix(".") {
                    for agent in (try? fm.contentsOfDirectory(atPath: root.path + "/" + workflows + "/" + workflow)) ?? []
                    where agent.hasPrefix("agent-") && agent.hasSuffix(".jsonl") {
                        let relative = workflows + "/" + workflow + "/" + agent
                        found[relative] = TranscriptInfo.of(root.path + "/" + relative, isSubagent: true)
                    }
                }
            }
        }
        return found
    }

    public static func ingest(_ line: UnsafeRawBufferPointer, lineOffset: UInt64, pathHash: UInt64, into record: inout FileRecord) -> Bool {
        guard let parsed = TranscriptLine.parse(line) else { return false }
        record.ingest(parsed, lineOffset: lineOffset, pathHash: pathHash)
        if JSONLine.contains(line, "\"advisor_message\""), let timestamp = parsed.timestamp,
           let entry = JSONLine.object(line), let message = entry["message"] as? [String: Any],
           let iterations = message[path: "usage", "iterations"] as? [[String: Any]] {
            let bucket = FileRecord.bucket(timestamp)
            let messageID = (message["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(parsed.messageID != 0 ? parsed.messageID : pathHash ^ (lineOffset &* 0x9E37_79B9_7F4A_7C15))
            for (index, item) in iterations.enumerated() where item["type"] as? String == "advisor_message" {
                guard let input = item.int("input_tokens"), let output = item.int("output_tokens"),
                      let cacheRead = item.int("cache_read_input_tokens"), let cacheWrite = item.int("cache_creation_input_tokens"),
                      let cacheWriteHour = ((item["cache_creation"] as? [String: Any]) ?? [:]).int("ephemeral_1h_input_tokens")
                else { continue }
                let model = (item["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? parsed.model ?? "unknown"
                let speed: Speed = item["speed"] as? String == "fast" ? .fast : .standard
                let tokens = TokenCounts(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
                let key = JSONLine.key(messageID, "advisor", String(index))
                if let existing = record.usage[key], existing.tokens.total > tokens.total { continue }
                record.usage[key] = UsageRecord(bucket: bucket, model: model, tokens: tokens, cacheWriteHour: cacheWriteHour, speed: speed)
            }
        }
        return true
    }
}

/// Claude Code's index, under the name the app has always used for it.
public typealias UsageIndex = TranscriptIndex<ClaudeTranscripts>

extension TranscriptIndex where Format == ClaudeTranscripts {
    public init(projectsURL: URL = ClaudeTranscripts.defaultRoot, cacheURL: URL? = UsageIndex.defaultCacheURL, readOnly: Bool = false) {
        self.init(root: projectsURL, cacheURL: cacheURL, readOnly: readOnly)
    }

    public nonisolated var projectsURL: URL { root }

    public static func discoverTranscripts(in root: URL) -> [String: TranscriptInfo] {
        ClaudeTranscripts.discover(in: root)
    }
}
