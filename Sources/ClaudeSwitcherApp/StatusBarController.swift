import ClaudeSwitcherCore
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
        title: "Start at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
    )

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath.circle",
                accessibilityDescription: "Claude Switcher"
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
            title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: ""
        )
        let reapplyVSCodePatch = NSMenuItem(
            title: "Reapply Patch to Claude Extension", action: #selector(reapplyVSCodePatch), keyEquivalent: ""
        )
        let about = NSMenuItem(
            title: "About Claude Switcher", action: #selector(showAbout), keyEquivalent: ""
        )
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")

        for item in [checkUpdates, reapplyVSCodePatch, launchAtLoginItem, about, quit] {
            item.target = self
        }

        rightClickMenu.addItem(checkUpdates)
        rightClickMenu.addItem(reapplyVSCodePatch)
        rightClickMenu.addItem(launchAtLoginItem)
        rightClickMenu.addItem(about)
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
            alert.messageText = "Could not change this"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
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
                alert.messageText = "No installation found"
                alert.informativeText = "Could not find the Claude extension in either VS Code or VS Code Insiders."
                alert.alertStyle = .informational
            } else {
                alert.messageText = summary.hadRealError ? "Patch not fully applied" : "Patch verified"
                alert.informativeText = summary.entries
                    .map { "\($0.root):\n\($0.scopeMessage)\n\($0.jsMessage)" }
                    .joined(separator: "\n\n")
                alert.alertStyle = summary.hadRealError ? .warning : .informational
            }
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
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
