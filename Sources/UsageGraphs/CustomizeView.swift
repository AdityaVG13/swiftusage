import SwiftUI
import UsageCore

/// Customize takes the panel's place: which providers and accounts the panel follows, what the menu bar
/// item shows, and how often the limits are read along with what else the app does on its own. As in
/// Control Center, each control is its own piece of glass with a circle that lights up white when it's on.
/// The back button or Escape returns to the numbers.
///
/// All pages stay built, each in a glass container of its own, and switching fades one container out
/// and the other in as whole layers. Glass in a shared container ignores opacity, so fading single
/// pieces of it would leave their glass behind.
struct CustomizeView: View {
    @Environment(PanelState.self) private var state

    var body: some View {
        let section = state.customizing ?? .providers
        VStack(spacing: Theme.Layout.spacing) {
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 10) {
                    // The title shares the back button's glass rather than sitting bare on the screen,
                    // where it would be hard to read over a light window.
                    HStack(spacing: 8) {
                        BackButton { state.customizing = nil }
                        Text("Customize")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(4)
                    .padding(.trailing, 10)
                    .glassEffect(.regular, in: .capsule)
                    Spacer()
                    GlassSegmentedControl("Section", selection: Binding(get: { section }, set: { state.customizing = $0 }),
                                          options: CustomizeSection.allCases, title: \.rawValue)
                }
            }
            ShownLayout(shown: CustomizeSection.allCases.firstIndex(of: section) ?? 0) {
                page(visible: section == .providers) { ProvidersPage() }
                page(visible: section == .menuBar) { MenuBarPage() }
                page(visible: section == .general) { GeneralPage() }
            }
        }
        .frame(width: Theme.Layout.contentWidth)
    }

    private func page(visible: Bool, @ViewBuilder content: () -> some View) -> some View {
        GlassEffectContainer(spacing: 0, content: content)
            .tabVisible(visible)
    }
}

// MARK: - Providers

/// A tile for each provider, then every signed-in account of the providers that are on.
private struct ProvidersPage: View {
    @Environment(UsageStore.self) private var store
    @Environment(LimitsStore.self) private var limits
    @Environment(Preferences.self) private var preferences
    @Environment(PanelState.self) private var state
    /// Counts refused attempts to turn off the last provider, which shakes its tile.
    @State private var refused: [Provider: Int] = [:]

    var body: some View {
        VStack(spacing: Theme.Layout.spacing) {
            Grid(horizontalSpacing: Theme.Layout.spacing, verticalSpacing: Theme.Layout.spacing) {
                ForEach(Array(stride(from: 0, to: Provider.allCases.count, by: 3)), id: \.self) { first in
                    GridRow {
                        ForEach(Provider.allCases[first..<min(first + 3, Provider.allCases.count)], id: \.self) { provider in
                            tile(provider)
                        }
                    }
                }
            }
            accounts
        }
    }

    private func tile(_ provider: Provider) -> some View {
        let isOn = preferences.isShown(provider)
        let last = isOn && preferences.shownProviders == [provider]
        return ToggleTile(title: provider.name, detail: detail(provider), isOn: isOn,
                          help: last ? "At least one provider stays on" : isOn ? "Turn off \(provider.name)" : "Turn on \(provider.name)",
                          refusals: refused[provider, default: 0]) {
            if last {
                refused[provider, default: 0] += 1
            } else {
                withAnimation(Theme.Motion.toggle) { preferences.setShown(provider, !isOn) }
            }
        } glyph: {
            ProviderMark(provider: provider, size: 18)
        }
    }

