import Foundation

/// One model response's token usage, deduplicated by response ID.
public struct UsageRecord: Codable, Sendable, Hashable {
    /// Quarter-hour bucket since 1970 (UTC). Every real time zone offset is a whole number of
    /// quarter hours, so this converts to an exact local day without storing full timestamps.
    public var bucket: Int32
    public var model: String
    public var tokens: TokenCounts
    /// The part of `tokens.cacheWrite` cached for an hour, which Claude bills higher.
    public var cacheWriteHour: Int64 = 0
    public var speed: Speed = .standard
    /// Dollars, for tools that log what each response cost (Grok, Pi, OpenCode). Never infinite or NaN,
    /// which a database's REAL column can hold.
    public var cost: Double?

    public init(bucket: Int32, model: String, tokens: TokenCounts, cacheWriteHour: Int64 = 0, speed: Speed = .standard, cost: Double? = nil) {
        self.bucket = bucket
        self.model = model
        self.tokens = tokens
        self.cacheWriteHour = cacheWriteHour
        self.speed = speed
        self.cost = cost.flatMap { $0.isFinite ? $0 : nil }
    }

    /// Dollars at API rates: what the tool logged, or else an estimate from `prices`. Nil when neither
    /// knows. Tools log $0 for models they can't price, so a logged zero falls back to the estimate.
    public func cost(in prices: PriceList) -> Double? {
        if let cost, cost > 0 { return cost }
        return prices.price(for: model, speed: speed)?.cost(tokens, cacheWriteHour: cacheWriteHour)
    }

    enum CodingKeys: String, CodingKey {
        case bucket = "b", model = "m", tokens = "t", cacheWriteHour = "h", speed = "s", cost = "c"
    }

    // The pricing details are left out when they're the default, which is nearly always.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucket = try container.decode(Int32.self, forKey: .bucket)
        model = try container.decode(String.self, forKey: .model)
        tokens = try container.decode(TokenCounts.self, forKey: .tokens)
        cacheWriteHour = try container.decodeIfPresent(Int64.self, forKey: .cacheWriteHour) ?? 0
        speed = try container.decodeIfPresent(Speed.self, forKey: .speed) ?? .standard
        cost = try container.decodeIfPresent(Double.self, forKey: .cost).flatMap { $0.isFinite ? $0 : nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bucket, forKey: .bucket)
        try container.encode(model, forKey: .model)
        try container.encode(tokens, forKey: .tokens)
        if cacheWriteHour != 0 { try container.encode(cacheWriteHour, forKey: .cacheWriteHour) }
        if speed != .standard { try container.encode(speed, forKey: .speed) }
        try container.encodeIfPresent(cost, forKey: .cost)
    }
}

/// Everything the stats need from a single `.jsonl` transcript, plus how far it has been read.
public struct FileRecord: Codable, Sendable, Equatable {
    public var size: UInt64 = 0
    public var modified: Double = 0
    public var inode: UInt64 = 0
    /// Byte offset just past the last fully parsed line. Appended data is read from here.
    public var offset: UInt64 = 0
    /// A hash of the bytes just before `offset`, so a file written again in place, rather than appended
    /// to, is read again from the start.
    public var tail: UInt64?
    public var isSubagent: Bool
    /// Set once the transcript disappears from disk. Claude Code prunes old transcripts, so the
    /// summary is kept to preserve all-time history.
    public var missingSince: Double?
    /// Timestamp of the first main-thread entry; nil for subagent transcripts.
    public var sessionStart: Double?
    /// Main-thread messages: user entry `uuid` or response `message.id` hash → quarter-hour bucket.
    /// Continued and forked sessions start with a verbatim copy of earlier history, so messages are
    /// keyed by their own IDs and counted once across all transcripts.
    public var messages: [UInt64: Int32] = [:]
    /// Message ID hash → usage. Claude Code writes one line per content block and repeats the
    /// response's usage on each, so keying by ID keeps every response exactly once.
    public var usage: [UInt64: UsageRecord] = [:]
    /// The model in use at the end of what's been read, for formats that name it once per turn rather
    /// than on every response.
    public var model: String?
    /// The transcript's running token total at the end of what's been read, for formats that log
    /// cumulative totals beside per-response usage.
    public var runningTotal: TokenCounts?
    /// Anything else a format needs to carry from one read of a file to the next.
    public var context: [String: String]?

    public init(isSubagent: Bool) {
        self.isSubagent = isSubagent
    }

    /// Forgets what's been read of the file, keeping its stamp.
    mutating func restart() {
        var fresh = FileRecord(isSubagent: isSubagent)
        (fresh.size, fresh.modified, fresh.inode) = (size, modified, inode)
        self = fresh
    }

    static let quarterHour: Double = 900

