import Foundation

/// Cursor's local chats, saved in a compact binary beside the transcript indexes.
enum CursorIndex {
    static let magic: [UInt8] = Array("SUCL".utf8)
    /// Bumped when the layout below changes.
    static let format: UInt32 = 1

    static func encode(_ chats: [String: CursorSource.Chat]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(chats.values.reduce(64) { $0 + 48 + $1.messages.count * 12 + $1.usage.count * 48 })
        out += magic
        u32(&out, format)
        u32(&out, UInt32(chats.count))
        for (path, chat) in chats {
            string(&out, path)
            string(&out, chat.id)
            if let stamp = chat.stamp {
                out.append(1)
                u64(&out, stamp.size)
                f64(&out, stamp.modified)
                u64(&out, stamp.walSize)
                f64(&out, stamp.walModified)
            } else {
                out.append(0)
            }
            u32(&out, UInt32(chat.sessions.count))
            for start in chat.sessions { f64(&out, start) }
            u32(&out, UInt32(chat.messages.count))
            for (key, bucket) in chat.messages {
                u64(&out, key)
                i32(&out, bucket)
            }
            u32(&out, UInt32(chat.usage.count))
            for (key, record) in chat.usage {
                u64(&out, key)
                i32(&out, record.bucket)
                string(&out, record.model)
                i64(&out, record.tokens.input)
                i64(&out, record.tokens.output)
                i64(&out, record.tokens.cacheRead)
                i64(&out, record.tokens.cacheWrite)
                var flags: UInt8 = 0
                if record.cacheWriteHour != 0 { flags |= 1 }
                if record.speed != .standard { flags |= 2 }
                if record.cost != nil { flags |= 4 }
                out.append(flags)
                if record.cacheWriteHour != 0 { i64(&out, record.cacheWriteHour) }
                if record.speed != .standard { out.append(record.speed.rawValue) }
                if let cost = record.cost { f64(&out, cost) }
            }
        }
        return out
    }

    static func decode(_ data: Data) -> [String: CursorSource.Chat]? {
        data.withUnsafeBytes { buffer in
            var reader = Reader(buffer)
            guard let header = try? reader.bytes(magic.count), Array(header) == magic,
                  let version = try? reader.u32(), version == format else { return nil }
            guard let count = try? reader.count(atLeast: 12) else { return nil }
            var chats: [String: CursorSource.Chat] = [:]
            chats.reserveCapacity(count)
            for _ in 0..<count {
                guard let path = try? reader.string(), let id = try? reader.string() else { return nil }
                var chat = CursorSource.Chat(id: id)
                guard let hasStamp = try? reader.u8() else { return nil }
                if hasStamp != 0 {
                    guard let size = try? reader.u64(), let modified = try? reader.f64(),
                          let walSize = try? reader.u64(), let walModified = try? reader.f64()
                    else { return nil }
                    chat.stamp = DatabaseStamp(size: size, modified: modified, walSize: walSize, walModified: walModified)
                }
                guard let sessionCount = try? reader.count(atLeast: 8) else { return nil }
                chat.sessions.reserveCapacity(sessionCount)
                for _ in 0..<sessionCount { guard let start = try? reader.f64() else { return nil }; chat.sessions.append(start) }
                guard let messageCount = try? reader.count(atLeast: 12) else { return nil }
                chat.messages.reserveCapacity(messageCount)
                for _ in 0..<messageCount {
                    guard let key = try? reader.u64(), let bucket = try? reader.i32() else { return nil }
                    chat.messages[key] = bucket
                }
                guard let usageCount = try? reader.count(atLeast: 49) else { return nil }
                chat.usage.reserveCapacity(usageCount)
                for _ in 0..<usageCount {
                    guard let key = try? reader.u64(), let bucket = try? reader.i32(),
                          let model = try? reader.string(), let tokens = try? reader.tokens(),
                          let flags = try? reader.u8()
                    else { return nil }
                    var record = UsageRecord(bucket: bucket, model: model, tokens: tokens)
                    if flags & 1 != 0 { guard let hour = try? reader.i64() else { return nil }; record.cacheWriteHour = hour }
                    if flags & 2 != 0 {
                        guard let speed = try? reader.u8(), let parsed = Speed(rawValue: speed) else { return nil }
                        record.speed = parsed
                    }
                    if flags & 4 != 0 {
                        guard let cost = try? reader.f64() else { return nil }
                        record.cost = cost.isFinite ? cost : nil
                    }
                    chat.usage[key] = record
                }
                chats[path] = chat
            }
            guard reader.position == buffer.count else { return nil }
            return chats
        }
    }

    private static func u32(_ out: inout [UInt8], _ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out += $0 } }
    private static func i32(_ out: inout [UInt8], _ value: Int32) { u32(&out, UInt32(bitPattern: value)) }
    private static func u64(_ out: inout [UInt8], _ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { out += $0 } }
    private static func i64(_ out: inout [UInt8], _ value: Int64) { u64(&out, UInt64(bitPattern: value)) }
    private static func f64(_ out: inout [UInt8], _ value: Double) { u64(&out, value.bitPattern) }

    private static func string(_ out: inout [UInt8], _ value: String) {
        u32(&out, UInt32(value.utf8.count))
        out += value.utf8
    }

    private struct Damaged: Error {}

    private struct Reader {
        let buffer: UnsafeRawBufferPointer
        var position = 0

        init(_ buffer: UnsafeRawBufferPointer) { self.buffer = buffer }

        mutating func bytes(_ size: Int) throws -> UnsafeRawBufferPointer {
            guard size <= buffer.count - position else { throw Damaged() }
            defer { position += size }
            return UnsafeRawBufferPointer(rebasing: buffer[position..<(position + size)])
        }

        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u32() throws -> UInt32 { UInt32(littleEndian: try bytes(4).loadUnaligned(as: UInt32.self)) }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func u64() throws -> UInt64 { UInt64(littleEndian: try bytes(8).loadUnaligned(as: UInt64.self)) }
        mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
        mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

        mutating func count(atLeast size: Int) throws -> Int {
            let count = Int(try u32())
            guard count <= (buffer.count - position) / size else { throw Damaged() }
            return count
        }

        mutating func string() throws -> String {
            String(decoding: try bytes(try count(atLeast: 1)), as: UTF8.self)
        }

        mutating func tokens() throws -> TokenCounts {
            TokenCounts(input: try i64(), output: try i64(), cacheRead: try i64(), cacheWrite: try i64())
        }
    }
}
