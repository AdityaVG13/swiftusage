import CryptoKit
import Foundation

/// JSON over HTTPS for the usage APIs. Each request stands alone: no cookies, no cache.
enum HTTP {
    struct Response {
        var status: Int
        var headers: [String: String]
        var data: Data

        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        var ok: Bool { (200..<300).contains(status) }

        /// `Retry-After` as seconds from now, whether sent as seconds or as a date.
        var retryAfter: TimeInterval? {
            guard let value = headers["retry-after"] else { return nil }
            if let seconds = Double(value) { return seconds }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter.date(from: value).map { $0.timeIntervalSinceNow }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "swiftusage/1.0"]
        return URLSession(configuration: configuration)
    }()

    static func get(_ url: String, headers: [String: String] = [:], timeout: TimeInterval = 15) async -> Response? {
        await send(url, method: "GET", headers: headers, body: nil, timeout: timeout)
    }

    static func post(_ url: String, headers: [String: String] = [:], json: Any, timeout: TimeInterval = 15) async -> Response? {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return await send(url, method: "POST", headers: headers, body: try? JSONSerialization.data(withJSONObject: json), timeout: timeout)
    }

    static func postForm(_ url: String, form: [String: String], timeout: TimeInterval = 15) async -> Response? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
        return await send(url, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8), timeout: timeout)
    }

    /// Nil when the request never got an answer (offline, timed out).
    private static func send(_ url: String, method: String, headers: [String: String], body: Data?, timeout: TimeInterval) async -> Response? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        var lowered: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { lowered[name.lowercased()] = value }
        }
        return Response(status: http.statusCode, headers: lowered, data: data)
    }
}

/// Reads the logins coding agents keep in the login keychain.
enum Keychain {
    /// The password of a generic keychain item, read with `/usr/bin/security`. Claude Code and Antigravity
    /// save their logins with that same tool, so reading them this way doesn't ask for permission.
    static func password(service: String, account: String? = nil) -> String? {
        var arguments = ["find-generic-password", "-s", service, "-w"]
        if let account { arguments.insert(contentsOf: ["-a", account], at: 1) }
        guard let output = run("/usr/bin/security", arguments) else { return nil }
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Stdout of a command that succeeded within `timeout` seconds, or nil. A locked keychain or a
    /// permission prompt would otherwise hold every later refresh.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = [:]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read as it arrives, so a large answer can't fill the pipe and stall the command.
        let buffer = OutputBuffer()
        output.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
        let ended = finished.wait(timeout: .now() + timeout) == .success
        output.fileHandleForReading.readabilityHandler = nil
        guard ended else {
            process.terminate()
            return nil
        }
        buffer.append(output.fileHandleForReading.readDataToEndOfFile())
        guard process.terminationStatus == 0 else { return nil }
        return String(data: buffer.data, encoding: .utf8)
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ chunk: Data) { lock.withLock { bytes.append(chunk) } }
        var data: Data { lock.withLock { bytes } }
    }
}

/// Lenient readers for the usage APIs' JSON, which sends numbers as numbers or strings depending on the
/// field and the day.
enum JSONValue {
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue.isFinite ? number.doubleValue : nil
        }
        if let string = value as? String, let number = Double(string.trimmingCharacters(in: .whitespaces)), number.isFinite {
            return number
        }
        return nil
    }

    /// An ISO 8601 date, with or without fractional seconds, or epoch seconds or milliseconds.
    static func date(_ value: Any?) -> Date? {
        if let string = value as? String, let seconds = Timestamp.parse(string) {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let number = number(value), number > 0 else { return nil }
        return Date(timeIntervalSince1970: number < 1e11 ? number : number / 1000)
    }

    static func object(_ data: Data?) -> [String: Any]? {
        data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    static func object(file url: URL) -> [String: Any]? {
        object(try? Data(contentsOf: url))
    }
}

/// The claims of a JSON Web Token, unverified: enough to tell when it expires and whose it is.
enum JWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return JSONValue.object(Data(base64Encoded: base64))
    }

    static func expiry(_ token: String) -> Date? {
        JSONValue.number(claims(token)?["exp"]).map { Date(timeIntervalSince1970: $0) }
    }
}

extension String {
    /// The first 8 hex digits of the string's SHA-256.
    var sha256Prefix: String {
        SHA256.hash(data: Data(utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// `team_plus` → `Team Plus`.
    var titleCased: String {
        split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}

extension TimeInterval {
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400
    static let week: TimeInterval = 604_800
}
