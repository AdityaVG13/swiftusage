import Foundation
import Observation
import UsageCore

enum PanelTab: String, CaseIterable {
    case overview = "Overview"
    case models = "Models"
    case limits = "Limits"
}

enum CustomizeSection: String, CaseIterable {
    case providers = "Providers"
    case menuBar = "Menu Bar"
}

/// What the panel is showing. Views only redraw for the properties they read, so what the pointer is
/// over lives here too: hovering redraws the caption and the graph under the pointer, not the panel.
@MainActor
@Observable
final class PanelState {
    var tab: PanelTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "tab") }
    }
    var provider: Provider? {
        didSet { UserDefaults.standard.set(provider?.rawValue ?? "all", forKey: "provider") }
    }
    var range: StatsRange {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "range") }
    }
    /// The Customize section in the panel's place, if it's open.
    var customizing: CustomizeSection?
    var screenshotMode = false
    /// The heatmap day under the pointer.
    var hoveredDay: Int?
    /// Details of the chart bar, model row or limit under the pointer.
    var chartHover: String?

    init() {
        let defaults = UserDefaults.standard
        tab = defaults.string(forKey: "tab").flatMap(PanelTab.init(rawValue:)) ?? .overview
        provider = defaults.string(forKey: "provider").flatMap(Provider.init(rawValue:))
        range = defaults.string(forKey: "range").flatMap(StatsRange.init(rawValue:)) ?? .all
    }

    func clearHover() {
        hoveredDay = nil
        chartHover = nil
    }
}
