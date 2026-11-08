import Foundation

/// Factory Droid's sessions, `sessions/<project>/<session id>.jsonl` with `<session id>.settings.json`
/// beside each: the model the session ran on and the tokens its calls have used so far, kept up to
/// date as it runs. The transcript carries no usage of its own, so the totals are read here and the
/// messages are read by `DroidTranscripts`.
///
/// A session's total is one figure for the whole of it, so a session that ran over several days is
/// counted as one that began the first day and ended the last: the stats keep its tokens in the total
/// and leave them out of the days they can't be split across, rather than pinning them on one day.
///
/// `tokenUsage` counts the session's own calls. `inclusiveTokenUsage` adds the sessions it started,
/// and those are sessions with settings files of their own, which are read here too, so the inclusive
/// figure is never the one counted. A session that switched models names only its last one, and its
/// tokens go to that model.
public actor DroidSource: UsageSource {
    public nonisolated let provider = Provider.droid
    public nonisolated let root: URL
    private var sessions: [String: Session] = [:]

    public init(root: URL = DroidSource.defaultRoot) {
        self.root = root
    }

    /// Droid joins `.factory` to the home folder, or to `FACTORY_HOME_OVERRIDE` when it names another one.
    public static var defaultRoot: URL {
        (URL.environment("FACTORY_HOME_OVERRIDE") ?? .home)
            .appendingPathComponent(".factory/sessions")
    }

    public nonisolated var watchedPaths: [String] { [root.path] }

    public func refresh(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        var live: [String: Session] = [:]
        for (path, info) in found() {
            if let kept = sessions[path], kept.size == info.size, kept.modified == info.modified, kept.inode == info.inode {
                live[path] = kept
            } else if let session = Session.read(path: path, stamp: info) {
                live[path] = session
            }
        }
        sessions = live
        return aggregate()
    }

    public func rebuild(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        sessions = [:]
        return await refresh(progress: progress)
    }

    public func save() {}

    /// Every `<session id>.settings.json` under the root, by path. The `.bak` copy beside each is the
    /// file as it was before the last write and is left out.
    private func found() -> [String: TranscriptInfo] {
        let fm = FileManager.default
        var found: [String: TranscriptInfo] = [:]
        for project in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !project.hasPrefix(".") {
            let folder = root.path + "/" + project
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".settings.json") {
                let path = folder + "/" + name
                if let info = TranscriptInfo.of(path) { found[path] = info }
            }
        }
        return found
    }

    private func aggregate() -> UsageData {
        var data = UsageData()
        // Droid copies a session's files beside the new project when a workspace moves, so one
        // session can sit in two folders. One id is one session: the copy that counted the most
        // holds its total, and the other adds nothing.
        var byID: [String: Session] = [:]
        for session in sessions.values {
            if let kept = byID[session.id], kept.tokens.total >= session.tokens.total { continue }
            byID[session.id] = session
        }
        var records: [UsageRecord] = []
        records.reserveCapacity(byID.count)
        for session in byID.values {
            guard session.tokens.total > 0 else { continue }
            let last = FileRecord.bucket(session.last)
            let first = FileRecord.bucket(session.first)
            var record = UsageRecord(bucket: last, model: session.model, tokens: session.tokens)
            if first < last { record.firstBucket = first }
            records.append(record)
        }
        data.usage = records
        data.scannedAt = Date()
        return data
    }

    struct Session: Sendable {
        /// The settings file's own name: one session id, wherever Droid copied it.
        var id: String
        /// The settings file's stamp, which changes with every call the session makes.
        var size: UInt64
        var modified: Double
        var inode: UInt64
        var model: String
        var tokens: TokenCounts
        /// When the session's first and last messages were written.
        var first: Double
        var last: Double

        static func read(path: String, stamp: TranscriptInfo) -> Session? {
            guard let data = FileManager.default.contents(atPath: path),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let usage = object["tokenUsage"] as? [String: Any]
            else { return nil }
            // Droid names the model the session ran on; a session that switched models keeps its last.
            let model = (object["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            // Thinking is billed as output, and Droid counts it apart from the answer.
            let tokens = TokenCounts(input: usage.int("inputTokens") ?? 0,
                                     output: (usage.int("outputTokens") ?? 0) + (usage.int("thinkingTokens") ?? 0),
                                     cacheRead: usage.int("cacheReadTokens") ?? 0,
                                     cacheWrite: usage.int("cacheCreationTokens") ?? 0)
            let transcript = String(path.dropLast(".settings.json".count)) + ".jsonl"
            let span = timestamps(ofTranscript: transcript) ?? (stamp.modified, stamp.modified)
            let id = URL(fileURLWithPath: path).deletingPathExtension().deletingPathExtension().lastPathComponent
            return Session(id: id, size: stamp.size, modified: stamp.modified, inode: stamp.inode,
                           model: model, tokens: tokens, first: span.first, last: span.last)
        }

        /// The first and last `"timestamp"` in a transcript, read from its first and last 64 KB so a
        /// session of any size costs two small reads.
        static func timestamps(ofTranscript path: String) -> (first: Double, last: Double)? {
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var status = stat()
            guard fstat(fd, &status) == 0, status.st_size > 0 else { return nil }
            let size = Int(status.st_size)
            let window = 64 << 10

            func scan(from offset: Int, count: Int, keepingLast: Bool) -> Double? {
                var bytes = [UInt8](repeating: 0, count: count)
                let read = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
                guard read == count else { return nil }
                let needle = Array("\"timestamp\":".utf8)
                return bytes.withUnsafeBytes { raw -> Double? in
                    guard let base = raw.baseAddress else { return nil }
                    var found: Double?
                    var position = 0
                    while position < raw.count {
                        let located = needle.withUnsafeBytes { key in
                            memmem(base + position, raw.count - position, key.baseAddress, key.count)
                        }
                        guard let hit = located else { break }
                        var start = base.distance(to: UnsafeRawPointer(hit)) + needle.count
                        // Space is optional in JSON, and a writer may put it in.
                        while start < raw.count, (base + start).load(as: UInt8.self) == UInt8(ascii: " ") { start += 1 }
                        guard start < raw.count,
                              let quote = memchr(base + start, Int32(UInt8(ascii: "\"")), raw.count - start),
                              base.distance(to: UnsafeRawPointer(quote)) == start,
                              let close = memchr(base + start + 1, Int32(UInt8(ascii: "\"")), raw.count - start - 1)
                        else { break }
                        let end = base.distance(to: UnsafeRawPointer(close))
                        guard let time = Timestamp.parse((base + start + 1).assumingMemoryBound(to: UInt8.self), count: end - start - 1)
                        else { break }
                        found = time
                        guard keepingLast else { return time }
                        position = end + 1
                    }
                    return found
                }
            }

            let first = scan(from: 0, count: min(size, window), keepingLast: false)
            // A session that grew past one window is dated by its last window; a shorter one, read
            // whole, by its last timestamp.
            let last = scan(from: max(0, size - window), count: min(size, window), keepingLast: true)
            guard let first, let last else { return nil }
            return (first, last)
        }
    }
}
