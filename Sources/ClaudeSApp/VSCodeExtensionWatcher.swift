import ClaudeSCore
import Foundation

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
        applyNow()

        for root in VSCodeEditorRoot.allCases {
            watch(path: root.extensionsDirPath)
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
        Task.detached(priority: .utility) {
            await ClaudePatchCoordinator.applyAll(log: true)
        }
    }
}
