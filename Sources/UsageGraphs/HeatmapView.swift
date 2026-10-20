import SwiftUI
import UsageCore

/// A GitHub-style contribution graph. Weeks run left to right, days top to bottom, ending with the current
/// week, with month names above and Mon, Wed and Fri beside the rows. Days after today are left out and
/// days before the selected range stay dark.
struct HeatmapView: View {
    let stats: RangeStats
    @Environment(PanelState.self) private var state

    private let weeks = Theme.Layout.weeks
    private let cell = Theme.Layout.cellSize
    private let gap = Theme.Layout.cellGap
    private let gridOrigin = CGPoint(x: Theme.Layout.dayLabelWidth, y: Theme.Layout.monthLabelHeight)

    private var firstDay: Int {
        let firstWeekday = Calendar.current.firstWeekday
        let intoWeek = (DayClock.weekday(of: stats.today) - firstWeekday + 7) % 7
        return stats.today - intoWeek - (weeks - 1) * 7
    }

    var body: some View {
        let start = firstDay
        let thresholds = quartiles(start: start)
        // The cells only redraw when the numbers change; the ring under the pointer is its own layer.
        Canvas { context, _ in
            for (column, name) in monthLabels(start: start) {
                context.draw(label(name), at: CGPoint(x: gridOrigin.x + CGFloat(column) * (cell + gap), y: 0), anchor: .topLeading)
            }
            for row in 0..<7 {
                let weekday = (Calendar.current.firstWeekday - 1 + row) % 7 + 1
                guard [2, 4, 6].contains(weekday) else { continue }
                let y = cellRect(column: 0, row: row).midY
                context.draw(label(Calendar.current.shortWeekdaySymbols[weekday - 1]), at: CGPoint(x: 0, y: y), anchor: .leading)
            }
            for column in 0..<weeks {
                for row in 0..<7 {
                    let day = start + column * 7 + row
                    guard day <= stats.today else { continue }
                    let rect = cellRect(column: column, row: row)
                    HeatCell.draw(in: &context, rect: rect, color: color(for: day, thresholds: thresholds))
                }
            }
        }
        .overlay(alignment: .topLeading) {
            HoverRing { day in
                let offset = day - start
                guard offset >= 0, offset < weeks * 7, day <= stats.today else { return nil }
                return cellRect(column: offset / 7, row: offset % 7)
            }
        }
        .frame(width: Theme.Layout.heatmapWidth, height: Theme.Layout.heatmapHeight)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let day = day(at: point, start: start)
                if state.hoveredDay != day { state.hoveredDay = day }
            case .ended:
                if state.hoveredDay != nil { state.hoveredDay = nil }
            }
        }
    }

    private func label(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }

    /// A month is named above the first week that starts in it. Like GitHub, the partial month at the left
    /// edge is only named when there's room before the next one.
    private func monthLabels(start: Int) -> [(column: Int, name: String)] {
        var labels: [(column: Int, name: String)] = []
        var previous = 0
        for column in 0..<weeks {
            let (_, month, _) = DayClock.civil(fromDays: start + column * 7)
            guard month != previous else { continue }
            labels.append((column, Calendar.current.shortMonthSymbols[month - 1]))
            previous = month
        }
        if labels.count > 1, labels[1].column - labels[0].column < 3 {
            labels.removeFirst()
        }
        return labels
    }

    private func cellRect(column: Int, row: Int) -> CGRect {
        CGRect(x: gridOrigin.x + CGFloat(column) * (cell + gap), y: gridOrigin.y + CGFloat(row) * (cell + gap), width: cell, height: cell)
    }

    private func day(at point: CGPoint, start: Int) -> Int? {
        let x = point.x - gridOrigin.x
        let y = point.y - gridOrigin.y
        guard x >= 0, y >= 0 else { return nil }
        let column = Int(x / (cell + gap))
        let row = Int(y / (cell + gap))
        guard (0..<weeks).contains(column), (0..<7).contains(row) else { return nil }
        let day = start + column * 7 + row
        return day <= stats.today ? day : nil
    }

    /// Upper bounds of the first three shades: the quartiles of active days in view, as GitHub does, so
    /// one outsized day doesn't flatten everything else into the faintest shade.
    private func quartiles(start: Int) -> [Int] {
        let counts = stats.days.lazy.filter { $0.key >= max(start, stats.firstDay) && $0.value.messages > 0 }.map(\.value.messages).sorted()
        guard !counts.isEmpty else { return [0, 0, 0] }
        return [0.25, 0.5, 0.75].map { counts[min(counts.count - 1, Int(Double(counts.count) * $0))] }
    }

    private func color(for day: Int, thresholds: [Int]) -> Color {
        guard day >= stats.firstDay, let messages = stats.days[day]?.messages, messages > 0 else {
            return Theme.emptyCell
        }
        let level = thresholds.firstIndex { messages <= $0 } ?? 3
        return Theme.heat[level]
    }
}

/// The outline around the day under the pointer. It glides from cell to cell and fades in and out, and
/// is the only part of the heatmap that redraws as the pointer moves.
private struct HoverRing: View {
    let rect: (Int) -> CGRect?
    @Environment(PanelState.self) private var state
    @State private var lastRect: CGRect?

    var body: some View {
        let current = state.hoveredDay.flatMap(rect)
        let shown = current ?? lastRect ?? .zero
        RoundedRectangle(cornerRadius: Theme.Layout.cellRadius + 1, style: .continuous)
            .stroke(.primary, lineWidth: 1.5)
            .frame(width: shown.width + 2, height: shown.height + 2)
            .offset(x: shown.minX - 1, y: shown.minY - 1)
            .opacity(current == nil ? 0 : 1)
            .animation(Theme.Motion.hover, value: current)
            .allowsHitTesting(false)
            .onChange(of: current) { _, new in
                // Fading out in place rather than flying back to the corner.
                if let new { lastRect = new }
            }
    }
}

/// One day square.
enum HeatCell {
    static func draw(in context: inout GraphicsContext, rect: CGRect, color: Color) {
        context.fill(Path(roundedRect: rect, cornerRadius: Theme.Layout.cellRadius, style: .continuous), with: .color(color))
    }
}

/// "Less ▢▢▢▢▢ More", as under a GitHub contribution graph.
struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Less")
            Canvas { context, _ in
                for (i, color) in ([Theme.emptyCell] + Theme.heat).enumerated() {
                    let rect = CGRect(x: CGFloat(i) * (Theme.Layout.cellSize + Theme.Layout.cellGap), y: 0,
                                      width: Theme.Layout.cellSize, height: Theme.Layout.cellSize)
                    HeatCell.draw(in: &context, rect: rect, color: color)
                }
            }
            .frame(width: Theme.Layout.cellSize * 5 + Theme.Layout.cellGap * 4, height: Theme.Layout.cellSize)
            Text("More")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }
}
