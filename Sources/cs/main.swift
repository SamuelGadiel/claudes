import ClaudeSCore
import Foundation

func printUsage() {
    print("""
    Usage:
      cs                                     runs claude with the current project's account (or the default one)
      cs <slug> [args...]                    runs claude with that account, passing along args (e.g.: cs work auth login)
      cs list                                lists registered accounts and expiration status
      cs add --name <name> [--dir <path>] [--slug <slug>] [--default]
      cs remove <slug>                       removes from the registry (doesn't delete the folder)
      cs set <slug>                          sets this project's account (.clauderc + .vscode/settings.json)
      cs default <slug>                      sets the account used when the project has no .clauderc
      cs install-cli                         installs/updates the 'cs' link in a PATH directory
      cs status                              lists open VS Code projects and running terminal sessions, with each one's account

    Legacy (spec 02, still works):
      cs set-account <project> <account>
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

func runList() {
    let file = loadAccountsPrintingMessages()
    if file.accounts.isEmpty {
        print("No accounts registered yet. Use 'cs add --name <name>'.")
        return
    }

    for account in file.accounts {
        let status = AccountDiscovery.status(for: account)
        let defaultMarker = file.defaultAccountSlug == account.slug ? " [default]" : ""
        print("— \(status.name) (\(account.slug))\(defaultMarker) — \(status.configDir)")
        print("   keychain service: \(status.keychainService)")

        if let error = status.error {
            print("   status: \(error)")
        } else {
            if let expiresAt = status.expiresAt {
                print("   access token expires on: \(dateFormatter.string(from: expiresAt)) (renews itself, ok)")
            }
            if let refreshExpiresAt = status.refreshTokenExpiresAt {
                let expired = refreshExpiresAt < Date()
                let marker = expired ? " [NEEDS LOGIN AGAIN]" : ""
                print("   refresh token expires on: \(dateFormatter.string(from: refreshExpiresAt))\(marker)")
            }
            if let subscriptionType = status.subscriptionType {
                print("   plan: \(subscriptionType)")
            }
            if let rateLimitTier = status.rateLimitTier {
                print("   rate limit tier: \(rateLimitTier)")
            }
        }
        print("")
    }
}

func runAdd(args: [String]) {
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
        case "--dir":
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

    guard let name, !name.isEmpty else {
        print("Usage: cs add --name <name> [--dir <path>] [--slug <slug>] [--default]")
        exit(1)
    }

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
        try ClauderFile.write(accountSlug: account.slug, inDir: cwd)
        print("OK: \(cwd)/.clauderc now uses account '\(account.name)' (\(account.slug)).")
    } catch {
        print("Error writing .clauderc: \(error)")
        exit(1)
    }

    do {
        let result = try VSCodeSettings.setConfigDir(projectPath: cwd, configDir: account.configDir)
        for warning in result.warnings {
            print("\n\(warning.englishText)")
        }
    } catch {
        print("\nWarning: could not update .vscode/settings.json: \(error)")
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

func runUsage(args: [String]) {
    guard let identifier = args.first else {
        print("Usage: cs usage <slug>")
        exit(1)
    }

    let file = loadAccountsPrintingMessages()
    guard let account = AccountsConfig.find(identifier: identifier, in: file) else {
        print("Account '\(identifier)' not found.")
        exit(1)
    }

    func formatWindow(_ label: String, _ window: UsageWindow?) {
        guard let window else { return }
        let pct = window.utilization.map { "\(Int($0))%" } ?? "?"
        let resets = window.resetsAt.map { dateFormatter.string(from: $0) } ?? "?"
        print("  \(label): \(pct) (resets \(resets))")
    }

    do {
        let response = try UsageControlClient.fetch(configDir: account.configDir)
        formatWindow("5h", response.fiveHour)
        formatWindow("Week", response.sevenDay)
        formatWindow("Week (Opus)", response.sevenDayOpus)
        if let extra = response.extraUsage, extra.isEnabled {
            let pct = extra.utilization.map { "\(Int($0))%" } ?? "?"
            print("  Extra: \(pct) (used \(extra.usedCredits ?? 0) of \(extra.monthlyLimit ?? 0))")
        }
    } catch {
        print("Error: \(error)")
    }
}

func runInstallCli() {
    do {
        let result = try ShellInstall.install()
        print("OK: \(result.linkPath) -> \(result.targetPath)")
        print("OK: \(result.aliasLinkPath) -> \(result.targetPath) (alias)")
        if result.linkDirInPath {
            print("Done — open a new terminal (or run 'exec $SHELL') and 'cs'/'claudes' will work.")
        } else {
            let dir = (result.linkPath as NSString).deletingLastPathComponent
            print(
                "\nWarning: \(dir) is not in your PATH yet. Add it to your shell profile "
                    + "(~/.zshrc, for example):\n  export PATH=\"\(dir):$PATH\""
            )
        }
    } catch {
        print("Error: \(error)")
        exit(1)
    }
}

func runSetAccount(projectPath: String, accountName: String) {
    let file = loadAccountsPrintingMessages()
    guard let account = AccountsConfig.find(identifier: accountName, in: file) else {
        print("Account '\(accountName)' not found. Registered accounts: \(file.accounts.map(\.name).joined(separator: ", "))")
        exit(1)
    }

    do {
        let result = try VSCodeSettings.setConfigDir(projectPath: projectPath, configDir: account.configDir)
        print("OK: \(result.settingsPath) now uses account '\(account.name)' (\(account.configDir)).")
        for warning in result.warnings {
            print("\n\(warning.englishText)")
        }
    } catch {
        print("Error updating settings.json: \(error)")
        exit(1)
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
    runList()
case "add":
    runAdd(args: rest)
case "remove":
    runRemove(args: rest)
case "set":
    runSet(args: rest)
case "default":
    runDefault(args: rest)
case "install-cli":
    runInstallCli()
case "status":
    runStatus()
case "usage":
    runUsage(args: rest)
case "set-account":
    guard rest.count == 2 else { printUsage(); exit(1) }
    runSetAccount(projectPath: rest[0], accountName: rest[1])
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
