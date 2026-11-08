import Foundation

/// Factory Droid's sessions: `sessions/<project>/<session id>.jsonl`, one record per event. A record
/// names its own `id` and `timestamp` before its `message`, whose role says whether it's the person's
/// or the model's, so the first bytes of a line are all a read needs of it. The session's tokens are
/// kept beside it, and `DroidSource` reads those.
///
/// A session a tool call started is tagged with the session that called it on its first line. It's
/// read as a subagent's: its messages aren't the conversation's, and its tokens are counted beside it.
public enum DroidTranscripts: TranscriptFormat {
    public static let provider = Provider.droid
    public static let cacheName = "droid-index.json"
    public static let cacheVersion = 1

    public static var defaultRoot: URL { DroidSource.defaultRoot }

    public static func discover(in root: URL) -> [String: TranscriptInfo] {
        TranscriptFolders.files(in: root, depth: 1) { $0.hasSuffix(".jsonl") }
    }

    /// Droid writes complete lines, and a line is skipped by markers in its first bytes, so a last line
    /// without a newline could be complete or half-written; it waits for its newline.
    public static let readsUnterminatedLastLine = false

    public static func ingest(_ line: UnsafeRawBufferPointer, lineOffset: UInt64, pathHash: UInt64, into record: inout FileRecord) -> Bool {
        // Only the head of a line holds what a message records; its content can be megabytes of tool
        // output, so every marker is looked for in the first kilobyte.
        // A subagent's calling session is written on its first line, before any content of its own, so
        // the marker is only looked for there: a parent's tool output could quote it later.
        if lineOffset == 0, field(line, "\"callingSessionId\":\"", within: 1024) != nil {
            record.isSubagent = true
            record.sessionStart = nil
            return true
        }
        guard let role = field(line, "\"role\":\"", within: 1024), role.count > 0,
              equals(role, "assistant") || equals(role, "user") else { return true }
        guard let time = field(line, "\"timestamp\":\"", within: 1024).flatMap({ Timestamp.parse($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: $0.count) })
        else { return true }
        let mainThread = !record.isSubagent
        if mainThread, record.sessionStart == nil { record.sessionStart = time }
        guard equals(role, "assistant") else { return true }
        // A continued or forked session starts with a copy of earlier messages, so a message is keyed by
        // its own id and counted once across transcripts.
        let key = field(line, "\"id\":\"", within: 1024).map { fnv1a($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: $0.count) }
            ?? (pathHash ^ (lineOffset &* 0x9E37_79B9_7F4A_7C15))
        record.messages[key] = FileRecord.bucket(time)
        return true
    }

    /// The value of the first `needle` in the line's first `limit` bytes, up to its closing quote.
    private static func field(_ line: UnsafeRawBufferPointer, _ needle: StaticString, within limit: Int) -> UnsafeRawBufferPointer? {
        guard let base = line.baseAddress, line.count > 1 else { return nil }
        guard let hit = memmem(base, min(line.count, limit), needle.utf8Start, needle.utf8CodeUnitCount) else { return nil }
        let start = base.distance(to: UnsafeRawPointer(hit)) + needle.utf8CodeUnitCount
        guard start < line.count, let quote = memchr(base + start, Int32(UInt8(ascii: "\"")), line.count - start) else { return nil }
        let end = base.distance(to: UnsafeRawPointer(quote))
        guard end >= start else { return nil }
        return UnsafeRawBufferPointer(start: base + start, count: end - start)
    }

    private static func equals(_ buffer: UnsafeRawBufferPointer, _ string: StaticString) -> Bool {
        guard buffer.count == string.utf8CodeUnitCount, let base = buffer.baseAddress else { return false }
        return memcmp(base, string.utf8Start, buffer.count) == 0
    }
}
