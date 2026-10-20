import Foundation

/// The prices in a compact form the app bundles and caches: LiteLLM's list, refreshed daily, and
/// OpenUsage's supplement, which ships with the app.
struct PriceCatalog: Codable, Sendable {
    var prices: [String: ModelPrice]
    var supplement: [String: ModelPrice] = [:]
    /// Regular expression and the model it names, tried in order.
    var aliases: [[String]] = []
    var fast: [String: Double] = [:]

    var list: PriceList {
        let aliases = aliases.compactMap { pair -> PriceList.Alias? in
            guard pair.count == 2, let pattern = try? NSRegularExpression(pattern: pair[0]) else { return nil }
            return PriceList.Alias(pattern: pattern, canonical: pair[1])
        }
        return PriceList(prices: prices, supplement: supplement, aliases: aliases,
                         fastMultipliers: Dictionary(fast.map { (PriceList.key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }))
    }
}

extension PriceList {
    /// The prices the app was built with.
    public static let bundled: PriceList = {
        guard let catalog = try? JSONDecoder().decode(PriceCatalog.self, from: Data(BundledPrices.json.utf8)) else {
            assertionFailure("BundledPrices.json doesn't decode")
            return PriceList(prices: [:])
        }
        return catalog.list
    }()

    /// The bundled prices updated with a newer copy of LiteLLM's list.
    func replacingPrices(_ litellm: [String: ModelPrice]) -> PriceList {
        var list = self
        list.prices.merge(litellm) { _, new in new }
        return list
    }
}

/// Converts the public price lists into `ModelPrice`s.
public enum PriceSources {
    /// First-party providers' entries win over resellers' copies of the same model.
    private static func rank(_ provider: String) -> Int {
        switch provider {
        case "anthropic", "openai", "xai", "gemini", "deepseek", "mistral", "moonshot", "zai", "minimax", "dashscope": 0
        case "vertex_ai-language-models", "vertex_ai-anthropic_models", "text-completion-openai": 1
        case "openrouter", "fireworks_ai", "together_ai", "groq", "cerebras", "deepinfra": 3
        default: 4
        }
    }

