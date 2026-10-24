import Foundation

/// The coding agents whose local history the app reads, in T3 Code's order, then Devin.
public enum Provider: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex, claude, cursor, grok, opencode, antigravity, muse, pi, devin

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .grok: "Grok"
        case .opencode: "OpenCode"
        case .antigravity: "Antigravity"
        case .muse: "Muse Code"
        case .pi: "Pi"
        case .devin: "Devin"
        }
    }

    /// Position in the provider picker.
    public var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Cursor keeps token usage on its servers; locally there are only chats and messages, and its tokens are
    /// known once its usage events have been fetched.
    public var recordsTokensLocally: Bool { self != .cursor }
}
