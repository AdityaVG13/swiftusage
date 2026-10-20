import Foundation

/// How fast a response was served. Fast modes bill at a multiple of the standard rate.
public enum Speed: UInt8, Codable, Sendable, Comparable {
    case standard = 0, fast = 1, ultrafast = 2

    public static func < (lhs: Speed, rhs: Speed) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One model's API prices, in dollars per million tokens.
public struct ModelPrice: Codable, Sendable, Equatable {
    public struct Rates: Codable, Sendable, Equatable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        /// Five-minute cache writes, or the only kind for models without a choice.
        public var cacheWrite: Double
        /// Claude's one-hour cache writes, which cost more than its five-minute ones.
        public var cacheWriteHour: Double?

        public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, cacheWriteHour: Double? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.cacheWriteHour = cacheWriteHour
        }

        func scaled(_ factor: Double) -> Rates {
            Rates(input: input * factor, output: output * factor, cacheRead: cacheRead * factor, cacheWrite: cacheWrite * factor,
                  cacheWriteHour: cacheWriteHour.map { $0 * factor })
        }

        enum CodingKeys: String, CodingKey {
            case input = "i", output = "o", cacheRead = "r", cacheWrite = "w", cacheWriteHour = "h"
        }
    }

    public var base: Rates
    /// Some models bill a whole request at higher rates once its prompt passes `threshold` tokens.
    public var threshold: Int64?
    public var long: Rates?
    /// How many times the standard rate fast and ultrafast responses cost, where the model has them.
    public var fast: Double?
    public var ultrafast: Double?

    public init(base: Rates, threshold: Int64? = nil, long: Rates? = nil, fast: Double? = nil, ultrafast: Double? = nil) {
        self.base = base
        self.threshold = threshold
        self.long = long
        self.fast = fast
        self.ultrafast = ultrafast
    }

    enum CodingKeys: String, CodingKey {
        case base = "b", threshold = "t", long = "l", fast = "f", ultrafast = "u"
    }

    /// Dollars for one response. `cacheWriteHour` is the part of `tokens.cacheWrite` cached for an hour.
    public func cost(_ tokens: TokenCounts, cacheWriteHour: Int64 = 0) -> Double {
        let prompt = tokens.input + tokens.cacheRead + tokens.cacheWrite
        let rates = threshold.map { prompt > $0 } == true ? long ?? base : base
        let hour = min(max(cacheWriteHour, 0), tokens.cacheWrite)
        let dollars = Double(tokens.input) * rates.input + Double(tokens.output) * rates.output
            + Double(tokens.cacheRead) * rates.cacheRead + Double(tokens.cacheWrite - hour) * rates.cacheWrite
            + Double(hour) * (rates.cacheWriteHour ?? rates.cacheWrite)
        return dollars / 1_000_000
    }

    /// The same model served at `speed`. A model without a known fast rate keeps its standard one.
    func at(_ speed: Speed) -> ModelPrice {
        let factor = switch speed {
        case .standard: 1.0
        case .fast: fast ?? 1
        case .ultrafast: ultrafast ?? fast ?? 1
        }
        guard factor != 1 else { return self }
        return ModelPrice(base: base.scaled(factor), threshold: threshold, long: long?.scaled(factor))
    }
}

/// Model prices from LiteLLM's public price list, with OpenUsage's supplement for models the list doesn't
/// carry yet and for the names tools give models in their logs.
public struct PriceList: Sendable {
    /// Both keyed by `PriceList.key(_:)`.
    var prices: [String: ModelPrice]
    var supplement: [String: ModelPrice]
    var aliases: [Alias]
    var fastMultipliers: [String: Double]

    struct Alias: @unchecked Sendable {
        let pattern: NSRegularExpression
        let canonical: String
    }

    init(prices: [String: ModelPrice], supplement: [String: ModelPrice] = [:], aliases: [Alias] = [], fastMultipliers: [String: Double] = [:]) {
        self.prices = prices
        self.supplement = supplement
        self.aliases = aliases
        self.fastMultipliers = fastMultipliers
    }

