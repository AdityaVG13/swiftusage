import Foundation

public struct TokenCounts: Codable, Sendable, Equatable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int64 { input + output + cacheRead + cacheWrite }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite += rhs.cacheWrite
    }

    enum CodingKeys: String, CodingKey {
        case input = "i", output = "o", cacheRead = "r", cacheWrite = "w"
    }
}

/// The fields of one transcript line that the stats need. Everything else is skipped unparsed.
public struct TranscriptLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case user, assistant, attachment, system, other
    }

    public var kind: Kind = .other
    public var timestamp: Double?
    public var isSidechain = false
    public var model: String?
    /// FNV-1a hash of `message.id`, or 0 when the line has none.
    public var messageID: UInt64 = 0
    /// FNV-1a hash of the entry's own `uuid`, or 0 when the line has none.
    public var entryID: UInt64 = 0
    public var usage: TokenCounts?
    /// The part of the cache write cached for an hour (`usage.cache_creation.ephemeral_1h_input_tokens`).
    public var cacheWriteHour: Int64 = 0
    /// `usage.speed`: Claude Code's fast mode bills more.
    public var speed: Speed = .standard

    public init() {}

    /// Parses one JSON object from a transcript line. Returns nil for malformed or truncated lines.
    public static func parse(_ bytes: UnsafeRawBufferPointer) -> TranscriptLine? {
        guard let base = bytes.baseAddress, bytes.count > 1 else { return nil }
        var parser = LineParser(p: base.assumingMemoryBound(to: UInt8.self), end: bytes.count)
        return parser.parseEntry()
    }

    public static func parse(_ string: String) -> TranscriptLine? {
        var copy = string
        return copy.withUTF8 { parse(UnsafeRawBufferPointer($0)) }
    }
}

private let quote = UInt8(ascii: "\"")
private let backslash = UInt8(ascii: "\\")
private let lbrace = UInt8(ascii: "{")
private let rbrace = UInt8(ascii: "}")
private let lbracket = UInt8(ascii: "[")
private let rbracket = UInt8(ascii: "]")
private let comma = UInt8(ascii: ",")
private let colon = UInt8(ascii: ":")
private let minus = UInt8(ascii: "-")
private let zero = UInt8(ascii: "0")
private let nine = UInt8(ascii: "9")

@inline(__always) private func isSpace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09
}

/// A forward-only JSON reader that extracts a handful of known keys and skips everything else.
/// Skipping strings uses memchr, so multi-megabyte tool results and images cost almost nothing.
struct LineParser {
    let p: UnsafePointer<UInt8>
    let end: Int
    var i = 0

    mutating func parseEntry() -> TranscriptLine? {
        skipSpace()
        guard i < end, p[i] == lbrace else { return nil }
        i += 1
        var line = TranscriptLine()
        while true {
            guard let key = nextKey() else { return nil }
            if key.isEmpty { return line }
            if matches(key, "type"), i < end, p[i] == quote {
                guard let value = scanString() else { return nil }
                line.kind = kind(of: value)
            } else if matches(key, "timestamp") {
                if i < end, p[i] == quote {
                    guard let value = scanString() else { return nil }
                    line.timestamp = Timestamp.parse(p + value.lowerBound, count: value.count)
                } else if !skipValue() { return nil }
            } else if matches(key, "uuid"), i < end, p[i] == quote {
                guard let value = scanString() else { return nil }
                line.entryID = fnv1a(p + value.lowerBound, count: value.count)
            } else if matches(key, "isSidechain") {
                line.isSidechain = i + 3 < end && p[i] == UInt8(ascii: "t")
                if !skipValue() { return nil }
            } else if matches(key, "message"), i < end, p[i] == lbrace {
                guard parseMessage(into: &line) else { return nil }
            } else if !skipValue() {
                return nil
            }
        }
    }

    private mutating func parseMessage(into line: inout TranscriptLine) -> Bool {
        i += 1
        while true {
            guard let key = nextKey() else { return false }
            if key.isEmpty { return true }
            if matches(key, "model"), i < end, p[i] == quote {
                guard let value = scanString() else { return false }
                line.model = String(decoding: UnsafeBufferPointer(start: p + value.lowerBound, count: value.count), as: UTF8.self)
            } else if matches(key, "id"), i < end, p[i] == quote {
                guard let value = scanString() else { return false }
                line.messageID = fnv1a(p + value.lowerBound, count: value.count)
            } else if matches(key, "usage"), i < end, p[i] == lbrace {
                guard parseUsage(into: &line) else { return false }
            } else if !skipValue() {
                return false
            }
        }
    }

    private mutating func parseUsage(into line: inout TranscriptLine) -> Bool {
        i += 1
        var usage = TokenCounts()
        defer { line.usage = usage }
        while true {
            guard let key = nextKey() else { return false }
            if key.isEmpty { return true }
            if matches(key, "input_tokens") {
                usage.input = scanInteger()
            } else if matches(key, "output_tokens") {
                usage.output = scanInteger()
            } else if matches(key, "cache_read_input_tokens") {
                usage.cacheRead = scanInteger()
            } else if matches(key, "cache_creation_input_tokens") {
                usage.cacheWrite = scanInteger()
            } else if matches(key, "cache_creation"), i < end, p[i] == lbrace {
                guard parseCacheCreation(into: &line) else { return false }
            } else if matches(key, "speed"), i < end, p[i] == quote {
                guard let value = scanString() else { return false }
                line.speed = matches(value, "fast") ? .fast : .standard
            } else if !skipValue() {
                return false
            }
        }
    }