    private var accounts: some View {
        let accounts = limits.followedAccounts
        return VStack(spacing: 0) {
            if accounts.isEmpty {
                Text(limits.isLoading ? "Looking for signed-in accounts…" : "No signed-in accounts yet")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                CappedScrollView(maxHeight: state.listCap(leaving: 520)) {
                    VStack(spacing: 2) {
                        ForEach(accounts) { account in
                            let isOn = limits.isShown(account)
                            AccountRow(account: account, isOn: isOn) {
                                withAnimation(Theme.Motion.toggle) { limits.setShown(account, !isOn) }
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .module()
    }

    /// How much of the provider there is on this Mac.
    private func detail(_ provider: Provider) -> String {
        guard preferences.isShown(provider) else { return "Off" }
        if store.providersWithData.contains(provider), let stats = store.stats[provider]?[.all] {
            return store.countsTokens(provider) ? "\(Format.compact(stats.totalTokens)) tokens" : "\(Format.compact(Int64(stats.messages))) messages"
        }
        let accounts = limits.accounts.filter { $0.provider == provider }.count
        if accounts > 0 { return accounts == 1 ? "Signed in" : "\(accounts) accounts" }
        // A provider's stats exist once its history has been read, however little there was.
        return store.stats[provider] != nil ? "No history yet" : "Reading…"
    }
}

/// A signed-in account; clicking it shows or hides it in the Limits tab and the menu bar.
private struct AccountRow: View {
    let account: AccountLimits
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                LitCircle(isOn: isOn, size: 32) {
                    ProviderMark(provider: account.provider, size: 15)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(account.account ?? account.provider.name)
                            .font(.system(size: 13, weight: .semibold))
                            .truncationMode(.middle)
                        if let plan = account.plan {
                            PlanBadge(plan: plan)
                        }
                    }
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .opacity(isOn ? 1 : 0.5)
                Spacer(minLength: 8)
                if let problem = account.problem {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                        .help(problem)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.Layout.moduleRadius - 6, style: .continuous).fill(.white.opacity(hovering ? 0.07 : 0)))
            .contentShape(.rect(cornerRadius: Theme.Layout.moduleRadius - 6))
        }
        .buttonStyle(PressScale(scale: 0.98))
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .help(isOn ? "Hide this account" : "Show this account")
        .accessibilityLabel(MenuBarStrip.name(account))
        .accessibilityValue(isOn ? "Shown" : "Hidden")
        .accessibilityAddTraits(.isToggle)
    }

    private var detail: String {
        guard !account.sharedWith.isEmpty else { return account.provider.name }
        return account.provider.name + " · also " + account.sharedWith.map(\.name).formatted(.list(type: .and))
    }
}

// MARK: - Menu bar

/// The menu bar item as it looks now, whether it shows today's tokens and cost, and which limits are pinned there.
private struct MenuBarPage: View {
    @Environment(UsageStore.self) private var store
    @Environment(LimitsStore.self) private var limits
    @Environment(PanelState.self) private var state
    @AppStorage("showTokensInMenuBar") private var showTokens = true
    @AppStorage("showCostInMenuBar") private var showCost = false
    @AppStorage("menuBarShowsLeft") private var showsLeft = false

    var body: some View {
        let content = MenuBarContent(store: store, limits: limits, showTokens: showTokens, showCost: showCost, showsLeft: showsLeft)
        VStack(spacing: Theme.Layout.spacing) {
            MenuBarPreview(content: content, onReorder: limits.orderPins(byAccount:))
                .module()
            HStack(spacing: Theme.Layout.spacing) {
                ToggleTile(title: "Tokens", detail: today(store.todayTokens > 0 ? Format.compact(store.todayTokens) : nil), isOn: showTokens,
                           help: "Today's tokens in the menu bar") {
                    withAnimation(Theme.Motion.toggle) { showTokens.toggle() }
                } glyph: {
                    Image(systemName: "number").font(.system(size: 15, weight: .semibold))
                        .symbolEffect(.bounce, value: showTokens)
                }
                ToggleTile(title: "Cost", detail: today(store.spend(for: nil).flatMap { $0.today > 0 ? Format.dollars($0.today) : nil }), isOn: showCost,
                           help: "Today's cost at API rates in the menu bar") {
                    withAnimation(Theme.Motion.toggle) { showCost.toggle() }
                } glyph: {
                    Image(systemName: "dollarsign").font(.system(size: 15, weight: .semibold))
                        // Flips like a tossed coin.
                        .rotation3DEffect(.degrees(showCost && !Theme.Motion.reduced ? 360 : 0), axis: (x: 0, y: 1, z: 0))
                }
                ToggleTile(title: "Remaining", detail: remaining(content), isOn: showsLeft,
                           help: "Show what's left of each limit instead of what's used") {
                    withAnimation(Theme.Motion.toggle) { showsLeft.toggle() }
                } glyph: {
                    Image(systemName: "hourglass").font(.system(size: 15, weight: .semibold))
                        // Turned over to count what's left.
                        .rotationEffect(.degrees(showsLeft ? 180 : 0))
                }
            }
            pins(content)
        }
    }

    private func pins(_ content: MenuBarContent) -> some View {
        let accounts = limits.accounts(for: nil).filter { !$0.meters.isEmpty }
        return VStack(spacing: 0) {
            if accounts.isEmpty {
                Text(limits.isLoading ? "Reading your plan limits…" : "No plan limits to pin yet")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                CappedScrollView(maxHeight: state.listCap(leaving: 400)) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(accounts) { account in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 7) {
                                    ProviderIcon(provider: account.provider, size: 14)
                                    Text(account.account ?? account.provider.name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let plan = account.plan {
                                        PlanBadge(plan: plan)
                                    }
                                }
                                FlowLayout(spacing: 6, lineSpacing: 6) {
                                    ForEach(account.meters) { meter in
                                        LimitPill(meter: meter, content: content, pinned: limits.isPinned(account, meter)) {
                                            withAnimation(Theme.Motion.toggle) { limits.togglePin(account, meter) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(Theme.Layout.modulePadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .module()
    }

    private func today(_ amount: String?) -> String {
        amount.map { "\($0) today" } ?? "None today"
    }

    /// What the first pinned limit would read, so the tile shows its effect.
    private func remaining(_ content: MenuBarContent) -> String {
        guard let meter = content.pinned.first?.meter else { return showsLeft ? "Shows what's left" : "Shows what's used" }
        return "\(content.percent(meter))% " + (showsLeft ? "left" : "used")
    }
}

/// The menu bar item drawn live, in a recessed bar, with which account each logo stands for. Pinned
/// limits blur in and out, and their numbers roll when they change. Dragging an account along the bar
/// moves it in the menu bar.
private struct MenuBarPreview: View {
    let content: MenuBarContent
    /// Takes the accounts in their new order.
    let onReorder: ([String]) -> Void
    /// Accounts the legend lists before it scrolls.
    private static let legendRows = 6

    var body: some View {
        let groups = content.groups
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                MenuBarReplica(content: content, onReorder: onReorder)
                    .padding(.horizontal, 16)
                // Wider than the panel with many accounts pinned: it scrolls sideways, and an account
                // dragged past the edge still reaches the end of the strip.
                ScrollView(.horizontal) {
                    MenuBarReplica(content: content, onReorder: onReorder)
                        .padding(.horizontal, 16)
                }
                .scrollIndicators(.never)
                .clipShape(Capsule())
            }
            .frame(height: 40)
            .background(Capsule().fill(.black.opacity(0.3)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.07)))
            let list = VStack(alignment: .leading, spacing: 5) {
                legend(groups)
            }
            .font(.system(size: 11.5))
            .lineLimit(1)
            if groups.count > Self.legendRows {
                CappedScrollView(maxHeight: CGFloat(Self.legendRows) * 21) { list }
            } else {
                list
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, Theme.Layout.modulePadding)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Menu bar preview")
        .accessibilityValue(MenuBarStrip.tooltip(content))
        .accessibilityActions {
            ForEach(Array(groups.enumerated().dropFirst()), id: \.element.id) { index, group in
                Button("Move \(MenuBarStrip.name(group.account)) left") {
                    var order = groups.map(\.id)
                    order.swapAt(index, index - 1)
                    withAnimation(Theme.Motion.reorder) { onReorder(order) }
                }
            }
        }
    }

    @ViewBuilder
    private func legend(_ groups: [MenuBarContent.Group]) -> some View {
        if groups.isEmpty {
            Text("Pin limits below to see them here")
                .foregroundStyle(.secondary)
        }
        ForEach(groups) { group in
            HStack(spacing: 5) {
                ProviderIcon(provider: group.account.provider, size: 12)
                Text(group.account.account ?? group.account.provider.name)
                    .fontWeight(.semibold)
                Text(group.meters.map(\.label).joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            .transition(.blurReplace)
        }
    }
}

/// The menu bar item as `MenuBarStrip` draws it, in SwiftUI so its parts can animate, a little larger.
/// Each account's logo and numbers lift when dragged; the others step aside as its edge passes their middles,
/// and it settles into the gap when dropped.
private struct MenuBarReplica: View {
    let content: MenuBarContent
    let onReorder: ([String]) -> Void
    private let size: CGFloat = 15
    /// Each account's width in the strip, with the gap before it: how far the others step aside.
    @State private var widths: [String: CGFloat] = [:]
    @State private var hovered: String?
    @GestureState(resetTransaction: Transaction(animation: Theme.Motion.reorder)) private var drag: Drag? = nil

    /// The account being dragged, how far it has moved, and the place it would drop into.
    private struct Drag {
        let id: String
        let offset: CGFloat
        let target: Int
    }

    var body: some View {
        let ids = content.groups.map(\.id)
        let movable = ids.count > 1
        // Each piece is padded by the gap before it, which the first one doesn't have.
        let leadingGap: CGFloat = content.text.isEmpty ? (ids.isEmpty ? 0 : 11) : 6
        HStack(spacing: 0) {
            if content.text.isEmpty, ids.isEmpty {
                Image(nsImage: MenuBarIcon.image)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: size * 1.23, height: size * 1.23)
                    .transition(.blurReplace)
            }
            if let tokens = content.tokens {
                Text(tokens)
                    .padding(.leading, 6)
                    .transition(.blurReplace)
            }
            if let cost = content.cost {
                Text(cost)
                    .padding(.leading, 6)
                    .transition(.blurReplace)
            }
            ForEach(content.groups) { group in
                let lifted = drag?.id == group.id
                HStack(spacing: 5) {
                    ProviderMark(provider: group.account.provider, size: size * 1.08)
                    HStack(spacing: 0) {
                        ForEach(Array(group.meters.enumerated()), id: \.element.id) { offset, meter in
                            if offset > 0 {
                                Text("·").opacity(0.45)
                            }
                            let percent = content.percent(meter)
                            Text("\(percent)")
                                .contentTransition(.numericText(value: Double(percent)))
                        }
                    }
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                }
                .background {
                    Capsule()
                        .fill(.white.opacity(lifted ? 0.14 : movable && drag == nil && hovered == group.id ? 0.07 : 0))
                        .padding(.horizontal, -6)
                        .padding(.vertical, -4)
                        .animation(Theme.Motion.hover, value: hovered)
                }
                .scaleEffect(lifted ? 1.08 : 1)
                .animation(Theme.Motion.reorder, value: lifted)
                .padding(.leading, 11)
                .contentShape(.rect)
                .offset(x: shift(group.id, in: ids))
                .animation(Theme.Motion.reorder, value: drag?.target)
                // Outside the animations above, so the dragged account keeps up with the pointer.
                .offset(x: lifted ? drag?.offset ?? 0 : 0)
                .zIndex(lifted ? 1 : 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[group.id] = $0 }
                .gesture(reorder(group.id, in: ids), isEnabled: movable)
                .onHover { hovering in
                    if hovering { hovered = group.id } else if hovered == group.id { hovered = nil }
                }
                .pointerStyle(movable ? lifted ? .grabActive : .grabIdle : nil)
                .help(movable ? "Drag to move \(MenuBarStrip.name(group.account)) in the menu bar" : "")
                .transition(.blurReplace)
            }
        }
        .padding(.leading, -leadingGap)
        .font(.system(size: size).monospacedDigit())
        .foregroundStyle(.white)
        .fixedSize()
    }

    /// Follows the pointer, and on release moves the account to the place it was dragged to. Letting go
    /// short of a neighbor's middle slides it back.
    private func reorder(_ id: String, in ids: [String]) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($drag) { value, drag, _ in
                drag = dragged(id, by: value.translation.width, in: ids)
            }
            .onEnded { value in
                guard let from = ids.firstIndex(of: id), let target = dragged(id, by: value.translation.width, in: ids)?.target,
                      target != from else { return }
                var order = ids
                order.remove(at: from)
                order.insert(id, at: target)
                withAnimation(Theme.Motion.reorder) { onReorder(order) }
            }
    }

    /// An account dragged this far, kept within the strip, and the place it would drop into: past every
    /// account whose middle its leading edge (going left) or trailing edge (going right) has crossed, so
    /// pushing it against either end of the strip always reaches that end, whatever the widths.
    private func dragged(_ id: String, by translation: CGFloat, in ids: [String]) -> Drag? {
        guard let from = ids.firstIndex(of: id) else { return nil }
        // Where each account starts, then where the last one ends.
        let edges = ids.reduce(into: [CGFloat(0)]) { edges, id in edges.append(edges[edges.count - 1] + (widths[id] ?? 0)) }
        let offset = min(max(translation, -edges[from]), edges[ids.count] - edges[from + 1])
        let middle = { (index: Int) in (edges[index] + edges[index + 1]) / 2 }
        let before = ids.indices.prefix(from).filter { middle($0) < edges[from] + offset }.count
        let after = ids.indices.suffix(from: from + 1).filter { middle($0) < edges[from + 1] + offset }.count
        return Drag(id: id, offset: offset, target: before + after)
    }

    /// How far an account steps aside for the one being dragged: that one's width, toward the place it left.
    private func shift(_ id: String, in ids: [String]) -> CGFloat {
        guard let drag, let from = ids.firstIndex(of: drag.id), let index = ids.firstIndex(of: id) else { return 0 }
        let width = widths[drag.id] ?? 0
        if from < index, index <= drag.target { return -width }
        if drag.target <= index, index < from { return width }
        return 0
    }
}

/// A limit to pin: its ring, name and number, lit white while it's in the menu bar.
private struct LimitPill: View {
    let meter: LimitMeter
    let content: MenuBarContent
    let pinned: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let percent = content.percent(meter)
        Button(action: action) {
            HStack(spacing: 6) {
                Ring(fraction: content.fraction(meter), color: Theme.paceColor(Pace(meter).verdict),
                     track: pinned ? .black.opacity(0.12) : .white.opacity(0.16))
                    .frame(width: 13, height: 13)
                Text(meter.label)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.5)
                    .contentTransition(.numericText(value: Double(percent)))
            }
            .lineLimit(1)
            .foregroundStyle(pinned ? Color.black : Color.white)
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 30)
            .background {
                // Drawn as is, so glass doesn't wash the white out with vibrancy.
                Capsule().fill(pinned ? Color.white : Color.white.opacity(hovering ? 0.15 : 0.09)).drawingGroup()
            }
            .contentShape(.capsule)
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .help(pinned ? "Remove from the menu bar" : "Show in the menu bar")
        .accessibilityLabel(meter.label)
        .accessibilityValue(pinned ? "In the menu bar" : "Not in the menu bar")
        .accessibilityAddTraits(.isToggle)
    }
}

/// How much of a limit is used (or left), as a ring.
private struct Ring: View {
    let fraction: Double
    let color: Color
    let track: Color

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(fraction, 0.001))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.25)
        .drawingGroup()
    }
}

// MARK: - General

/// One module of settings: how often the providers are asked for their limits, then switches for what
/// else the app does on its own, such as opening at login.
private struct GeneralPage: View {
    @Environment(LimitsStore.self) private var limits
    @Environment(Preferences.self) private var preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            interval
            Divider()
            SettingSwitch("Open at Login", detail: LoginItem.shared.problem ?? "Starts SwiftUsage with your Mac, in the menu bar.",
                          isOn: Binding(get: { LoginItem.shared.isEnabled }, set: { enabled in withAnimation(Theme.Motion.toggle) { LoginItem.shared.set(enabled) } }))
            Divider()
            let updater = Updater.shared
            SettingSwitch("Check for Updates",
                          detail: updater.canUpdate ? "Looks for a new version once a day and downloads it, then asks before installing it." : "This is a development build, which doesn't update itself.",
                          isOn: Binding(get: { updater.checksAutomatically }, set: { enabled in withAnimation(Theme.Motion.toggle) { updater.checksAutomatically = enabled } }))
                .disabled(!updater.canUpdate)
        }
        .padding(Theme.Layout.modulePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .module()
    }

    /// The interval, as a row of pills with the chosen one lit, with when the limits were last read and
    /// when they're next due.
    private var interval: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                CardTitle("Read limits every", systemImage: "arrow.clockwise")
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(readings(context.date))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Preferences.limitsIntervals, id: \.self) { interval in
                    ChoicePill(title: Preferences.intervalTitle(interval), selected: preferences.limitsInterval == interval) {
                        withAnimation(Theme.Motion.toggle) { preferences.limitsInterval = interval }
                    }
                }
            }
            .accessibilityRepresentation {
                Picker("Read limits every", selection: Binding(get: { preferences.limitsInterval }, set: { preferences.limitsInterval = $0 })) {
                    ForEach(Preferences.limitsIntervals, id: \.self) { Text(Preferences.intervalTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Text("Each signed-in account is asked for its limits this often, with the login its tool already keeps. The Refresh button asks right away.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `Read 2m ago · next in 3m`, or that a reading is under way.
    private func readings(_ now: Date) -> String {
        if limits.isLoading { return "Reading…" }
        guard let last = limits.lastFetched, let due = limits.nextReading else { return "" }
        let ago = now.timeIntervalSince(last)
        let next = LimitText.countdown(max(due.timeIntervalSince(now), 0))
        return "Read \(ago < 60 ? "just now" : LimitText.countdown(ago) + " ago") · next in \(next)"
    }
}

/// A setting that's on or off, as a row like System Settings': its name and a line about it, with a
/// switch at the end.
private struct SettingSwitch: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
    }
}

/// One of a few choices in a row: its name on a capsule, lit white while it's the one chosen.
private struct ChoicePill: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(selected ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background {
                    // Drawn as is, so glass doesn't wash the white out with vibrancy.
                    Capsule().fill(selected ? Color.white : Color.white.opacity(hovering ? 0.15 : 0.09)).drawingGroup()
                }
                .contentShape(.capsule)
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.hover, value: hovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Pieces

/// A Control Center button: a circle that lights up when it's on, a title and a line of detail, on a
/// tile of its own glass. The glass answers the pointer itself; only what's on it moves.
private struct ToggleTile<Glyph: View>: View {
    let title: String
    let detail: String
    let isOn: Bool
    let help: String
    /// Goes up each time a click is refused, which shakes the tile's contents.
    var refusals = 0
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LitCircle(isOn: isOn, size: 38, glyph: glyph)
                // Fills the rest of the tile itself: a spacer after it would take another 10pt of
                // spacing from a tile only 160pt wide.
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isOn ? 1 : 0.55)
            }
            .modifier(Shake(trigger: refusals))
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: Theme.Layout.tileRadius))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Theme.Layout.tileRadius))
        }
        .buttonStyle(BareButton())
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The round light of a Control Center button: clear when off, filled white with a dark glyph when on,
/// with a small bounce as it switches.
private struct LitCircle<Glyph: View>: View {
    let isOn: Bool
    let size: CGFloat
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.12))
            Circle().fill(.white)
                .scaleEffect(isOn || Theme.Motion.reduced ? 1 : 0.25)
                .opacity(isOn ? 1 : 0)
            glyph()
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.white.opacity(0.8))
        }
        .frame(width: size, height: size)
        // Drawn as is, so glass doesn't wash the white out with vibrancy.
        .drawingGroup()
        .modifier(Pop(trigger: isOn))
    }
}

