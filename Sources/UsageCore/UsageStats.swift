import Foundation

public enum StatsRange: String, CaseIterable, Sendable, Identifiable {
    case all = "All"
    case days30 = "30d"
    case days7 = "7d"

    public var id: String { rawValue }

    /// Number of days including today, or nil for all time.
    public var dayCount: Int? {
        switch self {
        case .all: nil
        case .days30: 30
        case .days7: 7
        }
    }
}

public struct DayStats: Sendable, Equatable {
    public var messages = 0
    public var sessions = 0
    public var tokens: Int64 = 0
    /// Dollars at API rates for the tokens whose model has a known price.
    public var cost: Double = 0

    public var isActive: Bool { messages > 0 || sessions > 0 }
}

public struct ModelStats: Sendable, Identifiable, Equatable {
    /// The display name when models are grouped by it (the default), else the model's ID.
    public var id: String
    public var name: String
    public var tokens: TokenCounts
    public var share: Double
    /// Dollars at API rates, or nil when no price list knows the model.
    public var cost: Double?
}

public struct RangeStats: Sendable, Equatable {
    public var range: StatsRange
    public var today: Int
    /// First day the range covers. For all time this is the first day with any activity.
    public var firstDay: Int
    public var sessions = 0
    public var messages = 0
    public var totalTokens: Int64 = 0
    /// Dollars at API rates for the tokens whose model has a known price.
    public var cost: Double = 0
    /// Models with tokens in the range but no known price, whose tokens `cost` leaves out.
    public var unpricedModels: [String] = []
    public var activeDays = 0
    public var peakHour: Int?
    public var models: [ModelStats] = []
    public var days: [Int: DayStats] = [:]
    public var dayModelTokens: [Int: [String: Int64]] = [:]

    public var favoriteModel: ModelStats? { models.first }
}

/// Converts UTC timestamps to local calendar days, numbered as days since 1970-01-01 on the wall clock.
public struct DayClock: Sendable {
    public let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    public func offset(at epoch: Double) -> Int {
        timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: epoch))
    }

    public func day(of epoch: Double) -> Int {
        Int(((epoch + Double(offset(at: epoch))) / 86_400).rounded(.down))
    }

    public func hour(of epoch: Double) -> Int {
        let local = epoch + Double(offset(at: epoch))
        let seconds = local - (local / 86_400).rounded(.down) * 86_400
        return min(23, max(0, Int(seconds / 3600)))
    }

    /// Weekday of a day number, 1 = Sunday … 7 = Saturday, matching `Calendar`.
    public static func weekday(of day: Int) -> Int {
        ((day + 4) % 7 + 7) % 7 + 1
    }

    /// The date at local midnight of a day number.
    public func date(of day: Int) -> Date {
        let (y, m, d) = Self.civil(fromDays: day)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? Date(timeIntervalSince1970: Double(day) * 86_400)
    }

    public static func civil(fromDays days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

public enum StatsBuilder {
    /// With `groupingModels`, models are counted by display name: tools name the same model differently
    /// (`claude-opus-5-5`, `claude-opus-5-5-xhigh`, `anthropic/claude-opus-5-5`), and it's one model to
    /// the person using them. Without, by ID.
    public static func build(_ data: UsageData, range: StatsRange, now: Date = Date(), clock: DayClock = DayClock(),
                             groupingModels: Bool = true, prices: PriceList = .bundled) -> RangeStats {
        let today = clock.day(of: now.timeIntervalSince1970)
        let firstAllowed = range.dayCount.map { today - $0 + 1 } ?? Int.min

        // Offsets only change at DST transitions, so look them up once per UTC hour.
        var offsets: [Int: Int] = [:]
        func day(ofBucket bucket: Int32) -> Int {
            let epoch = Double(bucket) * 900
            let hourKey = Int(bucket) >> 2
            let offset: Int
            if let cached = offsets[hourKey] {
                offset = cached
            } else {
                offset = clock.offset(at: epoch)
                offsets[hourKey] = offset
            }
            return Int(((epoch + Double(offset)) / 86_400).rounded(.down))
        }

        var stats = RangeStats(range: range, today: today, firstDay: firstAllowed)
        var hourCounts = [Int](repeating: 0, count: 24)

        for start in data.sessionStarts {
            let d = clock.day(of: start)
            guard d >= firstAllowed, d <= today else { continue }
            stats.sessions += 1
            stats.days[d, default: DayStats()].sessions += 1
            hourCounts[clock.hour(of: start)] += 1
        }

        for (bucket, count) in data.messageBuckets {
            let d = day(ofBucket: bucket)
            guard d >= firstAllowed, d <= today else { continue }
            stats.messages += count
            stats.days[d, default: DayStats()].messages += count
        }

        var keys: [String: String] = [:]
        func key(for model: String) -> String {
            if let key = keys[model] { return key }
            let key = groupingModels ? ModelName.display(model) : model
            keys[model] = key
            return key
        }

        // Looked up once per model and speed; a price list lookup tries several spellings of the name.
        var priceCache: [String: [Speed: ModelPrice?]] = [:]
        func cost(_ record: UsageRecord) -> Double? {
            if let logged = record.cost, logged > 0 { return logged }
            let price: ModelPrice?
            if let cached = priceCache[record.model]?[record.speed] {
                price = cached
            } else {
                price = prices.price(for: record.model, speed: record.speed)
                priceCache[record.model, default: [:]][record.speed] = .some(price)
            }
            return price?.cost(record.tokens, cacheWriteHour: record.cacheWriteHour)
        }

        var byModel: [String: TokenCounts] = [:]
        var costByModel: [String: Double] = [:]
        var unpriced: Set<String> = []
        for record in data.usage where record.model != "<synthetic>" {
            let d = day(ofBucket: record.bucket)
            guard d >= firstAllowed, d <= today else { continue }
            let total = record.tokens.total
            guard total > 0 else { continue }
            let model = key(for: record.model)
            byModel[model, default: TokenCounts()] += record.tokens
            stats.totalTokens += total
            stats.days[d, default: DayStats()].tokens += total
            stats.dayModelTokens[d, default: [:]][model, default: 0] += total
            if let cost = cost(record) {
                stats.cost += cost
                stats.days[d, default: DayStats()].cost += cost
                costByModel[model, default: 0] += cost
            } else {
                unpriced.insert(model)
            }
        }

        stats.activeDays = stats.days.values.filter(\.isActive).count
        if let peak = hourCounts.indices.max(by: { hourCounts[$0] < hourCounts[$1] || (hourCounts[$0] == hourCounts[$1] && $0 > $1) }),
           hourCounts[peak] > 0 {
            stats.peakHour = peak
        }
        let grandTotal = max(stats.totalTokens, 1)
        stats.models = byModel
            .map { ModelStats(id: $0.key, name: groupingModels ? $0.key : ModelName.display($0.key), tokens: $0.value,
                              share: Double($0.value.total) / Double(grandTotal), cost: costByModel[$0.key]) }
            .sorted { $0.tokens.total != $1.tokens.total ? $0.tokens.total > $1.tokens.total : $0.id < $1.id }
        // A model with some priced and some unpriced responses still has a cost; only wholly unpriced ones are listed.
        stats.unpricedModels = unpriced.filter { costByModel[$0] == nil }.sorted { (byModel[$0]?.total ?? 0) > (byModel[$1]?.total ?? 0) }
        if range == .all {
            stats.firstDay = stats.days.keys.min() ?? today
        }
        return stats
    }
}