    private mutating func parseCacheCreation(into line: inout TranscriptLine) -> Bool {
        i += 1
        while true {
            guard let key = nextKey() else { return false }
            if key.isEmpty { return true }
            if matches(key, "ephemeral_1h_input_tokens") {
                line.cacheWriteHour = scanInteger()
            } else if !skipValue() {
                return false
            }
        }
    }

    /// Advances to the next member of the current object and returns its key, leaving `i` at the value.
    /// Returns an empty range at the closing brace and nil on malformed input.
    private mutating func nextKey() -> Range<Int>? {
        skipSpace()
        if i < end, p[i] == comma {
            i += 1
            skipSpace()
        }
        guard i < end else { return nil }
        if p[i] == rbrace {
            i += 1
            return 0..<0
        }
        guard let key = scanString(), !key.isEmpty else { return nil }
        skipSpace()
        guard i < end, p[i] == colon else { return nil }
        i += 1
        skipSpace()
        return key
    }

    private func kind(of value: Range<Int>) -> TranscriptLine.Kind {
        if matches(value, "assistant") { return .assistant }
        if matches(value, "user") { return .user }
        if matches(value, "attachment") { return .attachment }
        if matches(value, "system") { return .system }
        return .other
    }

    private func matches(_ range: Range<Int>, _ literal: StaticString) -> Bool {
        range.count == literal.utf8CodeUnitCount && memcmp(p + range.lowerBound, literal.utf8Start, range.count) == 0
    }

    @inline(__always) private mutating func skipSpace() {
        while i < end, isSpace(p[i]) { i += 1 }
    }

    /// Reads a string starting at the opening quote and returns the raw (still escaped) contents.
    private mutating func scanString() -> Range<Int>? {
        guard i < end, p[i] == quote else { return nil }
        i += 1
        let start = i
        guard skipStringBody(from: start) else { return nil }
        return start..<(i - 1)
    }

    /// Moves `i` just past the closing quote of a string whose contents begin at `start`.
    private mutating func skipStringBody(from start: Int) -> Bool {
        while i < end {
            guard let hit = memchr(p + i, Int32(quote), end - i) else {
                i = end
                return false
            }
            let q = UnsafeRawPointer(p).distance(to: UnsafeRawPointer(hit))
            var slashes = 0
            var k = q - 1
            while k >= start, p[k] == backslash {
                slashes += 1
                k -= 1
            }
            i = q + 1
            if slashes % 2 == 0 { return true }
        }
        return false
    }

    private mutating func skipValue() -> Bool {
        skipSpace()
        guard i < end else { return false }
        switch p[i] {
        case quote:
            i += 1
            return skipStringBody(from: i)
        case lbrace, lbracket:
            var depth = 0
            while i < end {
                let c = p[i]
                if c == quote {
                    i += 1
                    if !skipStringBody(from: i) { return false }
                    continue
                }
                if c == lbrace || c == lbracket {
                    depth += 1
                } else if c == rbrace || c == rbracket {
                    depth -= 1
                    if depth == 0 {
                        i += 1
                        return true
                    }
                }
                i += 1
            }
            return false
        default:
            while i < end {
                let c = p[i]
                if c == comma || c == rbrace || c == rbracket || isSpace(c) { break }
                i += 1
            }
            return true
        }
    }

    private mutating func scanInteger() -> Int64 {
        var negative = false
        if i < end, p[i] == minus {
            negative = true
            i += 1
        }
        var value: Int64 = 0
        var sawDigit = false
        while i < end, p[i] >= zero, p[i] <= nine {
            value = value &* 10 &+ Int64(p[i] - zero)
            sawDigit = true
            i += 1
        }
        if !sawDigit {
            _ = skipValue()
            return 0
        }
        // Tolerate a fractional or exponent tail without misreading it as the next token.
        _ = skipValue()
        return negative ? -value : value
    }
}

func fnv1a(_ p: UnsafePointer<UInt8>, count: Int) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for k in 0..<count {
        hash ^= UInt64(p[k])
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash == 0 ? 1 : hash
}

func fnv1a(_ string: String) -> UInt64 {
    var copy = string
    return copy.withUTF8 { buffer in
        guard let base = buffer.baseAddress else { return 1 }
        return fnv1a(base, count: buffer.count)
    }
}

enum Timestamp {
    /// Parses `YYYY-MM-DDTHH:MM:SS[.fff][Z|±HH:MM]` into seconds since 1970 (UTC when no zone is given).
    static func parse(_ p: UnsafePointer<UInt8>, count: Int) -> Double? {
        guard count >= 19 else { return nil }
        func digits(_ at: Int, _ n: Int) -> Int? {
            var v = 0
            for k in at..<(at + n) {
                let c = p[k]
                guard c >= zero, c <= nine else { return nil }
                v = v * 10 + Int(c - zero)
            }
            return v
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var seconds = Double(daysFromCivil(year: year, month: month, day: day)) * 86_400
            + Double(hour * 3600 + minute * 60 + second)

        var k = 19
        if k < count, p[k] == UInt8(ascii: ".") {
            k += 1
            var scale = 0.1
            while k < count, p[k] >= zero, p[k] <= nine {
                seconds += Double(p[k] - zero) * scale
                scale /= 10
                k += 1
            }
        }
        if k + 5 < count, p[k] == UInt8(ascii: "+") || p[k] == minus,
           let oh = digits(k + 1, 2), let om = digits(k + 4, 2) {
            let offset = Double(oh * 3600 + om * 60)
            seconds += p[k] == minus ? offset : -offset
        }
        return seconds
    }

    static func parse(_ string: String) -> Double? {
        var copy = string
        return copy.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return parse(base, count: buffer.count)
        }
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
