import CryptoKit
import Foundation
import Synchronization

/// JSON over HTTPS for the usage APIs. Each request stands alone: no cookies, no cache.
enum HTTP {
    struct Response {
        var status: Int
        var headers: [String: String]
        var data: Data

        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
        var ok: Bool { (200..<300).contains(status) }

        /// `Retry-After` as seconds from now, whether sent as seconds or as a date.
        var retryAfter: TimeInterval? { retryAfter() }

        func retryAfter(now: Date = HTTP.now()) -> TimeInterval? {
            guard let value = headers["retry-after"] else { return nil }
            if let seconds = Double(value) { return seconds }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter.date(from: value).map { $0.timeIntervalSince(now) }
        }
    }

    @TaskLocal static var transport: (@Sendable (URLRequest) async -> Response?)?
    @TaskLocal static var now: @Sendable () -> Date = Date.init

    private struct Cooldown {
        var until: Date
        var wait: TimeInterval
    }

    private static let cooldowns = Mutex<[String: Cooldown]>([:])

    private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            if let original = task.originalRequest?.url, let target = request.url,
               let scheme = original.scheme?.lowercased(), let host = original.host?.lowercased(),
               scheme == target.scheme?.lowercased(), host == target.host?.lowercased(),
               original.port == target.port {
                completionHandler(request)
            } else {
                completionHandler(nil)
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "swiftusage/1.0"]
        // The per-request timeout only bounds the silence between packets; a body that trickles in would
        // otherwise hold every later reading behind it.
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
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
        let key = "\(url.host?.lowercased() ?? "")|\((request.value(forHTTPHeaderField: "Authorization") ?? "").sha256Prefix)|\((request.value(forHTTPHeaderField: "Cookie") ?? "").sha256Prefix)"
        let start = now()
        if let until = cooldowns.withLock({ $0[key]?.until }), until > start {
            return Response(status: 429, headers: ["retry-after": String(Int(until.timeIntervalSince(start).rounded(.up)))], data: Data())
        }
        let response: Response?
        if let transport {
            response = await transport(request)
        } else {
            guard let (data, raw) = try? await session.data(for: request), let http = raw as? HTTPURLResponse else { return nil }
            var lowered: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { lowered[name.lowercased()] = value }
            }
            response = Response(status: http.statusCode, headers: lowered, data: data)
        }
        guard let response else { return nil }
        let current = now()
        cooldowns.withLock { cooldowns in
            if response.status == 429 {
                let base = response.retryAfter(now: current).flatMap { $0 > 0 ? $0 : nil } ?? 300
                let wait = min(max(base, (cooldowns[key]?.wait ?? 0) * 2), .hour)
                cooldowns[key] = Cooldown(until: current.addingTimeInterval(wait), wait: wait)
            } else {
                cooldowns[key] = nil
            }
        }
        return response
    }
}

/// Config folders a tool was pointed to through the environment, such as `CLAUDE_CONFIG_DIR`. The app only
/// sees one when it's opened from a shell that sets it, so each is remembered: a login found there once is
/// still read after the app is opened from Finder. Folders that are gone are forgotten.
enum EnvironmentFolders {
    /// Every folder `$name` has named on this Mac, as written, the current one first.
    static func seen(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                     defaults: UserDefaults = .standard) -> [String] {
        let key = "environmentFolders." + name
        let saved = defaults.stringArray(forKey: key) ?? []
        var unique: Set<String> = []
        let folders = ([environment[name] ?? ""] + saved).filter { written in
            var isFolder: ObjCBool = false
            return !written.isEmpty && unique.insert(written).inserted
                && FileManager.default.fileExists(atPath: (written as NSString).expandingTildeInPath, isDirectory: &isFolder) && isFolder.boolValue
        }
        if folders != saved { defaults.set(folders, forKey: key) }
        return folders
    }
}

extension Int {
    /// A server's number as a whole count, rounded toward zero; one past `Int`'s range saturates rather
    /// than trapping.
    public init(saturating value: Double) {
        self = value.isNaN ? 0 : value >= 0x1p63 ? .max : value <= -0x1p63 ? .min : Int(value)
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
        guard let number = number(value), number > 0,
              let seconds = Timestamp.seconds(number < 1e11 ? number : number / 1000) else { return nil }
        return Date(timeIntervalSince1970: seconds)
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

extension LimitsSources {
    /// One reading per login, in order, except a login whose account an earlier login already read with
    /// values. Readings that share an ID are left to `merged`, which keeps the one with values.
    static func readings<Login>(of logins: [Login], id: (Login) -> String, read: (Login) async -> AccountLimits) async -> [AccountLimits] {
        var results: [AccountLimits] = []
        var served: Set<String> = []
        for login in logins where !served.contains(id(login)) {
            let reading = await read(login)
            if reading.hasValues { served.insert(reading.id) }
            results.append(reading)
        }
        return results
    }
}

