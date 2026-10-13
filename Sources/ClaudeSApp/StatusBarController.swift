import ClaudeSCore
import Cocoa
import Combine
import SwiftUI

/// Left click opens a custom panel (SwiftUI, via NSPopover) —
/// necessary because a native NSMenu doesn't support tabs or progress
/// bars. Right click opens a real classic NSMenu. See
/// plans/specs/05-app-status-bar.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let rightClickMenu = NSMenu()
    /// Created here (not inside the View) so the usage poll can be
    /// turned on/off together with the popover's real lifecycle — see
    /// togglePopover().
    private let viewModel = PanelViewModel()
    private var cancellables: Set<AnyCancellable> = []
    private let launchAtLoginItem = NSMenuItem(
        title: String(localized: "Start at Login", bundle: AppResources.bundle), action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
    )

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath.circle",
                accessibilityDescription: "ClaudeS"
            )
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hostingController = NSHostingController(rootView: PanelView(viewModel: viewModel))
        // Without this, the popover only recalculates its size the next time it's
        // recreated — if the SwiftUI content grows after it's already open (e.g.
        // a status message appears), the text stays clipped until it's closed
        // and opened again.
        hostingController.sizingOptions = [.preferredContentSize]
        // .transient closes the popover when it loses focus — the expected
        // behavior (clicked outside, closes). But during the login flow
        // (opens the browser, which steals focus on purpose) and right after
        // it (re-reads the Keychain, which may show the native password prompt —
        // another system window that steals focus) this would close the panel at
        // the worst moment. `viewModel.keepPopoverOpen` signals exactly that
        // time window; outside of it, the popover is always .transient.
        popover.behavior = .transient
        popover.contentViewController = hostingController

        viewModel.$keepPopoverOpen
            .sink { [weak self] keepOpen in
                self?.popover.behavior = keepOpen ? .applicationDefined : .transient
            }
            .store(in: &cancellables)

        popover.delegate = self
        rightClickMenu.delegate = self
        setUpRightClickMenu()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            statusItem.menu = rightClickMenu
            statusItem.button?.performClick(nil)
            // Remove the menu after use: if we left it fixed, AppKit
            // would start treating EVERY click (including left) as
            // opening the NSMenu, and the popover would never open again.
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            // popoverDidClose handles stopPolling() — covers both this
            // manual close and the automatic .transient one when
            // clicking outside, which doesn't go through here.
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            viewModel.prepareForDisplay()
        }
    }

    private func setUpRightClickMenu() {
        let checkUpdates = NSMenuItem(
            title: String(localized: "Check for Updates", bundle: AppResources.bundle), action: #selector(checkForUpdates), keyEquivalent: ""
        )
        let reapplyVSCodePatch = NSMenuItem(
            title: String(localized: "Reapply Patch to Claude Extension", bundle: AppResources.bundle),
            action: #selector(reapplyVSCodePatch), keyEquivalent: ""
        )
        let about = NSMenuItem(
            title: String(localized: "About ClaudeS", bundle: AppResources.bundle), action: #selector(showAbout), keyEquivalent: ""
        )
        // Temporary debug item — lets the user validate the notification
        // pipeline (permission + delivery) on demand, without waiting for a
        // real account's refresh token to expire. Remove once P9
        // (specs/05-app-status-bar) is confirmed working end to end.
        let testNotification = NSMenuItem(
            title: String(localized: "Test Expiry Notification", bundle: AppResources.bundle),
            action: #selector(sendTestNotification), keyEquivalent: ""
        )
        let quit = NSMenuItem(
            title: String(localized: "Quit", bundle: AppResources.bundle), action: #selector(quit), keyEquivalent: "q"
        )

        for item in [checkUpdates, reapplyVSCodePatch, launchAtLoginItem, about, testNotification, quit] {
            item.target = self
        }

        rightClickMenu.addItem(checkUpdates)
        rightClickMenu.addItem(reapplyVSCodePatch)
        rightClickMenu.addItem(launchAtLoginItem)
        rightClickMenu.addItem(about)
        rightClickMenu.addItem(.separator())
        rightClickMenu.addItem(testNotification)
        rightClickMenu.addItem(.separator())
        rightClickMenu.addItem(quit)
    }

    @objc private func checkForUpdates() {
        // TODO: implement real update checking (spec 07, packaging).
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLoginManager.setEnabled(!LaunchAtLoginManager.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Could not change this", bundle: AppResources.bundle)
            alert.informativeText = error.localizedForDisplay
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "OK", bundle: AppResources.bundle))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// Manual fallback while `VSCodeExtensionWatcher` (reactive, via
    /// DispatchSource) hasn't yet been validated in real-world use — the same fix
    /// that already runs on its own at startup and on every detected extension
    /// update, just triggerable by hand in case the watcher fails silently
    /// for some unforeseen reason.
    @objc private func reapplyVSCodePatch() {
        Task { @MainActor in
            let summary = await ClaudePatchCoordinator.applyAll(log: false)
            let alert = NSAlert()
            if summary.entries.isEmpty {
                alert.messageText = String(localized: "No installation found", bundle: AppResources.bundle)
                alert.informativeText = String(
                    localized: "Could not find the Claude extension in either VS Code or VS Code Insiders.",
                    bundle: AppResources.bundle
                )
                alert.alertStyle = .informational
            } else {
                alert.messageText = summary.hadRealError
                    ? String(localized: "Patch not fully applied", bundle: AppResources.bundle)
                    : String(localized: "Patch verified", bundle: AppResources.bundle)
                alert.informativeText = summary.entries
                    .map(Self.localizedDescription)
                    .joined(separator: "\n\n")
                alert.alertStyle = summary.hadRealError ? .warning : .informational
            }
            alert.addButton(withTitle: String(localized: "OK", bundle: AppResources.bundle))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// Builds the localized, human-readable block shown for one editor root
    /// in the "Reapply patch" result alert — explicitly names the Claude
    /// Code extension (not the editor) as what was patched. One version per
    /// line, a blank line before the status lines.
    private static func localizedDescription(for entry: ClaudePatchCoordinator.Entry) -> String {
        var lines = [entry.root.description]
        if let editorVersion = entry.editorVersion {
            lines.append(String(
                format: NSLocalizedString("Editor version: %@", bundle: AppResources.bundle, comment: ""),
                editorVersion
            ))
        }
        if let extensionVersion = entry.scope.extensionVersion {
            lines.append(String(
                format: NSLocalizedString("Extension version: %@", bundle: AppResources.bundle, comment: ""),
                extensionVersion
            ))
        }

        let scopeText: String
        switch entry.scope {
        case .alreadyApplied: scopeText = String(localized: "already applied", bundle: AppResources.bundle)
        case .appliedNow: scopeText = String(localized: "applied now", bundle: AppResources.bundle)
        case .skipped(let reason):
            scopeText = String(
                format: NSLocalizedString("skipped (%@)", bundle: AppResources.bundle, comment: ""), reason
            )
        case .error(let detail):
            scopeText = String(
                format: NSLocalizedString("error — %@", bundle: AppResources.bundle, comment: ""), detail
            )
        }
        let scopeLabel = String(localized: "Scope setting:", bundle: AppResources.bundle)

        let jsText: String
        switch entry.js {
        case .alreadyPatched: jsText = String(localized: "already patched", bundle: AppResources.bundle)
        case .patchedNow(let changes):
            jsText = String(
                format: NSLocalizedString("patched now (%@)", bundle: AppResources.bundle, comment: ""),
                changes.joined(separator: ", ")
            )
        case .skipped(let reason):
            jsText = String(
                format: NSLocalizedString("js skipped (%@)", bundle: AppResources.bundle, comment: ""), reason
            )
        case .error(let detail):
            jsText = String(
                format: NSLocalizedString("js error — %@", bundle: AppResources.bundle, comment: ""), detail
            )
        }

        lines.append("")
        lines.append("\(scopeLabel) \(scopeText)")
        lines.append("extension.js: \(jsText)")

        return lines.joined(separator: "\n")
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func sendTestNotification() {
        ExpiryMonitor.shared.sendTestNotification()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusBarController: NSPopoverDelegate {
    /// Single source of truth that the panel is no longer visible —
    /// fires both on manual close (icon/performClose) and on the
    /// automatic .transient one (click outside), which doesn't go through
    /// togglePopover().
    func popoverDidClose(_ notification: Notification) {
        viewModel.stopPolling()
        // The status message (e.g. "X now uses Y") is only meant to confirm
        // the action that was just taken — once the panel is closed, that
        // confirmation has been seen, so it shouldn't still be sitting there
        // the next time the panel opens.
        viewModel.statusMessage = nil
    }
}

extension StatusBarController: NSMenuDelegate {
    /// SMAppService.mainApp.status is the source of truth — re-read every time
    /// the menu opens, instead of keeping our own @Published that could
    /// get out of sync (e.g. user disables it from macOS's Login Items
    /// panel, outside our control).
    func menuWillOpen(_ menu: NSMenu) {
        launchAtLoginItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
    }
}