/// A provider's logo as a plain shape in the current color, the way the menu bar draws it.
private struct ProviderMark: View {
    let provider: Provider
    let size: CGFloat

    var body: some View {
        if let logo = ProviderLogo.template(provider) {
            Image(nsImage: logo)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}

/// The back button at the start of Customize's title capsule, a circle that brightens under the pointer
/// like the footer's buttons. Its chevron nudges back as it's clicked.
private struct BackButton: View {
    let action: () -> Void
    @State private var clicks = 0

    var body: some View {
        Button {
            clicks += 1
            withAnimation(Theme.Motion.select) { action() }
        } label: {
            CircleIcon(systemImage: "chevron.left", size: 28)
                .symbolEffect(.wiggle.backward, value: clicks)
        }
        .buttonStyle(PressScale(scale: 0.88))
        .help("Back")
        .accessibilityLabel("Back")
    }
}

/// A button that draws only its label, for glass that answers presses itself. The plain style would dim
/// the label, which glass doesn't follow.
private struct BareButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Shakes side to side each time `trigger` goes up, the way macOS refuses a wrong password.
private struct Shake: ViewModifier {
    let trigger: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if Theme.Motion.reduced {
            content
        } else {
            content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                LinearKeyframe(-7, duration: 0.06)
                LinearKeyframe(6, duration: 0.08)
                LinearKeyframe(-4, duration: 0.07)
                LinearKeyframe(2, duration: 0.06)
                SpringKeyframe(0, duration: 0.2)
            }
        }
    }
}
