import Foundation

public enum ModelName {
    private static let claudeFamilies = ["opus", "sonnet", "haiku", "fable", "mythos", "instant"]
    /// Words that tools append to a Claude model's ID for a reasoning mode or context size. The model is
    /// the same one, so they're dropped.
    private static let claudeQualifiers: Set = ["thinking", "minimal", "low", "medium", "high", "xhigh", "max", "fast", "1m"]
    /// Reasoning effort that tools append to a model's ID. Trailing ones are dropped; "max" isn't one,
    /// since for some models (GPT-5.1 Codex Max) it's part of the name.
    private static let efforts: Set = ["minimal", "low", "medium", "high", "xhigh"]
    private static let words: [String: String] = [
        "gpt": "GPT", "glm": "GLM", "oss": "OSS", "deepseek": "DeepSeek", "xai": "xAI", "openai": "OpenAI", "swe": "SWE",
    ]

    /// `claude-opus-5-5` → `Opus 5.5`, `claude-3-5-sonnet-20241022` → `Sonnet 3.5`, `opus` → `Opus`,
    /// `gpt-5.5-codex` → `GPT-5.5 Codex`, `gemini-3-pro-preview` → `Gemini 3 Pro Preview`,
    /// `anthropic/claude-sonnet-4-5` → `Sonnet 4.5`, `gpt-6-1-sol-xhigh` → `GPT-6.1 Sol`.
    public static func display(_ id: String) -> String {
        var name = id.lowercased()
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        // Bedrock's `us.anthropic.claude-haiku-4-5-20251001-v1:0`: a region, the vendor, then a version of
        // its own after the model's. Other models keep a `-v3` that's part of their name (`deepseek-v3`).
        if let anthropic = name.range(of: "anthropic.") {
            name = String(name[anthropic.upperBound...])
            if let dash = name.range(of: "-v", options: .backwards) {
                let pieces = name[dash.upperBound...].split(separator: ":", omittingEmptySubsequences: false)
                if (1...2).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                    name = String(name[..<dash.lowerBound])
                }
            }
        }
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }

        var parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        if parts.last == "latest" { parts.removeLast() }
        while parts.count > 1, let last = parts.last, efforts.contains(last) { parts.removeLast() }
        guard !parts.isEmpty else { return id }

        if let familyIndex = parts.firstIndex(where: { claudeFamilies.contains($0) }) {
            let family = parts[familyIndex].prefix(1).uppercased() + parts[familyIndex].dropFirst()
            // Other tools wrap Claude's IDs (`antigravity-claude-opus-4-5-thinking`); with "claude" in
            // the ID, only the family and version matter.
            let wrapped = id.lowercased().contains("claude")
            let rest = parts.enumerated().filter { $0.offset != familyIndex }.map(\.element)
                .filter { !claudeQualifiers.contains($0) && (!wrapped || isVersion($0)) }
            if rest.allSatisfy(isVersion) {
                let version = rest.joined(separator: ".")
                return version.isEmpty ? family : family + " " + version
            }
        }
        return generic(parts)
    }

    private static func isVersion(_ part: String) -> Bool {
        !part.isEmpty && part.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Capitalized words, with runs of bare numbers joined into one version (`2-5` → `2.5`). GPT keeps
    /// its hyphen (`GPT-5.5`).
    private static func generic(_ parts: [String]) -> String {
        var out: [String] = []
        for part in parts {
            if isVersion(part), let last = out.last, isVersion(last), !last.contains("."), !part.contains(".") {
                out[out.count - 1] = last + "." + part
            } else {
                out.append(part)
            }
        }
        var words = out.map { word -> String in
            if let known = Self.words[word] { return known }
            if isVersion(word) { return word }
            // o3, o4: OpenAI's reasoning models stay lowercase.
            if word.count <= 3, word.first == "o", word.dropFirst().allSatisfy(\.isNumber) { return word }
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        if words.first == "GPT", words.count > 1 {
            words[0] = "GPT-" + words[1]
            words.remove(at: 1)
        }
        return words.joined(separator: " ")
    }
}

public enum Format {
    private static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /// 242379 → "242,379"
    public static func grouped(_ value: Int) -> String {
        grouped.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 1234.5 → "1,234.5", 0.75 → "0.75", 12 → "12"
    public static func grouped(_ value: Double) -> String {
        grouped.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 23_612_000_000 → "23.6B", 41_200_000 → "41.2M", 950 → "950".
    public static func compact(_ value: Int64) -> String {
        let v = Double(value)
        switch abs(v) {
        case 999_950_000...: return String(format: "%.1fB", v / 1e9)
        case 999_950...: return String(format: "%.1fM", v / 1e6)
        case 1000...: return String(format: "%.1fK", v / 1e3)
        default: return String(value)
        }
    }

    /// 12_431.5 → "$12.4K", 361.03 → "$361", 4.08 → "$4.08", 0.004 → "<$0.01", 0 → "$0".
    public static func dollars(_ value: Double) -> String {
        switch abs(value) {
        case 999_950...: return String(format: "$%.1fM", value / 1e6)
        case 9_995...: return String(format: "$%.1fK", value / 1e3)
        case 999.5...: return String(format: "$%.2fK", value / 1e3)
        case 99.5...: return String(format: "$%.0f", value)
        case 0.01...: return String(format: "$%.2f", value)
        case 0: return "$0"
        default: return "<$0.01"
        }
    }

    /// 23 → "11 PM", 0 → "12 AM"
    public static func hour(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h) \(hour < 12 ? "AM" : "PM")"
    }
}

/// The "you've used more tokens than a novel" line, with the book lengths Claude Code uses.
public enum TokenComparison {
    public static let books: [(name: String, tokens: Int64)] = [
        ("The Little Prince", 22_000),
        ("The Old Man and the Sea", 35_000),
        ("A Christmas Carol", 37_000),
        ("Animal Farm", 39_000),
        ("Fahrenheit 451", 60_000),
        ("The Great Gatsby", 62_000),
        ("Slaughterhouse-Five", 64_000),
        ("Brave New World", 83_000),
        ("The Catcher in the Rye", 95_000),
        ("Harry Potter and the Philosopher's Stone", 103_000),
        ("The Hobbit", 123_000),
        ("1984", 123_000),
        ("To Kill a Mockingbird", 130_000),
        ("Pride and Prejudice", 156_000),
        ("Dune", 244_000),
        ("Moby-Dick", 268_000),
        ("Crime and Punishment", 274_000),
        ("A Game of Thrones", 381_000),
        ("Anna Karenina", 468_000),
        ("Don Quixote", 520_000),
        ("The Lord of the Rings", 576_000),
        ("The Count of Monte Cristo", 603_000),
        ("Les Misérables", 689_000),
        ("War and Peace", 730_000),
    ]

    /// Every comparison that applies to `tokens`; callers pick one. Once usage dwarfs short books,
    /// only full-length novels are offered, so the line stays "~2,000× The Lord of the Rings"
    /// rather than "~800,000× The Little Prince".
    public static func sentences(for tokens: Int64) -> [String] {
        guard tokens > 0 else { return [] }
        let novelLength: Int64 = 100_000
        let candidates = tokens >= novelLength * 2 ? books.filter { $0.tokens >= novelLength } : books
        var lines: [String] = []
        for book in candidates where tokens >= book.tokens {
            let ratio = tokens / book.tokens
            if ratio >= 2 {
                lines.append("You've used ~\(Format.grouped(Int(ratio)))× more tokens than \(book.name).")
            } else {
                lines.append("You've used about as many tokens as \(book.name).")
            }
        }
        if lines.isEmpty {
            let percent = max(1, Int(Double(tokens) / Double(books[0].tokens) * 100))
            lines.append("You've used \(percent)% of the tokens in \(books[0].name).")
        }
        return lines
    }
}
