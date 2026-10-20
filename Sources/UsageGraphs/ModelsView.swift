import SwiftUI
import UsageCore

struct ModelsView: View {
    let stats: RangeStats
    /// Changes with the provider and range shown, so switching cross-fades the chart and list.
    var contentID = ""
    @Environment(PanelState.self) private var state

    var body: some View {
        let data = TokenChartData(stats: stats)
        VStack(spacing: Theme.Layout.spacing) {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(data.bucketDays == 1 ? "Tokens per day" : "Tokens per week", systemImage: "chart.bar.fill")
                ZStack {
                    TokenChart(data: data)
                        .id(contentID)
                        .transition(.opacity)
                }
                .frame(minHeight: 90, maxHeight: .infinity)
            }
            .padding(Theme.Layout.modulePadding)
            .module()
            // With no models in the period, the chart says so and takes the list's place.
            if !stats.models.isEmpty {
                ZStack {
                    modelList(colors: data.colors)
                        .id(contentID)
                        .transition(.opacity)
                }
                // Five rows show at once; the chart above takes whatever height is left.
                .frame(height: CGFloat(min(stats.models.count, 5)) * ModelRow.height + Self.listMargin * 2)
                .module()
            }
        }
    }

    private static let listMargin: CGFloat = 8

    /// Rows passing through the margins fade out, so the one after the fifth doesn't peek in at the
    /// bottom edge.
    private func modelList(colors: [String: Color]) -> some View {
        ScrollView(.vertical) {
            // Lazy, so only the rows in view are built when the list changes.
            LazyVStack(spacing: 0) {
                ForEach(stats.models) { model in
                    ModelRow(model: model, color: colors[model.name] ?? TokenChartData.otherColor) { hovering in
                        state.chartHover = hovering ? details(for: model) : nil
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .contentMargins(Self.listMargin, for: .scrollContent)
        .modifier(ScrollEdgeFade(length: Self.listMargin))
    }

    /// The row already shows the cost, so the caption has room for the four kinds of tokens.
    private func details(for model: ModelStats) -> String {
        let t = model.tokens
        let price = model.cost == nil ? " · No known price" : ""
        return "\(model.name) · In \(Format.compact(t.input)) · Out \(Format.compact(t.output)) · Cache read \(Format.compact(t.cacheRead)) · Cache write \(Format.compact(t.cacheWrite))\(price)"
    }
}

/// Tokens per day or week, stacked by model, worked out once per change rather than per frame.
struct TokenChartData {
    static let maxSeries = 4
    static let otherName = "Other"
    static let otherColor = Theme.models.last!

    struct Bucket {
        var day: Int
        /// Tokens per series, biggest model first so it sits at the bottom.
        var segments: [(series: Int, tokens: Int64)]
        var total: Int64
    }

    let firstDay: Int
    let lastBucket: Int
    /// Daily bars for short spans, weekly once a range covers more than about two months.
    let bucketDays: Int
    let series: [String]
    let seriesColors: [Color]
    /// Each model in the list by name, and the color its bars have. Models past the first four are in
    /// the gray "Other" series instead, which a model of that name doesn't share.
    let colors: [String: Color]
    let buckets: [Bucket]
    let ticks: [Int64]

    init(stats: RangeStats) {
        firstDay = stats.firstDay
        bucketDays = stats.today - stats.firstDay + 1 > 62 ? 7 : 1
        lastBucket = stats.firstDay + (stats.today - stats.firstDay) / bucketDays * bucketDays
        let top = stats.models.prefix(Self.maxSeries).map(\.name)
        var names = top
        if stats.models.count > Self.maxSeries { names.append(Self.otherName) }
        series = names
        seriesColors = names.indices.map { $0 < top.count ? Theme.modelColor(rank: $0) : Self.otherColor }
        colors = Dictionary(zip(top, seriesColors), uniquingKeysWith: { first, _ in first })

        let index = Dictionary(uniqueKeysWithValues: stats.models.prefix(Self.maxSeries).enumerated().map { ($1.id, $0) })
        let other = names.count - 1
        var totals: [Int: [Int: Int64]] = [:]
        for (day, models) in stats.dayModelTokens {
            let bucket = stats.firstDay + (day - stats.firstDay) / bucketDays * bucketDays
            for (model, tokens) in models {
                totals[bucket, default: [:]][index[model] ?? other, default: 0] += tokens
            }
        }
        buckets = totals.map { day, bySeries in
            let segments = bySeries.sorted { $0.key < $1.key }.map { (series: $0.key, tokens: $0.value) }
            return Bucket(day: day, segments: segments, total: segments.reduce(0) { $0 + $1.tokens })
        }.sorted { $0.day < $1.day }
        ticks = Self.ticks(max: buckets.map(\.total).max() ?? 0)
    }

    /// Days the x axis spans, with half a bar of room at each end.
    var domain: ClosedRange<Double> {
        (Double(firstDay) - Double(bucketDays) * 0.6)...(Double(lastBucket) + Double(bucketDays) * 0.6)
    }

    /// Up to four evenly spread bar positions to label.
    var xTicks: [Int] {
        let span = lastBucket - firstDay
        guard span > 0 else { return [firstDay] }
        let steps = max(min(3, span / bucketDays), 1)
        return (0...steps).map { step in
            let day = firstDay + span * step / steps
            return firstDay + (day - firstDay) / bucketDays * bucketDays
        }
    }

    /// 0, a round step and twice it, with the top at or above the tallest bar.
    static func ticks(max: Int64) -> [Int64] {
        guard max > 0 else { return [0, 1, 2] }
        let rough = Double(max) / 2
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? 10 * magnitude
        return [0, Int64(step), Int64(step * 2)]
    }
}

/// A stacked bar chart drawn in three layers: axes, bars and the bar under the pointer. Hovering
/// redraws only the highlighted bar while the rest dim with a fade the GPU runs, so the pointer never
/// waits on a full redraw.
private struct TokenChart: View {
    let data: TokenChartData
    @Environment(PanelState.self) private var state
    @State private var size: CGSize = .zero
    @State private var hovered: Int?

    private static let labelFont = Font.system(size: 10)

    var body: some View {
        ZStack {
            Canvas { context, size in drawAxes(in: &context, layout: Layout(size: size, data: data)) }
            Canvas { context, size in drawBars(data.buckets, in: &context, layout: Layout(size: size, data: data)) }
                .opacity(hovered == nil ? 1 : 0.32)
            Canvas { context, size in
                drawBars(data.buckets.filter { $0.day == hovered }, in: &context, layout: Layout(size: size, data: data))
            }
            if data.buckets.isEmpty {
                Text("No usage in this period")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .animation(Theme.Motion.hover, value: hovered == nil)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onContinuousHover { phase in
            guard case .active(let point) = phase else { return setHover(nil) }
            setHover(Layout(size: size, data: data).bucket(at: point.x))
        }
    }

    private struct Layout {
        let plot: CGRect
        let data: TokenChartData

        init(size: CGSize, data: TokenChartData) {
            self.data = data
            plot = CGRect(x: 0, y: 5, width: max(1, size.width - 38), height: max(1, size.height - 22))
        }

        func x(_ day: Double) -> CGFloat {
            let domain = data.domain
            return plot.minX + CGFloat((day - domain.lowerBound) / (domain.upperBound - domain.lowerBound)) * plot.width
        }

        func y(_ tokens: Int64) -> CGFloat {
            plot.maxY - CGFloat(Double(tokens) / Double(max(data.ticks.last ?? 1, 1))) * plot.height
        }

        var barWidth: CGFloat {
            max(1.5, x(Double(data.bucketDays) * 0.72) - x(0))
        }

        func bucket(at x: CGFloat) -> Int? {
            let domain = data.domain
            let day = Int((domain.lowerBound + Double((x - plot.minX) / plot.width) * (domain.upperBound - domain.lowerBound)).rounded())
            guard day >= data.firstDay else { return nil }
            let bucket = data.firstDay + (day - data.firstDay) / data.bucketDays * data.bucketDays
            return bucket <= data.lastBucket ? bucket : nil
        }
    }

    private func drawAxes(in context: inout GraphicsContext, layout: Layout) {
        let grid = Color.primary.opacity(0.18)
        for tick in data.ticks {
            let y = layout.y(tick)
            var line = Path()
            line.move(to: CGPoint(x: layout.plot.minX, y: y))
            line.addLine(to: CGPoint(x: layout.plot.maxX, y: y))
            context.stroke(line, with: .color(grid), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let label = Text(Self.axisLabel(tick)).font(Self.labelFont).foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: layout.plot.maxX + 6, y: y), anchor: .leading)
        }
        let ticks = data.xTicks
        for (index, day) in ticks.enumerated() {
            // Edge labels hug the plot edges instead of running past them.
            let anchor: UnitPoint = ticks.count > 1 && index == 0 ? .topLeading : ticks.count > 1 && index == ticks.count - 1 ? .topTrailing : .top
            let date = DayClock().date(of: day).formatted(.dateTime.month(.abbreviated).day())
            let label = Text(date).font(Self.labelFont).foregroundStyle(.secondary)
            let x = min(max(layout.x(Double(day)), layout.plot.minX), layout.plot.maxX)
            context.draw(label, at: CGPoint(x: x, y: layout.plot.maxY + 5), anchor: anchor)
        }
    }

    /// `20B` rather than `20.0B`: the ticks are round numbers, so a trailing `.0` is noise.
    private static func axisLabel(_ tick: Int64) -> String {
        let label = Format.compact(tick)
        guard let unit = label.last, unit.isLetter, label.dropLast().hasSuffix(".0") else { return label }
        return label.dropLast(3) + String(unit)
    }

    private func drawBars(_ buckets: [TokenChartData.Bucket], in context: inout GraphicsContext, layout: Layout) {
        let width = layout.barWidth
        let radius = min(1.5, width / 2)
        for bucket in buckets {
            let left = layout.x(Double(bucket.day)) - width / 2
            var low: Int64 = 0
            for segment in bucket.segments {
                let top = layout.y(low + segment.tokens)
                let bottom = layout.y(low)
                low += segment.tokens
                guard bottom - top > 0.25 else { continue }
                let rect = CGRect(x: left, y: top, width: width, height: bottom - top)
                context.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(data.seriesColors[segment.series]))
            }
        }
    }

    private func setHover(_ bucket: Int?) {
        guard hovered != bucket else { return }
        hovered = bucket
        guard let bucket else {
            state.chartHover = nil
            return
        }
        let date = DayClock().date(of: bucket)
        let label = data.bucketDays == 1
            ? date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            : "Week of " + date.formatted(.dateTime.month(.abbreviated).day())
        guard let entry = data.buckets.first(where: { $0.day == bucket }), entry.total > 0 else {
            state.chartHover = "\(label) · No usage"
            return
        }
        let breakdown = entry.segments.sorted { $0.tokens > $1.tokens }.prefix(2)
            .map { "\(data.series[$0.series]) \(Format.compact($0.tokens))" }.joined(separator: ", ")
        state.chartHover = "\(label) · \(Format.compact(entry.total)) tokens · \(breakdown)"
    }
}

private struct ModelRow: View {
    static let height: CGFloat = 26

    let model: ModelStats
    let color: Color
    let onHover: (Bool) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Rasterized, so glass doesn't lighten the colors away from the chart's (as it does with
            // vibrancy for shapes drawn on it).
            Circle().fill(color).frame(width: 8, height: 8).drawingGroup()
            Text(model.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
            GeometryReader { geometry in
                Capsule()
                    .fill(.primary.opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: max(5, geometry.size.width * model.share)).drawingGroup()
                    }
            }
            .frame(height: 5)
            Text(Format.compact(model.tokens.total))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            Text(model.cost.map(Format.dollars) ?? "–")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            // A sliver of the total reads as under 0.1% rather than as none at all.
            Text(model.share > 0 && model.share < 0.0005 ? "<0.1%" : String(format: "%.1f%%", model.share * 100))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .frame(width: 46, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: Self.height)
        .background(Capsule().fill(.primary.opacity(hovering ? 0.1 : 0)))
        .animation(Theme.Motion.hover, value: hovering)
        .contentShape(Capsule())
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
    }
}
