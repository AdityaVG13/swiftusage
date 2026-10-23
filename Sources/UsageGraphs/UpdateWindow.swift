import AppKit
import SwiftUI

/// The update window: a release that's downloaded and ready, with Install and Relaunch, Remind Me Later
/// and Skip This Version, or how Check for Updates… is going. It floats over other apps'
/// windows, since the app has no Dock icon to find it by once it's behind them. When it opens by itself
/// it doesn't take the keyboard, so typing elsewhere can't press its buttons.
@MainActor
final class UpdateWindow: NSObject, NSWindowDelegate {
    static let shared = UpdateWindow()

    private var window: NSWindow?

    func show(activating: Bool) {
        let window = window ?? make()
        if !window.isVisible { window.center() }
        if activating {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// Without the close button's `windowWillClose`, which puts an offered release off.
    func hide() {
        window?.orderOut(nil)
    }

    /// Not while installing, which ends by reopening the app or with what went wrong.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !Updater.shared.isInstalling
    }

    func windowWillClose(_ notification: Notification) {
        Updater.shared.dismiss()
    }

    private func make() -> NSWindow {
        let host = NSHostingController(rootView: UpdateView().environment(Updater.shared))
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Software Update"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }
}

private struct UpdateView: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        let phase = updater.phase
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(phase))
                        .font(.system(size: 15, weight: .semibold))
                    Text(detail(phase))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if busy(phase) {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            buttons(phase)
                .padding(.top, 20)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(width: 480)
    }

    @ViewBuilder
    private func buttons(_ phase: Updater.Phase) -> some View {
        HStack(spacing: 8) {
            switch phase {
            case .ready, .manual, .installing:
                let installing = updater.isInstalling
                Button("Skip This Version") { updater.skip() }
                    .disabled(installing)
                Spacer()
                Button("Remind Me Later") { updater.remindLater() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(installing)
                if case .manual = phase {
                    Button("Download…") { updater.download() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Install and Relaunch") { updater.install() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(installing)
                }
            case .checking, .downloading:
                Spacer()
                Button("Cancel") { updater.dismiss() }
                    .keyboardShortcut(.cancelAction)
            case .idle, .upToDate, .failed:
                Spacer()
                Button("OK") { updater.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func busy(_ phase: Updater.Phase) -> Bool {
        switch phase {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    private func title(_ phase: Updater.Phase) -> String {
        switch phase {
        case .idle, .checking: "Checking for updates…"
        case .downloading(let feed): "Downloading SwiftUsage \(feed.version)…"
        case .upToDate: "SwiftUsage is up to date"
        case .ready(let feed): "SwiftUsage \(feed.version) is ready to install"
        case .manual(let feed, _): "SwiftUsage \(feed.version) is available"
        case .installing(let feed): "Installing SwiftUsage \(feed.version)…"
        case .failed(let title, _): title
        }
    }

    private func detail(_ phase: Updater.Phase) -> String {
        let installed = updater.app?.version ?? ""
        return switch phase {
        case .idle, .checking: "Looking for a newer release on GitHub."
        case .downloading(let feed): "You have \(installed). The new version is \(feed.size.formatted(.byteCount(style: .file)))."
        case .upToDate: "\(installed) is the newest version."
        case .ready: "You have \(installed). It's downloaded, and installing it reopens SwiftUsage in a few seconds with your settings and history as they are."
        case .manual(_, let problem): problem
        case .installing: "SwiftUsage reopens in a moment."
        case .failed(_, let message): message
        }
    }
}
