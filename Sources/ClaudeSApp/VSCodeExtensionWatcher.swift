import ClaudeSCore
import Foundation
import UserNotifications

/// Keeps the two patches of the official Claude Code extension (see
/// ClaudePatchCoordinator) always applied, reacting in real time when
/// the extension is updated — no polling. The user leaves the app running
/// indefinitely in the status bar (not restarting day to day), so running
/// the patches only once at startup is not enough: when VS Code
/// updates the extension on its own in the background, it gets a new folder
/// (`anthropic.claude-code-<new-version>-darwin-arm64`) with the
/// original, unpatched files.
///
/// Watches `extensions/` of each present `VSCodeEditorRoot` (stable
/// and/or Insiders) via `DispatchSource` (kqueue) — the same reactive
/// mechanism the official extension itself uses internally to watch
/// configuration changes (see `watchGlobalClaudeFileAt` in its
/// `extension.js`), instead of polling at intervals.
@MainActor
final class VSCodeExtensionWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceWorkItem: DispatchWorkItem?

    func start() {
        // See AccountAuthMonitor's note on requestAuthorization — scheduling
        // before the callback returns would get the notification silently
        // discarded if permission was still "not determined".
        requestAuthorization { [weak self] in
            guard let self else { return }
            self.applyNow()
            for root in VSCodeEditorRoot.allCases {
                self.watch(path: root.extensionsDirPath)
            }
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        sources = []
    }

    /// Directory may not exist yet (editor never installed on this
    /// machine) — `open` fails silently in that case, no problem:
    /// we simply don't watch that root.
    private func watch(path: String) {
        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleApply() }
        source.setCancelHandler { close(fileDescriptor) }
        source.resume()
        sources.append(source)
    }

    /// Debounce shared across all watched roots: extracting
    /// an update can generate more than one write event in quick
    /// succession (old folder removed, new one created) — waits for the dust
    /// to settle before re-reading the files, so it doesn't catch an
    /// intermediate state.
    private func scheduleApply() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyNow() }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func applyNow() {
        // .utility: the extension.js patch can take up to ~1.6s in rare
        // cases (retry/backoff against an update in progress) — never on the
        // main thread.
        Task.detached(priority: .utility) { [weak self] in
            let summary = await ClaudePatchCoordinator.applyAll(log: true)
            await self?.notifyIfNeeded(summary)
        }
    }

    /// This runs unattended (app launch, or a background extension update
    /// caught by the watcher) — the user never asked for it, so it only
    /// speaks up when there's something worth knowing: a patch that just
    /// got applied, or a real failure. Silent when nothing changed
    /// (everything already patched) or when there's no supported editor
    /// installation at all (expected for terminal-only users).
    private func notifyIfNeeded(_ summary: ClaudePatchCoordinator.Summary) {
        guard notificationsAvailable, !summary.entries.isEmpty else { return }

        if summary.hadRealError {
            notify(
                identifier: "vscode-patch-error",
                title: String(localized: "Patch not fully applied", bundle: AppResources.bundle),
                body: String(
                    localized: "ClaudeS couldn't fully patch the Claude Code extension. Right-click the status bar icon and choose \"Reapply Patch to Claude Extension\" for details.",
                    bundle: AppResources.bundle
                )
            )
            return
        }

        let appliedSomething = summary.entries.contains {
            Self.wasAppliedNow($0.clauderc) || Self.wasAppliedNow($0.env)
        }
        guard appliedSomething else { return }

        notify(
            identifier: "vscode-patch-applied",
            title: String(localized: "Patch applied", bundle: AppResources.bundle),
            body: String(
                localized: "ClaudeS patched the Claude Code extension in VS Code.",
                bundle: AppResources.bundle
            )
        )
    }

    private static func wasAppliedNow(_ outcome: ClaudePatchCoordinator.SubPatchOutcome) -> Bool {
        if case .appliedNow = outcome { return true }
        return false
    }

    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func requestAuthorization(completion: @escaping () -> Void) {
        guard notificationsAvailable else {
            completion()
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { completion() }
        }
    }

    private func notify(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }
}