    /// LiteLLM's `model_prices_and_context_window.json`, keyed by model name without its provider path.
    static func litellm(_ data: Data) -> [String: ModelPrice]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var best: [String: (rank: Int, price: ModelPrice)] = [:]
        // Up to nine digits, so a malformed key in the fetched list can't overflow the threshold.
        let threshold = try! NSRegularExpression(pattern: "^input_cost_per_token_above_(\\d{1,9})k_tokens$")
        for (id, value) in root {
            guard let entry = value as? [String: Any], let input = number(entry["input_cost_per_token"]),
                  number(entry["output_cost_per_token"]) != nil
            else { continue }
            if let mode = entry["mode"] as? String, !["chat", "responses", "completion"].contains(mode) { continue }
            let provider = entry["litellm_provider"] as? String ?? ""
            // Cloud mirrors of first-party models, under names no coding agent logs.
            if provider.hasPrefix("azure") || provider.hasPrefix("bedrock") { continue }
            let name = id.lowercased().split(separator: "/").last.map(String.init) ?? id.lowercased()
            let isClaude = name.contains("claude")
            // A copy under its plain name beats one under a provider path.
            let rank = rank(provider) * 2 + (id.contains("/") ? 1 : 0)
            if let existing = best[PriceList.key(name)], existing.rank <= rank { continue }

            // Per token, as LiteLLM lists them.
            func rates(_ suffix: String, fallback: ModelPrice.Rates?) -> ModelPrice.Rates? {
                guard let input = number(entry["input_cost_per_token" + suffix]) ?? fallback?.input else { return nil }
                return ModelPrice.Rates(
                    input: input,
                    output: number(entry["output_cost_per_token" + suffix]) ?? fallback?.output ?? 0,
                    cacheRead: number(entry["cache_read_input_token_cost" + suffix]) ?? fallback?.cacheRead ?? input,
                    cacheWrite: number(entry["cache_creation_input_token_cost" + suffix]) ?? fallback?.cacheWrite ?? input,
                    // Anthropic bills one-hour cache writes at twice the input rate.
                    cacheWriteHour: number(entry["cache_creation_input_token_cost_above_1hr" + suffix]) ?? (isClaude ? input * 2 : fallback?.cacheWriteHour))
            }
            guard let base = rates("", fallback: nil) else { continue }
            var price = ModelPrice(base: perMillion(base))
            let thresholds = entry.keys.compactMap { key -> Int? in
                guard let match = threshold.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)),
                      let range = Range(match.range(at: 1), in: key) else { return nil }
                return Int(key[range])
            }
            if let k = thresholds.min(), let long = rates("_above_\(k)k_tokens", fallback: base) {
                price.threshold = Int64(k) * 1000
                price.long = perMillion(long)
            }
            if input > 0 {
                price.fast = number(entry["input_cost_per_token_priority"]).map { ($0 / input * 100).rounded() / 100 }
                price.ultrafast = number(entry["input_cost_per_token_ultrafast"]).map { ($0 / input * 100).rounded() / 100 }
            }
            best[PriceList.key(name)] = (rank, price)
        }
        return best.mapValues(\.price)
    }

    /// OpenUsage's `pricing_supplement.json`: prices per million, alias rules and fast multipliers.
    static func supplement(_ data: Data) -> (prices: [String: ModelPrice], aliases: [[String]], fast: [String: Double])? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pricing = root["pricing"] as? [String: Any] else { return nil }
        var prices: [String: ModelPrice] = [:]
        for (id, value) in pricing {
            guard let entry = value as? [String: Any], let input = number(entry["input_per_million"]),
                  let output = number(entry["output_per_million"]) else { continue }
            let name = id.lowercased().split(separator: "/").last.map(String.init) ?? id.lowercased()
            let base = ModelPrice.Rates(input: input, output: output,
                                        cacheRead: number(entry["cache_read_per_million"]) ?? input,
                                        cacheWrite: number(entry["cache_write_per_million"]) ?? input,
                                        cacheWriteHour: name.contains("claude") ? input * 2 : nil)
            prices[PriceList.key(name)] = ModelPrice(base: base)
        }
        let aliases = (root["alias_rules"] as? [[String: Any]] ?? []).compactMap { rule -> [String]? in
            guard let pattern = rule["pattern"] as? String, let canonical = rule["canonical"] as? String else { return nil }
            return [pattern, canonical.split(separator: "/").last.map(String.init) ?? canonical]
        }
        let fast = (root["fast_multipliers"] as? [String: Any] ?? [:]).compactMapValues(number)
        return (prices, aliases, fast)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite && double >= 0 ? double : nil
    }

    /// Dollars per token to dollars per million, without float noise (`4e-06` → `4`, not `3.9999999999999996`).
    private static func perMillion(_ rates: ModelPrice.Rates) -> ModelPrice.Rates {
        func round(_ value: Double) -> Double { (value * 1e12).rounded() / 1e6 }
        return ModelPrice.Rates(input: round(rates.input), output: round(rates.output), cacheRead: round(rates.cacheRead),
                                cacheWrite: round(rates.cacheWrite), cacheWriteHour: rates.cacheWriteHour.map(round))
    }

    /// The bundled catalog as Swift source, for `scripts/update-prices.sh`.
    public static func bundledSource(litellm: Data, supplement: Data) -> String? {
        guard let prices = Self.litellm(litellm), let extra = Self.supplement(supplement) else { return nil }
        let catalog = PriceCatalog(prices: prices, supplement: extra.prices, aliases: extra.aliases, fast: extra.fast)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try? encoder.encode(catalog), let text = String(data: json, encoding: .utf8) else { return nil }
        return """
        // Generated by scripts/update-prices.sh from LiteLLM's model_prices_and_context_window.json
        // (https://github.com/BerriAI/litellm, MIT) and OpenUsage's pricing_supplement.json
        // (https://github.com/robinebers/openusage, MIT). Don't edit by hand.

        enum BundledPrices {
            static let json = #\"\"\"
        \(text)
        \"\"\"#
        }

        """
    }
}

/// Keeps LiteLLM's list current: fetched at most once a day, cached, and used until the next fetch. The
/// request carries nothing about your usage.
public actor PriceUpdates {
    public static let shared = PriceUpdates()
    static let source = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private static let maxAge: TimeInterval = 86_400

    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dev.tasteskill.UsageGraphs/prices.json")

    private struct Cache: Codable {
        var fetchedAt: Date
        var etag: String?
        var prices: [String: ModelPrice]
    }

    /// The freshest prices on hand, without touching the network.
    public func current() -> PriceList {
        guard let cache = loadCache() else { return .bundled }
        return PriceList.bundled.replacingPrices(cache.prices)
    }

    /// Fetches the list if the cached copy is over a day old. Returns the new prices, or nil when nothing
    /// changed or the fetch failed.
    public func refreshIfStale() async -> PriceList? {
        let cache = loadCache()
        if let cache, Date().timeIntervalSince(cache.fetchedAt) < Self.maxAge { return nil }
        var request = URLRequest(url: Self.source, timeoutInterval: 30)
        if let etag = cache?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 304, var cache {
            cache.fetchedAt = Date()
            save(cache)
            return nil
        }
        guard http.statusCode == 200, let prices = PriceSources.litellm(data), prices.count > 100 else { return nil }
        save(Cache(fetchedAt: Date(), etag: http.value(forHTTPHeaderField: "ETag"), prices: prices))
        return PriceList.bundled.replacingPrices(prices)
    }

    private func loadCache() -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func save(_ cache: Cache) {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("swiftusage: could not save prices: \(error)")
        }
    }
}
