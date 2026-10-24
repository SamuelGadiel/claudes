import ClaudeSCore
import Foundation

func printUsage() {
    print("""
    Usage: cs [command] [options]

    Running claude
      cs
          Runs claude with the current project's account (or the default one).

      cs <slug> [args...]
          Runs claude with that account, passing the rest of the args through.
          Example: cs work auth login

    Accounts
      cs list [--expiry]
          Lists registered accounts and login status, via 'claude auth status'.
          --expiry also reads the Keychain for the exact login expiry date —
          opt-in, since it's the only thing here that can trigger a macOS
          Keychain password prompt.

      cs add --name <name> [--slug <slug>] [--default]
          Registers a brand-new account (fresh, empty CLAUDE_CONFIG_DIR).

      cs import --dir <path> --name <name> [--slug <slug>] [--default]
          Registers an existing CLAUDE_CONFIG_DIR (e.g. set up before this tool).

      cs remove <slug>
          Deletes the registry entry, the CLAUDE_CONFIG_DIR folder, and the
          Keychain credential. Asks for confirmation — cannot be undone.

      cs default <slug>
          Sets the account used when a project has no .clauderc.

    Projects & sessions
      cs set <slug>
          Sets this project's account (.clauderc + .vscode/settings.json).

      cs status
          Lists open VS Code projects and running terminal sessions, with
          each one's account.

    Usage
      cs usage [slug]
          Shows the account's current rate-limit usage (5h/week windows).
          With no slug, shows every registered account, one after another.
    """)
}

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    // Always English, regardless of the system locale — the whole project
    // standardizes on English, not just the source code.
    f.locale = Locale(identifier: "en_US")
    return f
}()

/// Loads accounts.json and prints Core's informational messages
/// (config created, migration) — Core only returns data, the CLI does the printing.
func loadAccountsPrintingMessages() -> AccountsFile {
    let (file, messages) = AccountsConfig.load()
    for message in messages { print(message) }
    if !messages.isEmpty { print("") }
    return file
}

/// Login state and email/org/plan come from `claude auth status` — never
/// the Keychain directly, same as the GUI app's AccountAuthMonitor. The
/// exact refresh-token expiry date is the one thing only the Keychain has;
/// showing it is opt-in (`--expiry`), because reading it directly is the
/// one thing in this CLI that can resurface the macOS Keychain password
/// prompt — see plans/research/keychain-bypass-blocked-by-policy.md.
func runList(showExpiry: Bool) {
    let file = loadAccountsPrintingMessages()
    if file.accounts.isEmpty {
        print("No accounts registered yet. Use 'cs add --name <name>'.")
        return
    }

    for account in file.accounts {
        let defaultMarker = file.defaultAccountSlug == account.slug ? " [default]" : ""
        print("— \(account.name) (\(account.slug))\(defaultMarker) — \(account.configDir)")

        if let authStatus = try? ClaudeAuthStatusClient.fetch(configDir: account.configDir), authStatus.loggedIn {
            if let email = authStatus.email { print("   \(email)") }
            if let plan = authStatus.subscriptionType { print("   plan: \(plan)") }
        } else {
            print("   not logged in — run: cs \(account.slug) auth login")
        }

        if showExpiry {
            let status = AccountDiscovery.status(for: account)
            if let error = status.error {
                print("   keychain: \(error)")
            } else if let refreshExpiresAt = status.refreshTokenExpiresAt {
                let expired = refreshExpiresAt < Date()
                let marker = expired ? " [NEEDS LOGIN AGAIN]" : ""
                print("   refresh token expires on: \(dateFormatter.string(from: refreshExpiresAt))\(marker)")
            }
        }
        print("")
    }
}

