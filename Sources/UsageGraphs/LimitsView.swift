import SwiftUI
import UsageCore

/// The Limits tab: what the selected provider (or every one) cost today, yesterday and over 30 days, and
/// each signed-in account's plan limits with their reset times and pace.
struct LimitsView: View {
    let provider: Provider?
    @Environment(LimitsStore.self) private var limits
    @Environment(PanelState.self) private var state
    @Environment(UsageStore.self) private var store

    var body: some View {
        let accounts = limits.accounts(for: provider)
        VStack(spacing: Theme.Layout.spacing) {
            spend
            if accounts.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .module()
            } else {
                // The cards scroll once they'd make the panel taller than the screen allows.
                // Percentages need a narrow column; dollar and request counts (`$1.2K/$2.5K`) a wider
                // one. Every card takes the same, so the bars line up from card to card.
                let usedWidth: CGFloat = accounts.contains { $0.meters.contains { $0.unit != .percent } } ? 76 : 40
                // Room for the cards below the pickers and the spend tiles, and above the footer.
                CappedScrollView(maxHeight: state.listCap(leaving: 300, atLeast: 260), fadesEdges: false) {
                    VStack(spacing: Theme.Layout.spacing) {
                        ForEach(accounts) { AccountCard(account: $0, usedWidth: usedWidth) }
                    }
                }
            }
        }
    }

    private var spend: some View {
        let spend = store.spend(for: provider)
        let counts = provider?.recordsTokensLocally ?? true
        func value(_ dollars: Double?) -> String { counts ? dollars.map(Format.dollars) ?? "–" : "–" }
        return Grid(horizontalSpacing: Theme.Layout.spacing) {
            GridRow {
                StatTile(label: "Today", systemImage: "dollarsign.circle", value: value(spend?.today))
                StatTile(label: "Yesterday", systemImage: "clock.arrow.circlepath", value: value(spend?.yesterday))
                StatTile(label: "Last 30 days", systemImage: "calendar", value: value(spend?.month))
            }
        }
    }

    private var emptyText: String {
        if limits.accounts.isEmpty, limits.isLoading { return "Reading your plan limits…" }
        guard let provider else { return "No coding agent with plan limits is signed in on this Mac." }
        switch provider {
        // Muse Code's limits are per-minute rates on Meta's API, with nothing to read them from.
        case .muse: return "Muse Code doesn't report plan limits."
        case .pi: return "Pi isn't signed in to a Claude, ChatGPT or Grok subscription."
        default: return "\(provider.name) isn't signed in on this Mac."
        }
    }
}

/// One account: its provider, name and plan, then a bar per limit and any balances.
private struct AccountCard: View {
    let account: AccountLimits
    let usedWidth: CGFloat
    @Environment(LimitsStore.self) private var limits

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                ProviderIcon(provider: account.provider, size: 15)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let plan = account.plan {
                    PlanBadge(plan: plan)
                }
                Spacer(minLength: 0)
                if account.problem != nil, account.hasValues {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Updated " + account.updated.formatted(.relative(presentation: .named)))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if let problem = account.problem {
                HStack(spacing: 8) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                    if let action = account.action {
                        Spacer(minLength: 0)
                        Button(action.title) { Task { await limits.perform(action) } }
                            .controlSize(.small)
                            .fixedSize()
                    }
                }
            }
            ForEach(account.meters) { meter in
                MeterRow(account: account, meter: meter, usedWidth: usedWidth)
            }
            if account.resets != nil || limits.resetUses[account.id] != nil {
                ResetsRow(account: account)
            }
            if !account.notes.isEmpty || !account.sharedWith.isEmpty {
                // Wraps rather than cutting notes short when an account has several.
                FlowLayout(spacing: 14, lineSpacing: 4) {
                    ForEach(account.notes) { note in
                        Text("\(Text(note.label).foregroundStyle(.secondary))  \(Text(note.value).fontWeight(.semibold))")
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                    }
                    if !account.sharedWith.isEmpty {
                        Text("Also used by " + account.sharedWith.map(\.name).formatted(.list(type: .and)))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, Theme.Layout.modulePadding)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .module(cornerRadius: Theme.Layout.tileRadius)
        .contextMenu {
            Button("Hide \(title)") { limits.hidden.insert(account.id) }
            Button("Refresh Limits") { Task { await limits.refresh(force: true) } }
        }
    }

    private var title: String {
        guard let name = account.account else { return account.provider.name }
        return account.provider.name + " · " + name
    }
}

