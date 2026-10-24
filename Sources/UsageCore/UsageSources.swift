import Foundation

public enum UsageSources {
    /// Every provider's source, reading from where the tool keeps its history. Without `cached`, saved
    /// indexes are neither read nor written; with `readOnly`, they are never written. With `waitingForServers`,
    /// a read waits for what's fetched from a provider's servers (Cursor's usage events).
    public static func all(cached: Bool = true, readOnly: Bool = false, waitingForServers: Bool = false) -> [any UsageSource] {
        func index<Format: TranscriptFormat>(_ format: Format.Type, root: URL) -> TranscriptIndex<Format> {
            TranscriptIndex<Format>(root: root, cacheURL: cached ? TranscriptIndex<Format>.defaultCacheURL : nil, readOnly: readOnly)
        }
        return [
            index(CodexTranscripts.self, root: CodexTranscripts.defaultRoot),
            index(ClaudeTranscripts.self, root: ClaudeTranscripts.defaultRoot),
            CursorSource(server: .live(cached: cached, readOnly: readOnly, waits: waitingForServers)),
            index(GrokTranscripts.self, root: GrokTranscripts.defaultRoot),
            OpenCodeSource(),
            AntigravitySource(),
            index(MuseTranscripts.self, root: MuseTranscripts.defaultRoot),
            index(PiTranscripts.self, root: PiTranscripts.defaultRoot),
            DevinSource(),
        ]
    }
}
