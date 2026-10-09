import ClaudeSwitcherCore
import Foundation

func printUsage() {
    print("""
    Uso:
      cs                                     roda claude com a conta do projeto atual (ou a default)
      cs <slug> [args...]                    roda claude com essa conta, repassando args (ex: cs trabalho auth login)
      cs list                                lista contas registradas e status de expiração
      cs add --name <nome> [--dir <path>] [--slug <slug>] [--default]
      cs remove <slug>                       remove do registro (não apaga a pasta)
      cs set <slug>                          define a conta deste projeto (.clauderc + .vscode/settings.json)
      cs default <slug>                      define a conta usada quando o projeto não tem .clauderc
      cs install-cli                         instala/atualiza o link 'cs' num diretório do PATH
      cs status                              lista projetos VS Code abertos e sessões de terminal rodando, com a conta de cada um

    Legado (specs 02/04, ainda funcionam):
      cs set-account <projeto> <conta>
      cs sync-sessions <projeto> <origem> <destino>
    """)
}

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

/// Carrega accounts.json e imprime as mensagens informativas do Core
/// (config criada, migração) — o Core só retorna dados, quem imprime é o CLI.
func loadAccountsPrintingMessages() -> AccountsFile {
    let (file, messages) = AccountsConfig.load()
    for message in messages { print(message) }
    if !messages.isEmpty { print("") }
    return file
}

func runList() {
    let file = loadAccountsPrintingMessages()
    if file.accounts.isEmpty {
        print("Nenhuma conta registrada ainda. Use 'cs add --name <nome>'.")
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
                print("   access token expira em: \(dateFormatter.string(from: expiresAt)) (renova sozinho, ok)")
            }
            if let refreshExpiresAt = status.refreshTokenExpiresAt {
                let expired = refreshExpiresAt < Date()
                let marker = expired ? " [PRECISA LOGIN DE NOVO]" : ""
                print("   refresh token expira em: \(dateFormatter.string(from: refreshExpiresAt))\(marker)")
            }
            if let subscriptionType = status.subscriptionType {
                print("   plano: \(subscriptionType)")
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
            guard i < args.count else { print("faltou valor para --name"); exit(1) }
            name = args[i]
        case "--dir":
            i += 1
            guard i < args.count else { print("faltou valor para --dir"); exit(1) }
            dir = args[i]
        case "--slug":
            i += 1
            guard i < args.count else { print("faltou valor para --slug"); exit(1) }
            slugOverride = args[i]
        case "--default":
            markDefault = true
        default:
            print("Argumento desconhecido: \(args[i])")
            exit(1)
        }
        i += 1
    }

    guard let name, !name.isEmpty else {
        print("Uso: cs add --name <nome> [--dir <path>] [--slug <slug>] [--default]")
        exit(1)
    }

    let account: RegisteredAccount
    do {
        account = try AccountsConfig.addAccount(
            name: name, dir: dir, slugOverride: slugOverride, markDefault: markDefault
        )
    } catch {
        print("Erro: \(error)")
        exit(1)
    }

    let (file, _) = AccountsConfig.load()
    print("Conta '\(account.name)' registrada (slug: \(account.slug), dir: \(account.configDir)).")
    if file.defaultAccountSlug == account.slug {
        print("Definida como conta default.")
    }

    print("\nFazer login nessa conta agora? [s/N] ", terminator: "")
    let answer = readLine()?.lowercased() ?? ""
    if answer == "s" || answer == "sim" || answer == "y" || answer == "yes" {
        let status = ClaudeGateway.execute(configDir: account.configDir, arguments: ["auth", "login"])
        if status != 0 {
            print("\n'claude auth login' terminou com código \(status).")
        }
    } else {
        print("Ok. Quando quiser logar: cs \(account.slug) auth login")
    }
}