/// An account's plan (`Max`, `Pro`) in a small capsule beside its name.
struct PlanBadge: View {
    let plan: String

    var body: some View {
        Text(plan)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(.primary.opacity(0.1)))
            .fixedSize()
    }
}

/// A limit's name, a bar colored by its pace, how much is used and when it resets.
private struct MeterRow: View {
    let account: AccountLimits
    let meter: LimitMeter
    let usedWidth: CGFloat
    @Environment(LimitsStore.self) private var limits
    @Environment(PanelState.self) private var state
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let pace = Pace(meter, now: context.date)
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text(meter.label)
                        .lineLimit(1)
                    if limits.isPinned(account, meter) {
                        Image(systemName: "menubar.rectangle")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .help("Shown in the menu bar")
                    }
                }
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 112, alignment: .leading)
                MeterBar(fraction: meter.fraction, even: pace.verdict == .fine ? nil : pace.even, color: Theme.paceColor(pace.verdict))
                    .frame(height: 6)
                Text(LimitText.used(meter))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Theme.Motion.roll, value: LimitText.used(meter))
                    .frame(width: usedWidth, alignment: .trailing)
                Text(LimitText.reset(meter, now: context.date))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 112, alignment: .trailing)
            }
            .monospacedDigit()
            .frame(height: 20)
            .onChange(of: hovering) { _, inside in
                state.chartHover = inside ? LimitText.details(meter, pace: pace, now: context.date) : nil
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A row hidden or removed under the pointer gets no hover end.
        .onDisappear { if hovering { state.chartHover = nil } }
        .contextMenu {
            Button(limits.isPinned(account, meter) ? "Remove from Menu Bar" : "Show in Menu Bar") { limits.togglePin(account, meter) }
            Button("Hide \(account.account ?? account.provider.name)") { limits.hidden.insert(account.id) }
        }
    }
}