    static func bucket(_ timestamp: Double) -> Int32 {
        Int32(clamping: Int(saturating: (timestamp / quarterHour).rounded(.down)))
    }

    mutating func ingest(_ line: TranscriptLine, lineOffset: UInt64, pathHash: UInt64) {
        guard line.kind != .other, let timestamp = line.timestamp else { return }
        let mainThread = !isSubagent && !line.isSidechain
        if mainThread, sessionStart == nil {
            sessionStart = timestamp
        }
        let bucket = Self.bucket(timestamp)

        let lineKey = pathHash ^ (lineOffset &* 0x9E37_79B9_7F4A_7C15)
        switch line.kind {
        case .user:
            if mainThread {
                let key = line.entryID != 0 ? line.entryID : lineKey
                if messages[key] == nil { messages[key] = bucket }
            }
        case .assistant:
            let key = line.messageID != 0 ? line.messageID : lineKey
            let record = UsageRecord(bucket: bucket, model: line.model ?? "unknown", tokens: line.usage ?? TokenCounts(),
                                     cacheWriteHour: line.cacheWriteHour, speed: line.speed)
            // Earlier lines of a response carry partial output counts, and Claude Code sometimes
            // appends extra lines with the usage zeroed, so the largest usage seen is the real one.
            if let existing = usage[key], existing.tokens.total > record.tokens.total {
                // keep existing
            } else {
                usage[key] = record
            }
            // `<synthetic>` lines are Claude Code's own notices (API errors, interruptions), not replies.
            if mainThread, line.model != "<synthetic>", messages[key] == nil { messages[key] = bucket }
        default:
            break
        }
    }
}

enum TranscriptReader {
    typealias Ingest = (UnsafeRawBufferPointer, UInt64, UInt64, inout FileRecord) -> Bool

    /// Reads `path` from `record.offset` to the end, folding every complete line into `record`.
    /// A zstd-compressed file (`.zst`) is read whole and can't be resumed part way. Returns false if
    /// the file could not be opened or decompressed.
    static func read(path: String, into record: inout FileRecord, unterminated: Bool = true, ingest: Ingest) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let pathHash = fnv1a(path)
        let compressed = path.hasSuffix(".zst")
        let fill: (UnsafeMutableRawPointer, Int) -> Int
        if compressed {
            guard let stream = Zstd.Stream(fd: fd) else { return false }
            record.offset = 0
            fill = { stream.read(into: $0, count: $1) }
        } else {
            if record.offset > 0, let tail = record.tail, Self.tail(fd, before: record.offset) != tail { record.restart() }
            if record.offset > 0, lseek(fd, off_t(record.offset), SEEK_SET) < 0 { return false }
            fill = { buffer, count in
                while true {
                    let n = Foundation.read(fd, buffer, count)
                    if n < 0, errno == EINTR { continue }
                    return n
                }
            }
        }

        var capacity = 4 << 20
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var filled = 0
        var consumed = record.offset

        while true {
            if filled == capacity {
                let grown = UnsafeMutableRawPointer.allocate(byteCount: capacity * 2, alignment: 16)
                grown.copyMemory(from: buffer, byteCount: filled)
                buffer.deallocate()
                buffer = grown
                capacity *= 2
            }
            let n = fill(buffer + filled, capacity - filled)
            if n < 0, compressed { return false }
            if n <= 0 { break }
            filled += n

            var lineStart = 0
            while lineStart < filled, let newline = memchr(buffer + lineStart, 0x0A, filled - lineStart) {
                let lineEnd = buffer.distance(to: newline)
                _ = ingest(UnsafeRawBufferPointer(start: buffer + lineStart, count: lineEnd - lineStart), consumed + UInt64(lineStart), pathHash, &record)
                lineStart = lineEnd + 1
            }
            consumed += UInt64(lineStart)
            if lineStart > 0 {
                filled -= lineStart
                if filled > 0 { memmove(buffer, buffer + lineStart, filled) }
            }
        }

        // A final line without a newline is either complete or still being written. Only a line
        // that parses as a whole object is taken, so a half-written one is retried next time.
        if unterminated, filled > 0, ingest(UnsafeRawBufferPointer(start: buffer, count: filled), consumed, pathHash, &record) {
            consumed += UInt64(filled)
        }
        // A compressed file's offset is its compressed size, so an unchanged file reads as fully read.
        record.offset = compressed ? record.size : consumed
        record.tail = compressed ? nil : tail(fd, before: consumed)
        return true
    }

    /// A hash of the up to 64 bytes before `offset`.
    static func tail(_ fd: Int32, before offset: UInt64) -> UInt64? {
        let count = Int(min(offset, 64))
        guard count > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let read = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset) - off_t(count)) }
        guard read == count else { return nil }
        return bytes.withUnsafeBufferPointer { fnv1a($0.baseAddress!, count: count) }
    }
}
