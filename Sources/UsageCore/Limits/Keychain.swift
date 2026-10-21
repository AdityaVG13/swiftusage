import Foundation
import Security
import Synchronization

/// Reads the logins coding agents keep in the login keychain, without ever making macOS ask. An item that
/// would be asked about, because its keychain is locked or the item doesn't trust the reader, reads as
/// `needsPermission`, and its card asks for it when the person says so. A prompt that comes up on its own
/// with every reading looks like the app wanting the password for no reason.
public enum Keychain {
    struct Item: Hashable, Sendable {
        var service: String
        var account: String?

        /// A search for the first item that matches.
        var query: [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if let account { query[kSecAttrAccount as String] = account }
            return query
        }
    }

    enum Reading: Equatable {
        case password(String)
        case missing
        case needsPermission
    }

    enum Access: Equatable {
        case allowed
        case missing
        case needsPermission
    }

    /// Who reads an item, as items' access lists name them.
    enum Reader {
        /// `/usr/bin/security`. Claude Code and Antigravity save their logins with it, so their items trust
        /// it from the start.
        case securityTool
        /// This app, which an item only trusts once the person has allowed it.
        case app

        var paths: [String] {
            switch self {
            case .securityTool: ["/usr/bin/security"]
            case .app: [Bundle.main.bundlePath] + (Bundle.main.executablePath.map { [$0] } ?? [])
            }
        }

        /// The partition macOS files the reader under; nil when it can't be told.
        var partition: String? {
            switch self {
            case .securityTool: "apple-tool:"
            case .app: Keychain.appTeam.map { "teamid:" + $0 }
            }
        }
    }

    private struct State {
        /// The item each card is waiting on, by card ID.
        var waiting: [String: Item] = [:]
        /// Items whose read waited on macOS after all. They're left alone until the person asks for them.
        var refused: Set<Item> = []
    }

    private static let state = Mutex(State())
    private static let security = "/usr/bin/security"

    /// The password of a generic keychain item, read with `/usr/bin/security`.
    static func password(_ item: Item) -> Reading {
        guard !state.withLock({ $0.refused.contains(item) }) else { return .needsPermission }
        switch access(item, by: .securityTool) {
        case .missing: return .missing
        case .needsPermission: return .needsPermission
        case .allowed: break
        }
        switch run(security, arguments(item)) {
        case .succeeded(let output):
            let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .missing : .password(value)
        case .failed:
            return .missing
        case .timedOut:
            // The access list let it through, yet macOS asked.
            state.withLock { _ = $0.refused.insert(item) }
            return .needsPermission
        }
    }

    /// Whether macOS asked for `item` after its access list let the reader through, and was turned down:
    /// it's left alone until the person asks for it, rather than asking again on every reading.
    static func isRefused(_ item: Item) -> Bool {
        state.withLock { $0.refused.contains(item) }
    }

    static func setRefused(_ item: Item, _ refused: Bool) {
        state.withLock { state in
            if refused {
                state.refused.insert(item)
            } else {
                state.refused.remove(item)
            }
        }
    }

    /// Remembers the item a card is waiting on, for `requestAccess(for:)`.
    static func wait(_ id: String, on item: Item) {
        state.withLock { $0.waiting[id] = item }
    }

    /// Reads the item the card `id` is waiting on, which lets macOS ask for it. Always Allow lets later
    /// readings through without asking. Blocks until the person answers, so call it off the main thread.
    /// Returns whether the item could be read.
    public static func requestAccess(for id: String) -> Bool {
        guard let item = state.withLock({ $0.waiting[id] }),
              case .succeeded = run(security, arguments(item), timeout: 600) else { return false }
        state.withLock { _ = $0.refused.remove(item) }
        return true
    }

