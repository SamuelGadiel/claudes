import AppKit
import ClaudeSwitcherCore
import SwiftUI

struct ProjectInfo: Identifiable {
    let path: String
    let name: String
    var currentAccountSlug: String?
    var id: String { path }
}

struct TerminalSessionInfo: Identifiable {
    let pid: Int32
    let cwd: String
    let accountLabel: String
    var id: Int32 { pid }
}

struct AccountUsageState {
    var isLoading = false
    var response: UsageResponse?
    var errorMessage: String?
}

struct AccountAuthInfo {
    var email: String?
    var orgName: String?
    var subscriptionType: String?
}

@MainActor
final class PanelViewModel: ObservableObject {
    @Published var accounts: [RegisteredAccount] = []
    @Published var defaultSlug: String?
    @Published var projects: [ProjectInfo] = []
    @Published var terminalSessions: [TerminalSessionInfo] = []
    @Published var statusMessage: String?
    @Published var selectedAccountSlug: String?
    @Published var usageStates: [String: AccountUsageState] = [:]
    @Published var isAddingAccount = false
    @Published var newAccountName = ""
    @Published var newAccountSlug = ""
    @Published var addAccountError: String?
    /// Non-nil while the add-account form represents "import an existing
    /// CLAUDE_CONFIG_DIR" rather than "create a brand-new one" — same form,
    /// same confirmAddAccount(), just a pre-picked directory instead of the
    /// ~/.claude-<slug> default.
    @Published var importedConfigDir: String?
    /// While the user hasn't manually edited the slug, it tracks the
    /// typed name. Once edited by hand, it stops being overwritten.
    private var slugManuallyEdited = false
    /// Read from the Keychain (local, fast) — used to know whether it's worth
    /// trying to fetch usage. Without this, an account never logged in would make
    /// UsageControlClient hang waiting for an interactive login flow that would
    /// never arrive (process stuck until timeout).
    @Published var accountStatuses: [String: AccountStatus] = [:]
    /// Email/organization/plan — comes from `claude auth status`, not the
    /// Keychain (which has no email). Loaded once per account (never
    /// changes on its own), not repeated on every usage poll.
    @Published var authInfoStates: [String: AccountAuthInfo] = [:]
    /// true while the login flow is active — during that period the popover
    /// should not close on its own (`claude auth login` opens the browser, which
    /// steals focus, and the end of login re-reads the Keychain, which may prompt
    /// for a password). Observed by StatusBarController to switch the
    /// NSPopover's `behavior`. Outside that period, the popover closes normally
    /// when clicking outside, like any panel of this kind.
    @Published var keepPopoverOpen = false

    /// Periodically re-reads the usage of the selected tab while the panel is
    /// open — local subprocess via UsageControlClient, never network/HTTP,
    /// but not entirely free: each call is a `claude` process that could in
    /// principle race a real foreground session over OAuth token renewal
    /// (see refreshStatus/loadUsage). Short enough that the panel feels live
    /// while open; there's no reason to do this with the popover closed.
    private let pollInterval: TimeInterval = 5
    private var pollTimer: Timer?

    init() {
        let (file, _) = AccountsConfig.load()
        accounts = file.accounts
        defaultSlug = file.defaultAccountSlug
        warmUpKeychain()
    }

    /// Reads the status (Keychain) of each registered account as soon as the app
    /// opens, before any popover is on screen — a single read per
    /// account, cached in `accountStatuses`. `refresh()` afterward never re-reads
    /// the Keychain for an account already in this cache, only for a newly created one.
    /// It then already triggers loading the usage of all accounts —
    /// by the time the user clicks the icon, the data should already be
    /// ready, without waiting for the popover to open to start fetching.
    private func warmUpKeychain() {
        Task.detached(priority: .utility) {
            let (file, _) = AccountsConfig.load()
            let statuses = file.accounts.reduce(into: [String: AccountStatus]()) { result, account in
                result[account.slug] = AccountDiscovery.status(for: account)
            }
            await MainActor.run { [statuses] in
                for (slug, status) in statuses where self.accountStatuses[slug] == nil {
                    self.accountStatuses[slug] = status
                }
                self.loadUsageForAllAccounts()
                self.loadAuthInfoForAllAccounts()
            }
        }
    }

