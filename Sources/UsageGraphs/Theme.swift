import AppKit
import SwiftUI
import UsageCore

/// Everything else uses system styles. The panel is always drawn in the dark appearance, like Control
/// Center, so its glass reads as one tinted layer over the dimmed screen.
enum Theme {
    static let emptyCell = Color.primary.opacity(0.09)

    /// Heatmap intensity, faintest to strongest: GitHub's contribution greens, stepped so the faintest
    /// still shows on glass in either appearance.
    static let heat = [
        Color(light: 0x58BD6F, dark: 0x1B7A37),
        Color(light: 0x2F9F4E, dark: 0x22994A),
        Color(light: 0x22803C, dark: 0x30C25A),
        Color(light: 0x16552A, dark: 0x4CE36C),
    ]

    /// Per-model colors for the Models tab, by rank, then gray for everything else.
    static let models: [Color] = [.green, .blue, .orange, .purple, .gray]

    static func modelColor(rank: Int) -> Color {
        models[min(rank, models.count - 1)]
    }

    /// A limit's bar: green while it's on course to last, yellow when it'll be close, red when it'll run out.
    static func paceColor(_ verdict: Pace.Verdict) -> Color {
        switch verdict {
        case .fine: heat[2]
        case .tight: .yellow
        case .over, .reached: .red
        }
    }

    /// How much the screen behind the panel darkens while it's open, as Control Center does.
    static let dimming: CGFloat = 0.18

    /// Every animation in the panel, so they all move with the same feel: springs with a visible bounce
    /// for anything that arrives, moves or changes, and quick eases only for what's leaving, which a
    /// spring would bounce back into view.
    enum Motion {
        /// Opening: the modules drop down into place and bounce as they land.
        static let open = Animation.spring(duration: 0.5, bounce: 0.38)
        static let close = Animation.smooth(duration: 0.2)
        /// Window fades, which Core Animation runs alongside the springs.
        static let fadeIn: TimeInterval = 0.2
        static let fadeOut: TimeInterval = 0.17
        /// Switching tab, provider or range: the selection pill overshoots and springs back.
        static let select = Animation.spring(duration: 0.4, bounce: 0.3)
        /// Whatever is being replaced, so old and new barely overlap.
        static let leave = Animation.easeIn(duration: 0.14)
        /// Text being replaced in place. It fades fastest at the start, so it's mostly gone before the
        /// new text shows; an ease-in would keep it near full strength over the new text.
        static let textOut = Animation.easeOut(duration: 0.09)
        /// A value's characters rolling into place: quick, settling with a bounce like a reel.
        static let roll = Animation.spring(duration: 0.5, bounce: 0.32)
        /// A value's characters morphing into new ones in place, the new ones popping a little past full
        /// size before they settle.
        static let morph = Animation.spring(duration: 0.45, bounce: 0.32)
        /// New numbers arriving while the panel is open.
        static let data = Animation.spring(duration: 0.55, bounce: 0.28)
        /// Pointer feedback: quick, with a little spring where something moves, like the heatmap's ring
        /// overshooting into the next day.
        static let hover = Animation.spring(duration: 0.24, bounce: 0.3)
        /// Turning something on or off in Customize: lively, with a clear overshoot.
        static let toggle = Animation.spring(duration: 0.42, bounce: 0.38)
        /// An account in the menu bar preview lifting as it's dragged, the others stepping aside for it,
        /// and settling where it's dropped.
        static let reorder = Animation.spring(duration: 0.34, bounce: 0.3)
        /// A button sinking as it's pressed and springing back past its size.
        static let press = Animation.spring(duration: 0.3, bounce: 0.5)
        /// The caption under the pointer: quick, so it keeps up with the pointer.
        static let caption = Animation.easeOut(duration: 0.12)
        /// The refresh arrow following each step of its turn. A spring keeps its speed from step to
        /// step, so it gathers speed, turns evenly, and wobbles past upright when the steps stop.
        static let spin = Animation.spring(duration: 0.6, bounce: 0.32)
    }

    enum Layout {
        static let contentWidth: CGFloat = 500
        /// Clear space around the modules inside the panel window, so their shadows aren't clipped.
        static let margin: CGFloat = 22
        /// Gap between the menu bar and the first row of modules.
        static let topGap: CGFloat = 7
        static let spacing: CGFloat = 10
        static let moduleRadius: CGFloat = 26
        static let tileRadius: CGFloat = 22
        static let modulePadding: CGFloat = 16

        // The heatmap, sized like GitHub's contribution graph: 10pt cells 3pt apart, as many weeks as fit.
        static let cellSize: CGFloat = 10
        static let cellGap: CGFloat = 3
        static let cellRadius: CGFloat = 2.5
        static let dayLabelWidth: CGFloat = 26
        static let monthLabelHeight: CGFloat = 15
        static var weeks: Int {
            Int((contentWidth - modulePadding * 2 - dayLabelWidth + cellGap) / (cellSize + cellGap))
        }
        static var heatmapWidth: CGFloat { dayLabelWidth + CGFloat(weeks) * (cellSize + cellGap) - cellGap }
        static var heatmapHeight: CGFloat { monthLabelHeight + cellSize * 7 + cellGap * 6 }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// A Liquid Glass module floating over the dimmed screen, like a Control Center module.
    func module(cornerRadius: CGFloat = Theme.Layout.moduleRadius) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    /// Shows or hides one tab's glass container. Both tabs stay built, so switching only fades: the one
    /// leaving clears out quickly and the one arriving settles in just after, so their glass barely
    /// overlaps rather than showing both layouts at half strength.
    func tabVisible(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.96, anchor: .top)
            .animation(visible ? Theme.Motion.select.delay(0.05) : Theme.Motion.leave, value: visible)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}
