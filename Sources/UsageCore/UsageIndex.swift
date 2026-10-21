import Foundation

/// Raw usage across every transcript, independent of time zone and date range.
public struct UsageData: Sendable {
    public var sessionStarts: [Double] = []
    /// Quarter-hour bucket → main-thread messages.
    public var messageBuckets: [Int32: Int] = [:]
    /// One record per model response, deduplicated across all transcripts.
    public var usage: [UsageRecord] = []
    public var transcriptCount = 0
    public var scannedAt = Date()

    public init() {}

    public var isEmpty: Bool { sessionStarts.isEmpty && usage.isEmpty && messageBuckets.isEmpty }

    /// Whether two reads found the same history, whenever each was made. Sources that rebuild their
    /// history from dictionaries list it in another order on each read, so the order doesn't count.
    public func sameHistory(as other: UsageData) -> Bool {
        guard transcriptCount == other.transcriptCount, sessionStarts.count == other.sessionStarts.count,
              usage.count == other.usage.count, messageBuckets == other.messageBuckets else { return false }
        if sessionStarts == other.sessionStarts, usage == other.usage { return true }
        // Sorting a large history on every streamed reply would cost a tenth of a second.
        return sessionStarts.sorted() == other.sessionStarts.sorted() && Self.digest(usage) == Self.digest(other.usage)
    }

    /// The same for the same records in any order, and for different ones all but never.
    private static func digest(_ records: [UsageRecord]) -> (UInt64, UInt64) {
        var sum: UInt64 = 0, squares: UInt64 = 0
        for record in records {
            let hash = UInt64(bitPattern: Int64(record.hashValue))
            sum &+= hash
            squares &+= hash &* hash
        }
        return (sum, squares)
    }

    /// Several providers' usage as one.
    public static func merged(_ parts: [UsageData]) -> UsageData {
        var data = UsageData()
        for part in parts {
            data.sessionStarts += part.sessionStarts
            data.messageBuckets.merge(part.messageBuckets, uniquingKeysWith: +)
            data.usage += part.usage
            data.transcriptCount += part.transcriptCount
        }
        data.scannedAt = parts.map(\.scannedAt).max() ?? Date()
        return data
    }
}

public struct ScanProgress: Sendable {
    public var bytesRead: Int64
    public var bytesTotal: Int64
    public var filesDone: Int
    public var filesTotal: Int

    public init(bytesRead: Int64, bytesTotal: Int64, filesDone: Int, filesTotal: Int) {
        self.bytesRead = bytesRead
        self.bytesTotal = bytesTotal
        self.filesDone = filesDone
        self.filesTotal = filesTotal
    }

    public var fraction: Double { bytesTotal > 0 ? Double(bytesRead) / Double(bytesTotal) : 0 }
}

/// Where one provider's usage comes from. Each source keeps its own state and is refreshed on its own.
public protocol UsageSource: Actor {
    nonisolated var provider: Provider { get }
    /// Folders whose changes mean there may be new usage. Missing ones are skipped.
    nonisolated var watchedPaths: [String] { get }
    /// Brings the source up to date and returns everything it knows.
    func refresh(progress: (@Sendable (ScanProgress) -> Void)?) async -> UsageData
    /// Forgets saved state and reads everything again.
    func rebuild(progress: (@Sendable (ScanProgress) -> Void)?) async -> UsageData
    /// Writes saved state to disk, if the source keeps any.
    func save()
}

public struct TranscriptInfo: Sendable {
    public var path: String
    public var size: UInt64
    var modified: Double
    var inode: UInt64
    var isSubagent: Bool

    /// Stats `path`; nil unless it's a regular file.
    static func of(_ path: String, isSubagent: Bool = false) -> TranscriptInfo? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return TranscriptInfo(path: path, size: UInt64(st.st_size), modified: modified, inode: UInt64(st.st_ino), isSubagent: isSubagent)
    }
}

