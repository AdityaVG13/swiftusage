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
            }
        }
        return found
    }

    public static func ingest(_ line: UnsafeRawBufferPointer, lineOffset: UInt64, pathHash: UInt64, into record: inout FileRecord) -> Bool {
        guard let parsed = TranscriptLine.parse(line) else { return false }
        record.ingest(parsed, lineOffset: lineOffset, pathHash: pathHash)
        return true
    }
}

/// Claude Code's index, under the name the app has always used for it.
public typealias UsageIndex = TranscriptIndex<ClaudeTranscripts>

extension TranscriptIndex where Format == ClaudeTranscripts {
    public init(projectsURL: URL = ClaudeTranscripts.defaultRoot, cacheURL: URL? = UsageIndex.defaultCacheURL) {
        self.init(root: projectsURL, cacheURL: cacheURL)
    }

    public nonisolated var projectsURL: URL { root }

    public static func discoverTranscripts(in root: URL) -> [String: TranscriptInfo] {
        ClaudeTranscripts.discover(in: root)
    }
}