    /// Re-reads the Keychain for a single account — used when we know its
    /// status specifically may have changed (e.g. login just finished),
    /// without re-querying all the others again. Also drops the cached
    /// auth info (email/org/plan): `loadAuthInfo` only ever fetches it once
    /// per account and otherwise never refreshes it, so a fresh login is the
    /// one moment that cache actually needs invalidating.
    func refreshStatus(slug: String) {
        guard let account = accounts.first(where: { $0.slug == slug }) else { return }
        accountStatuses[slug] = AccountDiscovery.status(for: account)
        authInfoStates[slug] = nil
    }

    private static let vscodeBundleIdentifiers: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]

    private static var isVSCodeRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            guard let bundleIdentifier = $0.bundleIdentifier else { return false }
            return vscodeBundleIdentifiers.contains(bundleIdentifier)
        }
    }

    func refresh() {
        let (file, _) = AccountsConfig.load()
        accounts = file.accounts
        defaultSlug = file.defaultAccountSlug

        // storage.json is state VS Code persists for session restore, not a
        // live snapshot — it keeps whatever was last written even after VS
        // Code fully quits. Without this check, the last project open before
        // quitting would show up here forever as still "open".
        projects = Self.isVSCodeRunning
            ? OpenedWindowsReader.read().map { window in
                let slug = ClauderFile.find(startingAt: window.path)?.account
                return ProjectInfo(path: window.path, name: window.name, currentAccountSlug: slug)
            }
            : []

        terminalSessions = RunningClaudeSessions.list()
            .filter { !$0.isManagedByEditor }
            .compactMap { session in
                guard let cwd = session.cwd else { return nil }
                let expandedDefault = ("~/.claude" as NSString).expandingTildeInPath
                let target = ((session.configDirFromEnv ?? expandedDefault) as NSString).expandingTildeInPath
                let label = accounts.first {
                    ($0.configDir as NSString).expandingTildeInPath == target
                }?.name ?? String(localized: "unregistered account", bundle: AppResources.bundle)
                return TerminalSessionInfo(pid: session.pid, cwd: cwd, accountLabel: label)
            }

        // Only queries the Keychain for not-yet-cached (new) accounts —
        // avoids re-reading already-known credentials on every refresh() and,
        // with that, repeated authorization prompts.
        for account in accounts where accountStatuses[account.slug] == nil {
            accountStatuses[account.slug] = AccountDiscovery.status(for: account)
        }
    }

    /// true for both "never logged in" and "expired" — anything that needs
    /// the user to go through the login flow again. `accountStatuses[slug] ==
    /// nil` (status not read yet) deliberately does NOT count as needing
    /// login — only an actually-confirmed bad state does.
    func needsLogin(slug: String) -> Bool {
        guard let state = accountStatuses[slug]?.loginState else { return false }
        return state != .loggedIn
    }

    /// Distinguishes "has a credential, but the refresh token expired" from
    /// "never logged in" — same underlying `needsLogin` gate, different
    /// message/icon in the UI.
    func isExpiredLogin(slug: String) -> Bool {
        accountStatuses[slug]?.loginState == .expired
    }

    func accountName(forSlug slug: String?) -> String {
        guard let slug, let account = accounts.first(where: { $0.slug == slug }) else {
            return String(localized: "No account set", bundle: AppResources.bundle)
        }
        return account.name
    }

    /// Switches the account of a project (.clauderc + .vscode/settings.json —
    /// same flow as `cs set`). No session sync needed anymore: every
    /// account's `projects/` is the same shared directory (see
    /// SharedSessionsDirectory), so chat history is already there no matter
    /// which account ends up active.
    func switchAccount(project: ProjectInfo, to newAccount: RegisteredAccount) {
        do {
            try ClauderFile.write(accountSlug: newAccount.slug, inDir: project.path)
            let result = try VSCodeSettings.setConfigDir(projectPath: project.path, configDir: newAccount.configDir)
            statusMessage = String(
                format: NSLocalizedString("%@ now uses %@", bundle: AppResources.bundle, comment: ""),
                project.name, newAccount.name
            )
            for warning in result.warnings {
                statusMessage? += " — \(warning.localizedForDisplay)"
            }
        } catch {
            statusMessage = String(
                format: NSLocalizedString("Error switching %@: %@", bundle: AppResources.bundle, comment: ""),
                project.name, error.localizedForDisplay
            )
        }
        refresh()
    }

    /// Deletes every saved chat for this project from the shared sessions
    /// directory — affects every account, since chats aren't account-scoped
    /// anymore. Irreversible; the view already confirmed with the user.
    func clearChatHistory(project: ProjectInfo) {
        do {
            try SharedSessionsDirectory.clearHistory(forProjectPath: project.path)
            statusMessage = String(
                format: NSLocalizedString("Chat history for %@ cleared", bundle: AppResources.bundle, comment: ""),
                project.name
            )
        } catch {
            statusMessage = String(
                format: NSLocalizedString(
                    "Error clearing history for %@: %@", bundle: AppResources.bundle, comment: ""
                ),
                project.name, error.localizedForDisplay
            )
        }
    }

    /// It's not possible to change the environment of an already-running process —
    /// this only writes the directory's .clauderc, taking effect next time
    /// claude/cs is run there. See plans/specs/05-app-status-bar.
    func switchTerminalSessionAccount(session: TerminalSessionInfo, to newAccount: RegisteredAccount) {
        do {
            try ClauderFile.write(accountSlug: newAccount.slug, inDir: session.cwd)
            statusMessage = String(
                format: NSLocalizedString(
                    "%@ will use %@ on the next run (the current session, pid %d, keeps the old account)",
                    bundle: AppResources.bundle, comment: ""
                ),
                session.cwd, newAccount.name, session.pid
            )
        } catch {
            statusMessage = String(
                format: NSLocalizedString("Error writing .clauderc at %@: %@", bundle: AppResources.bundle, comment: ""),
                session.cwd, error.localizedForDisplay
            )
        }
        refresh()
    }

    func selectAccount(_ slug: String) {
        selectedAccountSlug = slug
        loadUsage(slug: slug)
    }

    func startAddingAccount() {
        newAccountName = ""
        newAccountSlug = ""
        slugManuallyEdited = false
        addAccountError = nil
        importedConfigDir = nil
        isAddingAccount = true
    }

    /// Same form as startAddingAccount(), but the directory is already
    /// picked (an existing CLAUDE_CONFIG_DIR, e.g. one set up before this
    /// app existed) instead of the ~/.claude-<slug> default — the user only
    /// still needs to give it a name.
    func startImportingAccount(dir: String) {
        newAccountName = ""
        newAccountSlug = ""
        slugManuallyEdited = false
        addAccountError = nil
        importedConfigDir = dir
        isAddingAccount = true
    }

    func cancelAddingAccount() {
        isAddingAccount = false
        newAccountName = ""
        newAccountSlug = ""
        slugManuallyEdited = false
        addAccountError = nil
        importedConfigDir = nil
    }

    /// Called by the name TextField — while the slug hasn't been edited by
    /// hand, it's recalculated from the name on every keystroke.
    func setAccountName(_ name: String) {
        newAccountName = name
        if !slugManuallyEdited {
            newAccountSlug = Slug.make(from: name)
        }
    }

    /// Called by the slug TextField — marks manual editing, so the slug
    /// stops being automatically overwritten by the name from here on.
    func setAccountSlugManually(_ slug: String) {
        newAccountSlug = slug
        slugManuallyEdited = true
    }

    /// Same logic as `cs add` (shared Core — specs/05). Login doesn't
    /// happen here: the user triggers it via the panel's "Log In" button.
    /// A newly created account never has a credential in the Keychain yet — the
    /// status is known in advance, without needing to query the Keychain for it.
    func confirmAddAccount() {
        let wasImporting = importedConfigDir != nil
        do {
            let trimmedSlug = newAccountSlug.trimmingCharacters(in: .whitespaces)
            let account = try AccountsConfig.addAccount(
                name: newAccountName, dir: importedConfigDir, slugOverride: trimmedSlug.isEmpty ? nil : trimmedSlug
            )
            isAddingAccount = false
            newAccountName = ""
            newAccountSlug = ""
            slugManuallyEdited = false
            addAccountError = nil
            importedConfigDir = nil
            // An imported account may already have a real credential —
            // unlike a brand-new one, don't assume "not logged in".
            accountStatuses[account.slug] = AccountDiscovery.status(for: account)
            // A freshly created account can't possibly already be expired
            // (it has no credential yet) — only worth checking for an
            // imported one, which may carry a credential that's already bad.
            if wasImporting {
                ExpiryMonitor.shared.checkAccountImmediately(account)
            }
            refresh()
            selectAccount(account.slug)
        } catch {
            addAccountError = error.localizedForDisplay
        }
    }

    func removeAccount(_ account: RegisteredAccount) {
        do {
            try AccountsConfig.removeAccount(slug: account.slug)
            let wasSelected = selectedAccountSlug == account.slug
            usageStates[account.slug] = nil
            accountStatuses[account.slug] = nil
            refresh()
            // The displayed tab always falls back to the first remaining account
            // (see `selectedAccount` in the View) — without explicitly re-selecting
            // here, its usage is never fetched, because loadUsage only runs
            // from `selectAccount`.
            if wasSelected {
                if let fallback = accounts.first {
                    selectAccount(fallback.slug)
                } else {
                    selectedAccountSlug = nil
                }
            }
        } catch {
            statusMessage = String(
                format: NSLocalizedString("Error removing '%@': %@", bundle: AppResources.bundle, comment: ""),
                account.name, error.localizedForDisplay
            )
        }
    }

    /// Fetches usage on demand via UsageControlClient (invokes `claude`
    /// itself in the control protocol the official extension uses — see
    /// specs/06). Synchronous/blocking by nature (spawns a subprocess),
    /// so it runs off the main thread.
    func loadUsage(slug: String) {
        guard let account = accounts.first(where: { $0.slug == slug }) else { return }
        guard usageStates[slug]?.isLoading != true else { return }
        // Without a credential, get_usage would get stuck waiting for an
        // interactive login flow that never arrives — don't even try.
        guard !needsLogin(slug: slug) else { return }

        usageStates[slug, default: AccountUsageState()].isLoading = true
        let configDir = account.configDir

        Task {
            let result: Result<UsageResponse, Error> = await Task.detached(priority: .userInitiated) {
                Result { try UsageControlClient.fetch(configDir: configDir) }
            }.value

            switch result {
            case .success(let response):
                usageStates[slug] = AccountUsageState(isLoading: false, response: response)
            case .failure(let error):
                let previous = usageStates[slug]
                usageStates[slug] = AccountUsageState(
                    isLoading: false, response: previous?.response, errorMessage: error.localizedForDisplay
                )
            }
        }
    }

    /// Called by StatusBarController every time the popover opens — you can't
    /// rely on the SwiftUI view's `.onAppear` for this: a reopened NSPopover
    /// doesn't necessarily remount the hierarchy (the NSHostingController
    /// stays alive in memory, only the NSView disappears/appears), so without this
    /// the project/session list stayed stuck in the state of the first opening
    /// — a project opened in VS Code after that would only show up by restarting
    /// the whole app.
    func prepareForDisplay() {
        refresh()
        if selectedAccountSlug == nil {
            selectedAccountSlug = accounts.first?.slug
        }
        // Always reloads all accounts when the panel opens — before it only
        // reloaded the selected tab, and only if the user switched tabs
        // (selectAccount), never when simply reopening the popover.
        loadUsageForAllAccounts()
        loadAuthInfoForAllAccounts()
        startPolling()
    }

    func loadUsageForAllAccounts() {
        for account in accounts where !needsLogin(slug: account.slug) {
            loadUsage(slug: account.slug)
        }
    }

    func loadAuthInfoForAllAccounts() {
        for account in accounts where !needsLogin(slug: account.slug) {
            loadAuthInfo(slug: account.slug)
        }
    }

    /// Email/plan don't change on their own — loaded once per account and
    /// cached, never repeated on every usage poll. `refreshStatus`/a successful
    /// login invalidate the cache when it may actually have changed.
    func loadAuthInfo(slug: String) {
        guard authInfoStates[slug] == nil else { return }
        guard let account = accounts.first(where: { $0.slug == slug }) else { return }
        let configDir = account.configDir

        Task {
            let status = await Task.detached(priority: .utility) {
                try? ClaudeAuthStatusClient.fetch(configDir: configDir)
            }.value
            guard let status else { return }
            authInfoStates[slug] = AccountAuthInfo(
                email: status.email, orgName: status.orgName, subscriptionType: status.subscriptionType
            )
        }
    }

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let slug = self.selectedAccountSlug else { return }
                self.loadUsage(slug: slug)
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