/// How one tool lays out and writes its append-only JSONL transcripts.
public protocol TranscriptFormat: Sendable {
    static var provider: Provider { get }
    /// Name of the saved index in the app's cache folder.
    static var cacheName: String { get }
    /// Bumped when `ingest` changes what it records, so old saved indexes are read again.
    static var cacheVersion: Int { get }
    /// The oldest saved index that can be upgraded rather than discarded: its transcripts still on disk
    /// are read again, and its summaries of deleted ones carry over.
    static var upgradableCacheVersion: Int { get }
    /// Every transcript under `root`, keyed by path relative to it.
    static func discover(in root: URL) -> [String: TranscriptInfo]
    /// Folds one line into its transcript's record. Returns false for a line that isn't a whole JSON
    /// object, which at the end of a file means it's still being written.
    static func ingest(_ line: UnsafeRawBufferPointer, lineOffset: UInt64, pathHash: UInt64, into record: inout FileRecord) -> Bool
    /// Reads `path` from `record.offset` into `record`.
    static func read(path: String, into record: inout FileRecord) -> Bool
    /// Folders to watch for changes, if not all of `root`.
    static func watchedPaths(root: URL) -> [String]
    /// Whether a last line without a newline is read when it parses. Formats that skip lines without
    /// parsing them can't tell a finished line from a half-written one, so they wait for the newline.
    static var readsUnterminatedLastLine: Bool { get }
}

extension TranscriptFormat {
    public static var upgradableCacheVersion: Int { cacheVersion }
    public static var readsUnterminatedLastLine: Bool { false }
    public static func watchedPaths(root: URL) -> [String] { [root.path] }
    public static func read(path: String, into record: inout FileRecord) -> Bool {
        TranscriptReader.read(path: path, into: &record, unterminated: readsUnterminatedLastLine, ingest: ingest)
    }
}