func runRemove(args: [String]) {
    guard let identifier = args.first else {
        print("Uso: cs remove <slug>")
        exit(1)
    }

    let file = loadAccountsPrintingMessages()
    guard let target = AccountsConfig.find(identifier: identifier, in: file) else {
        print("Conta '\(identifier)' não encontrada.")
        exit(1)
    }

    print(
        "Isso apaga o diretório \(target.configDir) e a credencial no Keychain — não dá pra desfazer. "
            + "Remover '\(target.name)'? [s/N] ", terminator: ""
    )
    let answer = readLine()?.lowercased() ?? ""
    guard answer == "s" || answer == "sim" || answer == "y" || answer == "yes" else {
        print("Cancelado.")
        return
    }

    let wasDefault = file.defaultAccountSlug

    let account: RegisteredAccount
    do {
        account = try AccountsConfig.removeAccount(slug: identifier)
    } catch {
        print("Erro: \(error)")
        exit(1)
    }

    let (after, _) = AccountsConfig.load()
    if wasDefault == account.slug, let newDefault = after.defaultAccountSlug {
        print("'\(account.name)' era a conta default — promovendo '\(newDefault)' no lugar.")
    }

    print(
        "Conta '\(account.name)' removida — diretório \(account.configDir) e credencial do "
            + "Keychain apagados."
    )
}

func runSet(args: [String]) {
    guard let identifier = args.first else {
        print("Uso: cs set <slug>")
        exit(1)
    }

    let file = loadAccountsPrintingMessages()
    guard let account = AccountsConfig.find(identifier: identifier, in: file) else {
        print("Conta '\(identifier)' não encontrada.")
        exit(1)
    }

    let cwd = FileManager.default.currentDirectoryPath

    do {
        try ClauderFile.write(accountSlug: account.slug, inDir: cwd)
        print("OK: \(cwd)/.clauderc agora usa a conta '\(account.name)' (\(account.slug)).")
    } catch {
        print("Erro ao escrever .clauderc: \(error)")
        exit(1)
    }

    do {
        let result = try VSCodeSettings.setConfigDir(projectPath: cwd, configDir: account.configDir)
        for warning in result.warnings {
            print("\n\(warning)")
        }
    } catch {
        print("\nAviso: não consegui atualizar .vscode/settings.json: \(error)")
    }
}

func runDefault(args: [String]) {
    guard let identifier = args.first else {
        print("Uso: cs default <slug>")
        exit(1)
    }

    var file = loadAccountsPrintingMessages()
    guard let account = AccountsConfig.find(identifier: identifier, in: file) else {
        print("Conta '\(identifier)' não encontrada.")
        exit(1)
    }

    file.defaultAccountSlug = account.slug
    AccountsConfig.save(file)
    print("'\(account.name)' (\(account.slug)) agora é a conta default.")
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
        return "conta não registrada (\(target))"
    }

    let openedWindows = OpenedWindowsReader.read()
    print("Projetos abertos no VS Code:")
    if openedWindows.isEmpty {
        print("   (nenhum)")
    } else {
        for window in openedWindows {
            let slug = ClauderFile.find(startingAt: window.path)?.account
            let label = slug.flatMap { AccountsConfig.find(identifier: $0, in: file) }
                .map { "\($0.name) (\($0.slug))" } ?? "sem conta definida"
            print("   \(window.name) — \(label) — \(window.path)")
        }
    }

    print("\nSessões de terminal (fora de editores):")
    let sessions = RunningClaudeSessions.list().filter { !$0.isManagedByEditor }
    if sessions.isEmpty {
        print("   (nenhuma)")
    } else {
        for session in sessions {
            let cwd = session.cwd ?? "(cwd desconhecido)"
            print("   pid \(session.pid) — \(accountLabel(forConfigDir: session.configDirFromEnv)) — \(cwd)")
        }
    }
}

func runUsage(args: [String]) {
    guard let identifier = args.first else {
        print("Uso: cs usage <slug>")
        exit(1)
    }

    let file = loadAccountsPrintingMessages()
    guard let account = AccountsConfig.find(identifier: identifier, in: file) else {
        print("Conta '\(identifier)' não encontrada.")
        exit(1)
    }

    func formatWindow(_ label: String, _ window: UsageWindow?) {
        guard let window else { return }
        let pct = window.utilization.map { "\(Int($0))%" } ?? "?"
        let resets = window.resetsAt.map { dateFormatter.string(from: $0) } ?? "?"
        print("  \(label): \(pct) (reseta \(resets))")
    }

    do {
        let response = try UsageControlClient.fetch(configDir: account.configDir)
        formatWindow("5h", response.fiveHour)
        formatWindow("Semana", response.sevenDay)
        formatWindow("Semana (Opus)", response.sevenDayOpus)
        if let extra = response.extraUsage, extra.isEnabled {
            let pct = extra.utilization.map { "\(Int($0))%" } ?? "?"
            print("  Extra: \(pct) (usado \(extra.usedCredits ?? 0) de \(extra.monthlyLimit ?? 0))")
        }
    } catch {
        print("Erro: \(error)")
    }
}

