import Domain
import SwiftUI

public struct PasswordResetView: View {
    private let model: PasswordResetViewModel
    private let onBack: () -> Void
    private let onDone: (_ cpf: String) -> Void

    public init(model: PasswordResetViewModel, onBack: @escaping () -> Void, onDone: @escaping (_ cpf: String) -> Void) {
        self.model = model
        self.onBack = onBack
        self.onDone = onDone
    }

    public var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { model.step == .code ? model.back() : onBack() } label: { Label(String(localized: "Back"), systemImage: "chevron.left") }
                    .accessibilityIdentifier("reset-back")

                Text(String(localized: "Reset password")).font(.largeTitle.bold())

                switch model.step {
                case .identify:
                    Text(String(localized: "Enter your CPF and the e-mail you registered at your first access.")).foregroundStyle(.secondary)
                    AuthTextField(String(localized: "CPF"), prompt: "000.000.000-00", text: $model.cpf, id: "reset-cpf", keyboard: .numbers, mask: CPFMask.apply)
                    if model.cpfIsValid { Label(String(localized: "Valid CPF"), systemImage: "checkmark.circle.fill").font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent) }
                    AuthTextField(String(localized: "Registered e-mail"), prompt: "name@email.com", text: $model.email, id: "reset-email", keyboard: .email)
                    AuthPrimaryButton(String(localized: "Send code"), enabled: model.canRequest, id: "reset-send") { await model.requestTapped() }

                case .code:
                    if let notice = model.notice { Text(verbatim: notice).foregroundStyle(.secondary).accessibilityIdentifier("reset-notice") }
                    if let demo = model.demoCode {
                        // Demo and UI-test builds have no mailbox.
                        Label(String(localized: "Demo mode: the code is \(demo)"), systemImage: "envelope.badge")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.warning)
                            .accessibilityIdentifier("reset-demo-code")
                    }
                    AuthTextField(String(localized: "6-digit code"), prompt: "000000", text: $model.code, id: "reset-code", keyboard: .code)
                    AuthSecureField(String(localized: "New password"), prompt: String(localized: "At least 8 characters"), text: $model.newPassword, id: "reset-password")
                    AuthSecureField(String(localized: "Repeat new password"), prompt: nil, text: $model.confirmPassword, id: "reset-password-2")
                    AuthPrimaryButton(String(localized: "Change password"), enabled: model.canConfirm, id: "reset-confirm") { await model.confirmTapped() }
                    Button(String(localized: "Send a new code")) { Task { await model.requestTapped() } }
                        .font(.subheadline.weight(.semibold))
                        .disabled(!model.canRequest)
                        .accessibilityIdentifier("reset-resend")

                case .done:
                    VStack(alignment: .leading, spacing: 14) {
                        Label(String(localized: "Password changed"), systemImage: "checkmark.circle.fill").font(.title3.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text(String(localized: "Sign in with your new password. Other devices have been signed out.")).foregroundStyle(.secondary)
                        AuthPrimaryButton(String(localized: "Go to sign in"), enabled: true, id: "reset-done") { onDone(model.cpf) }
                    }
                }

                if let message = model.errorMessage {
                    Text(verbatim: message).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("reset-error")
                }
            }
            .padding(24)
            .adaptiveContentWidth(maxWidth: 480)
        }
        .scrollDismissesKeyboard(.interactively)       // the keyboard never hides the button below the fields
        .background(Theme.background)
    }
}