/// Custom bar (instead of the native ProgressView) because we need the
/// background track to be the same color as the fill, just translucent — that's
/// how claude.ai shows it (dark blue background under the blue bar, dark
/// orange under the warning bar, etc.), unlike macOS's ProgressView
/// default neutral gray.
private struct UsageProgressBar: View {
    let pct: Double
    let color: Color
    @State private var animatedPct: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                Capsule().fill(color)
                    .frame(width: geo.size.width * CGFloat(min(100, max(0, animatedPct)) / 100))
            }
        }
        .frame(height: 6)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { animatedPct = pct }
        }
        .onChange(of: pct) { newValue in
            withAnimation(.easeOut(duration: 0.6)) { animatedPct = newValue }
        }
    }
}

struct PanelView: View {
    @ObservedObject var viewModel: PanelViewModel
    @StateObject private var loginSession = LoginSessionController()

    private var selectedAccount: RegisteredAccount? {
        guard let slug = viewModel.selectedAccountSlug else { return viewModel.accounts.first }
        return viewModel.accounts.first { $0.slug == slug }
    }

    var body: some View {
        if loginSession.state != .idle {
            LoginSessionView(session: loginSession, onDismiss: dismissLoginSession)
                .padding()
                .frame(width: 320)
                .onChange(of: loginSession.state) { newState in
                    // Success without needing the manual code (common: the
                    // browser callback already confirms on its own) shouldn't
                    // require an extra click or an intermediate screen
                    // — goes straight to the account tab with usage already loading.
                    guard newState == .success else { return }
                    dismissLoginSession()
                }
        } else {
            mainContent
        }
    }

