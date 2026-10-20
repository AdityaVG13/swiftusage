import Foundation
import Observation
import UsageCore

/// Which providers the person follows, chosen in Customize. A provider that's turned off leaves the
/// picker, the totals, the Limits tab and the menu bar, and its history and limits aren't read.
@MainActor
@Observable
final class Preferences {
    var hiddenProviders: Set<Provider> {
        didSet {
            guard hiddenProviders != oldValue else { return }
            UserDefaults.standard.set(hiddenProviders.map(\.rawValue).sorted(), forKey: "hiddenProviders")
            onProvidersChange?()
        }
    }
    /// Set by the menu bar controller, which owns the stores that read the providers.
    @ObservationIgnored var onProvidersChange: (() -> Void)?

    init() {
        hiddenProviders = Set((UserDefaults.standard.stringArray(forKey: "hiddenProviders") ?? []).compactMap(Provider.init(rawValue:)))
    }

    /// In the picker's order.
    var shownProviders: [Provider] {
        Provider.allCases.filter { !hiddenProviders.contains($0) }
    }

    func isShown(_ provider: Provider) -> Bool {
        !hiddenProviders.contains(provider)
    }

    /// Turns a provider on or off. The last one on stays on, so the panel always has something to show.
    func setShown(_ provider: Provider, _ shown: Bool) {
        if shown {
            hiddenProviders.remove(provider)
        } else if shownProviders != [provider] {
            hiddenProviders.insert(provider)
        }
    }
}
