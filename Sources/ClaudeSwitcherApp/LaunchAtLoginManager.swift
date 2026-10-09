import ServiceManagement

/// Liga/desliga iniciar o app automaticamente no login do macOS.
///
/// Usa `SMAppService` (ServiceManagement, macOS 13+), a API atual da Apple —
/// a antiga `SMLoginItemSetEnabled` está deprecated. Requer que o processo
/// rode de dentro de um `.app` bundle registrado (associado a um Login Items
/// helper ou ao próprio executável principal do bundle); rodando solto via
/// `swift run`/binário avulso, `register()` falha. Validação real depende do
/// empacotamento do `.app` (ver specs/05-app-status-bar).
enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
