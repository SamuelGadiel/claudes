import Cocoa
import Combine
import SwiftUI

/// Clique esquerdo abre um painel customizado (SwiftUI, via NSPopover) —
/// necessário porque um NSMenu nativo não suporta abas nem barras de
/// progresso. Clique direito abre um NSMenu clássico de verdade. Ver
/// plans/specs/05-app-status-bar.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let rightClickMenu = NSMenu()
    /// Criado aqui (não dentro da View) para que o poll de uso possa ser
    /// ligado/desligado junto do ciclo de vida real do popover — ver
    /// togglePopover().
    private let viewModel = PanelViewModel()
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath.circle",
                accessibilityDescription: "Claude Switcher"
            )
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hostingController = NSHostingController(rootView: PanelView(viewModel: viewModel))
        // Sem isso, o popover só recalcula o tamanho na próxima vez que é
        // recriado — se o conteúdo SwiftUI cresce depois de já aberto (ex.:
        // uma mensagem de status aparece), o texto fica cortado até fechar
        // e abrir de novo.
        hostingController.sizingOptions = [.preferredContentSize]
        // .transient fecha o popover ao perder o foco — o comportamento
        // esperado (clicou fora, fecha). Mas durante o fluxo de login
        // (abre o browser, que rouba o foco de propósito) e logo depois
        // dele (relê o Keychain, que pode exibir o prompt nativo de senha —
        // outra janela do sistema que rouba foco) isso fecharia o painel no
        // pior momento. `viewModel.keepPopoverOpen` sinaliza exatamente essa
        // janela de tempo; fora dela, o popover é sempre .transient.
        popover.behavior = .transient
        popover.contentViewController = hostingController

        viewModel.$keepPopoverOpen
            .sink { [weak self] keepOpen in
                self?.popover.behavior = keepOpen ? .applicationDefined : .transient
            }
            .store(in: &cancellables)

        popover.delegate = self
        setUpRightClickMenu()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            statusItem.menu = rightClickMenu
            statusItem.button?.performClick(nil)
            // Remove o menu depois de usado: se deixássemos fixo, o AppKit
            // passaria a tratar TODO clique (incluindo o esquerdo) como
            // abertura do NSMenu, e o popover nunca mais abriria.
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            // popoverDidClose cuida de stopPolling() — cobre tanto esse
            // fechamento manual quanto o automático do .transient ao
            // clicar fora, que não passa por aqui.
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            viewModel.prepareForDisplay()
        }
    }

    private func setUpRightClickMenu() {
        let checkUpdates = NSMenuItem(
            title: "Verificar atualizações", action: #selector(checkForUpdates), keyEquivalent: ""
        )
        let about = NSMenuItem(
            title: "Sobre o Claude Switcher", action: #selector(showAbout), keyEquivalent: ""
        )
        let quit = NSMenuItem(title: "Sair", action: #selector(quit), keyEquivalent: "q")

        for item in [checkUpdates, about, quit] {
            item.target = self
        }

        rightClickMenu.addItem(checkUpdates)
        rightClickMenu.addItem(about)
        rightClickMenu.addItem(.separator())
        rightClickMenu.addItem(quit)
    }

    @objc private func checkForUpdates() {
        // TODO: implementar checagem real de atualização (spec 07, empacotamento).
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusBarController: NSPopoverDelegate {
    /// Fonte única de verdade de que o painel não está mais visível —
    /// dispara tanto no fechamento manual (ícone/performClose) quanto no
    /// automático do .transient (clique fora), que não passa por
    /// togglePopover().
    func popoverDidClose(_ notification: Notification) {
        viewModel.stopPolling()
    }
}