    /// Words tools append to a model's ID for a reasoning mode or context size. Dropped from the end one
    /// at a time until a price is found.
    private static let qualifiers: Set = ["thinking", "minimal", "none", "low", "medium", "high", "xhigh", "max", "ultra",
                                          "latest", "preview", "exp", "1m"]
    /// Prefixes tools put on the models they route (`antigravity-gemini-3-flash`).
    private static let wrappers = ["antigravity-", "cursor-", "windsurf-"]
    private static let claudeFamilies: Set = ["opus", "sonnet", "haiku", "fable", "mythos"]
    /// Models neither price list covers whose price is known: Codex's auto-review has been free since
    /// 6 October 2026.
    private static let free: Set = ["codex-auto-review"]

    /// What `model` costs at `speed`, or nil when no source prices it.
    public func price(for model: String, speed: Speed = .standard) -> ModelPrice? {
        var name = model.lowercased().trimmingCharacters(in: .whitespaces)
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        var speed = speed
        if name.hasSuffix("-fast") {
            name.removeLast(5)
            speed = max(speed, .fast)
        }
        // Free tiers (`deepseek-v4.1-flash-free`, `opencode/glm-5-free`) cost nothing.
        if Self.free.contains(name) || name.split(whereSeparator: { "-/:_ ".contains($0) }).last == "free" {
            return ModelPrice(base: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0))
        }
        for base in bases(name) {
            for candidate in trimmed(alias(base) ?? base) {
                let key = Self.key(candidate)
                if speed != .standard {
                    // Some fast modes are listed as models of their own.
                    let fastKey = Self.key(candidate + "-fast")
                    if let fast = prices[fastKey] { return fast }
                    if let price = prices[key], price.fast != nil { return price.at(speed) }
                    if let fast = supplement[fastKey] { return fast }
                }
                if var price = lookup(candidate) {
                    price.fast = price.fast ?? fastMultipliers[key]
                    return price.at(speed)
                }
            }
        }
        return nil
    }

    private func alias(_ name: String) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        return aliases.first { $0.pattern.firstMatch(in: name, range: range) != nil }?.canonical.lowercased()
    }

    /// Spellings of a model's name to try, most specific first: as written, without its provider path,
    /// without the tool's prefix, from `claude-` on when a tool wrapped a Claude ID, and with a Claude
    /// version moved after the family (`claude-5-fable` → `claude-fable-5`).
    private func bases(_ name: String) -> [String] {
        var bases = [name]
        func add(_ base: String) { if !bases.contains(base) { bases.append(base) } }
        if let slash = name.lastIndex(of: "/") { add(String(name[name.index(after: slash)...])) }
        if let last = bases.last, let wrapper = Self.wrappers.first(where: last.hasPrefix) { add(String(last.dropFirst(wrapper.count))) }
        if let last = bases.last, !last.hasPrefix("claude-"), let claude = last.range(of: "claude-") { add(String(last[claude.lowerBound...])) }
        if let last = bases.last, last.hasPrefix("claude-") {
            var parts = last.split(separator: "-").map(String.init)
            if let family = parts.firstIndex(where: Self.claudeFamilies.contains), family > 1,
               parts[1..<family].allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                let versions = Array(parts[1..<family])
                parts.removeSubrange(1..<family)
                parts.insert(contentsOf: versions, at: 2)
                add(parts.joined(separator: "-"))
            }
        }
        return bases
    }

    /// `name`, then with trailing qualifiers and dates dropped one at a time.
    private func trimmed(_ name: String) -> [String] {
        var result = [name]
        var parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 1 {
            if parts.count > 3, Self.isDate(parts.suffix(3)) {
                parts.removeLast(3)
            } else if let last = parts.last, Self.qualifiers.contains(last) || (last.count == 8 && last.allSatisfy(\.isNumber)) {
                parts.removeLast()
            } else {
                break
            }
            result.append(parts.joined(separator: "-"))
        }
        return result
    }

    /// `2025`, `04`, `23`: a date written with dashes.
    private static func isDate(_ parts: ArraySlice<String>) -> Bool {
        let parts = Array(parts)
        return parts[0].count == 4 && parts[0].hasPrefix("20") && parts[1].count == 2 && parts[2].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// LiteLLM's entries carry long-context and fast rates, so they win; the supplement fills the gaps.
    private func lookup(_ name: String) -> ModelPrice? {
        let key = Self.key(name)
        return prices[key] ?? supplement[key]
    }

    /// Tools write versions with dots or dashes (`grok-4.6`, `grok-4-6`), so both match.
    static func key(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: ".", with: "-")
    }
}
