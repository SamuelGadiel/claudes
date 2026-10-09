import SwiftUI

/// UI do fluxo de login embutido — nunca implementa autenticação, só
/// reflete o estado real de `claude auth login` rodando por trás e repassa
/// o código que o usuário cola de volta para esse processo.
struct LoginSessionView: View {
    @ObservedObject var session: LoginSessionController
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch session.state {
            case .idle:
                EmptyView()

            case .starting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Iniciando login…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .waitingForCode:
                Text("Faça login no navegador que abriu")
                    .font(.headline)
                Text("Depois, cole aqui o código que a página mostrou:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Código", text: $session.codeInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.submitCode() }
                HStack {
                    Button("Cancelar") { onDismiss() }
                    Spacer()
                    Button("Confirmar") { session.submitCode() }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.codeInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

            case .submitting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verificando código…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .success:
                // Fechamento é imediato (ver onChange em PanelView) — nunca
                // fica visível por tempo perceptível, não precisa de conteúdo.
                EmptyView()

            case .failure(let message):
                Text("Não deu certo")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Fechar") { onDismiss() }
            }
        }
    }
}
