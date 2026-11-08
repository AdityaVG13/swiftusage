import Foundation

/// Pi's sessions: `sessions/--<cwd>--/<time>_<id>.jsonl`, one file per session starting with a
/// `session` header. Forks and clones copy entries verbatim (same `id` and `timestamp`) into a new file,
/// so entries are keyed by those and counted once across files.
public enum PiTranscripts: TranscriptFormat {
    public static let provider = Provider.pi
    public static let cacheName = "pi-index.json"
    /// 3: retain each call's provider and response identity for plan attribution.
    public static let cacheVersion = 3
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

    public static func watchedPaths(root: URL) -> [String] {
        ([root] + otherRoots(of: root)).map { $0.resolvingSymlinksInPath().path }
    }

    /// Oh My Pi keeps its own sessions; its older `.zmp` and newer `.omp` names may be aliases.
    static func otherRoots(of root: URL, home: URL = .home) -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PI_CODING_AGENT_DIR"]?.isEmpty ?? true,
              environment["PI_CODING_AGENT_SESSION_DIR"]?.isEmpty ?? true,
              root.standardizedFileURL == home.appendingPathComponent(".pi/agent/sessions").standardizedFileURL
        else { return [] }
        var seen = Set([root.resolvingSymlinksInPath().path])
        return [".omp/agent/sessions", ".zmp/agent/sessions"].map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    public static func discover(in root: URL) -> [String: TranscriptInfo] {
        let sessionDirs = EnvironmentFolders.seen("PI_CODING_AGENT_SESSION_DIR")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        return discover(in: root, others: otherRoots(of: root), includeTopLevel: sessionDirs.contains(root.standardizedFileURL.path))
    }

    static func discover(in root: URL, others: [URL], includeTopLevel: Bool = false) -> [String: TranscriptInfo] {
        var found: [String: TranscriptInfo] = [:]
        var seen = Set<String>()
        for (index, folder) in ([root] + others).enumerated() {
            let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
            let canonical = resolved.path
            guard seen.insert(canonical).inserted,
                  let walker = FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            let prefix = index == 0 ? "" : "@" + String(fnv1a(canonical), radix: 16) + "/"
            let base = canonical + "/"
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base) else { continue }
                let relative = String(path.dropFirst(base.count))
                let depth = relative.split(separator: "/").count
                guard depth > 1 || index > 0 || includeTopLevel else { continue }
                if let info = TranscriptInfo.of(path, isSubagent: depth > 2) {
                    found[prefix + relative] = info
                }
            }
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
                let response = (message["responseId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let plan = plan(for: message["provider"] as? String)
                let scope = plan?.rawValue ?? (message["provider"] as? String ?? "unknown")
                let usageKey = response.map { JSONLine.key("response", scope, $0) } ?? key
                let identity = response.flatMap { id in plan.map { JSONLine.key("plan-response", $0.rawValue, id) } }
                record.usage[usageKey] = UsageRecord(bucket: FileRecord.bucket(time), model: message["model"] as? String ?? record.model ?? "unknown",
                                                     tokens: counts, cost: cost(usage), plan: plan, responseID: identity)
            }
            if role == "user" || role == "assistant", record.messages[key] == nil {
                record.messages[key] = FileRecord.bucket(time)
            }
        case "compaction", "branch_summary", "usage":
            // Summaries and standalone usage entries (such as cache warming) are model calls too. A
            // compaction's retained tail repeats earlier entries and isn't read.
            if let usage = entry["usage"] as? [String: Any], let counts = tokens(usage) {
                let model = entry["model"] as? String ?? entry[path: "details", "modelId"] as? String ?? record.model ?? "unknown"
                record.usage[key] = UsageRecord(bucket: FileRecord.bucket(timestamp), model: model, tokens: counts, cost: cost(usage),
                                                plan: plan(for: entry["provider"] as? String))
            }
        default:
            break
        }
        return true
    }

    /// Only explicit subscription/client routes are attributed; a model name or API provider alone is not proof.
    static func plan(for provider: String?) -> Provider? {
        guard let provider else { return nil }
        if provider == "openai-codex" || provider.range(of: #"^openai-codex-account-[0-9]+$"#, options: .regularExpression) != nil {
            return .codex
        }
        if provider.range(of: #"^cursor-account-[0-9]+$"#, options: .regularExpression) != nil { return .cursor }
        return switch provider {
        case "kimi-code", "kimi-coding": .kimi
        case "muse-code": .muse
        case "xai-oauth", "xai-auth": .grok
        case "opencode-go": .opencode
        case "cursor": .cursor
        case "devin": .devin
        case "google-antigravity": .antigravity
        default: nil
        }
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