/// Keeps a per-transcript summary of one tool's transcripts, re-reading only bytes appended since the
/// last scan, and persists it so a relaunch doesn't have to read gigabytes of history again.
public actor TranscriptIndex<Format: TranscriptFormat>: UsageSource {
    /// Saving re-encodes the whole index, so during heavy use it's batched. Losing unsaved progress
    /// only means re-reading the bytes appended since the last save.
    private static var saveInterval: TimeInterval { 300 }

    public nonisolated let root: URL
    private var cacheURL: URL?
    /// Set once the index has moved beside another folder's, which keeps the file it found.
    private var cacheKeyedByRoot = false
    private var records: [String: FileRecord] = [:]
    private var loadedCache = false
    /// Set when the saved index is from an older version: the next scan reads every transcript still on
    /// disk again and keeps the summaries of the rest.
    private var upgrading = false
    /// The saved index's version until every transcript on disk has been read again, so an index saved
    /// part way through the upgrade (the app quitting, say) is upgraded again on the next launch.
    private var upgradingFrom: Int?
    /// Set when the saved index belongs to a newer build or another folder: it's left untouched.
    private var savingDisabled = false
    private var dirty = false
    private var lastSave = Date.distantPast
    private var inFlight: Task<UsageData, Never>?
    private var rerunRequested = false
    /// The last aggregate, reused while no transcript changes.
    private var aggregated: UsageData?

    public init(root: URL, cacheURL: URL?, readOnly: Bool = false) {
        self.root = root
        self.cacheURL = cacheURL
        savingDisabled = readOnly
    }

    public static var defaultCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.tasteskill.UsageGraphs/" + Format.cacheName)
    }

    public nonisolated var provider: Provider { Format.provider }
    public nonisolated var watchedPaths: [String] { Format.watchedPaths(root: root) }

    /// Brings the index up to date and returns the aggregate. Concurrent callers share one scan;
    /// a call that arrives mid-scan schedules one more pass so late changes aren't missed.
    public func refresh(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        if let inFlight {
            rerunRequested = true
            return await inFlight.value
        }
        let task = Task { await self.scanUntilSettled(progress: progress) }
        inFlight = task
        return await task.value
    }

    /// Drops the index and reads every transcript from scratch.
    public func rebuild(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        while let inFlight { _ = await inFlight.value }
        // Loaded first all the same, for where the index is saved and whether this run may replace it.
        if !loadedCache { loadCache() }
        records = [:]
        aggregated = nil
        dirty = true
        return await refresh(progress: progress)
    }

    public func save() {
        guard dirty, !savingDisabled, let cacheURL else { return }
        let file = IndexFile.encode(version: upgradingFrom ?? Format.cacheVersion, root: root.path, records: records)
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.withUnsafeBytes { bytes in
                try Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), count: bytes.count, deallocator: .none)
                    .write(to: Self.binaryURL(cacheURL), options: .atomic)
            }
            dirty = false
            lastSave = Date()
        } catch {
            NSLog("swiftusage: could not save \(Format.cacheName): \(error)")
        }
    }

    private func scanUntilSettled(progress: (@Sendable (ScanProgress) -> Void)?) async -> UsageData {
        var data = await scan(progress: progress)
        while rerunRequested {
            rerunRequested = false
            data = await scan(progress: nil)
        }
        // Cleared here rather than by the caller, so whoever the finished scan wakes first finds none under way.
        inFlight = nil
        return data
    }

    private func scan(progress: (@Sendable (ScanProgress) -> Void)?) async -> UsageData {
        if !loadedCache { loadCache() }

        let found = Format.discover(in: root)
        // Upgrading reads every transcript still on disk from the start. Their old summaries stay until
        // the new ones are read, so a file that can't be read keeps what it had. A folder with none at all
        // (one on a volume that isn't mounted yet) leaves the upgrade for when it has some.
        let finishesUpgrade = upgrading && !found.isEmpty
        let rereading = finishesUpgrade ? Set(found.keys) : []
        if finishesUpgrade { upgrading = false }
        var jobs: [Job] = []
        var changed = false
        for (key, info) in found {
            if records[key]?.missingSince != nil {
                records[key]?.missingSince = nil
                changed = true
            }
            if !rereading.contains(key), let record = records[key], record.size == info.size, record.modified == info.modified, record.inode == info.inode {
                continue
            }
            var record = rereading.contains(key) ? FileRecord(isSubagent: info.isSubagent) : records[key] ?? FileRecord(isSubagent: info.isSubagent)
            // A shrunk, replaced or compressed file can't be resumed from the old offset.
            if record.inode != info.inode || info.size < record.offset || info.path.hasSuffix(".zst") {
                record = FileRecord(isSubagent: info.isSubagent)
            }
            record.size = info.size
            record.modified = info.modified
            record.inode = info.inode
            jobs.append(Job(key: key, path: info.path, record: record))
        }

        let now = Date().timeIntervalSince1970
        for key in records.keys where found[key] == nil && records[key]?.missingSince == nil {
            records[key]?.missingSince = now
            changed = true
        }

        if !jobs.isEmpty {
            let archives = Dictionary(jobs.filter { $0.path.hasSuffix(".zst") }.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            jobs.sort { ($0.record.size - min($0.record.offset, $0.record.size)) > ($1.record.size - min($1.record.offset, $1.record.size)) }
            let total = jobs.reduce(Int64(0)) { $0 + Int64($1.record.size - min($1.record.offset, $1.record.size)) }
            var bytesDone: Int64 = 0
            var filesDone = 0
            progress?(ScanProgress(bytesRead: 0, bytesTotal: total, filesDone: 0, filesTotal: jobs.count))

            await withTaskGroup(of: (String, FileRecord?, Int64).self) { group in
                for job in jobs {
                    group.addTask {
                        var record = job.record
                        let start = record.offset
                        guard Format.read(path: job.path, into: &record) else { return (job.key, nil, 0) }
                        return (job.key, record, Int64(record.offset - min(start, record.offset)))
                    }
                }
                for await (key, record, bytes) in group {
                    // A file that couldn't be read (deleted mid-scan, not readable) keeps its last
                    // summary and is tried again next time.
                    if let record {
                        records[key] = record
                    } else if let archive = archives[key], Self.opens(archive.path) {
                        // A damaged archive only fails once it's been read through, so rather than being
                        // decompressed again on every pass it waits for another copy, keeping what it had. One
                        // that couldn't even be opened (its permissions, say) is tried again like any file.
                        var kept = records[key] ?? archive.record
                        (kept.size, kept.modified, kept.inode) = (archive.record.size, archive.record.modified, archive.record.inode)
                        records[key] = kept
                    } else if rereading.contains(key) {
                        records[key]?.inode = 0
                    }
                    bytesDone += bytes
                    filesDone += 1
                    progress?(ScanProgress(bytesRead: min(bytesDone, total), bytesTotal: total, filesDone: filesDone, filesTotal: jobs.count))
                }
            }
        }

        if finishesUpgrade { upgradingFrom = nil }

        if !jobs.isEmpty || changed {
            dirty = true
            aggregated = nil
            let coldScan = jobs.count > 50
            if coldScan || Date().timeIntervalSince(lastSave) > Self.saveInterval { save() }
        }
        var data = aggregated ?? aggregate(records)
        aggregated = data
        data.scannedAt = Date()
        return data
    }

    /// Combines per-transcript summaries, counting anything that appears in several transcripts once.
    func aggregate(_ records: [String: FileRecord]) -> UsageData {
        var data = UsageData()
        // Transcripts on disk come first, so an archived copy of a moved file is the one set aside.
        let ordered = records.keys.sorted { a, b in
            let aMissing = records[a]?.missingSince != nil, bMissing = records[b]?.missingSince != nil
            return aMissing != bMissing ? !aMissing : a < b
        }.compactMap { records[$0] }
        data.transcriptCount = ordered.count { $0.missingSince == nil }

        // Tokens: one record per response across every transcript, keeping the largest usage seen.
        var responses: [UInt64: UsageRecord] = [:]
        for record in ordered {
            for (id, usage) in record.usage {
                if let kept = responses[id], kept.tokens.total >= usage.tokens.total { continue }
                responses[id] = usage
            }
        }
        data.usage = Array(responses.values)

        // Messages: each main-thread entry once, however many transcripts carry a copy of it.
        let sessions = ordered.filter { !$0.isSubagent }
        var holders: [UInt64: Int] = [:]
        var counted = Set<UInt64>()
        for record in sessions {
            for (key, bucket) in record.messages {
                holders[key, default: 0] += 1
                if counted.insert(key).inserted { data.messageBuckets[bucket, default: 0] += 1 }
            }
        }
        var positionsByKey: [UInt64: [Int]] = [:]
        for (position, record) in sessions.enumerated() {
            for key in record.messages.keys where holders[key, default: 0] > 1 {
                positionsByKey[key, default: []].append(position)
            }
        }

        // Sessions: a transcript whose every message also lives in a larger transcript (or an
        // identical one listed earlier) is a copy, such as the original of a continued session or an
        // archived duplicate, not a session of its own. Forks keep their own messages, so they count.
        func isCopy(_ position: Int) -> Bool {
            let messages = sessions[position].messages
            guard let probe = messages.keys.first, messages.keys.allSatisfy({ holders[$0, default: 0] > 1 }) else { return false }
            for other in positionsByKey[probe] ?? [] where other != position {
                let candidate = sessions[other]
                let larger = candidate.messages.count > messages.count || (candidate.messages.count == messages.count && other < position)
                if larger, messages.keys.allSatisfy({ candidate.messages[$0] != nil }) { return true }
            }
            return false
        }
        for (position, record) in sessions.enumerated() {
            // A saved start the readers couldn't have written (a damaged index's NaN) is no time at all.
            guard let start = record.sessionStart.flatMap(Timestamp.seconds), !isCopy(position) else { continue }
            data.sessionStarts.append(start)
        }
        return data
    }

    private static func opens(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// Where the index is saved: beside `cacheURL`, where earlier versions kept it as JSON. That copy is
    /// read while there's no other, and left for those versions.
    static func binaryURL(_ cacheURL: URL) -> URL {
        cacheURL.deletingPathExtension().appendingPathExtension("bin")
    }

    private func loadCache() {
        loadedCache = true
        guard let cacheURL else { return }
        let binaryURL = Self.binaryURL(cacheURL)
        var file: CacheFile?
        var header: CacheHeader?
        // Mapped rather than copied in: it's only read once, record by record.
        if let raw = try? Data(contentsOf: binaryURL, options: .alwaysMapped) {
            let read = IndexFile.header(raw)
            file = IndexFile.decode(raw).map { CacheFile(version: $0.header.version, root: $0.header.root, records: $0.records) }
            header = read.map { CacheHeader(version: $0.version, root: $0.root, newerFormat: $0.format > IndexFile.format) }
            // A newer build's file or another folder's is dealt with below. One of this folder's that won't read,
            // or claims a version no build could have written, is set aside rather than overwritten, since it
            // may hold the only record of deleted transcripts, and the JSON beside it is read instead.
            let foreign = read.map { $0.format > IndexFile.format || $0.root != root.path } ?? false
            let plausible = read.map { (0...Format.cacheVersion + 1000).contains($0.version) } ?? false
            if !foreign, file == nil || !plausible {
                if !savingDisabled { UnreadableFile.setAside(binaryURL) }
                (file, header) = (nil, nil)
            }
        }
        let savedAsJSON = header == nil
        if savedAsJSON {
            // A newer build's records may not decode here, so only its header is read then.
            guard let raw = try? Data(contentsOf: cacheURL) else { return }
            let decoder = JSONDecoder()
            file = try? decoder.decode(CacheFile.self, from: raw)
            header = file.map { CacheHeader(version: $0.version, root: $0.root) } ?? (try? decoder.decode(CacheHeader.self, from: raw))
        }
        if let header, header.root != root.path, !cacheKeyedByRoot {
            // Another folder's index (a different `CLAUDE_CONFIG_DIR`) stays as it is; this folder's lives beside it.
            self.cacheURL = cacheURL.deletingPathExtension()
                .appendingPathExtension(String(fnv1a(root.path), radix: 16)).appendingPathExtension(cacheURL.pathExtension)
            cacheKeyedByRoot = true
            return loadCache()
        }
        // Nor is a newer build's index this run's to replace.
        if let header, header.root != root.path || header.version > Format.cacheVersion || header.newerFormat {
            savingDisabled = true
            return
        }
        guard let file, file.version >= Format.upgradableCacheVersion else {
            if !savedAsJSON, !savingDisabled { UnreadableFile.setAside(binaryURL) }
            return
        }
        records = file.records
        if file.version == Format.cacheVersion {
            lastSave = Date()
            if savedAsJSON { dirty = true }
        } else {
            upgrading = true
            upgradingFrom = file.version
            dirty = true
        }
    }

    private struct Job: Sendable {
        var key: String
        var path: String
        var record: FileRecord
    }

    private struct CacheHeader: Decodable {
        var version: Int
        var root: String
        var newerFormat = false

        enum CodingKeys: CodingKey {
            case version, root
        }
    }

    private struct CacheFile: Decodable {
        var version: Int
        var root: String
        var records: [String: FileRecord]
    }
}

enum UnreadableFile {
    /// Moves `url` to `<url>.unreadable-<yyyyMMdd-HHmmss>` (or `-2`, `-3`… if that name is taken), never
    /// deleting or overwriting an earlier set-aside copy.
    static func setAside(_ url: URL, now: Date = Date()) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "unreadable-" + formatter.string(from: now)
        let fm = FileManager.default
        for attempt in 1...1000 {
            let ext = attempt == 1 ? base : "\(base)-\(attempt)"
            let aside = url.appendingPathExtension(ext)
            guard !fm.fileExists(atPath: aside.path) else { continue }
            if (try? fm.moveItem(at: url, to: aside)) != nil { return }
        }
    }
}

/// A file listing helper for formats that keep transcripts a fixed number of folders deep.
enum TranscriptFolders {
    /// Every file under `root` exactly `depth` folders down whose name passes `include`, keyed by
    /// relative path. Hidden entries are skipped.
    static func files(in root: URL, depth: Int, isSubagent: Bool = false, include: (String) -> Bool) -> [String: TranscriptInfo] {
        let fm = FileManager.default
        var found: [String: TranscriptInfo] = [:]
        func walk(_ relative: String, _ level: Int) {
            let path = relative.isEmpty ? root.path : root.path + "/" + relative
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return }
            for entry in entries where !entry.hasPrefix(".") {
                let child = relative.isEmpty ? entry : relative + "/" + entry
                if level == depth {
                    if include(entry), let info = TranscriptInfo.of(root.path + "/" + child, isSubagent: isSubagent) {
                        found[child] = info
                    }
                } else {
                    walk(child, level + 1)
                }
            }
        }
        walk("", 0)
        return found
    }
}
