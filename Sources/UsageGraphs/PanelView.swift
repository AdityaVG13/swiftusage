import ServiceManagement
import SwiftUI
import UsageCore

extension StatsRange {
    var title: String {
        switch self {
        case .all: "All Time"
        case .days30: "30 Days"
        case .days7: "7 Days"
        }
    }
}

struct PanelView: View {
    @Environment(UsageStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(PanelState.self) private var state

    private var stats: RangeStats? { store.stats[state.provider]?[state.range] }

    var body: some View {
        @Bindable var state = state
        // Each part of the panel is one glass container, so its modules sample the screen together and
        // get the same frosting. The tabs have a container each and fade as a whole, which is a plain
        // layer fade; switching the glass itself on and off would rebuild it every frame.
        VStack(spacing: Theme.Layout.spacing) {
            GlassEffectContainer(spacing: 0) {
                VStack(spacing: Theme.Layout.spacing) {
                    ProviderPicker(selection: $state.provider, providers: preferences.shownProviders, available: store.providersWithData)
                    HStack {
                        GlassSegmentedControl("View", selection: $state.tab, options: PanelTab.allCases, title: \.rawValue)
                        Spacer()
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Limits are live windows, not a date range, so the range picker steps aside on that tab.
                // Glass in a shared container ignores opacity, so it has a container of its own to fade
                // with the tabs rather than popping out.
                GlassEffectContainer(spacing: 0) {
                    GlassSegmentedControl("Range", selection: $state.range, options: StatsRange.allCases, title: \.title)
                }
                .tabVisible(state.tab != .limits)
            }
            // Every tab stays built, and the place they share takes the size of the one in view (Models
            // shares the overview's). A hidden tab keeps what it last showed, so a switch of provider or
            // range only rebuilds the tab in view.
            let shown = Shown(stats: stats, provider: state.provider, id: contentID)
            ShownLayout(shown: state.tab == .limits ? 1 : 0) {
                HeldWhileHidden(shown, visible: state.tab == .overview) { shown in
                    GlassEffectContainer(spacing: 0) {
                        OverviewView(stats: shown.stats, countsTokens: shown.provider?.recordsTokensLocally ?? true, heatmapID: shown.id)
                    }
                }
                .tabVisible(state.tab == .overview)
                .overlay(alignment: .top) {
                    HeldWhileHidden(shown, visible: state.tab == .models) { shown in
                        if let stats = shown.stats {
                            GlassEffectContainer(spacing: 0) {
                                ModelsView(stats: stats, contentID: shown.id)
                            }
                        }
                    }
                    .tabVisible(state.tab == .models)
                }
                HeldWhileHidden(state.provider, visible: state.tab == .limits) { provider in
                    GlassEffectContainer(spacing: 0) {
                        LimitsView(provider: provider)
                    }
                }
                .tabVisible(state.tab == .limits)
            }
            // The footer slides as the tabs change height. Whatever is past the edge it's sliding to
            // stays hidden until it has made room, so it never passes over a tab fading in.
            .mask(alignment: .top) {
                Rectangle()
                    .padding(.horizontal, -Theme.Layout.margin)
                    .padding(.top, -Theme.Layout.spacing)
                    .padding(.bottom, -Theme.Layout.spacing)
            }
            GlassEffectContainer(spacing: 0) {
                Footer()
            }
        }
        .frame(width: Theme.Layout.contentWidth)
        .onChange(of: state.tab) { state.clearHover() }
        .onChange(of: state.provider) { state.clearHover() }
    }

    /// Changes with the provider and range shown, so switching cross-fades the graphs rather than
    /// repainting them at once.
    private var contentID: String { "\(state.provider?.rawValue ?? "all")-\(state.range.rawValue)" }
}

/// What a tab shows: the numbers, whose they are, and an ID that changes with the provider and range.
private struct Shown: Equatable {
    var stats: RangeStats?
    var provider: Provider?
    var id: String
}

/// Shows `value` while visible and keeps showing the last visible value while hidden, catching up at
/// once when shown again, so the tab fades in already showing what changed rather than moving to it.
private struct HeldWhileHidden<Value: Equatable, Content: View>: View {
    let value: Value
    let visible: Bool
    @ViewBuilder let content: (Value) -> Content
    @State private var held: Value?

    init(_ value: Value, visible: Bool, @ViewBuilder content: @escaping (Value) -> Content) {
        self.value = value
        self.visible = visible
        self.content = content
    }

    var body: some View {
        content(visible ? value : held ?? value)
            .transaction(value: visible) {
                $0.animation = nil
                $0.disablesAnimations = true
            }
            .onAppear { held = value }
            .onChange(of: value) { if visible { held = value } }
            .onChange(of: visible) { if visible { held = value } }
    }
}

/// The caption: a book comparison, a note about the provider's history, or details of whatever the
/// pointer is over. It's the only view besides the graphs that reads the hover state.
private struct Caption: View {
    @Environment(UsageStore.self) private var store
    @Environment(LimitsStore.self) private var limits
    @Environment(PanelState.self) private var state

    var body: some View {
        let text = text
        // One line beside the buttons: a long detail shrinks a little before it's cut off, and the
        // whole of it is in the tooltip.
        CrossfadeText(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .truncationMode(.tail)
            .monospacedDigit()
            .help(text)
            .animation(Theme.Motion.caption, value: text)
    }

    private var text: String {
        let provider = state.provider
        if state.tab == .limits { return limitsText }
        guard store.hasLoaded, let stats = store.stats[provider]?[state.range] else { return "Reading your coding agents' history…" }
        if let provider, !store.providersWithData.contains(provider) {
            return "No \(provider.name) history found on this Mac yet."
        }
        if provider == nil, store.providersWithData.isEmpty {
            return "No coding agent history found on this Mac yet."
        }
        let noUsage = "No \(provider?.name ?? "coding agent") usage in this period."
        switch state.tab {
        case .overview:
            if let day = state.hoveredDay { return dayDescription(day, stats: stats) }
            if provider == .codex, store.codexNeedsZstd {
                return "Install zstd (brew install zstd) to count older Codex sessions."
            }
            if provider == .cursor {
                return "Cursor keeps token counts on its servers, not on this Mac."
            }
            let sentences = TokenComparison.sentences(for: stats.totalTokens)
            guard !sentences.isEmpty else { return noUsage }
            return sentences[store.comparisonIndex % sentences.count]
        case .models:
            if let hover = state.chartHover { return hover }
            guard let favorite = stats.favoriteModel else {
                return provider == .cursor ? "Cursor doesn't record token counts on this Mac." : noUsage
            }
            if let unpriced = stats.unpricedModels.first {
                let others = stats.unpricedModels.count - 1
                return "No known price for \(unpriced)\(others > 0 ? " and \(others) more" : ""), so the cost leaves \(others > 0 ? "them" : "it") out."
            }
            return String(format: "%@ handled %.1f%% of your tokens.", favorite.name, favorite.share * 100)
        case .limits:
            return limitsText
        }
    }

    /// The limit under the pointer, else the one closest to running out.
    private var limitsText: String {
        if let hover = state.chartHover { return hover }
        let accounts = limits.accounts(for: state.provider)
        let readings = accounts.flatMap { account in account.meters.map { (account, $0, Pace($0)) } }
        if let (account, meter, pace) = readings.filter({ $0.2.verdict == .reached || $0.2.verdict == .over }).max(by: { $0.1.fraction < $1.1.fraction }) {
            // The provider, or the account's own name when the provider has several, so the line fits.
            let several = accounts.filter { $0.provider == account.provider }.count > 1
            let who = several ? account.account ?? account.provider.name : account.provider.name
            if pace.verdict == .reached, let reset = meter.resetsAt {
                return "\(who): \(meter.label) limit used up · resets in \(LimitText.countdown(reset.timeIntervalSinceNow))"
            }
            if let runsOut = pace.runsOut {
                return "\(who): \(meter.label) limit runs out in \(LimitText.countdown(runsOut.timeIntervalSinceNow)) at this pace"
            }
        }
        if accounts.isEmpty { return limits.isLoading ? "Reading your plan limits…" : "Costs are API-rate estimates from your local history." }
        return "Costs are API-rate estimates from your local history."
    }

    private func dayDescription(_ day: Int, stats: RangeStats) -> String {
        let date = DayClock().date(of: day).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        guard day >= stats.firstDay, let summary = stats.days[day], summary.isActive || summary.tokens > 0 else {
            return day < stats.firstDay && stats.range != .all ? "\(date) · Outside this range" : "\(date) · No activity"
        }
        var parts = [date]
        if summary.sessions > 0 { parts.append("\(Format.grouped(summary.sessions)) session\(summary.sessions == 1 ? "" : "s")") }
        parts.append("\(Format.grouped(summary.messages)) messages")
        parts.append("\(Format.compact(summary.tokens)) tokens")
        if summary.cost > 0 { parts.append(Format.dollars(summary.cost)) }
        return parts.joined(separator: " · ")
    }
}

struct OverviewView: View {
    let stats: RangeStats?
    /// False for a provider whose token counts aren't on this Mac, so they show as unknown, not zero.
    var countsTokens = true
    var heatmapID = ""

    var body: some View {
        VStack(spacing: Theme.Layout.spacing) {
            Grid(horizontalSpacing: Theme.Layout.spacing, verticalSpacing: Theme.Layout.spacing) {
                GridRow {
                    StatTile(label: "Sessions", systemImage: "terminal", value: value { Format.grouped($0.sessions) })
                    StatTile(label: "Messages", systemImage: "text.bubble", value: value { Format.grouped($0.messages) })
                    StatTile(label: "Total tokens", systemImage: "number", value: countsTokens ? value { Format.compact($0.totalTokens) } : "–")
                }
                GridRow {
                    StatTile(label: "Active days", systemImage: "calendar", value: value { Format.grouped($0.activeDays) })
                    StatTile(label: "Peak hour", systemImage: "clock", value: value { $0.peakHour.map(Format.hour) ?? "–" })
                    StatTile(label: "Favorite model", systemImage: "star", value: value { $0.favoriteModel?.name ?? "–" })
                }
            }
            graph
        }
    }

    private var graph: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardTitle("Messages per day", systemImage: "square.grid.3x3.fill")
                Spacer()
                HeatLegend()
            }
            ZStack {
                if let stats {
                    HeatmapView(stats: stats)
                        .id(heatmapID)
                        .transition(.opacity)
                }
            }
            .frame(width: Theme.Layout.heatmapWidth, height: Theme.Layout.heatmapHeight)
        }
        .frame(width: Theme.Layout.heatmapWidth)
        .padding(Theme.Layout.modulePadding)
        .frame(maxWidth: .infinity)
        .module()
    }

    private func value(_ make: (RangeStats) -> String) -> String {
        stats.map(make) ?? "–"
    }
}

/// The bottom capsule: the caption (a book comparison, or details of whatever the pointer is over),
/// when the numbers were last read, and the refresh and settings buttons. The refresh arrow turns until
/// what it started has been read; the other buttons' symbols bounce as they're clicked.
private struct Footer: View {
    @Environment(UsageStore.self) private var store
    @Environment(LimitsStore.self) private var limits
    @Environment(Preferences.self) private var preferences
    @Environment(PanelState.self) private var state
    @Environment(PanelPresentation.self) private var presentation
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Reloads started here that haven't finished.
    @State private var reloading = 0
    @State private var spinning = false
    @State private var arrowAngle = 0.0
    @State private var customizeClicks = 0
    @State private var menuOpenings = 0
    @State private var overMenu = false

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Caption()
                status
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                reload {
                    async let usage: Void = store.refresh()
                    async let plans: Void = limits.refresh(force: true)
                    _ = await (usage, plans)
                }
            } label: {
                CircleIcon(systemImage: "arrow.clockwise")
                    // The circle behind it is round, so only the arrow is seen to turn.
                    .rotationEffect(.degrees(arrowAngle))
            }
            .buttonStyle(PressScale(scale: 0.88))
            .help("Refresh")
            .accessibilityLabel("Refresh")
            Button {
                customizeClicks += 1
                customize(.providers)
            } label: {
                CircleIcon(systemImage: "slider.horizontal.3")
                    .symbolEffect(.bounce.byLayer, value: customizeClicks)
            }
            .buttonStyle(PressScale(scale: 0.88))
            .help("Customize")
            .accessibilityLabel("Customize")
            Menu {
                Button("Customize…") { customize(.providers) }
                    .keyboardShortcut(",")
                Button("Menu Bar…") { customize(.menuBar) }
                Toggle("Open at Login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Toggle("Screenshot Mode", isOn: $state.screenshotMode.animation(Theme.Motion.select))
                Divider()
                Button("Re-read All History") {
                    reload { await store.rebuild() }
                }
                let folders = preferences.shownProviders.compactMap { provider in store.folder(for: provider).map { (provider, $0) } }
                if !folders.isEmpty {
                    Menu("Show History in Finder") {
                        ForEach(folders, id: \.0) { provider, folder in
                            Button(provider.name) { NSWorkspace.shared.open(folder) }
                        }
                    }
                }
                Divider()
                Button("About SwiftUsage") { AboutPanel.show() }
                Button("Quit SwiftUsage") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            } label: {
                CircleIcon(systemImage: "ellipsis")
                    .symbolEffect(.bounce.byLayer, value: menuOpenings)
                    .onHover { overMenu = $0 }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
            // A menu doesn't say when it opens, so its dots bounce when any menu starts tracking with the
            // pointer over them. Context menus open elsewhere, over the cards.
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                if overMenu { menuOpenings += 1 }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        // The login item can be turned off in System Settings too.
        .onChange(of: presentation.isPresented) { _, presented in
            if presented { launchAtLogin = SMAppService.mainApp.status == .enabled }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("swiftusage: login item change failed: \(error)")
        }
        // A login item the person once turned off in System Settings has to be allowed there again.
        if enabled, service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        launchAtLogin = service.status == .enabled
    }

    private func customize(_ section: CustomizeSection) {
        state.clearHover()
        withAnimation(Theme.Motion.select) { state.customizing = section }
    }

    /// Runs `work` with the refresh arrow turning, at least once round, until it and every other reload
    /// started here are done.
    private func reload(_ work: @escaping @MainActor () async -> Void) {
        reloading += 1
        Task {
            await work()
            reloading -= 1
        }
        guard !spinning else { return }
        spinning = true
        Task {
            // The arrow's spring chases a target stepped a little further round every tenth of a second,
            // and the steps stop on a whole turn, so it comes to rest upright.
            repeat {
                withAnimation(Theme.Motion.spin) { arrowAngle += 45 }
                try? await Task.sleep(for: .milliseconds(100))
            } while reloading > 0 || arrowAngle.truncatingRemainder(dividingBy: 360) != 0
            spinning = false
        }
    }

    @ViewBuilder
    private var status: some View {
        if let progress = store.progress {
            HStack(spacing: 6) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .frame(width: 60)
                Text("Reading \(Format.grouped(progress.filesTotal)) files…")
            }
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                CrossfadeText(updatedText)
            }
        }
    }

    private var updatedText: String {
        let name = state.provider?.name ?? "All providers"
        guard let updated = state.tab == .limits ? limits.lastFetched : store.lastUpdated else { return name }
        let seconds = Date().timeIntervalSince(updated)
        let when = seconds < 60 ? "just now" : updated.formatted(.relative(presentation: .named))
        return "\(name) · Updated \(when)"
    }
}
