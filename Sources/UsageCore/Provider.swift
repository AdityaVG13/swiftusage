import Foundation

/// The coding agents whose usage the app shows, in T3 Code's order, then Devin, Droid and the plans
/// that come through Hermes.
public enum Provider: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex, claude, cursor, grok, opencode, antigravity, muse, pi, devin, droid, nous, zai, kimi, unattributed

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .grok: "Grok"
        case .opencode: "OpenCode"
        case .antigravity: "Antigravity"
        case .muse: "Muse"
        case .pi: "Pi"
        case .devin: "Devin"
        case .droid: "Droid"
        case .nous: "Nous Portal"
        case .zai: "Z.AI"
        case .kimi: "Kimi"
        case .unattributed: "Unattributed"
        }
    }

    /// Position in the provider picker.
    public var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Cursor keeps token usage on its servers; locally there are only chats and messages, and its tokens are
    /// known once its usage events have been fetched.
    public var recordsTokensLocally: Bool { self != .cursor }
}
