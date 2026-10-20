import Foundation

public enum UsageSources {
    /// Every provider's source, reading from where the tool keeps its history. Without `cached`, saved
    /// indexes are neither read nor written.
    public static func all(cached: Bool = true) -> [any UsageSource] {
        func index<Format: TranscriptFormat>(_ format: Format.Type, root: URL) -> TranscriptIndex<Format> {
            TranscriptIndex<Format>(root: root, cacheURL: cached ? TranscriptIndex<Format>.defaultCacheURL : nil)
        }
        return [
            index(CodexTranscripts.self, root: CodexTranscripts.defaultRoot),
            index(ClaudeTranscripts.self, root: ClaudeTranscripts.defaultRoot),
            CursorSource(),
            index(GrokTranscripts.self, root: GrokTranscripts.defaultRoot),
            OpenCodeSource(),
            AntigravitySource(),
            index(MuseTranscripts.self, root: MuseTranscripts.defaultRoot),
            index(PiTranscripts.self, root: PiTranscripts.defaultRoot),
            DevinSource(),
        ]
    }
}

extension UsageSources {
    /// Whether Codex has compressed rollouts that can't be read because no zstd library was found.
    public static func codexHasUnreadableRollouts() -> Bool {
        guard !Zstd.isAvailable else { return false }
        return CodexTranscripts.discover(in: CodexTranscripts.defaultRoot).values.contains { $0.path.hasSuffix(".zst") }
    }
}
