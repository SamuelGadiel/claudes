import ClaudeSwitcherCore
import UserNotifications

/// Avisa via notificação nativa quando uma conta expirou ou está prestes a
/// expirar — observa `refreshTokenExpiresAt`, nunca `expiresAt` (o access
/// token expira e renova sozinho o tempo todo, isso é normal; ver
/// specs/01-gerenciamento-contas-storage). Checagem periódica, sem nenhuma
/// chamada de rede — só lê o Keychain, mesmo mecanismo de `cs list`.
@MainActor
final class ExpiryMonitor {
    private var timer: Timer?
    /// Evita notificar repetidamente pela mesma condição a cada checagem —
    /// só dispara de novo se a condição for resolvida e voltar a ocorrer.
    private var notifiedKeys: Set<String> = []

    private let checkInterval: TimeInterval = 300
    private let warningWindow: TimeInterval = 24 * 3600

    func start() {
        // requestAuthorization é assíncrono — agendar notificações antes do
        // callback retornar significa agendar enquanto a permissão ainda
        // está "not determined"; o sistema aceita o agendamento mas depois
        // descarta a notificação quando chega a hora de exibir, porque a
        // permissão só foi concedida DEPOIS. Por isso check()/timer só
        // começam dentro do callback.
        requestAuthorization { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: self.checkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.check() }
            }
            self.check()
        }
    }

    /// UNUserNotificationCenter exige um .app bundle de verdade, assinado
    /// (mesmo ad-hoc) — sem isso, crasha o processo inteiro com
    /// NSInternalInconsistencyException, ou nega silenciosamente sem nunca
    /// mostrar o prompt. Uma notificação é secundária; nunca deveria
    /// derrubar o app. Ver specs/05-app-status-bar para o histórico completo
    /// dessa investigação.
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
                    title: "Sessão expirada: \(account.name)",
                    body: "Faça login de novo: rode 'cs \(account.slug) auth login' no terminal."
                )
            } else {
                notifiedKeys.remove(expiredKey)
                if refreshExpiresAt.timeIntervalSince(now) < warningWindow {
                    notify(
                        key: expiringKey,
                        title: "Sessão expira em breve: \(account.name)",
                        body: "Expira \(refreshExpiresAt.formatted(date: .abbreviated, time: .shortened))."
                    )
                } else {
                    notifiedKeys.remove(expiringKey)
                }
            }
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