/// The limit resets an account holds, with a button that uses one once the person confirms, then what
/// came of it.
private struct ResetsRow: View {
    let account: AccountLimits
    @Environment(LimitsStore.self) private var limits
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 8) {
            switch limits.resetUses[account.id] {
            case .using?:
                ProgressView()
                    .controlSize(.small)
                Text("Using a limit reset…")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case .done(let outcome)?:
                Label(outcome.text, systemImage: outcome.symbol)
                    .foregroundStyle(outcome.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("OK") { limits.dismissResetUse(account) }
                    .controlSize(.small)
            case nil:
                if let resets = account.resets {
                    if confirming {
                        Text(question(resets))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Cancel") { confirming = false }
                            .controlSize(.small)
                        Button("Use Reset") {
                            confirming = false
                            Task { await limits.useReset(account) }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    } else {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text("\(Text("Limit resets").foregroundStyle(.secondary))  \(Text("\(resets.available) available").fontWeight(.semibold))\(Text(expiry(resets, now: context.date)).foregroundStyle(.secondary))")
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        // Even when the last reading failed: a refused use spends nothing.
                        if resets.usable {
                            Button("Use a Reset…") { confirming = true }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .font(.system(size: 11.5))
        .frame(minHeight: 22)
        .onDisappear { confirming = false }
    }

    private func expiry(_ resets: LimitResets, now: Date) -> String {
        resets.nextExpiry.map { " · next expires in " + LimitText.countdown($0.timeIntervalSince(now)) } ?? ""
    }

    /// `Refill your session and weekly limits now? This uses 1 of your 2 resets and can't be undone.`
    private func question(_ resets: LimitResets) -> String {
        let names = account.meters.filter { resets.refills.contains($0.id) }.map { $0.label.lowercased() }
        let what = names.isEmpty ? "your limits" : "your " + names.formatted(.list(type: .and)) + " limits"
        let spent = resets.available == 1 ? "your last reset" : "1 of your \(resets.available) resets"
        return "Refill \(what) now? This uses \(spent) and can't be undone."
    }
}

private extension ResetOutcome {
    var text: String {
        switch self {
        case .reset: "Reset used. Your limits are refilled."
        case .usedEarlier: "Your earlier try went through after all, so no other reset was used."
        case .notUsed(let why): why + " No reset was used."
        case .unsure(let why): why + " Check your limits in a moment. Trying again won't use a second reset."
        }
    }

    var symbol: String {
        switch self {
        case .reset, .usedEarlier: "checkmark.circle.fill"
        case .notUsed: "info.circle.fill"
        case .unsure: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .reset, .usedEarlier: .green
        case .notUsed: .secondary
        case .unsure: .orange
        }
    }
}

/// A rounded track filled to `fraction`, with a tick where an even pace would be.
private struct MeterBar: View {
    let fraction: Double
    let even: Double?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Capsule()
                .fill(.primary.opacity(0.12))
                .overlay(alignment: .leading) {
                    // Rasterized, so glass doesn't lighten the color with vibrancy.
                    Capsule().fill(color).frame(width: fraction > 0 ? max(geometry.size.height, width * fraction) : 0).drawingGroup()
                }
                .overlay(alignment: .leading) {
                    if let even {
                        Capsule()
                            .fill(.primary.opacity(0.75))
                            .frame(width: 2, height: geometry.size.height + 6)
                            .offset(x: min(max(width * even - 1, 0), width - 2))
                    }
                }
        }
    }
}

/// How limits read in the panel, the caption and the menu bar.
enum LimitText {
    /// `67%`, `$3/$250` for a dollar limit, or `120/500` for an allowance of requests.
    static func used(_ meter: LimitMeter) -> String {
        switch meter.unit {
        case .percent: String(format: "%.0f%%", meter.used.rounded(.down))
        case .dollars: compactDollars(meter.used) + "/" + compactDollars(meter.limit)
        case .count: Format.grouped(Int(meter.used)) + "/" + Format.grouped(Int(meter.limit))
        }
    }

    /// `Resets in 3h 25m`, or `Not started` for a session that begins with the next message.
    static func reset(_ meter: LimitMeter, now: Date = Date()) -> String {
        guard let reset = meter.resetsAt else { return meter.period.map { $0 <= 5 * 3600 ? "Not started" : "" } ?? "" }
        return "Resets in " + countdown(reset.timeIntervalSince(now))
    }

    /// The caption for a limit under the pointer: what's used, when it resets and where the pace leads.
    static func details(_ meter: LimitMeter, pace: Pace, now: Date = Date()) -> String {
        var parts = [meter.label]
        switch meter.unit {
        // Rounded down, as in the row beside it.
        case .percent: parts.append(String(format: "%.0f%% used", meter.used.rounded(.down)))
        case .dollars: parts.append("\(compactDollars(meter.used)) of \(compactDollars(meter.limit)) used")
        case .count: parts.append("\(Format.grouped(Int(meter.used))) of \(Format.grouped(Int(meter.limit))) used")
        }
        if let reset = meter.resetsAt {
            parts.append("resets " + reset.formatted(Calendar.current.isDate(reset, inSameDayAs: now) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()))
        }
        switch pace.verdict {
        case .reached:
            parts.append("limit reached")
        case .over:
            if let runsOut = pace.runsOut {
                parts.append("runs out in " + countdown(runsOut.timeIntervalSince(now)) + " at this pace")
            } else {
                parts.append("on pace to hit the limit")
            }
        case .tight, .fine:
            if let atReset = pace.atReset { parts.append(String(format: "on pace for ~%.0f%% by then", min(atReset, 1) * 100)) }
        }
        return parts.joined(separator: " · ")
    }

    static func countdown(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval / 60), 0)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    private static func compactDollars(_ value: Double) -> String {
        value >= 1000 ? String(format: "$%.1fK", value / 1000) : String(format: value.rounded() == value ? "$%.0f" : "$%.2f", value)
    }
}

extension LimitAction {
    var title: String {
        switch self {
        case .allowClaudeDesktop: "Allow Access…"
        }
    }
}
