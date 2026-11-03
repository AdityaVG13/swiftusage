import AppKit
import Observation
import SwiftUI
import UsageCore

/// Whether the panel's modules are settled in place; flipped with an animation as it opens and closes.
@MainActor
@Observable
final class PanelPresentation {
    var isPresented = false
}

/// The menu bar item and its panel. The panel opens the way Control Center does: the screen dims and
/// the modules float on it as separate pieces of Liquid Glass. A SwiftUI `MenuBarExtra` can't do this,
/// since its window draws one glass backdrop under everything.
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private let store: UsageStore
    private let limits: LimitsStore
    private let preferences: Preferences
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let presentation = PanelPresentation()
    private let state = PanelState()
    private let panel = GlassPanel()
    private let dimmer = DimmingWindow()
    private var monitors: [Any] = []
    private var isOpen = false
    private var hasPrewarmed = false
    /// Rereads after providers are turned on or off, once a quick run of switches has settled.
    private var providersWork: Task<Void, Never>?

    init(store: UsageStore, limits: LimitsStore, preferences: Preferences) {
        self.store = store
        self.limits = limits
        self.preferences = preferences
        super.init()

        followSelectedProvider()
        preferences.onProvidersChange = { [weak self] in
            guard let self else { return }
            // After the switch's own animation, so recounting doesn't take frames from it, and once for
            // several switches in a row.
            self.providersWork?.cancel()
            self.providersWork = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.followSelectedProvider()
                Task { await store.providersChanged() }
                await limits.providersChanged()
            }
        }

        let root = PanelRoot { [weak self] frame in self?.panel.modulesFrame = frame }
            .environment(store).environment(limits).environment(preferences).environment(presentation).environment(state)
        let host = NSHostingView(rootView: root)
        // The panel is sized here, as tall as the screen below the menu bar, and the modules sit at its
        // top. Switching tab, provider or Customize only moves them inside it: a window resized to fit
        // them lags their layout, and for that moment they're centered in the old size and jump.
        host.sizingOptions = []
        panel.contentView = host
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onClickOutside = { [weak self] in self?.close() }

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        observeTitle()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        // A display that's unplugged or rearranged leaves the panel sized for the old one.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// Opens the panel as a click on the item does. Opening the app again from Finder does this too,
    /// which is the way in when the menu bar has hidden the item.
    func show() {
        if !isOpen, !panel.isVisible { open() }
    }

    /// Redraws the title whenever the numbers it shows change, re-arming observation after each change.
    /// Settings changes redraw it directly, so only this one observation is ever armed.
    private func observeTitle() {
        withObservationTracking {
            updateTitle()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTitle() }
        }
    }

    /// Today's tokens and cost, then any pinned limits; the icon only when there's none of them.
    private func updateTitle() {
        let content = MenuBarContent(store: store, limits: limits)
        guard let button = statusItem.button else { return }
        if content.pinned.isEmpty {
            button.image = content.text.isEmpty ? MenuBarIcon.image : nil
            button.title = content.text.joined(separator: " · ")
            button.toolTip = nil
        } else {
            button.image = MenuBarStrip.image(content, font: button.font ?? MenuBarStrip.font)
            button.title = ""
            button.toolTip = MenuBarStrip.tooltip(content)
        }
    }

    /// A provider that's turned off can't stay selected; the panel goes back to all of them.
    private func followSelectedProvider() {
        if let provider = state.provider, !preferences.isShown(provider) { state.provider = nil }
    }

    /// Whether a point on screen is on the menu bar item, which takes clicks over the menu bar's whole
    /// height, up to the edge of the screen.
    private func isOnItem(_ point: NSPoint) -> Bool {
        guard let frame = statusItem.button?.window?.frame else { return false }
        return (frame.minX...frame.maxX).contains(point.x) && (frame.minY...frame.maxY).contains(point.y)
    }

    /// The menu bar is drawn by another process, which hands a click on the item to the app only after
    /// the panel may have lost key to it and closed. While the panel is still fading out, the click is
    /// the one that closed it.
    @objc private func toggle() {
        if isOpen {
            close()
        } else if !panel.isVisible {
            open()
        }
    }

    /// Escape leaves Customize first, then closes the panel.
    private func cancel() {
        if state.customizing != nil {
            withAnimation(Theme.Motion.select) { state.customizing = nil }
        } else {
            close()
        }
    }

    /// The panel's frame for the item's current place, laid out before it's shown.
    @discardableResult
    private func place(button: NSStatusBarButton) -> NSScreen? {
        // The item's place on screen. The menu bar hides items that don't fit beside the notch, and any
        // the person turns off in System Settings; then the panel opens at the top right of the screen.
        let item: (left: CGFloat, bottom: CGFloat)?
        let screen: NSScreen
        if let bar = button.window, bar.isVisible, let barScreen = bar.screen, barScreen.frame.intersects(bar.frame) {
            item = (bar.convertToScreen(button.convert(button.bounds, to: nil)).minX, bar.frame.minY)
            screen = barScreen
        } else if let main = NSScreen.main {
            item = nil
            screen = main
        } else {
            return nil
        }

        // The modules' leading edge lines up with the item, kept 8pt inside the screen.
        let margin = Theme.Layout.margin
        let width = Theme.Layout.contentWidth + margin * 2
        let x = min(max((item?.left ?? screen.frame.maxX) - margin, screen.frame.minX + 8 - margin), screen.frame.maxX - 8 + margin - width)
        let top = item?.bottom ?? screen.visibleFrame.maxY
        let below = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: top - screen.frame.minY)
        if state.screenHeight != screen.visibleFrame.height { state.screenHeight = screen.visibleFrame.height }
        panel.setFrame(NSRect(x: x, y: below.minY, width: width, height: below.height), display: false)
        dimmer.setFrame(below, display: false)
        return screen
    }

    /// Lays the panel out and draws it once off screen, so the first open doesn't pay for both.
    func prewarm() {
        guard !hasPrewarmed, !isOpen, let button = statusItem.button else { return }
        guard let screen = place(button: button) else { return }
        hasPrewarmed = true
        panel.contentView?.layoutSubtreeIfNeeded()
        // Showing it invisible, one turn of the run loop, draws the whole hierarchy into layers; the first
        // click then composites a tree that has been drawn before. It never takes key and never shows.
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(x: screen.frame.minX - frame.width * 2, y: frame.minY))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.contentView?.displayIfNeeded()
        panel.orderOut(nil)
        panel.setFrameOrigin(frame.origin)
    }

    private func open() {
        guard let button = statusItem.button, place(button: button) != nil else { return }
        isOpen = true
        state.clearHover()
        store.panelOpened()
        Telemetry.shared.panelOpened()
        Task { await limits.refresh() }

        // Laid out at its new size before the modules animate in, or the animation would also carry them
        // from where they sat in the old size: half off the left edge, the first time the panel opens.
        panel.contentView?.layoutSubtreeIfNeeded()

        panel.alphaValue = 0
        dimmer.alphaValue = 0
        dimmer.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        withAnimation(Theme.Motion.open) { presentation.isPresented = true }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            dimmer.animator().alphaValue = 1
        }
        // After the mouse-down that opened the panel, which would otherwise clear it.
        DispatchQueue.main.async { button.highlight(true) }

        // Clicks in other apps, including the menu bar. Clicks there that switch apps also resign key.
        // Clicks on the item come here too, being in the menu bar; its own action closes the panel.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                guard let self, !self.isOnItem(location) else { return }
                self.close()
            }
        }) {
            monitors.append(monitor)
        }
    }

    private func close() {
        guard isOpen else { return }
        isOpen = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        statusItem.button?.highlight(false)

        withAnimation(Theme.Motion.close) { presentation.isPresented = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            dimmer.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
                self.dimmer.orderOut(nil)
                self.store.panelClosed()
                // The panel opens on the numbers again.
                self.state.customizing = nil
                self.state.screenshotMode = false
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// The modules, with clear room around them for their shadows. They drop down into place with a bounce
/// as the panel opens, and stay at the top of the window however tall they are. Customize takes their place;
/// the numbers stay built underneath, so going back shows them as they were. The side leaving clears
/// out quickly and the one arriving settles in just after, so their glass barely overlaps.
private struct PanelRoot: View {
    /// Where the modules end up, in the window's content.
    let onModulesFrame: @MainActor (CGRect) -> Void
    @Environment(PanelPresentation.self) private var presentation
    @Environment(PanelState.self) private var state

    var body: some View {
        let customizing = state.customizing != nil
        let inset = state.screenshotMode ? Theme.Layout.margin : 0
        let zoom: AnyTransition = Theme.Motion.reduced ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
        let still = presentation.isPresented || Theme.Motion.reduced
        ShownLayout(shown: customizing ? 1 : 0) {
            PanelView()
                .tabVisible(!customizing)
            if customizing {
                CustomizeView()
                    .transition(.asymmetric(
                        insertion: zoom.animation(Theme.Motion.select.delay(0.05)),
                        removal: zoom.animation(Theme.Motion.leave)))
            }
        }
        .background {
            // ⌘, opens Customize, as Settings opens in other apps.
            Button("Customize") {
                withAnimation(Theme.Motion.select) { state.customizing = state.customizing ?? .providers }
            }
            .keyboardShortcut(",", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .padding(inset)
        .background {
            if state.screenshotMode {
                RoundedRectangle(cornerRadius: Theme.Layout.moduleRadius + inset, style: .continuous)
                    .fill(.black)
                    .transition(.opacity)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onModulesFrame($0) }
        .padding(.horizontal, Theme.Layout.margin - inset)
        .padding(.top, Theme.Layout.topGap)
        .padding(.bottom, Theme.Layout.margin)
        .scaleEffect(still ? 1 : 0.9, anchor: .top)
        .offset(y: still ? 0 : -18)
        // Exactly the window's height, so modules taller than it run off the bottom rather than being
        // centered.
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}

/// A clear window that takes the keyboard without activating the app, so the app in front stays in front.
private final class GlassPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onClickOutside: (() -> Void)?
    /// Where the modules are, in the content view's top-down coordinates.
    var modulesFrame: CGRect = .zero

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// The panel runs to the bottom of the screen, clear below the modules. Clicks on clear parts of a
    /// window go through to the one underneath; any that land on the panel outside the modules anyway
    /// close it, as a click anywhere else does.
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), let contentView, !modulesFrame.isEmpty {
            var point = contentView.convert(event.locationInWindow, from: nil)
            if !contentView.isFlipped { point.y = contentView.bounds.height - point.y }
            if !modulesFrame.contains(point) {
                onClickOutside?()
                return
            }
        }
        super.sendEvent(event)
    }
}

/// Darkens the screen below the menu bar while the panel is open. Clicks pass through it.
private final class DimmingWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .black.withAlphaComponent(Theme.dimming)
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(NSWindow.Level.popUpMenu.rawValue - 1)
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
}
