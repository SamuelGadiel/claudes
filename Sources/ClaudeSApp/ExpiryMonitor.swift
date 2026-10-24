import AppKit
import ClaudeSCore

/// Opt-in, display-only tracker for the exact Keychain expiry date ("Login
/// expires in X") — off by default, and touches the Keychain only while
/// enabled. This is the one place in the app that still reads the Keychain
/// directly, which is exactly why it's opt-in: unlike `AccountAuthMonitor`
/// (always on, backed by `claude auth status`, never at risk of the macOS
/// password prompt), a direct read here can resurface it whenever the
/// `claude` CLI has rewritten the credential since our last successful read
/// — see plans/research/keychain-bypass-blocked-by-policy.md.
///
/// Login state itself (whether the account needs a fresh login) is decided
/// entirely by `AccountAuthMonitor`, never by this tracker — a date read
/// here can go stale (the real session can die before the date we last read
/// says it should), so the UI only shows it when `AccountAuthMonitor` also
/// agrees the account is currently logged in.
///
/// Mechanism: one timer per account, scheduled to fire at its own
/// last-known `refreshTokenExpiresAt` — never sooner, never a blind
/// interval. When it fires: if the token quietly rotated forward in the
/// meantime (the common case), update the stored date and reschedule,
/// silently. If it's genuinely expired by then, there's nothing to show
/// anymore — go dormant; `AccountAuthMonitor`'s hourly/panel-open check
/// will have already caught the real "needs login" state faster than this
/// could anyway.
@MainActor
final class ExpiryMonitor {
    static let shared = ExpiryMonitor()
    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private static let enabledKey = "showLoginExpiryDate"

    private(set) var isEnabled: Bool
    private(set) var expiryDates: [String: Date] = [:]
    /// Called on the main actor after `expiryDates` changes — PanelViewModel
    /// mirrors it into its own @Published copy from here.
    var onUpdate: (() -> Void)?

    private var timers: [String: Timer] = [:]
    private var wakeObserver: NSObjectProtocol?

    /// Toggled from the right-click menu. Turning it on reads the Keychain
    /// once per currently-logged-in account (per `AccountAuthMonitor`) and
    /// arms their timers; turning it off cancels everything and forgets the
    /// dates — no further Keychain access until re-enabled.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            for timer in timers.values { timer.invalidate() }
            timers.removeAll()
            expiryDates.removeAll()
            onUpdate?()
        }
    }

    func start() {
        guard isEnabled else { return }
        let (file, _) = AccountsConfig.load()
        for account in file.accounts where AccountAuthMonitor.shared.states[account.slug]?.loggedIn == true {
            checkAccount(account)
        }
        if wakeObserver == nil {
            // A Timer's RunLoop doesn't run while the Mac is asleep — a timer
            // scheduled to fire mid-sleep just fires on its own on wake, no
            // extra action needed for that ordinary case. This is only a
            // safety net for the unlikely case a timer gets dropped instead
            // of merely delayed across sleep.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
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

    /// Re-reads the Keychain for a single account — used right after a
    /// successful login (new expiry date) and right after importing an
    /// existing CLAUDE_CONFIG_DIR that may already carry a credential.
    /// No-op while the feature is disabled.
    func checkAccountImmediately(_ account: RegisteredAccount) {
        guard isEnabled else { return }
        checkAccount(account)
    }

    func remove(slug: String) {
        timers[slug]?.invalidate()
        timers[slug] = nil
        expiryDates[slug] = nil
    }

    private func catchUpOverdueAccounts() {
        let now = Date()
        let overdueSlugs = Set(timers.filter { $0.value.fireDate <= now }.keys)
        guard !overdueSlugs.isEmpty else { return }
        let (file, _) = AccountsConfig.load()
        for account in file.accounts where overdueSlugs.contains(account.slug) {
            checkAccount(account)
        }
    }

    private func checkAccount(_ account: RegisteredAccount) {
        timers[account.slug]?.invalidate()
        timers[account.slug] = nil

        let now = Date()
        let status = AccountDiscovery.status(for: account)
        guard let refreshExpiresAt = status.refreshTokenExpiresAt, refreshExpiresAt > now else {
            // No credential, or genuinely expired — nothing to display.
            // AccountAuthMonitor is the one that'll tell the UI this account
            // needs login; this tracker just stays dormant until the next
            // login re-arms it.
            expiryDates[account.slug] = nil
            onUpdate?()
            return
        }

        expiryDates[account.slug] = refreshExpiresAt
        onUpdate?()
        timers[account.slug] = Timer.scheduledTimer(
            withTimeInterval: refreshExpiresAt.timeIntervalSince(now), repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.checkAccount(account) }
        }
    }
}
