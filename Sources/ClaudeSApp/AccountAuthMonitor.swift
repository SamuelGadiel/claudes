import AppKit
import ClaudeSCore
import UserNotifications

/// Tracks whether each account is actually logged in, and notifies once when
/// one falls out of that state — entirely via `claude auth status`, never
/// the Keychain directly. That's the key difference from the old
/// Keychain-based design: `claude` itself always has standing trust to read
/// its own credential (it's the one that wrote it), so this never risks
/// resurfacing the macOS Keychain password prompt the way our own direct
/// reads did (see plans/research/keychain-bypass-blocked-by-policy.md). The
/// trade-off is precision: there's no exact expiry date here, only "logged
/// in or not" discovered up to an hour late — see `ExpiryMonitor` for the
/// opt-in, Keychain-based exact date on top of this.
///
/// Each logged-in account gets an hourly recheck. An account found logged
/// out goes dormant (no more background timer) until something gives a
/// reason to look again: the panel opening (`checkAllOnPanelOpen`, which
/// rechecks every account, logged out or not — covers logging back in from
/// outside this app, e.g. a terminal), a completed login in this app
/// (`checkNow`), or a freshly imported account.
@MainActor
final class AccountAuthMonitor {
    static let shared = AccountAuthMonitor()
    private init() {}

    struct State {
        let loggedIn: Bool
        let email: String?
        let orgName: String?
        let subscriptionType: String?
    }

    private(set) var states: [String: State] = [:]
    /// Called on the main actor after any state changes — PanelViewModel
    /// mirrors `states` into its own @Published copy from here.
    var onUpdate: (() -> Void)?

    private var timers: [String: Timer] = [:]
    private var inFlight: Set<String> = []
    /// An account only needs the "session expired" wording/notification once
    /// we've actually seen it logged in before — otherwise a brand new
    /// account would be indistinguishable from one that just fell out.
    private var everLoggedIn: Set<String> = []
    private var notifiedExpired: Set<String> = []
    private var wakeObserver: NSObjectProtocol?
    private var lastFullCheck: Date?

    private static let hourlyInterval: TimeInterval = 3600
    /// Opening/closing the popover in quick succession shouldn't re-spawn
    /// `claude` for every account on every click.
    private static let panelCheckDebounce: TimeInterval = 60

    func start() {
        // See ExpiryMonitor's note on requestAuthorization — scheduling
        // before the callback returns would get the notification silently
        // discarded if permission was still "not determined".
        requestAuthorization { [weak self] in
            guard let self else { return }
            self.checkAll()
            self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.catchUpOverdueAccounts() }
            }
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Called every time the popover opens — rechecks every account (even
    /// ones already known to be logged out) and resets each one's hourly
    /// clock from now.
    func checkAllOnPanelOpen() {
        if let lastFullCheck, Date().timeIntervalSince(lastFullCheck) < Self.panelCheckDebounce { return }
        checkAll()
    }

    private func checkAll() {
        lastFullCheck = Date()
        let (file, _) = AccountsConfig.load()
        for account in file.accounts {
            check(account)
        }
    }

    /// Immediate, single-account check — used right after a login completes
    /// in this app, and right after importing an existing CLAUDE_CONFIG_DIR.
    func checkNow(_ account: RegisteredAccount) {
        check(account)
    }

    /// A brand new account can't possibly be logged in yet (no credential
    /// exists) — known in advance, no need to spawn `claude` to find that out.
    func markNeverLoggedIn(slug: String) {
        states[slug] = State(loggedIn: false, email: nil, orgName: nil, subscriptionType: nil)
        onUpdate?()
    }

    func remove(slug: String) {
        timers[slug]?.invalidate()
        timers[slug] = nil
        states[slug] = nil
        everLoggedIn.remove(slug)
        notifiedExpired.remove(slug)
    }

    /// Distinguishes "has logged in before, now isn't" from "never logged
    /// in" — same underlying "needs login" condition, different message/icon.
    func isExpiredLogin(slug: String) -> Bool {
        states[slug]?.loggedIn == false && everLoggedIn.contains(slug)
    }

    private func catchUpOverdueAccounts() {
        let now = Date()
        let overdueSlugs = Set(timers.filter { $0.value.fireDate <= now }.keys)
        guard !overdueSlugs.isEmpty else { return }
        let (file, _) = AccountsConfig.load()
        for account in file.accounts where overdueSlugs.contains(account.slug) {
            check(account)
        }
    }

    private func check(_ account: RegisteredAccount) {
        guard !inFlight.contains(account.slug) else { return }
        inFlight.insert(account.slug)
        timers[account.slug]?.invalidate()
        timers[account.slug] = nil

        let configDir = account.configDir
        Task {
            let result = await Task.detached(priority: .utility) {
                try? ClaudeAuthStatusClient.fetch(configDir: configDir)
            }.value

            self.inFlight.remove(account.slug)
            // A transient failure to even run `claude` isn't the same as
            // being logged out — keep whatever we last knew and let the
            // next trigger (panel open, hourly timer if still scheduled) try again.
            guard let result else { return }

            self.states[account.slug] = State(
                loggedIn: result.loggedIn, email: result.email, orgName: result.orgName,
                subscriptionType: result.subscriptionType
            )
            self.onUpdate?()

            if result.loggedIn {
                self.everLoggedIn.insert(account.slug)
                self.notifiedExpired.remove(account.slug)
                self.scheduleNext(for: account)
            } else if self.everLoggedIn.contains(account.slug) {
                self.notify(account)
            }
            // Not logged in and never was: no timer, no notification —
            // dormant until the panel opens or a login/import happens.
        }
    }

    private func scheduleNext(for account: RegisteredAccount) {
        timers[account.slug] = Timer.scheduledTimer(withTimeInterval: Self.hourlyInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.check(account) }
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

    private func notify(_ account: RegisteredAccount) {
        guard notificationsAvailable else { return }
        guard !notifiedExpired.contains(account.slug) else { return }
        notifiedExpired.insert(account.slug)

        let content = UNMutableNotificationContent()
        content.title = String(
            format: NSLocalizedString("Session expired: %@", bundle: AppResources.bundle, comment: ""),
            account.name
        )
        content.body = String(
            localized: "Open ClaudeS and log in again to keep using this account.",
            bundle: AppResources.bundle
        )
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(account.slug)-expired", content: content, trigger: nil)
        )
    }
}