/// Shared by `cs add` and `cs import` — same backend (`AccountsConfig.addAccount`),
/// same parsing shape (`--name`/`--slug`/`--default`, plus `--dir` only for
/// import), same as the GUI's "Add Account…"/"Import Existing Account…" split
/// in the "..." menu, which already calls the same Core function either way.
private func parseAccountArgs(_ args: [String], allowDir: Bool) -> (name: String?, dir: String?, slug: String?, markDefault: Bool) {
    var name: String?
    var dir: String?
    var slugOverride: String?
    var markDefault = false

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--name":
            i += 1
            guard i < args.count else { print("missing value for --name"); exit(1) }
            name = args[i]
        case "--dir" where allowDir:
            i += 1
            guard i < args.count else { print("missing value for --dir"); exit(1) }
            dir = args[i]
        case "--slug":
            i += 1
            guard i < args.count else { print("missing value for --slug"); exit(1) }
            slugOverride = args[i]
        case "--default":
            markDefault = true
        default:
            print("Unknown argument: \(args[i])")
            exit(1)
        }
        i += 1
    }
    return (name, dir, slugOverride, markDefault)
}

/// Registers the account (new directory or, when `dir` is set, an existing
/// one) and, for a genuinely new directory, offers to log in right away.
private func registerAccount(name: String, dir: String?, slugOverride: String?, markDefault: Bool) {
    let account: RegisteredAccount
    do {
        account = try AccountsConfig.addAccount(
            name: name, dir: dir, slugOverride: slugOverride, markDefault: markDefault
        )
    } catch {
        print("Error: \(error)")
        exit(1)
    }

    let (file, _) = AccountsConfig.load()
    print("Account '\(account.name)' registered (slug: \(account.slug), dir: \(account.configDir)).")
    if file.defaultAccountSlug == account.slug {
        print("Set as the default account.")
    }

    // An imported directory may already carry a valid credential — unlike a
    // brand-new one, don't assume it needs a login. Same check the GUI app
    // does right after importing.
    if dir != nil, let authStatus = try? ClaudeAuthStatusClient.fetch(configDir: account.configDir), authStatus.loggedIn {
        print("Already logged in" + (authStatus.email.map { " as \($0)" } ?? "") + ".")
        return
    }

    print("\nLog in to this account now? [y/N] ", terminator: "")
    let answer = readLine()?.lowercased() ?? ""
    if answer == "y" || answer == "yes" {
        let status = ClaudeGateway.execute(configDir: account.configDir, arguments: ["auth", "login"])
        if status != 0 {
            print("\n'claude auth login' exited with code \(status).")
        }
    } else {
        print("Ok. When you want to log in: cs \(account.slug) auth login")
    }
}

func runAdd(args: [String]) {
    let parsed = parseAccountArgs(args, allowDir: false)
    guard let name = parsed.name, !name.isEmpty else {
        print("Usage: cs add --name <name> [--slug <slug>] [--default]")
        exit(1)
    }
    registerAccount(name: name, dir: nil, slugOverride: parsed.slug, markDefault: parsed.markDefault)
}

func runImport(args: [String]) {
    let parsed = parseAccountArgs(args, allowDir: true)
    guard let dir = parsed.dir, !dir.isEmpty else {
        print("Usage: cs import --dir <path> --name <name> [--slug <slug>] [--default]")
        exit(1)
    }
    guard let name = parsed.name, !name.isEmpty else {
        print("Usage: cs import --dir <path> --name <name> [--slug <slug>] [--default]")
        exit(1)
    }
    registerAccount(name: name, dir: dir, slugOverride: parsed.slug, markDefault: parsed.markDefault)
}

func runRemove(args: [String]) {
    guard let identifier = args.first else {
        print("Usage: cs remove <slug>")
        exit(1)
    }

    let file = loadAccountsPrintingMessages()
    guard let target = AccountsConfig.find(identifier: identifier, in: file) else {
        print("Account '\(identifier)' not found.")
        exit(1)
    }

    print(
        "This deletes the \(target.configDir) directory and the credential in the Keychain — it cannot be undone. "
            + "Remove '\(target.name)'? [y/N] ", terminator: ""
    )
    let answer = readLine()?.lowercased() ?? ""
    guard answer == "y" || answer == "yes" else {
        print("Cancelled.")
        return
    }

    let wasDefault = file.defaultAccountSlug

    let account: RegisteredAccount
    do {
        account = try AccountsConfig.removeAccount(slug: identifier)
    } catch {
        print("Error: \(error)")
        exit(1)
    }

    let (after, _) = AccountsConfig.load()
    if wasDefault == account.slug, let newDefault = after.defaultAccountSlug {
        print("'\(account.name)' was the default account — promoting '\(newDefault)' in its place.")
    }

    print(
        "Account '\(account.name)' removed — directory \(account.configDir) and the "
            + "Keychain credential deleted."
    )
}

