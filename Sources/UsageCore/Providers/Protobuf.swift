import Foundation

/// Just enough of the protobuf wire format to walk messages whose schema isn't published: each field
/// is read by number and wire type.
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed(UInt64)
    }

    let fields: [(number: Int, value: Value)]

    init?(_ data: Data) {
        var fields: [(Int, Value)] = []
        var index = data.startIndex
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < data.endIndex, shift < 64 {
                let byte = data[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while index < data.endIndex {
            guard let tag = varint(), tag >> 3 > 0 else { return nil }
            switch tag & 7 {
            case 0:
                guard let value = varint() else { return nil }
                fields.append((Int(tag >> 3), .varint(value)))
            case 1, 5:
                let width = tag & 7 == 1 ? 8 : 4
                guard data.endIndex - index >= width else { return nil }
                var value: UInt64 = 0
                for k in 0..<width { value |= UInt64(data[index + k]) << (8 * UInt64(k)) }
                index += width
                fields.append((Int(tag >> 3), .fixed(value)))
            case 2:
                guard let length = varint(), length <= UInt64(data.endIndex - index) else { return nil }
                let end = index + Int(length)
                fields.append((Int(tag >> 3), .bytes(data[index..<end])))
                index = end
            default:
                return nil
            }
        }
        self.fields = fields
    }

    func int(_ number: Int) -> Int64? {
        for field in fields where field.number == number {
            if case .varint(let value) = field.value { return Int64(bitPattern: value) }
        }
        return nil
    }

    func bytes(_ number: Int) -> Data? {
        for field in fields where field.number == number {
            if case .bytes(let value) = field.value { return value }
        }
        return nil
    }

    func allBytes(_ number: Int) -> [Data] {
        fields.compactMap { field in
            if field.number == number, case .bytes(let value) = field.value { return value }
            return nil
        }
    }

    func message(_ number: Int) -> ProtoMessage? {
        bytes(number).flatMap(ProtoMessage.init)
    }

    func string(_ number: Int) -> String? {
        bytes(number).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A `google.protobuf.Timestamp` (seconds, nanos) as seconds since 1970.
    var timestamp: Double? {
        guard let seconds = int(1), seconds > 0 else { return nil }
        let nanos = max(0, min(int(2) ?? 0, 999_999_999))
        return Timestamp.seconds(Double(seconds) + Double(nanos) / 1e9)
    }
}
