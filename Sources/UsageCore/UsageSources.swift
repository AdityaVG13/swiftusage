import Foundation

public enum UsageSources {
    /// Every provider's source, reading from where the tool keeps its history. Without `cached`, saved
    /// indexes are neither read nor written; with `readOnly`, they are never written. With `waitingForServers`,
    /// a read waits for what's fetched from a provider's servers (Cursor's usage events).
    public static func all(cached: Bool = true, readOnly: Bool = false, waitingForServers: Bool = false) -> [any UsageSource] {
        func index<Format: TranscriptFormat>(_ format: Format.Type, root: URL) -> TranscriptIndex<Format> {
            TranscriptIndex<Format>(root: root, cacheURL: cached ? TranscriptIndex<Format>.defaultCacheURL : nil, readOnly: readOnly)
        }
        let empryo = EmpryoReader()
        let hermes = HermesReader()
        var sources: [any UsageSource] = [
            index(CodexTranscripts.self, root: CodexTranscripts.defaultRoot),
            index(ClaudeTranscripts.self, root: ClaudeTranscripts.defaultRoot),
            CursorSource(server: .live(cached: cached, readOnly: readOnly, waits: waitingForServers),
                         cacheURL: cached ? CursorSource.defaultCacheURL : nil, readOnly: readOnly),
            index(GrokTranscripts.self, root: GrokTranscripts.defaultRoot),
            OpenCodeSource(),
            AntigravitySource(),
            index(MuseTranscripts.self, root: MuseTranscripts.defaultRoot),
            index(PiTranscripts.self, root: PiTranscripts.defaultRoot),
            DevinSource(),
            KimiSource(),
        ]
        // Empryo and Hermes name the plan each call was billed to, so their usage feeds the plan's
        // card rather than a card of its own. Every plan's source shares one reader.
        sources += [Provider.claude, .codex, .grok, .kimi, .cursor, .devin].map {
            EmpryoSource(provider: $0, reader: empryo)
        }
        sources += [Provider.codex, .muse, .grok, .zai, .nous, .claude, .cursor, .antigravity, .opencode].map {
            HermesSource(provider: $0, reader: hermes)
        }
        return sources
    }
}
