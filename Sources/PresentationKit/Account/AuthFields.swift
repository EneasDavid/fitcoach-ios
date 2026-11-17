import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The form pieces the sign-in screens share (first access, forgot password): a caption that stays visible while typing — a placeholder
/// vanishes the moment you type, leaving a bare "22" or "Prefer not to say" — over a rounded field.
enum AuthKeyboard { case numbers, decimal, name, email, code }

struct LabelledField<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AuthTextField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let id: String
    let keyboard: AuthKeyboard
    /// Rewrites what was typed (the CPF's dots and dash). Applied after each change, the same way the sign-in field does it.
    let mask: ((String) -> String)?

    init(_ title: String, prompt: String, text: Binding<String>, id: String, keyboard: AuthKeyboard, mask: ((String) -> String)? = nil) {
        self.title = title
        self.prompt = prompt
        self._text = text
        self.id = id
        self.keyboard = keyboard
        self.mask = mask
    }

    var body: some View {
        LabelledField(title) {
            TextField("", text: $text, prompt: Text(verbatim: prompt))
                .padding(14).background(Theme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                #if os(iOS)
                .keyboardType(Self.keyboardType(keyboard))
                .textInputAutocapitalization(keyboard == .name ? .words : .never)
                .autocorrectionDisabled()
                .textContentType(keyboard == .code ? .oneTimeCode : nil)
                #endif
                .accessibilityIdentifier(id)
                .onChange(of: text) { _, new in
                    if let mask { let masked = mask(new); if masked != new { text = masked } }
                }
        }
    }

    #if os(iOS)
    private static func keyboardType(_ keyboard: AuthKeyboard) -> UIKeyboardType {
        switch keyboard {
        case .numbers: return .numbersAndPunctuation
        case .decimal: return .decimalPad
        case .code: return .numberPad
        case .email: return .emailAddress
        case .name: return .default
        }
    }
    #endif
}

struct AuthSecureField: View {
    let title: String
    let prompt: String?
    @Binding var text: String
    let id: String

    init(_ title: String, prompt: String?, text: Binding<String>, id: String) {
        self.title = title
        self.prompt = prompt
        self._text = text
        self.id = id
    }

    var body: some View {
        LabelledField(title) {
            SecureField("", text: $text, prompt: prompt.map { Text(verbatim: $0) })
                .padding(14).background(Theme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityIdentifier(id)
        }
    }
}

struct AuthPrimaryButton: View {
    let title: String
    let enabled: Bool
    let id: String
    let action: () async -> Void

    init(_ title: String, enabled: Bool, id: String, action: @escaping () async -> Void) {
        self.title = title
        self.enabled = enabled
        self.id = id
        self.action = action
    }

    var body: some View {
        Button(title) { Task { await action() } }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!enabled)
            .accessibilityIdentifier(id)
    }
}