    private func dismissLoginSession() {
        loginSession.cancel()
        viewModel.keepPopoverOpen = false
        if let slug = viewModel.selectedAccountSlug {
            viewModel.refreshStatus(slug: slug)
            viewModel.loadUsage(slug: slug)
            viewModel.loadAuthInfo(slug: slug)
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open Projects (VS Code)", bundle: AppResources.bundle)
                .font(.headline)

            if viewModel.projects.isEmpty {
                Text("No projects open", bundle: AppResources.bundle)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.projects) { project in
                    projectRow(project)
                }
            }

            if !viewModel.terminalSessions.isEmpty {
                Divider()
                Text("Terminal Sessions", bundle: AppResources.bundle)
                    .font(.headline)
                ForEach(viewModel.terminalSessions) { session in
                    terminalSessionRow(session)
                }
            }

            if let statusMessage = viewModel.statusMessage {
                Divider()
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Text("Accounts", bundle: AppResources.bundle)
                    .font(.headline)
                Spacer()
                if !viewModel.isAddingAccount {
                    Menu {
                        Button {
                            viewModel.startAddingAccount()
                        } label: {
                            Text("Add Account…", bundle: AppResources.bundle)
                        }
                        Button {
                            importExistingAccount()
                        } label: {
                            Text("Import Existing Account…", bundle: AppResources.bundle)
                        }
                        if let account = selectedAccount {
                            Button(role: .destructive) {
                                confirmAndRemove(account)
                            } label: {
                                Text(String(
                                    format: NSLocalizedString("Remove \"%@\"", bundle: AppResources.bundle, comment: ""),
                                    account.name
                                ))
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            if viewModel.isAddingAccount {
                addAccountForm
            }

            if viewModel.accounts.isEmpty {
                Text("No accounts registered", bundle: AppResources.bundle)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: accountSelectionBinding) {
                    ForEach(viewModel.accounts, id: \.slug) { account in
                        accountTabLabel(for: account).tag(account.slug)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                usageContent
            }
        }
        .padding()
        .frame(width: 320)
    }

    /// A segmented `Picker`'s items only accept `Text` (not arbitrary views),
    /// so the warning indicator is embedded as an inline symbol via
    /// `Text(Image(systemName:))` concatenation rather than an `HStack`.
    private func accountTabLabel(for account: RegisteredAccount) -> Text {
        guard viewModel.isExpiredLogin(slug: account.slug) else {
            return Text(account.name)
        }
        return Text(Image(systemName: "exclamationmark.triangle.fill")) + Text(" " + account.name)
    }

    /// Lets the user point at a `CLAUDE_CONFIG_DIR` that already exists on
    /// disk (e.g. set up before this app existed) instead of creating a
    /// fresh one — `AccountsConfig.addAccount(dir:)` already supports this,
    /// SharedSessionsDirectory.adopt merges any real sessions it finds there
    /// into the shared directory, same as it does for any other account.
    private func importExistingAccount() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Claude config directory to import", bundle: AppResources.bundle)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        viewModel.keepPopoverOpen = true
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        viewModel.keepPopoverOpen = false
        guard response == .OK, let url = panel.urls.first else { return }
        viewModel.startImportingAccount(dir: url.path)
    }

    private func confirmAndRemove(_ account: RegisteredAccount) {
        // NSAlert is a separate system window — opening it steals the popover's
        // focus, and with .transient that would close the panel on its own before
        // the user even decides (same case as the Keychain prompt during
        // login). keepPopoverOpen holds the panel open until the decision is made.
        viewModel.keepPopoverOpen = true
        let confirmed = ConfirmationAlert.confirmDestructive(
            title: String(
                format: NSLocalizedString("Remove \"%@\"?", bundle: AppResources.bundle, comment: ""),
                account.name
            ),
            message: String(
                format: NSLocalizedString(
                    "This deletes the account's directory (%@) and the credential in the Keychain. "
                        + "It cannot be undone — if you want to use this account again, you'll need to log in from scratch.",
                    bundle: AppResources.bundle,
                    comment: ""
                ),
                account.configDir
            ),
            confirmTitle: String(localized: "Remove", bundle: AppResources.bundle)
        )
        viewModel.keepPopoverOpen = false
        if confirmed {
            viewModel.removeAccount(account)
        }
    }

    private var accountSelectionBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedAccountSlug ?? viewModel.accounts.first?.slug ?? "" },
            set: { viewModel.selectAccount($0) }
        )
    }

    @ViewBuilder
    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let dir = viewModel.importedConfigDir {
                Text(String(
                    format: NSLocalizedString("Importing: %@", bundle: AppResources.bundle, comment: ""), dir
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            TextField(
                text: Binding(get: { viewModel.newAccountName }, set: { viewModel.setAccountName($0) }),
                label: { Text("Account name (e.g.: Client X)", bundle: AppResources.bundle) }
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { viewModel.confirmAddAccount() }

            TextField(
                text: Binding(get: { viewModel.newAccountSlug }, set: { viewModel.setAccountSlugManually($0) }),
                label: { Text("Slug (identifier, e.g.: client-x)", bundle: AppResources.bundle) }
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .onSubmit { viewModel.confirmAddAccount() }

            if let error = viewModel.addAccountError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    viewModel.cancelAddingAccount()
                } label: {
                    Text("Cancel", bundle: AppResources.bundle)
                }
                Spacer()
                Button {
                    viewModel.confirmAddAccount()
                } label: {
                    Text(
                        viewModel.importedConfigDir != nil ? "Import" : "Create",
                        bundle: AppResources.bundle
                    )
                }
                .disabled(viewModel.newAccountName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.15))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var accountIdentityHeader: some View {
        let slug = viewModel.selectedAccountSlug ?? ""
        if !viewModel.needsLogin(slug: slug) {
            VStack(alignment: .leading, spacing: 2) {
                if let info = viewModel.authInfoStates[slug] {
                    HStack(alignment: .firstTextBaseline) {
                        if let email = info.email {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if let plan = info.subscriptionType {
                            Text(plan.capitalized)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                }
                if let expiresAt = viewModel.accountStatuses[slug]?.refreshTokenExpiresAt {
                    Text(String(
                        format: NSLocalizedString("Login expires %@", bundle: AppResources.bundle, comment: ""),
                        expiresAt.formatted(.relative(presentation: .named))
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            if viewModel.authInfoStates[slug] != nil || viewModel.accountStatuses[slug]?.refreshTokenExpiresAt != nil {
                Divider()
            }
        }
    }

    @ViewBuilder
    private var usageContent: some View {
        let slug = viewModel.selectedAccountSlug ?? ""
        let state = viewModel.usageStates[slug]

        accountIdentityHeader

        if viewModel.needsLogin(slug: slug) {
            VStack(alignment: .leading, spacing: 6) {
                if viewModel.isExpiredLogin(slug: slug) {
                    Text("Session expired — log in again to keep using this account.", bundle: AppResources.bundle)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("This account hasn't logged in yet.", bundle: AppResources.bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    if let account = viewModel.accounts.first(where: { $0.slug == slug }) {
                        viewModel.keepPopoverOpen = true
                        loginSession.start(configDir: account.configDir)
                    }
                } label: {
                    Text("Log In", bundle: AppResources.bundle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
        } else if state?.isLoading == true, state?.response == nil {
            ProgressView().controlSize(.small)
        } else if let response = state?.response {
            // .id(slug) forces SwiftUI to recreate (not just update) these
            // bars when switching tabs — resets their animation @State,
            // so the bar always grows from zero again. Between polls of the
            // same account, identity is preserved and the transition animates
            // smoothly from the old value to the new one, not from zero.
            Group {
                usageBar(title: "Session (5h)", window: response.fiveHour, resetStyle: .relative)
                usageBar(title: "Week", window: response.sevenDay, resetStyle: .weekday)
                if let extra = response.extraUsage, extra.isEnabled {
                    extraUsageBar(extra)
                }
            }
            .id(slug)
            if let error = state?.errorMessage {
                Text(String(
                    format: NSLocalizedString("Not updated: %@", bundle: AppResources.bundle, comment: ""),
                    error
                ))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let error = state?.errorMessage {
            VStack(alignment: .leading, spacing: 4) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    viewModel.loadUsage(slug: slug)
                } label: {
                    Text("Try Again", bundle: AppResources.bundle)
                }
                .font(.caption)
            }
        }
    }

    /// Same 3 stages, thresholds, and colors as claude.ai (the VS
    /// Code extension only has 2 — the site is more granular, as the user noticed).
    /// Confirmed by reading the site's JS bundle (chunk shared-8, function `qF`):
    /// `e>=90?"critical":e>=75?"warning":"normal"`, with the classes mapped
    /// to `--cds-role-{accent,warning,danger}-*` → `--cds-{blue-450,
    /// yellow-200,red-450}` in the resolved CSS. "normal" uses the site's blue
    /// (not the system accent) to match the reference screenshot.
    private static let normalColor = Color(red: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255)
    private static let warningColor = Color(red: 0xfa / 255, green: 0xb2 / 255, blue: 0x19 / 255)
    private static let criticalColor = Color(red: 0xd0 / 255, green: 0x3b / 255, blue: 0x3b / 255)

    private func usageColor(for pct: Double) -> Color {
        if pct >= UsageThresholds.critical { return Self.criticalColor }
        if pct >= UsageThresholds.warning { return Self.warningColor }
        return Self.normalColor
    }

    private enum ResetStyle {
        /// "resets in 3h 26min" — short windows (5h session).
        case relative
        /// "resets Mon, 06:00" — long windows (weekly limit).
        case weekday
    }

    private func resetText(_ date: Date, style: ResetStyle) -> String {
        switch style {
        case .relative:
            let seconds = max(0, date.timeIntervalSinceNow)
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            if hours > 0 {
                return String(
                    format: NSLocalizedString("Resets in %dh %dmin", bundle: AppResources.bundle, comment: ""),
                    hours, minutes
                )
            }
            return String(
                format: NSLocalizedString("Resets in %dmin", bundle: AppResources.bundle, comment: ""),
                minutes
            )
        case .weekday:
            let weekday = Self.weekdayName(for: date)
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = "d"
            let day = formatter.string(from: date)
            formatter.dateFormat = "HH:mm"
            let time = formatter.string(from: date)
            return String(
                format: NSLocalizedString("Resets %@ (%@) at %@", bundle: AppResources.bundle, comment: ""),
                weekday, day, time
            )
        }
    }

    /// Own keys instead of `DateFormatter.weekdaySymbols` (which in
    /// Portuguese returns the full form, "segunda-feira") — here we control
    /// the exact wording per language ("segunda" instead).
    private static func weekdayName(for date: Date) -> String {
        let weekday = Calendar.current.component(.weekday, from: date)
        let key = "weekday_short_\(weekday)"
        // NSLocalizedString, not String(localized:) — the key here is built
        // at runtime (not a string interpolation literal the compiler can
        // turn into a format-based lookup), so it needs a plain table lookup.
        return NSLocalizedString(key, bundle: AppResources.bundle, comment: "")
    }

    @ViewBuilder
    private func usageBar(title: LocalizedStringKey, window: UsageWindow?, resetStyle: ResetStyle) -> some View {
        if let window {
            let pct = max(0, min(100, window.utilization ?? 0))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title, bundle: AppResources.bundle).font(.caption)
                    Spacer()
                    Text("\(Int(pct))%").font(.caption).foregroundStyle(.secondary)
                }
                UsageProgressBar(pct: pct, color: usageColor(for: pct))
                if let resetsAt = window.resetsAt {
                    Text(resetText(resetsAt, style: resetStyle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func extraUsageBar(_ extra: ExtraUsage) -> some View {
        let pct = max(0, min(100, extra.utilization ?? 0))
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Extra", bundle: AppResources.bundle).font(.caption)
                Spacer()
                Text("\(Int(pct))%").font(.caption).foregroundStyle(.secondary)
            }
            UsageProgressBar(pct: pct, color: usageColor(for: pct))
            if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                Text(String(
                    format: NSLocalizedString("used %.2f of %.2f", bundle: AppResources.bundle, comment: ""),
                    used, limit
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func projectRow(_ project: ProjectInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                Text(viewModel.accountName(forSlug: project.currentAccountSlug))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(viewModel.accounts, id: \.slug) { account in
                    Button(account.name) {
                        viewModel.switchAccount(project: project, to: account)
                    }
                }
            } label: {
                Text("Switch", bundle: AppResources.bundle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button(role: .destructive) {
                    confirmAndClearHistory(project)
                } label: {
                    Text("Clear Chat History…", bundle: AppResources.bundle)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func confirmAndClearHistory(_ project: ProjectInfo) {
        // Same reasoning as confirmAndRemove: NSAlert steals the popover's
        // focus, keepPopoverOpen holds the panel open until the decision is made.
        viewModel.keepPopoverOpen = true
        let confirmed = ConfirmationAlert.confirmDestructive(
            title: String(
                format: NSLocalizedString("Clear chat history for \"%@\"?", bundle: AppResources.bundle, comment: ""),
                project.name
            ),
            message: NSLocalizedString(
                "This deletes every saved conversation for this project — shared by every account, "
                    + "since chats belong to the project, not to any single account. It cannot be undone.",
                bundle: AppResources.bundle, comment: ""
            ),
            confirmTitle: String(localized: "Clear History", bundle: AppResources.bundle)
        )
        viewModel.keepPopoverOpen = false
        if confirmed {
            viewModel.clearChatHistory(project: project)
        }
    }

    @ViewBuilder
    private func terminalSessionRow(_ session: TerminalSessionInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.cwd)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(session.accountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(viewModel.accounts, id: \.slug) { account in
                    Button(account.name) {
                        viewModel.switchTerminalSessionAccount(session: session, to: account)
                    }
                }
            } label: {
                Text("Switch", bundle: AppResources.bundle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
