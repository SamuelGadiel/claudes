import AppKit
import ClaudeSwitcherCore
import UserNotifications

/// Warns via native notification when an account's usage crosses the same
/// thresholds the panel's progress bar uses to turn yellow/red (75%/90%) —
/// unlike the panel's own 5s poll, this runs always, with the panel closed
/// or not, since nobody's watching the bar when it's closed.
///
/// Deliberately not a straightforward "poll everyone every N minutes": each
/// check is a real `claude` subprocess (UsageControlClient), and Anthropic's
/// OAuth refresh token is single-use and rotating — a concurrent renewal
/// attempt from two processes can wipe the Keychain credential (see
/// anthropics/claude-code#88583/#80585/#95822, and ExpiryMonitor/
/// UsageControlClient's own comments). A real foreground session already
/// running `claude` for an account (the VS Code extension's chat panel) is
/// skipped — nobody's watching this background check anyway, and that's
/// exactly the moment the risk of colliding is highest.
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

    // A background poll with nobody watching can afford to be much less
    // frequent than the panel's 5s (which only runs while the popover is
    // actually open) — 10 min balances not taking forever to notice crossing
    // a threshold against adding as few extra `claude` processes to the
    // system as possible.
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
            guard !RunningClaudeSessions.hasActiveEditorSession(configDir: account.configDir) else { continue }

            let configDir = account.configDir
            Task.detached(priority: .background) {
                guard let response = try? UsageControlClient.fetch(configDir: configDir) else { return }
                await MainActor.run { [weak self] in
                    self?.checkThresholds(for: account, response: response)
                }
            }
        }
    }

    private func checkThresholds(for account: RegisteredAccount, response: UsageResponse) {
        checkWindow(
            response.fiveHour, account: account, metric: "session_5h",
            label: String(localized: "the 5h session", bundle: AppResources.bundle)
        )
        checkWindow(
            response.sevenDay, account: account, metric: "week",
            label: String(localized: "the weekly limit", bundle: AppResources.bundle)
        )
        checkWindow(
            response.sevenDayOpus, account: account, metric: "week_opus",
            label: String(localized: "the weekly Opus limit", bundle: AppResources.bundle)
        )
    }

    /// Only the highest threshold already crossed fires — if usage jumped
    /// straight past 90%, there's no value in also notifying about 75%
    /// right after, and once the higher one notifies, the lower one for the
    /// same window never will either (same reasoning, read backwards).
    private func checkWindow(_ window: UsageWindow?, account: RegisteredAccount, metric: String, label: String) {
        guard let window, let utilization = window.utilization, let resetsAt = window.resetsAt else { return }
        let resetTag = Int(resetsAt.timeIntervalSince1970)

        for threshold in [UsageThresholds.critical, UsageThresholds.warning] where utilization >= threshold {
            let key = "\(account.slug)-\(metric)-\(Int(threshold))-\(resetTag)"
            notify(
                key: key,
                title: String(
                    format: NSLocalizedString("High usage: %@", bundle: AppResources.bundle, comment: ""),
                    account.name
                ),
                body: String(
                    format: NSLocalizedString("Passed %d%% of %@.", bundle: AppResources.bundle, comment: ""),
                    Int(threshold), label
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
