import ClaudeSwitcherCore
import UserNotifications

/// Warns via native notification when an account has expired or is about to
/// expire — watches `refreshTokenExpiresAt`, never `expiresAt` (the access
/// token expires and renews itself all the time, that's normal; see
/// specs/01-gerenciamento-contas-storage). Periodic check, with no
/// network call at all — only reads the Keychain, the same mechanism as `cs list`.
@MainActor
final class ExpiryMonitor {
    private var timer: Timer?
    /// Avoids notifying repeatedly for the same condition on every check —
    /// only fires again if the condition is resolved and then happens again.
    private var notifiedKeys: Set<String> = []

    // The original 5min re-read the Keychain for every account with the whole app
    // in the background, forever — the same class of bug already fixed in the usage
    // poll (spec 06), except it hadn't been covered in this component: it was
    // the cause of Keychain password prompts periodically reappearing
    // even with the panel closed. 6h still warns with plenty of margin within the
    // 24h window, reading the Keychain ~72x less.
    private let checkInterval: TimeInterval = 6 * 3600
    private let warningWindow: TimeInterval = 24 * 3600

    func start() {
        // requestAuthorization is asynchronous — scheduling notifications before
        // the callback returns means scheduling while permission is still
        // "not determined"; the system accepts the scheduling but then
        // discards the notification when it's time to display it, because
        // permission was only granted AFTERWARD. That's why check()/timer only
        // start inside the callback.
        requestAuthorization { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: self.checkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.check() }
            }
            self.check()
        }
    }

    /// UNUserNotificationCenter requires a real, signed .app bundle
    /// (even ad-hoc) — without that, it crashes the entire process with
    /// NSInternalInconsistencyException, or silently denies without ever
    /// showing the prompt. A notification is secondary; it should never
    /// take down the app. See specs/05-app-status-bar for the complete history
    /// of this investigation.
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
        let now = Date()

        for account in file.accounts {
            let status = AccountDiscovery.status(for: account)
            guard let refreshExpiresAt = status.refreshTokenExpiresAt else { continue }

            let expiredKey = "\(account.slug)-expired"
            let expiringKey = "\(account.slug)-expiring"

            if refreshExpiresAt < now {
                notify(
                    key: expiredKey,
                    title: String(
                        format: NSLocalizedString("Session expired: %@", bundle: AppResources.bundle, comment: ""),
                        account.name
                    ),
                    body: String(
                        localized: "Open Claude Switcher and log in again to keep using this account.",
                        bundle: AppResources.bundle
                    )
                )
            } else {
                notifiedKeys.remove(expiredKey)
                if refreshExpiresAt.timeIntervalSince(now) < warningWindow {
                    notify(
                        key: expiringKey,
                        title: String(
                            format: NSLocalizedString("Session expiring soon: %@", bundle: AppResources.bundle, comment: ""),
                            account.name
                        ),
                        body: String(
                            format: NSLocalizedString("Expires %@.", bundle: AppResources.bundle, comment: ""),
                            refreshExpiresAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened))
                        )
                    )
                } else {
                    notifiedKeys.remove(expiringKey)
                }
            }
        }
    }

    /// Manual trigger for testing the notification pipeline end-to-end
    /// without waiting for a real account to expire — bypasses the normal
    /// dedup (notifiedKeys) so it can be fired repeatedly on demand. Exposed
    /// via the right-click menu's "Test Expiry Notification" item.
    func sendTestNotification() {
        requestAuthorization { [weak self] in
            guard self?.notificationsAvailable == true else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Test notification", bundle: AppResources.bundle)
            content.body = String(
                localized: "If you can see this, notifications are working correctly.",
                bundle: AppResources.bundle
            )
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)
            )
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