func runInstallCli() {
    do {
        let result = try ShellInstall.install()
        print("OK: \(result.linkPath) -> \(result.targetPath)")
        if result.linkDirInPath {
            print("Pronto — abra um novo terminal (ou rode 'exec $SHELL') e 'cs' já funciona.")
        } else {
            let dir = (result.linkPath as NSString).deletingLastPathComponent
            print(
                "\nAviso: \(dir) não está no seu PATH ainda. Adicione ao seu shell profile "
                    + "(~/.zshrc, por exemplo):\n  export PATH=\"\(dir):$PATH\""
            )
        }
    } catch {
        print("Erro: \(error)")
        exit(1)
    }
}

func runSetAccount(projectPath: String, accountName: String) {
    let file = loadAccountsPrintingMessages()
    guard let account = AccountsConfig.find(identifier: accountName, in: file) else {
        print("Conta '\(accountName)' não encontrada. Contas registradas: \(file.accounts.map(\.name).joined(separator: ", "))")
        exit(1)
    }

    do {
        let result = try VSCodeSettings.setConfigDir(projectPath: projectPath, configDir: account.configDir)
        print("OK: \(result.settingsPath) agora usa a conta '\(account.name)' (\(account.configDir)).")
        for warning in result.warnings {
            print("\n\(warning)")
        }
    } catch {
        print("Erro ao atualizar settings.json: \(error)")
        exit(1)
    }
}

func runSyncSessions(projectPath: String, fromName: String, toName: String) {
    let file = loadAccountsPrintingMessages()
    guard let fromAccount = AccountsConfig.find(identifier: fromName, in: file) else {
        print("Conta '\(fromName)' não encontrada. Contas registradas: \(file.accounts.map(\.name).joined(separator: ", "))")
        exit(1)
    }
    guard let toAccount = AccountsConfig.find(identifier: toName, in: file) else {
        print("Conta '\(toName)' não encontrada. Contas registradas: \(file.accounts.map(\.name).joined(separator: ", "))")
        exit(1)
    }

    do {
        let result = try SessionSync.sync(projectPath: projectPath, from: fromAccount, to: toAccount)

        if result.copied.isEmpty {
            print("Nada para sincronizar — nenhuma sessão nova em '\(fromAccount.name)' (\(result.sourceDir)).")
        } else {
            print("Copiadas \(result.copied.count) sessão(ões) de '\(fromAccount.name)' para '\(toAccount.name)':")
            for file in result.copied { print("  - \(file)") }
        }

        if !result.skippedExisting.isEmpty {
            print("\nJá existiam em '\(toAccount.name)' e NÃO foram sobrescritas:")
            for file in result.skippedExisting { print("  - \(file)") }
        }
    } catch {
        print("Erro: \(error)")
        exit(1)
    }
}

// MARK: - Dispatch

let allArgs = Array(CommandLine.arguments.dropFirst())

guard let first = allArgs.first else {
    // `cs` sozinho: resolve a conta do projeto atual e abre o claude interativo.
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
case "sync-sessions":
    guard rest.count == 3 else { printUsage(); exit(1) }
    runSyncSessions(projectPath: rest[0], fromName: rest[1], toName: rest[2])
case "help", "-h", "--help":
    printUsage()
case "-v", "--version":
    print("cs (claude-switcher) dev")
default:
    // Gateway: trata o primeiro argumento como slug de conta e repassa o
    // resto para o claude real (ex: "cs trabalho auth login").
    let file = loadAccountsPrintingMessages()
    guard let account = AccountsConfig.find(identifier: first, in: file) else {
        print("'\(first)' não é um comando nem uma conta registrada. Rode 'cs list' ou 'cs help'.")
        exit(1)
    }
    ClaudeGateway.run(configDir: account.configDir, arguments: rest)
}
