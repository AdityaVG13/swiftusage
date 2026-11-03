import AppKit
import Testing
@testable import UsageCore
@testable import UsageGraphs

/// Every plan in the picker and the menu bar draws a mark of its own. A provider with no entry falls
/// back to a generic square, which looks like a plan nobody drew a logo for rather than an error.
struct LogoAssetsTests {
    @Test func everyProviderDrawsItsOwnMark() {
        for provider in Provider.allCases {
            let image = ProviderLogo.nsImage(provider)
            #expect(image != nil, "\(provider.rawValue) has no logo")
            #expect((image?.size.width ?? 0) > 0, "\(provider.rawValue)'s logo has no width")
            #expect((image?.size.height ?? 0) > 0, "\(provider.rawValue)'s logo has no height")
        }
    }
}
