import Foundation

/// Where a limit is heading at the rate it's being used, OpenUsage's way: a window on course to finish
/// with a tenth or more to spare is fine, one that will land in its last tenth is tight, and one that
/// will run out before it resets is over.
public struct Pace: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case fine, tight, over, reached
    }

    public var verdict: Verdict
    /// Share used by the reset at this rate, which can pass 1. Nil when there's no rate to go on.
    public var atReset: Double?
    /// When the limit runs out at this rate, if that's before the reset.
    public var runsOut: Date?
    /// How much would be used by now at an even rate across the window, 0...1.
    public var even: Double?

    public init(_ meter: LimitMeter, now: Date = Date()) {
        let used = meter.fraction
        guard used < 0.995 else {
            self.init(verdict: .reached)
            return
        }
        guard let reset = meter.resetsAt, let period = meter.period, period > 0, reset > now else {
            // Nothing to project from: judge the level alone.
            self.init(verdict: used >= 0.9 ? .over : used >= 0.8 ? .tight : .fine)
            return
        }
        let elapsed = period - reset.timeIntervalSince(now)
        let even = min(max(elapsed / period, 0), 1)
        // A window that's barely begun, or hasn't been touched, has no rate worth projecting.
        guard used > 0, elapsed >= max(period * 0.05, 15 * 60) else {
            self.init(verdict: used >= 0.9 ? .over : used >= 0.8 ? .tight : .fine, even: used > 0 ? even : nil)
            return
        }
        let atReset = used / elapsed * period
        let runsOut = atReset > 1 ? now.addingTimeInterval((1 - used) / (used / elapsed)) : nil
        let verdict: Verdict = atReset >= 0.995 ? .over : atReset > 0.9 ? .tight : .fine
        self.init(verdict: verdict, atReset: atReset, runsOut: runsOut, even: even)
    }

    init(verdict: Verdict, atReset: Double? = nil, runsOut: Date? = nil, even: Double? = nil) {
        self.verdict = verdict
        self.atReset = atReset
        self.runsOut = runsOut
        self.even = even
    }
}
