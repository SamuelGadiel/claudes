import AppKit
import ClaudeSwitcherCore
import UserNotifications

/// Warns via native notification when an account's usage crosses the same
/// thresholds the panel's progress bar uses to turn yellow/red (75%/90%), and
/// again when a window that was high resets (so waiting for a limit to free
/// up doesn't mean babysitting the panel) — unlike the panel's own 5s poll,
/// this runs always, with the panel closed or not, since nobody's watching
/// the bar when it's closed.
///
/// Deliberately keeps checking an account even while a real foreground
/// session (the VS Code extension's chat panel) is actively using it — that
/// is the single most important case this notification exists for: noticing
/// you've crossed 75%/90% *while you're mid-task and not watching the bar*.
/// Skipping exactly that case would defeat the whole point. Each check is a
/// real `claude` subprocess (UsageControlClient), and Anthropic's OAuth
/// refresh token is single-use and rotating — a concurrent renewal attempt
/// from two processes can wipe the Keychain credential (see anthropics/
/// claude-code#88583/#80585/#95822) — same residual risk already accepted
/// for the panel's own live poll, for the same reason: the feature's value
/// outweighs it.
@MainActor
final class UsageThresholdMonitor {
    static let shared = UsageThresholdMonitor()
    private init() {}

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// Keyed by account+window+threshold+the window's own resetsAt, not just
    /// account+window+threshold — once the window resets, resetsAt changes,
    /// the key stops matching on its own, and a fresh crossing notifies
    /// again without needing any explicit "forget this" logic.
    private var notifiedKeys: Set<String> = []

    private struct WindowSnapshot {
        let resetsAt: Date
        let utilization: Double
    }
    /// What each window looked like on the previous check — the only way to
    /// detect "this window just reset" is noticing resetsAt changed since
    /// last time; there's nothing in a single snapshot that says that on its
    /// own. Keyed by "<slug>-<metric>".
    private var lastSnapshot: [String: WindowSnapshot] = [:]

    // A background poll can afford to be far less frequent than the panel's
    // 5s (which only runs while the popover is actually open) without losing
    // the point — 10 min balances not taking forever to notice crossing a
    // threshold against adding as few extra `claude` processes to the system
    // as possible.
    private let checkInterval: TimeInterval = 10 * 60

    func start() {
        requestAuthorization { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: self.checkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.check() }
            }
            self.check()

            self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.check() }
            }
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
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

    private func check() {
        let (file, _) = AccountsConfig.load()
        for account in file.accounts {
            let configDir = account.configDir
            Task.detached(priority: .background) {
                guard let response = try? UsageControlClient.fetch(configDir: configDir) else { return }
                await MainActor.run { [weak self] in
                    self?.checkThresholds(for: account, response: response)
                }
            }
        }
    }

    /// Each metric carries its own complete sentence templates (not a
    /// generic noun plugged into one shared template) — "session"/"limit"
    /// don't share a grammatical gender or article in every language this
    /// app supports, so composing the message from a bare label breaks
    /// agreement in at least Portuguese ("da sessão" vs. "do limite").
    private func checkThresholds(for account: RegisteredAccount, response: UsageResponse) {
        checkWindow(
            response.fiveHour, account: account, metric: "session_5h",
            passedFormatKey: "Passed %d%% of the 5h session.",
            resetFormatKey: "The 5h session is available again."
        )
        checkWindow(
            response.sevenDay, account: account, metric: "week",
            passedFormatKey: "Passed %d%% of the weekly limit.",
            resetFormatKey: "The weekly limit is available again."
        )
        checkWindow(
            response.sevenDayOpus, account: account, metric: "week_opus",
            passedFormatKey: "Passed %d%% of the weekly Opus limit.",
            resetFormatKey: "The weekly Opus limit is available again."
        )
    }

    private func checkWindow(
        _ window: UsageWindow?, account: RegisteredAccount, metric: String,
        passedFormatKey: String, resetFormatKey: String
    ) {
        guard let window, let utilization = window.utilization, let resetsAt = window.resetsAt else { return }

        let snapshotKey = "\(account.slug)-\(metric)"
        let previous = lastSnapshot[snapshotKey]
        lastSnapshot[snapshotKey] = WindowSnapshot(resetsAt: resetsAt, utilization: utilization)

        // The window reset since the last check (its resetsAt moved to a new
        // point in time) and it was actually exhausted before resetting —
        // not just high. Someone who peaked at 80% and never got blocked
        // doesn't care that the window reset, they were never stopped by
        // it; this is for "I hit the wall, went to do something else, and
        // now I'd otherwise forget to come back."
        if let previous, previous.resetsAt < resetsAt, previous.utilization >= UsageThresholds.exhausted {
            notify(
                key: "reset-\(snapshotKey)-\(Int(resetsAt.timeIntervalSince1970))",
                title: String(
                    format: NSLocalizedString("Usage reset: %@", bundle: AppResources.bundle, comment: ""),
                    account.name
                ),
                body: NSLocalizedString(resetFormatKey, bundle: AppResources.bundle, comment: "")
            )
        }

        // Only the highest threshold already crossed fires — if usage jumped
        // straight past 90%, there's no value in also notifying about 75%
        // right after, and once the higher one notifies, the lower one for
        // the same window never will either (same reasoning, read backwards).
        for threshold in [UsageThresholds.critical, UsageThresholds.warning] where utilization >= threshold {
            notify(
                key: "\(snapshotKey)-\(Int(threshold))-\(Int(resetsAt.timeIntervalSince1970))",
                title: String(
                    format: NSLocalizedString("High usage: %@", bundle: AppResources.bundle, comment: ""),
                    account.name
                ),
                body: String(
                    format: NSLocalizedString(passedFormatKey, bundle: AppResources.bundle, comment: ""),
                    Int(threshold)
                )
            )
            return
        }
    }

    private func notify(key: String, title: String, body: String) {
        guard notificationsAvailable else { return }
        guard !notifiedKeys.contains(key) else { return }
        notifiedKeys.insert(key)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: key, content: content, trigger: nil)
        )
    }
}
