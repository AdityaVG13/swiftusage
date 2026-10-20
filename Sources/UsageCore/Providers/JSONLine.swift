import Foundation

/// Helpers for formats read with Foundation's JSON parser. Lines are first checked for a marker with
/// `memmem`, so the many lines that can't matter (streamed text, tool output) are never parsed.
enum JSONLine {
    static func contains(_ line: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = line.baseAddress else { return false }
        return memmem(base, line.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    static func object(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard let base = line.baseAddress, line.count > 1 else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func key(_ parts: String...) -> UInt64 {
        fnv1a(parts.joined(separator: "\u{1F}"))
    }
}

extension [String: Any] {
    subscript(path keys: String...) -> Any? {
        var value: Any? = self
        for key in keys {
            value = (value as? [String: Any])?[key]
        }
        return value
    }

    func int(_ key: String) -> Int64 {
        (self[key] as? NSNumber)?.int64Value ?? 0
    }
}

extension URL {
    /// `$name` from the environment as a path, if it's set.
    static func environment(_ name: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }

    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
}
