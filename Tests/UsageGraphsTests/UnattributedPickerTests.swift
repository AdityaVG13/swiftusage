import AppKit
import SwiftUI
import Testing
import UsageCore
@testable import UsageGraphs

struct UnattributedPickerTests {
    @MainActor
    @Test func pickerCanBeCapturedOffscreen() throws {
        _ = NSApplication.shared
        let root = ProviderPicker(selection: .constant(.unattributed), providers: Provider.allCases,
                                  available: Set(Provider.allCases))
            .frame(width: Theme.Layout.contentWidth, height: 40)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: Theme.Layout.contentWidth, height: 40)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(Theme.Layout.contentWidth))
        #expect(bitmap.pixelsHigh >= 40)
        if let scratch = ProcessInfo.processInfo.environment["SWIFTUSAGE_RENDER_DIR"] {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let output = URL(fileURLWithPath: scratch).appendingPathComponent("swiftusage-unattributed-picker.png")
            try png.write(to: output, options: .atomic)
            print("Offscreen picker: \(output.path)")
        }
    }
}