    /// Whether `reader` can read the item without macOS asking, told from its keychain's lock and its
    /// access list. Neither needs the item's password, so finding out never asks.
    static func access(_ item: Item, by reader: Reader) -> Access {
        var query = item.query
        query[kSecReturnRef as String] = true
        var found: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &found) {
        case errSecSuccess:
            guard let found else { return .missing }
            let lists: any AccessLists.Type = FileKeychain.self
            return lists.allows(found as! SecKeychainItem, reader) ? .allowed : .needsPermission
        case errSecItemNotFound:
            return .missing
        default:
            return .needsPermission
        }
    }

    private static func arguments(_ item: Item) -> [String] {
        ["find-generic-password", "-s", item.service] + (item.account.map { ["-a", $0] } ?? []) + ["-w"]
    }

    private static let appTeam: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    private enum Run {
        case succeeded(String)
        case failed
        /// Still going at the timeout, such as waiting on a prompt, and stopped.
        case timedOut
    }

    /// Stdout of a command, stopped if it runs past `timeout` seconds so a locked keychain or a prompt
    /// can't hold every later reading.
    private static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> Run {
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
            return .failed
        }
        // Read as it arrives, so a large answer can't fill the pipe and stall the command.
        let buffer = OutputBuffer()
        output.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
        let ended = finished.wait(timeout: .now() + timeout) == .success
        output.fileHandleForReading.readabilityHandler = nil
        guard ended else {
            process.terminate()
            return .timedOut
        }
        buffer.append(output.fileHandleForReading.readDataToEndOfFile())
        guard process.terminationStatus == 0, let text = String(data: buffer.data, encoding: .utf8) else { return .failed }
        return .succeeded(text)
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        func append(_ chunk: Data) { lock.withLock { bytes.append(chunk) } }
        var data: Data { lock.withLock { bytes } }
    }
}

/// Apple deprecated the calls that read an item's access list along with the rest of the file-based
/// keychain, which still holds these logins, and nothing replaces them. Going through a protocol keeps
/// their warnings out of the build.
private protocol AccessLists {
    static func allows(_ item: SecKeychainItem, _ reader: Keychain.Reader) -> Bool
}

private enum FileKeychain: AccessLists {
    @available(macOS, deprecated: 10.10)
    static func allows(_ item: SecKeychainItem, _ reader: Keychain.Reader) -> Bool {
        // A locked keychain asks to be unlocked before anything in it is read, its access lists included.
        var keychain: SecKeychain?
        var status = SecKeychainStatus()
        guard SecKeychainItemCopyKeychain(item, &keychain) == errSecSuccess, let keychain,
              SecKeychainGetStatus(keychain, &status) == errSecSuccess, status & UInt32(kSecUnlockStateStatus) != 0 else { return false }

        var access: SecAccess?
        var list: CFArray?
        guard SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access,
              SecAccessCopyACLList(access, &list) == errSecSuccess, let entries = list as? [SecACL] else { return false }
        var trusted = false
        var partitions: [String]?
        for entry in entries {
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(entry, &apps, &description, &prompt) == errSecSuccess else { continue }
            let authorizations = SecACLCopyAuthorizations(entry) as? [String] ?? []
            if authorizations.contains("ACLAuthorizationPartitionID") {
                // A property list, in hex: `{"Partitions": ["apple-tool:", "teamid:…"]}`.
                partitions = (description as String?).flatMap(Data.init(hex:))
                    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["Partitions"] as? [String]
            } else if authorizations.contains(kSecACLAuthorizationDecrypt as String) || authorizations.contains(kSecACLAuthorizationAny as String),
                      !prompt.contains(.requirePassphase) {
                // No list at all lets every app in.
                trusted = trusted || apps == nil || (apps as? [SecTrustedApplication] ?? []).contains { app in
                    var data: CFData?
                    guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let data else { return false }
                    return reader.paths.contains(String(decoding: data as Data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0")))
                }
            }
        }
        // Since macOS 10.12 a reader also has to be in one of the item's partitions.
        guard let partitions, let partition = reader.partition else { return trusted }
        return trusted && partitions.contains(partition)
    }
}