func runSet(args: [String]) {
    guard let identifier = args.first else {
        print("Usage: cs set <slug>")
        exit(1)
    }

    let file = loadAccountsPrintingMessages()
    guard let account = AccountsConfig.find(identifier: identifier, in: file) else {
        print("Account '\(identifier)' not found.")
        exit(1)
    }

    let cwd = FileManager.default.currentDirectoryPath

    do {
        try ClauderFile.write(account: account, inDir: cwd)
        print("OK: \(cwd)/.clauderc now uses account '\(account.name)' (\(account.slug)).")
    } catch {
        print("Error writing .clauderc: \(error)")
        exit(1)
    }
}

func runDefault(args: [String]) {
    guard let identifier = args.first else {
        print("Usage: cs default <slug>")
        exit(1)
    }

    var file = loadAccountsPrintingMessages()
    guard let account = AccountsConfig.find(identifier: identifier, in: file) else {
        print("Account '\(identifier)' not found.")
        exit(1)
    }

    file.defaultAccountSlug = account.slug
    AccountsConfig.save(file)
    print("'\(account.name)' (\(account.slug)) is now the default account.")
}

func runStatus() {
    let file = loadAccountsPrintingMessages()

    func accountLabel(forConfigDir configDir: String?) -> String {
        let target = ((configDir ?? "~/.claude") as NSString).expandingTildeInPath
        if let account = file.accounts.first(where: {
            ($0.configDir as NSString).expandingTildeInPath == target
        }) {
            return "\(account.name) (\(account.slug))"
        }
        return "unregistered account (\(target))"
    }

    let openedWindows = OpenedWindowsReader.read()
    print("Projects open in VS Code:")
    if openedWindows.isEmpty {
        print("   (none)")
    } else {
        for window in openedWindows {
            let slug = ClauderFile.find(startingAt: window.path)?.account
            let label = slug.flatMap { AccountsConfig.find(identifier: $0, in: file) }
                .map { "\($0.name) (\($0.slug))" } ?? "no account set"
            print("   \(window.name) — \(label) — \(window.path)")
        }
    }

    print("\nTerminal sessions (outside editors):")
    let sessions = RunningClaudeSessions.list().filter { !$0.isManagedByEditor }
    if sessions.isEmpty {
        print("   (none)")
    } else {
        for session in sessions {
            let cwd = session.cwd ?? "(unknown cwd)"
            print("   pid \(session.pid) — \(accountLabel(forConfigDir: session.configDirFromEnv)) — \(cwd)")
        }
    }
}

/// `cs usage` with no slug fetches every registered account's usage in
/// parallel — one `claude` subprocess per account, running concurrently
/// instead of one after another, so the wait is ~one account's worth, not
/// N. `usageLines(for:)` only ever computes and returns strings, never
/// prints — printing happens here, strictly after every fetch has finished,
/// all from this one thread. Concurrent `print()` calls from the worker
/// threads would interleave mid-line; this sidesteps that entirely instead
/// of trying to synchronize around it.
func runUsage(args: [String]) {
    let file = loadAccountsPrintingMessages()

    guard let identifier = args.first else {
        guard !file.accounts.isEmpty else {
            print("No accounts registered yet. Use 'cs add --name <name>'.")
            return
        }

        var results = [[String]](repeating: [], count: file.accounts.count)
        let group = DispatchGroup()
        for (index, account) in file.accounts.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                results[index] = usageLines(for: account)
                group.leave()
            }
        }
        group.wait()

        for (index, account) in file.accounts.enumerated() {
            if index > 0 { print("") }
            print("— \(account.name) (\(account.slug))")
            results[index].forEach { print($0) }
        }
        return
    }

    guard let account = AccountsConfig.find(identifier: identifier, in: file) else {
        print("Account '\(identifier)' not found.")
        exit(1)
    }
    usageLines(for: account).forEach { print($0) }
}

