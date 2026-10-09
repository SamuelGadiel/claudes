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
    var lastUpdated: Date?
    var errorMessage: String?
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
    /// Enquanto o usuário não edita o slug manualmente, ele acompanha o
    /// nome digitado. Uma vez editado à mão, para de ser sobrescrito.
    private var slugManuallyEdited = false
    /// Lido do Keychain (local, rápido) — usado para saber se vale a pena
    /// tentar buscar uso. Sem isso, uma conta nunca logada faria
    /// UsageControlClient travar esperando um fluxo de login interativo que
    /// nunca chegaria (processo preso até o timeout).
    @Published var accountStatuses: [String: AccountStatus] = [:]
    /// true enquanto o fluxo de login está ativo — nesse período o popover
    /// não deve fechar sozinho (o `claude auth login` abre o browser, que
    /// rouba o foco, e o fim do login relê o Keychain, que pode pedir
    /// senha). Observado pelo StatusBarController para trocar o `behavior`
    /// do NSPopover. Fora desse período, o popover fecha normalmente ao
    /// clicar fora, como qualquer painel desse tipo.
    @Published var keepPopoverOpen = false

    /// Relê o uso da aba selecionada periodicamente enquanto o painel está
    /// aberto — barato (subprocesso local via UsageControlClient, nunca
    /// rede/HTTP), mas não há razão para fazer isso com o popover fechado.
    private let pollInterval: TimeInterval = 30
    private var pollTimer: Timer?

    init() {
        warmUpKeychain()
    }

    /// Lê o status (Keychain) de cada conta registrada assim que o app abre,
    /// antes de qualquer popover estar na tela — uma única leitura por
    /// conta, cacheada em `accountStatuses`. `refresh()` depois nunca relê o
    /// Keychain de uma conta que já está nesse cache, só de uma recém-criada.
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
            }
        }
    }

    /// Relê o Keychain para uma única conta — usado quando sabemos que o
    /// status dela especificamente pode ter mudado (ex: login acabou de
    /// terminar), sem reconsultar todas as outras de novo.
    func refreshStatus(slug: String) {
        guard let account = accounts.first(where: { $0.slug == slug }) else { return }
        accountStatuses[slug] = AccountDiscovery.status(for: account)
    }

    func refresh() {
        let (file, _) = AccountsConfig.load()
        accounts = file.accounts
        defaultSlug = file.defaultAccountSlug

        projects = OpenedWindowsReader.read().map { window in
            let slug = ClauderFile.find(startingAt: window.path)?.account
            return ProjectInfo(path: window.path, name: window.name, currentAccountSlug: slug)
        }

        terminalSessions = RunningClaudeSessions.list()
            .filter { !$0.isManagedByEditor }
            .compactMap { session in
                guard let cwd = session.cwd else { return nil }
                let expandedDefault = ("~/.claude" as NSString).expandingTildeInPath
                let target = ((session.configDirFromEnv ?? expandedDefault) as NSString).expandingTildeInPath
                let label = accounts.first {
                    ($0.configDir as NSString).expandingTildeInPath == target
                }?.name ?? "conta não registrada"
                return TerminalSessionInfo(pid: session.pid, cwd: cwd, accountLabel: label)
            }

        // Só consulta o Keychain para contas ainda não cacheadas (novas) —
        // evita reler credenciais já conhecidas a cada refresh() e, com
        // isso, prompts de autorização repetidos.
        for account in accounts where accountStatuses[account.slug] == nil {
            accountStatuses[account.slug] = AccountDiscovery.status(for: account)
        }
    }

    /// true quando não há credencial legível no Keychain para essa conta —
    /// conta recém-criada e nunca logada, ou revogada por completo.
    func needsLogin(slug: String) -> Bool {
        accountStatuses[slug]?.error != nil
    }

    func accountName(forSlug slug: String?) -> String {
        guard let slug, let account = accounts.first(where: { $0.slug == slug }) else {
            return "sem conta definida"
        }
        return account.name
    }

    /// Troca a conta de um projeto (.clauderc + .vscode/settings.json —
    /// mesmo fluxo de `cs set`). Sincronização de sessão (spec 04) ainda
    /// não está encadeada aqui — ver kanban.
    func switchAccount(project: ProjectInfo, to newAccount: RegisteredAccount) {
        do {
            try ClauderFile.write(accountSlug: newAccount.slug, inDir: project.path)
            let result = try VSCodeSettings.setConfigDir(projectPath: project.path, configDir: newAccount.configDir)
            statusMessage = "\(project.name) agora usa \(newAccount.name)"
            for warning in result.warnings {
                statusMessage? += " — \(warning)"
            }
        } catch {
            statusMessage = "Erro ao trocar \(project.name): \(error)"
        }
        refresh()
    }

    /// Não é possível alterar o ambiente de um processo já em execução —
    /// isso só grava o .clauderc do diretório, valendo na próxima vez que
    /// claude/cs for rodado ali. Ver plans/specs/05-app-status-bar.
    func switchTerminalSessionAccount(session: TerminalSessionInfo, to newAccount: RegisteredAccount) {
        do {
            try ClauderFile.write(accountSlug: newAccount.slug, inDir: session.cwd)
            statusMessage = "\(session.cwd) vai usar \(newAccount.name) na próxima execução (sessão atual, pid \(session.pid), continua com a conta antiga)"
        } catch {
            statusMessage = "Erro ao gravar .clauderc em \(session.cwd): \(error)"
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
        isAddingAccount = true
    }

    func cancelAddingAccount() {
        isAddingAccount = false
        newAccountName = ""
        newAccountSlug = ""
        slugManuallyEdited = false
        addAccountError = nil
    }

    /// Chamado pelo TextField de nome — enquanto o slug não foi editado à
    /// mão, ele é recalculado a partir do nome a cada tecla.
    func setAccountName(_ name: String) {
        newAccountName = name
        if !slugManuallyEdited {
            newAccountSlug = Slug.make(from: name)
        }
    }

    /// Chamado pelo TextField de slug — marca edição manual, para o slug
    /// parar de ser sobrescrito automaticamente pelo nome a partir daqui.
    func setAccountSlugManually(_ slug: String) {
        newAccountSlug = slug
        slugManuallyEdited = true
    }

    /// Mesma lógica de `cs add` (Core compartilhado — specs/05). Login não
    /// acontece aqui: o usuário aciona pelo botão "Fazer login" do painel.
    /// Conta recém-criada nunca tem credencial no Keychain ainda — o status
    /// é conhecido de antemão, sem precisar consultar o Keychain por ela.
    func confirmAddAccount() {
        do {
            let trimmedSlug = newAccountSlug.trimmingCharacters(in: .whitespaces)
            let account = try AccountsConfig.addAccount(
                name: newAccountName, slugOverride: trimmedSlug.isEmpty ? nil : trimmedSlug
            )
            isAddingAccount = false
            newAccountName = ""
            newAccountSlug = ""
            slugManuallyEdited = false
            addAccountError = nil
            accountStatuses[account.slug] = AccountDiscovery.notLoggedInStatus(for: account)
            refresh()
            selectAccount(account.slug)
        } catch {
            addAccountError = "\(error)"
        }
    }

    func removeAccount(_ account: RegisteredAccount) {
        do {
            try AccountsConfig.removeAccount(slug: account.slug)
            let wasSelected = selectedAccountSlug == account.slug
            usageStates[account.slug] = nil
            accountStatuses[account.slug] = nil
            refresh()
            // A aba exibida sempre cai para a primeira conta restante (ver
            // `selectedAccount` na View) — sem re-selecionar explicitamente
            // aqui, o uso dela nunca é buscado, porque loadUsage só roda a
            // partir de `selectAccount`.
            if wasSelected {
                if let fallback = accounts.first {
                    selectAccount(fallback.slug)
                } else {
                    selectedAccountSlug = nil
                }
            }
        } catch {
            statusMessage = "Erro ao remover '\(account.name)': \(error)"
        }
    }

    /// Busca o uso sob demanda via UsageControlClient (invoca o próprio
    /// `claude` no protocolo de controle que a extensão oficial usa — ver
    /// specs/06). Síncrono/bloqueante por natureza (spawna um subprocesso),
    /// por isso roda fora da main thread.
    func loadUsage(slug: String) {
        guard let account = accounts.first(where: { $0.slug == slug }) else { return }
        guard usageStates[slug]?.isLoading != true else { return }
        // Sem credencial, get_usage ficaria preso esperando um fluxo de
        // login interativo que nunca chega — nem tenta.
        guard !needsLogin(slug: slug) else { return }

        usageStates[slug, default: AccountUsageState()].isLoading = true
        let configDir = account.configDir

        Task {
            let result: Result<UsageResponse, Error> = await Task.detached(priority: .userInitiated) {
                Result { try UsageControlClient.fetch(configDir: configDir) }
            }.value

            switch result {
            case .success(let response):
                usageStates[slug] = AccountUsageState(isLoading: false, response: response, lastUpdated: Date())
            case .failure(let error):
                let previous = usageStates[slug]
                usageStates[slug] = AccountUsageState(
                    isLoading: false, response: previous?.response, lastUpdated: previous?.lastUpdated,
                    errorMessage: "\(error)"
                )
            }
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

/// Barra customizada (em vez do ProgressView nativo) porque precisamos da
/// trilha de fundo na mesma cor do preenchimento, só translúcida — é assim
/// que o claude.ai mostra (fundo azul escuro sob a barra azul, laranja
/// escuro sob a barra de warning etc.), diferente do cinza neutro padrão
/// do ProgressView do macOS.
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
                    // Sucesso sem precisar do código manual (comum: o
                    // callback do browser já confirma sozinho) não deveria
                    // exigir nem um clique extra, nem uma tela intermediária
                    // — vai direto para a aba da conta já com o uso carregando.
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
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Projetos abertos (VS Code)")
                .font(.headline)

            if viewModel.projects.isEmpty {
                Text("Nenhum projeto aberto")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.projects) { project in
                    projectRow(project)
                }
            }

            if !viewModel.terminalSessions.isEmpty {
                Divider()
                Text("Sessões de terminal")
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
                Text("Contas")
                    .font(.headline)
                Spacer()
                if !viewModel.isAddingAccount {
                    Menu {
                        Button("Adicionar conta…") { viewModel.startAddingAccount() }
                        if let account = selectedAccount {
                            Button("Remover \"\(account.name)\"", role: .destructive) {
                                confirmAndRemove(account)
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
                Text("Nenhuma conta registrada")
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: accountSelectionBinding) {
                    ForEach(viewModel.accounts, id: \.slug) { account in
                        Text(account.name).tag(account.slug)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                usageContent
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear {
            viewModel.refresh()
            let slug = viewModel.selectedAccountSlug ?? viewModel.accounts.first?.slug
            if let slug {
                viewModel.selectAccount(slug)
            }
            viewModel.startPolling()
        }
        .onDisappear {
            viewModel.stopPolling()
        }
    }

    private func confirmAndRemove(_ account: RegisteredAccount) {
        // NSAlert é uma janela do sistema separada — abri-la rouba o foco
        // do popover, e com .transient isso fecharia o painel sozinho antes
        // mesmo do usuário decidir (mesmo caso do prompt de Keychain no
        // login). keepPopoverOpen segura o painel até a decisão.
        viewModel.keepPopoverOpen = true
        let confirmed = ConfirmationAlert.confirmDestructive(
            title: "Remover \"\(account.name)\"?",
            message: "Isso apaga o diretório da conta (\(account.configDir)) e a credencial no Keychain. "
                + "Não dá pra desfazer — se quiser usar essa conta de novo, vai precisar fazer login do zero.",
            confirmTitle: "Remover"
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
            TextField(
                "Nome da conta (ex.: Cliente X)",
                text: Binding(get: { viewModel.newAccountName }, set: { viewModel.setAccountName($0) })
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit { viewModel.confirmAddAccount() }

            TextField(
                "Slug (identificador, ex.: cliente-x)",
                text: Binding(get: { viewModel.newAccountSlug }, set: { viewModel.setAccountSlugManually($0) })
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
                Button("Cancelar") { viewModel.cancelAddingAccount() }
                Spacer()
                Button("Criar") { viewModel.confirmAddAccount() }
                    .disabled(viewModel.newAccountName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.15))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var usageContent: some View {
        let slug = viewModel.selectedAccountSlug ?? ""
        let state = viewModel.usageStates[slug]

        if viewModel.needsLogin(slug: slug) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Essa conta ainda não fez login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    if let account = viewModel.accounts.first(where: { $0.slug == slug }) {
                        viewModel.keepPopoverOpen = true
                        loginSession.start(configDir: account.configDir)
                    }
                } label: {
                    Text("Fazer login")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
            }
        } else if state?.isLoading == true, state?.response == nil {
            ProgressView().controlSize(.small)
        } else if let response = state?.response {
            // .id(slug) força o SwiftUI a recriar (não só atualizar) essas
            // barras ao trocar de aba — reseta o @State de animação delas,
            // então a barra sempre cresce do zero de novo. Entre polls da
            // mesma conta, a identity é preservada e a transição anima
            // suavemente do valor antigo pro novo, não do zero.
            Group {
                usageBar(title: "Sessão (5h)", window: response.fiveHour, resetStyle: .relative)
                usageBar(title: "Semana", window: response.sevenDay, resetStyle: .weekday)
                if let extra = response.extraUsage, extra.isEnabled {
                    extraUsageBar(extra)
                }
            }
            .id(slug)
            if let error = state?.errorMessage {
                Text("Não atualizado: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let lastUpdated = state?.lastUpdated {
                Text("atualizado \(lastUpdated.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if let error = state?.errorMessage {
            VStack(alignment: .leading, spacing: 4) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Tentar novamente") {
                    viewModel.loadUsage(slug: slug)
                }
                .font(.caption)
            }
        }
    }

    /// Mesmos 3 estágios, thresholds e cores do claude.ai (a extensão do VS
    /// Code só tem 2 — site é mais granular, como o usuário notou).
    /// Confirmado lendo o bundle JS do site (chunk shared-8, função `qF`):
    /// `e>=90?"critical":e>=75?"warning":"normal"`, com as classes mapeadas
    /// para `--cds-role-{accent,warning,danger}-*` → `--cds-{blue-450,
    /// yellow-200,red-450}` no CSS resolvido. "normal" usa o azul do site
    /// (não o accent do sistema) para bater com o print de referência.
    private static let warningThreshold: Double = 75
    private static let criticalThreshold: Double = 90
    private static let normalColor = Color(red: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255)
    private static let warningColor = Color(red: 0xfa / 255, green: 0xb2 / 255, blue: 0x19 / 255)
    private static let criticalColor = Color(red: 0xd0 / 255, green: 0x3b / 255, blue: 0x3b / 255)

    private func usageColor(for pct: Double) -> Color {
        if pct >= Self.criticalThreshold { return Self.criticalColor }
        if pct >= Self.warningThreshold { return Self.warningColor }
        return Self.normalColor
    }

    private enum ResetStyle {
        /// "reinicia em 3h 26min" — janelas curtas (sessão de 5h).
        case relative
        /// "reinicia seg., 06:00" — janelas longas (limite semanal).
        case weekday
    }

    private func resetText(_ date: Date, style: ResetStyle) -> String {
        switch style {
        case .relative:
            let seconds = max(0, date.timeIntervalSinceNow)
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            if hours > 0 {
                return "Reinicia em \(hours)h \(minutes)min"
            }
            return "Reinicia em \(minutes)min"
        case .weekday:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "pt_BR")
            // "EEEE" em pt_BR dá "segunda-feira" — tira o "-feira" para bater
            // com o formato pedido ("segunda", não "segunda-feira").
            let weekday = formatter.weekdaySymbols[Calendar.current.component(.weekday, from: date) - 1]
                .replacingOccurrences(of: "-feira", with: "")
            formatter.dateFormat = "d"
            let day = formatter.string(from: date)
            formatter.dateFormat = "HH:mm"
            let time = formatter.string(from: date)
            return "Reinicia \(weekday) (\(day)) às \(time)"
        }
    }

    @ViewBuilder
    private func usageBar(title: String, window: UsageWindow?, resetStyle: ResetStyle) -> some View {
        if let window {
            let pct = max(0, min(100, window.utilization ?? 0))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.caption)
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
                Text("Extra").font(.caption)
                Spacer()
                Text("\(Int(pct))%").font(.caption).foregroundStyle(.secondary)
            }
            UsageProgressBar(pct: pct, color: usageColor(for: pct))
            if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                Text("usado \(used, specifier: "%.2f") de \(limit, specifier: "%.2f")")
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
            Menu("Trocar") {
                ForEach(viewModel.accounts, id: \.slug) { account in
                    Button(account.name) {
                        viewModel.switchAccount(project: project, to: account)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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
            Menu("Trocar") {
                ForEach(viewModel.accounts, id: \.slug) { account in
                    Button(account.name) {
                        viewModel.switchTerminalSessionAccount(session: session, to: account)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
