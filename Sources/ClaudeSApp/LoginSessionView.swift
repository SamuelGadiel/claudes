import SwiftUI

/// UI for the embedded login flow — never implements authentication, only
/// reflects the real state of `claude auth login` running behind it and passes
/// the code the user pastes back to that process.
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
                    Text("Starting login…", bundle: AppResources.bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .waitingForCode:
                Text("Log in in the browser that opened", bundle: AppResources.bundle)
                    .font(.headline)
                Text("Then, paste the code the page showed here:", bundle: AppResources.bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(text: $session.codeInput, label: { Text("Code", bundle: AppResources.bundle) })
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.submitCode() }
                HStack {
                    Button {
                        onDismiss()
                    } label: {
                        Text("Cancel", bundle: AppResources.bundle)
                    }
                    Spacer()
                    Button {
                        session.submitCode()
                    } label: {
                        Text("Confirm", bundle: AppResources.bundle)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.codeInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

            case .submitting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Verifying code…", bundle: AppResources.bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .success:
                // Dismissal is immediate (see onChange in PanelView) — it never
                // stays visible long enough to notice, no content needed.
                EmptyView()

            case .failure(let message):
                Text("That didn't work", bundle: AppResources.bundle)
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    onDismiss()
                } label: {
                    Text("Close", bundle: AppResources.bundle)
                }
            }
        }
    }
}