/// Safe to call concurrently from multiple threads: each call only touches
/// its own `account`/local state and spawns its own `claude` subprocess via
/// `UsageControlClient`/`ClaudeAuthStatusClient` — no shared mutable state
/// between calls. Never prints.
private func usageLines(for account: RegisteredAccount) -> [String] {
    // Fails fast instead of letting UsageControlClient wait out its own
    // timeout on an account that's obviously not logged in — same guard
    // the GUI app's loadUsage() has.
    guard let authStatus = try? ClaudeAuthStatusClient.fetch(configDir: account.configDir), authStatus.loggedIn else {
        return ["  Not logged in — run: cs \(account.slug) auth login"]
    }

    func formatWindow(_ label: String, _ window: UsageWindow?) -> String? {
        guard let window else { return nil }
        let pct = window.utilization.map { "\(Int($0))%" } ?? "?"
        let resets = window.resetsAt.map { dateFormatter.string(from: $0) } ?? "?"
        return "  \(label): \(pct) (resets \(resets))"
    }

    do {
        let response = try UsageControlClient.fetch(configDir: account.configDir)
        // `claude get_usage` can answer successfully with no rate limit data
        // at all despite a valid login (seen for a Team account) — same
        // case the GUI app shows a "try logging in again" prompt for,
        // instead of silently printing nothing.
        guard response.fiveHour != nil || response.sevenDay != nil else {
            return ["  Usage isn't available right now. Try: cs \(account.slug) auth login"]
        }
        var lines = [
            formatWindow("5h", response.fiveHour), formatWindow("Week", response.sevenDay),
            formatWindow("Week (Opus)", response.sevenDayOpus),
        ].compactMap { $0 }
        if let extra = response.extraUsage, extra.isEnabled {
            let pct = extra.utilization.map { "\(Int($0))%" } ?? "?"
            lines.append("  Extra: \(pct) (used \(extra.usedCredits ?? 0) of \(extra.monthlyLimit ?? 0))")
        }
        return lines
    } catch {
        return ["  Error: \(error)"]
    }
}

// MARK: - Dispatch

let allArgs = Array(CommandLine.arguments.dropFirst())

guard let first = allArgs.first else {
    // `cs` alone: resolves the current project's account and opens interactive claude.
    let file = loadAccountsPrintingMessages()
    let cwd = FileManager.default.currentDirectoryPath
    let account = AccountResolver.resolve(forCwd: cwd, in: file)
    ClaudeGateway.run(configDir: account?.configDir, arguments: [])
}

let rest = Array(allArgs.dropFirst())

switch first {
case "list":
    runList(showExpiry: rest.contains("--expiry"))
case "add":
    runAdd(args: rest)
case "import":
    runImport(args: rest)
case "remove":
    runRemove(args: rest)
case "set":
    runSet(args: rest)
case "default":
    runDefault(args: rest)
case "status":
    runStatus()
case "usage":
    runUsage(args: rest)
case "help", "-h", "--help":
    printUsage()
case "-v", "--version":
    print("cs (claudes) dev")
default:
    // Gateway: treats the first argument as an account slug and passes the
    // rest to the real claude (e.g.: "cs work auth login").
    let file = loadAccountsPrintingMessages()
    guard let account = AccountsConfig.find(identifier: first, in: file) else {
        print("'\(first)' is neither a command nor a registered account. Run 'cs list' or 'cs help'.")
        exit(1)
    }
    ClaudeGateway.run(configDir: account.configDir, arguments: rest)
}
