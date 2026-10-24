import AppKit
import ServiceManagement
import UsageCore

@MainActor
enum UsageGraphsApp {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        takeOverFromOtherCopies()
        app.delegate = delegate
        // Also covers running the bare binary during development, outside the LSUIElement bundle.
        app.setActivationPolicy(.accessory)
        app.mainMenu = mainMenu()
        app.run()
    }

    /// The copy opened last takes over from any other that's running: a newer version dragged over the
    /// old one, or the one in Applications after one run from the disk image. Two would put two items in
    /// the menu bar and read every transcript twice.
    private static func takeOverFromOtherCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        // They save their indexes as they quit; waiting keeps two copies from writing the same files.
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
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

/// The standard About panel: the icon, the version, build and copyright from the bundle, where to follow
/// the app on X, and credit for the price lists (THIRD-PARTY-NOTICES.md has their licenses).
@MainActor
enum AboutPanel {
    /// `1.0.0 (12)`, or `development build` for the bare binary, which has no bundle around it.
    nonisolated static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String else { return "development build" }
        return (info["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }

    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let credits = NSMutableAttributedString(string: "Made by ", attributes: small)
        var link = small
        link[.link] = URL(string: "https://x.com/blueemi99")!
        credits.append(NSAttributedString(string: "@blueemi99", attributes: link))
        credits.append(NSAttributedString(string: ". Follow along on X for updates.\n\n", attributes: small))
        var quiet = small
        quiet[.foregroundColor] = NSColor.secondaryLabelColor
        credits.append(NSAttributedString(
            string: "Prices from LiteLLM and OpenUsage, both under the MIT License. Provider names and logos belong to their owners.",
            attributes: quiet))
        // The app has no Dock icon, so it comes forward first or the panel opens behind the app in front.
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// Whether the app opens at login, as macOS has it: the ⋯ menu and Customize both set it, and it can be
/// turned off in System Settings too, so it's read again each time the panel opens (asking macOS is a
/// round trip, too slow for every redraw).
@MainActor
@Observable
final class LoginItem {
    static let shared = LoginItem()

    private(set) var isEnabled = false
    /// Why the last change didn't take.
    private(set) var problem: String?
    /// Counts changes asked for, so only the latest one's outcome is shown.
    @ObservationIgnored private var attempt = 0

    private init() {
        reload()
    }

    func reload() {
        isEnabled = SMAppService.mainApp.status == .enabled
        if isEnabled { problem = nil }
    }

    /// Shows the change at once and asks macOS for it off the main thread, then shows what macOS did.
    func set(_ enabled: Bool) {
        isEnabled = enabled
        problem = nil
        attempt += 1
        let attempt = attempt
        Task.detached {
            let service = SMAppService.mainApp
            var failure: Error?
            do {
                if enabled {
                    try service.register()
                } else {
                    try await service.unregister()
                }
            } catch {
                failure = error
                NSLog("swiftusage: login item change failed: \(error)")
            }
            let status = service.status
            await self.landed(enabled, status: status, failure: failure, attempt: attempt)
        }
    }

    private func landed(_ enabled: Bool, status: SMAppService.Status, failure: Error?, attempt: Int) {
        guard attempt == self.attempt else { return }
        isEnabled = status == .enabled
        guard isEnabled != enabled else {
            problem = nil
            return
        }
        // A login item the person once turned off in System Settings has to be allowed there again.
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        problem = switch status {
        case .requiresApproval: "Allow SwiftUsage in System Settings, under Login Items."
        case .notFound: "Only a copy of SwiftUsage in Applications can open at login."
        default: failure.map { "macOS didn't change it: \($0.localizedDescription)" } ?? "macOS didn't change it."
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = Preferences()
        let usage = UsageStore(preferences: preferences)
        let limits = LimitsStore(preferences: preferences)
        Telemetry.shared.start(usage: usage, limits: limits, preferences: preferences)
        menuBar = MenuBarController(store: usage, limits: limits, preferences: preferences)
        Updater.shared.start()
        // The first time, the panel opens by itself, under the item it's found at from then on, once the
        // menu bar has placed the item.
        if !UserDefaults.standard.bool(forKey: "hasOpened") {
            UserDefaults.standard.set(true, forKey: "hasOpened")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.menuBar?.show()
            }
        }
    }

    /// Opening the app while it runs, from Finder, Spotlight or Launchpad, opens the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.show()
        return false
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

/// The SwiftUsage mark, drawn as a template image: a tilde, one round-capped stroke (see `brand/`). The
/// menu bar shows it only when it has nothing else to show, so the item is still there to click.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            // The mark's 120 grid, its caps reaching the sides. The stroke is a little lighter than the
            // logo's so it sits with the menu bar's other icons.
            let width: CGFloat = 2.6
            let unit = (16 - width) / 96
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 8 + (x - 60) * unit, y: 8 + (y - 60) * unit) }
            let tilde = NSBezierPath()
            tilde.move(to: point(12, 74))
            tilde.curve(to: point(60, 60), controlPoint1: point(24, 36), controlPoint2: point(52, 36))
            tilde.curve(to: point(108, 46), controlPoint1: point(68, 84), controlPoint2: point(96, 84))
            tilde.lineWidth = width
            tilde.lineCapStyle = .round
            NSColor.black.setStroke()
            tilde.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SwiftUsage"
        return image
    }()
}
