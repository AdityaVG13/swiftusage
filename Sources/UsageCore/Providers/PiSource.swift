import Foundation

/// Pi and Oh My Pi record the route of each response. Their shared index is read once and split by plan.
public actor PiSource: UsageSource {
    public nonisolated let provider: Provider
    private nonisolated let reader: PiReader

    public init(provider: Provider, reader: PiReader) {
        self.provider = provider
        self.reader = reader
    }

    init(provider: Provider, index: TranscriptIndex<PiTranscripts>) {
        self.provider = provider
        self.reader = PiReader(index: index)
    }

    public nonisolated var watchedPaths: [String] { reader.watchedPaths }

    public func refresh(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        await reader.read(progress: progress).forPiPlan(provider)
    }

    public func rebuild(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> UsageData {
        await reader.rebuild(progress: progress).forPiPlan(provider)
    }

    public func save() async { await reader.save() }
}

public actor PiReader {
    private nonisolated let index: TranscriptIndex<PiTranscripts>
    private var rebuilding: Task<UsageData, Never>?

    public init(index: TranscriptIndex<PiTranscripts>) { self.index = index }
    nonisolated var watchedPaths: [String] { index.watchedPaths }

    func read(progress: (@Sendable (ScanProgress) -> Void)?) async -> UsageData {
        await index.refresh(progress: progress)
    }

    func rebuild(progress: (@Sendable (ScanProgress) -> Void)?) async -> UsageData {
        if let rebuilding { return await rebuilding.value }
        let task = Task { await index.rebuild(progress: progress) }
        rebuilding = task
        let result = await task.value
        rebuilding = nil
        return result
    }

    func save() async { await index.save() }
}

private extension UsageData {
    func forPiPlan(_ provider: Provider) -> UsageData {
        var result = provider == .pi ? self : UsageData()
        result.usage = usage.filter { provider == .pi ? $0.plan == nil : $0.plan == provider }
        result.scannedAt = scannedAt
        return result
    }
}
