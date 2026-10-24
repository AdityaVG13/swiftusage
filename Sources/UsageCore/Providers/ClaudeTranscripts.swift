import Foundation

/// Claude Code's transcripts: `<project>/<session>.jsonl`, with subagents in
/// `<project>/<session>/subagents/agent-*.jsonl`. Read from the default config folder's `projects`, and with it
/// every other config folder's, as the limits are; `CLAUDE_CONFIG_DIR` names the one folder to read instead.
public enum ClaudeTranscripts: TranscriptFormat {
    public static let provider = Provider.claude
    public static let cacheName = "transcript-index.json"
    /// 3: responses record their one-hour cache writes and speed, for pricing. 4: responses whose ID isn't
    /// one of a kind are told apart by their request or prompt.
    public static let cacheVersion = 4
    public static let upgradableCacheVersion = 2
    public static let readsUnterminatedLastLine = true

    public static var defaultRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Transcripts in `root` are keyed by their path relative to it, and those in another folder's `projects`
    /// by their full path.
    public static func discover(in root: URL) -> [String: TranscriptInfo] {
        discover(in: root, others: otherRoots(of: root))
    }

    static func discover(in root: URL, others: [URL]) -> [String: TranscriptInfo] {
        var found = discover(projects: root, keyPrefix: "")
        for other in others {
            found.merge(discover(projects: other, keyPrefix: other.path + "/")) { kept, _ in kept }
        }
        return found
    }

    public static func watchedPaths(root: URL) -> [String] {
        [root.path] + otherRoots(of: root).map(\.path)
    }

    /// The other config folders' `projects`, when `root` is the default folder's and `CLAUDE_CONFIG_DIR` isn't set.
    static func otherRoots(of root: URL) -> [URL] {
        guard ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?.isEmpty ?? true,
              root.standardizedFileURL == defaultRoot.standardizedFileURL else { return [] }
        return otherRoots(of: root, home: .home, remembered: EnvironmentFolders.seen("CLAUDE_CONFIG_DIR"))
    }

    /// Every other config folder's `projects`: the folders `CLAUDE_CONFIG_DIR` has named, and any `~/.claude*` or
    /// `~/.config/claude*` folder, such as `~/.claude_personal` for a second account. One that's another's through
    /// a symlink is left out.
    static func otherRoots(of root: URL, home: URL, remembered: [String]) -> [URL] {
        var folders = remembered.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        for (parent, prefix) in [(home, ".claude"), (home.appendingPathComponent(".config"), "claude")] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            folders += names.sorted().filter { $0.hasPrefix(prefix) }.map { parent.appendingPathComponent($0) }
        }
        var seen: Set<String> = [root.resolvingSymlinksInPath().path]
        return folders.map { $0.appendingPathComponent("projects") }.filter { projects in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: projects.path, isDirectory: &isFolder) && isFolder.boolValue
                && seen.insert(projects.resolvingSymlinksInPath().path).inserted
        }
    }

    private static func discover(projects root: URL, keyPrefix: String) -> [String: TranscriptInfo] {
        let fm = FileManager.default
        var found: [String: TranscriptInfo] = [:]
        guard let projects = try? fm.contentsOfDirectory(atPath: root.path) else { return found }

        for project in projects where !project.hasPrefix(".") {
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path + "/" + project) else { continue }
            for entry in entries {
                if entry.hasSuffix(".jsonl") {
                    let relative = project + "/" + entry
                    found[keyPrefix + relative] = TranscriptInfo.of(root.path + "/" + relative)
                    continue
                }
                let subagents = project + "/" + entry + "/subagents"
                guard let agents = try? fm.contentsOfDirectory(atPath: root.path + "/" + subagents) else { continue }
                for agent in agents where agent.hasPrefix("agent-") && agent.hasSuffix(".jsonl") {
                    let relative = subagents + "/" + agent
                    found[keyPrefix + relative] = TranscriptInfo.of(root.path + "/" + relative, isSubagent: true)
                }
                let workflows = subagents + "/workflows"
                for workflow in (try? fm.contentsOfDirectory(atPath: root.path + "/" + workflows)) ?? [] where !workflow.hasPrefix(".") {
                    for agent in (try? fm.contentsOfDirectory(atPath: root.path + "/" + workflows + "/" + workflow)) ?? []
                    where agent.hasPrefix("agent-") && agent.hasSuffix(".jsonl") {
                        let relative = workflows + "/" + workflow + "/" + agent
                        found[keyPrefix + relative] = TranscriptInfo.of(root.path + "/" + relative, isSubagent: true)
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
            let messageID = (parsed.messageIDIsUnique ? message["id"] as? String : nil)
                ?? String(parsed.responseKey ?? pathHash ^ (lineOffset &* 0x9E37_79B9_7F4A_7C15))
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
