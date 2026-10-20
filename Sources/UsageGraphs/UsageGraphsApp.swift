import AppKit
import UsageCore

@MainActor
enum UsageGraphsApp {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        // Also covers running the bare binary during development, outside the LSUIElement bundle.
        app.setActivationPolicy(.accessory)
        app.mainMenu = mainMenu()
        app.run()
    }

    /// Never shown, since the app has no Dock icon, but it gives ⌘Q to the panel.
    private static func mainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit SwiftUsage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let menu = NSMenu()
        menu.addItem(appItem)
        return menu
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = Preferences()
        menuBar = MenuBarController(store: UsageStore(preferences: preferences), limits: LimitsStore(preferences: preferences), preferences: preferences)
    }
}

/// What the menu bar item shows, from the settings in Customize: today's tokens and cost, then the
/// pinned limits. The item and Customize's preview both draw it.
@MainActor
struct MenuBarContent {
    var tokens: String?
    var cost: String?
    var pinned: [(account: AccountLimits, meter: LimitMeter)]
    /// Limits read as what's left rather than what's used.
    var showsLeft: Bool

    init(store: UsageStore, limits: LimitsStore, showTokens: Bool, showCost: Bool, showsLeft: Bool) {
        if showTokens, store.todayTokens > 0 { tokens = Format.compact(store.todayTokens) }
        if showCost, let today = store.spend(for: nil)?.today, today > 0 { cost = Format.dollars(today) }
        pinned = limits.pinned
        self.showsLeft = showsLeft
    }

    /// Today's tokens and cost, as the menu bar reads them.
    var text: [String] { [tokens, cost].compactMap { $0 } }

    /// As saved by Customize.
    init(store: UsageStore, limits: LimitsStore, defaults: UserDefaults = .standard) {
        self.init(store: store, limits: limits, showTokens: defaults.object(forKey: "showTokensInMenuBar") as? Bool ?? true,
                  showCost: defaults.bool(forKey: "showCostInMenuBar"), showsLeft: defaults.bool(forKey: "menuBarShowsLeft"))
    }

    /// One account's pinned limits, which share its logo.
    struct Group: Identifiable {
        let account: AccountLimits
        var meters: [LimitMeter]
        var id: String { account.id }
    }

    /// In the order of each account's first pin, which dragging in Customize's preview rearranges.
    var groups: [Group] {
        var groups: [Group] = []
        for (account, meter) in pinned {
            if let index = groups.firstIndex(where: { $0.id == account.id }) {
                groups[index].meters.append(meter)
            } else {
                groups.append(Group(account: account, meters: [meter]))
            }
        }
        return groups
    }

    /// The share a limit's bar or ring fills: used, or left.
    func fraction(_ meter: LimitMeter) -> Double {
        showsLeft ? 1 - meter.fraction : meter.fraction
    }

    /// A limit's number in the menu bar. Used is rounded down like the panel's percentages, and left is
    /// rounded down too, so neither promises more than there is. The nudge keeps 0.58 × 100 from reading 57.
    func percent(_ meter: LimitMeter) -> Int {
        let used = meter.fraction * 100
        return showsLeft ? max(0, 100 - Int((used - 1e-6).rounded(.up))) : Int((used + 1e-6).rounded(.down))
    }

    /// `Session 58%`, or `Session 42% left`.
    func describe(_ meter: LimitMeter) -> String {
        showsLeft ? "\(meter.label) \(percent(meter))% left" : "\(meter.label) \(LimitText.used(meter))"
    }
}

/// The menu bar item with pinned limits, drawn as one template image so the system tints it for the
/// menu bar's appearance: today's tokens and cost, then for each account its provider's logo and the
/// percentages of its pinned limits.
enum MenuBarStrip {
    /// The menu bar item's font.
    static var font: NSFont { .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }

    @MainActor
    static func image(_ content: MenuBarContent, font: NSFont = font) -> NSImage {
        enum Piece {
            case logo(NSImage)
            case text(String, [NSAttributedString.Key: Any])
            case gap(CGFloat)
        }
        let rounded = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold).fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .semibold)
        let numbers: [NSAttributedString.Key: Any] = [.font: rounded, .foregroundColor: NSColor.black]
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular), .foregroundColor: NSColor.black]
        // The separator between one account's numbers, quieter than the numbers.
        let dot: [NSAttributedString.Key: Any] = [.font: rounded, .foregroundColor: NSColor.black.withAlphaComponent(0.45)]

        var pieces: [Piece] = []
        for item in content.text {
            if !pieces.isEmpty { pieces.append(.gap(5)) }
            pieces.append(.text(item, plain))
        }
        for group in content.groups {
            if !pieces.isEmpty { pieces.append(.gap(9)) }
            if let logo = ProviderLogo.template(group.account.provider) { pieces += [.logo(logo), .gap(4)] }
            for (offset, meter) in group.meters.enumerated() {
                if offset > 0 { pieces.append(.text("·", dot)) }
                pieces.append(.text(String(content.percent(meter)), numbers))
            }
        }

        let height: CGFloat = 22
        let logoSize: CGFloat = 14
        func width(_ piece: Piece) -> CGFloat {
            switch piece {
            case .logo: logoSize
            case .text(let string, let attributes): ceil((string as NSString).size(withAttributes: attributes).width)
            case .gap(let gap): gap
            }
        }
        let image = NSImage(size: NSSize(width: pieces.reduce(0) { $0 + width($1) }, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for piece in pieces {
                switch piece {
                case .logo(let logo):
                    // Drawn into a template image, so only its shape shows, in the menu bar's color.
                    logo.draw(in: NSRect(x: x, y: (height - logoSize) / 2, width: logoSize, height: logoSize))
                case .text(let string, let attributes):
                    let size = (string as NSString).size(withAttributes: attributes)
                    (string as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: attributes)
                case .gap:
                    break
                }
                x += width(piece)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = (content.text + content.pinned.map { name($0.account) + " " + content.describe($0.meter) })
            .joined(separator: ", ")
        return image
    }

    /// What the strip shows, spelled out: which account each logo's numbers belong to.
    @MainActor
    static func tooltip(_ content: MenuBarContent) -> String {
        content.groups.map { "\(name($0.account)): \($0.meters.map(content.describe).joined(separator: ", "))" }.joined(separator: "\n")
    }

    static func name(_ account: AccountLimits) -> String {
        [account.provider.name, account.account].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The SwiftUsage mark, drawn as a template image: a 3×3 grid of heatmap cells whose filled ones rise
/// like a bar chart (see `brand/`). The menu bar shows it only when it has nothing else to show, so the
/// item is still there to click.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            let filled = [false, false, true,
                          false, true, true,
                          true, true, true]
            // The mark's 32:12 cells and gaps, on whole pixels at 2x. Empty cells are a little stronger
            // than the logo's 18% so they still show at this size.
            let cell: CGFloat = 4
            let gap: CGFloat = 1.5
            let origin = (16 - (cell * 3 + gap * 2)) / 2
            for row in 0..<3 {
                for column in 0..<3 {
                    let rect = NSRect(x: origin + CGFloat(column) * (cell + gap), y: origin + CGFloat(row) * (cell + gap), width: cell, height: cell)
                    NSColor.black.withAlphaComponent(filled[row * 3 + column] ? 1 : 0.25).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SwiftUsage"
        return image
    }()
}
