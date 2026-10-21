import Foundation

/// A saved index in binary: a header, each transcript's record as fixed-width little-endian numbers, then
/// every string the records use, once (model names repeat on almost every response), where the header
/// says. A JSON copy of a large history took a second and hundreds of megabytes to read, most of it the
/// parser's.
enum IndexFile {
    static let magic: [UInt8] = Array("SUIX".utf8)
    /// Bumped when the layout below changes.
    static let format: UInt32 = 1

    struct Header: Equatable {
        var format: UInt32
        var version: Int
        var root: String
    }

    static func isIndexFile(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    static func encode(version: Int, root: String, records: [String: FileRecord]) -> [UInt8] {
        var strings = Strings()
        var body = Writer()
        // Sized once, so a large index isn't copied as it grows.
        body.bytes.reserveCapacity(records.values.reduce(root.utf8.count + 64) { $0 + 120 + $1.messages.count * 12 + $1.usage.count * 50 })
        body.bytes += magic
        body.u32(format)
        body.i64(Int64(version))
        body.string(root)
        let tablePosition = body.bytes.count
        body.u64(0)
        body.u32(UInt32(records.count))
        for (key, record) in records {
            body.u32(strings.index(key))
            body.u64(record.size)
            body.f64(record.modified)
            body.u64(record.inode)
            body.u64(record.offset)
            var flags: UInt8 = record.isSubagent ? 1 : 0
            if record.missingSince != nil { flags |= 2 }
            if record.sessionStart != nil { flags |= 4 }
            if record.tail != nil { flags |= 8 }
            if record.model != nil { flags |= 16 }
            if record.runningTotal != nil { flags |= 32 }
            if record.context != nil { flags |= 64 }
            body.u8(flags)
            if let missingSince = record.missingSince { body.f64(missingSince) }
            if let sessionStart = record.sessionStart { body.f64(sessionStart) }
            if let tail = record.tail { body.u64(tail) }
            if let model = record.model { body.u32(strings.index(model)) }
            if let total = record.runningTotal { body.tokens(total) }
            if let context = record.context {
                body.u32(UInt32(context.count))
                for (name, value) in context {
                    body.u32(strings.index(name))
                    body.u32(strings.index(value))
                }
            }
            body.u32(UInt32(record.messages.count))
            for (id, bucket) in record.messages {
                body.u64(id)
                body.i32(bucket)
            }
            body.u32(UInt32(record.usage.count))
            for (id, usage) in record.usage {
                body.u64(id)
                body.i32(usage.bucket)
                body.u32(strings.index(usage.model))
                body.tokens(usage.tokens)
                var flags: UInt8 = 0
                if usage.cacheWriteHour != 0 { flags |= 1 }
                if usage.speed != .standard { flags |= 2 }
                if usage.cost != nil { flags |= 4 }
                body.u8(flags)
                if usage.cacheWriteHour != 0 { body.i64(usage.cacheWriteHour) }
                if usage.speed != .standard { body.u8(usage.speed.rawValue) }
                if let cost = usage.cost { body.f64(cost) }
            }
        }

        withUnsafeBytes(of: UInt64(body.bytes.count).littleEndian) { offset in
            body.bytes.replaceSubrange(tablePosition..<(tablePosition + 8), with: offset)
        }
        body.u32(UInt32(strings.list.count))
        for string in strings.list { body.string(string) }
        return body.bytes
    }

    /// The header of an index file of any format, this one's or a later one's.
    static func header(_ data: Data) -> Header? {
        data.withUnsafeBytes { buffer in
            var reader = Reader(buffer)
            return try? reader.header()
        }
    }

    /// Nil when the file is damaged or in a later format.
    static func decode(_ data: Data) -> (header: Header, records: [String: FileRecord])? {
        data.withUnsafeBytes { buffer in
            var reader = Reader(buffer)
            guard let header = try? reader.header(), header.format == format else { return nil }
            return try? (header, reader.records())
        }
    }

    private struct Strings {
        var list: [String] = []
        var indexes: [String: UInt32] = [:]

        mutating func index(_ string: String) -> UInt32 {
            if let index = indexes[string] { return index }
            let index = UInt32(list.count)
            list.append(string)
            indexes[string] = index
            return index
        }
    }

    private struct Writer {
        var bytes: [UInt8] = []

        mutating func u8(_ value: UInt8) { bytes.append(value) }
        mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
        mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        mutating func i64(_ value: Int64) { u64(UInt64(bitPattern: value)) }
        mutating func f64(_ value: Double) { u64(value.bitPattern) }

        mutating func string(_ value: String) {
            u32(UInt32(value.utf8.count))
            bytes += value.utf8
        }

        mutating func tokens(_ counts: TokenCounts) {
            i64(counts.input)
            i64(counts.output)
            i64(counts.cacheRead)
            i64(counts.cacheWrite)
        }
    }

    private struct Damaged: Error {}

    private struct Reader {
        let buffer: UnsafeRawBufferPointer
        var position = 0
        var strings: [String] = []

        init(_ buffer: UnsafeRawBufferPointer) {
            self.buffer = buffer
        }

        mutating func header() throws -> Header {
            guard buffer.starts(with: magic) else { throw Damaged() }
            position = magic.count
            return Header(format: try u32(), version: Int(try i64()), root: try string())
        }

        mutating func records() throws -> [String: FileRecord] {
            let table = Int(clamping: try u64())
            let body = position
            guard table >= body, table <= buffer.count else { throw Damaged() }
            position = table
            let stringCount = try count(atLeast: 4)
            strings.reserveCapacity(stringCount)
            for _ in 0..<stringCount { strings.append(try string()) }
            guard position == buffer.count else { throw Damaged() }
            position = body

            let recordCount = try count(atLeast: 45)
            var records: [String: FileRecord] = [:]
            records.reserveCapacity(recordCount)
            for _ in 0..<recordCount {
                let key = try stringRef()
                var record = FileRecord(isSubagent: false)
                record.size = try u64()
                record.modified = try f64()
                record.inode = try u64()
                record.offset = try u64()
                let flags = try u8()
                record.isSubagent = flags & 1 != 0
                if flags & 2 != 0 { record.missingSince = try f64() }
                if flags & 4 != 0 { record.sessionStart = try f64() }
                if flags & 8 != 0 { record.tail = try u64() }
                if flags & 16 != 0 { record.model = try stringRef() }
                if flags & 32 != 0 { record.runningTotal = try tokens() }
                if flags & 64 != 0 {
                    let contextCount = try count(atLeast: 8)
                    var context: [String: String] = [:]
                    context.reserveCapacity(contextCount)
                    for _ in 0..<contextCount { context[try stringRef()] = try stringRef() }
                    record.context = context
                }
                let messageCount = try count(atLeast: 12)
                record.messages.reserveCapacity(messageCount)
                for _ in 0..<messageCount { record.messages[try u64()] = try i32() }
                let usageCount = try count(atLeast: 49)
                record.usage.reserveCapacity(usageCount)
                for _ in 0..<usageCount {
                    let id = try u64()
                    var usage = UsageRecord(bucket: try i32(), model: try stringRef(), tokens: try tokens())
                    let flags = try u8()
                    if flags & 1 != 0 { usage.cacheWriteHour = try count() }
                    if flags & 2 != 0 {
                        guard let speed = Speed(rawValue: try u8()) else { throw Damaged() }
                        usage.speed = speed
                    }
                    if flags & 4 != 0 {
                        let cost = try f64()
                        usage.cost = cost.isFinite ? cost : nil
                    }
                    record.usage[id] = usage
                }
                records[key] = record
            }
            guard position == table else { throw Damaged() }
            return records
        }

        private mutating func take(_ size: Int) throws -> UnsafeRawBufferPointer {
            guard size <= buffer.count - position else { throw Damaged() }
            defer { position += size }
            return UnsafeRawBufferPointer(rebasing: buffer[position..<(position + size)])
        }

        mutating func u8() throws -> UInt8 { try take(1)[0] }
        mutating func u32() throws -> UInt32 { UInt32(littleEndian: try take(4).loadUnaligned(as: UInt32.self)) }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func u64() throws -> UInt64 { UInt64(littleEndian: try take(8).loadUnaligned(as: UInt64.self)) }
        mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
        mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

        /// A count of items at least `size` bytes each, which the rest of the file must have room for.
        mutating func count(atLeast size: Int) throws -> Int {
            let count = Int(try u32())
            guard count <= (buffer.count - position) / size else { throw Damaged() }
            return count
        }

        mutating func string() throws -> String {
            String(decoding: try take(try count(atLeast: 1)), as: UTF8.self)
        }

        mutating func stringRef() throws -> String {
            let index = Int(try u32())
            guard index < strings.count else { throw Damaged() }
            return strings[index]
        }

        /// A token count held to what the parsers write, never below zero or past `TokenCount.max`, so no sum
        /// of them can overflow.
        mutating func count() throws -> Int64 {
            TokenCount.clamped(try i64())
        }

        mutating func tokens() throws -> TokenCounts {
            TokenCounts(input: try count(), output: try count(), cacheRead: try count(), cacheWrite: try count())
        }
    }
}
