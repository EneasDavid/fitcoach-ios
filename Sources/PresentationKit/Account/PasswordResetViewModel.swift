import Domain
import Foundation
import Observation

/// Forgot password: **CPF + the e-mail registered at first access** → a six-digit code in that e-mail → the code and a new password.
/// (First access is a different door: CPF + the name the trainer registered.)
@MainActor
@Observable
public final class PasswordResetViewModel {
    public enum Step: Equatable, Sendable { case identify, code, done }

    public var cpf = ""
    public var email = ""
    public var code = ""
    public var newPassword = ""
    public var confirmPassword = ""

    public private(set) var step: Step = .identify
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?
    /// Shown on the code step. Deliberately worded so it never confirms that the CPF and e-mail matched anything.
    public private(set) var notice: String?

    @ObservationIgnored private let service: any PasswordResetting

    public init(service: any PasswordResetting) { self.service = service }

    /// Demo builds only: there is no mailbox, so the screen shows the code to the tester.
    public var demoCode: String? { service.demoCode }

    public var cpfIsValid: Bool { (try? RegistrationRules.cpf(cpf)) != nil }
    public var emailIsValid: Bool { (try? RegistrationRules.email(email)) != nil }
    public var canRequest: Bool { cpfIsValid && emailIsValid && !isWorking }

    public var codeIsComplete: Bool { (try? RegistrationRules.resetCode(code)) != nil }
    public var passwordIsStrongEnough: Bool { newPassword.count >= RegistrationRules.minimumPasswordLength }
    public var passwordsMatch: Bool { !newPassword.isEmpty && newPassword == confirmPassword }
    public var canConfirm: Bool { codeIsComplete && passwordIsStrongEnough && passwordsMatch && !isWorking }

    /// Step 1 (and "send me a new code").
    public func requestTapped() async {
        guard canRequest else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await service.requestReset(cpf: cpf, email: email)
            notice = String(localized: "If that CPF and e-mail match a registration, we sent a 6-digit code to the registered e-mail. It works for 15 minutes.")
            step = .code
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Step 2.
    public func confirmTapped() async {
        guard canConfirm else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await service.confirmReset(cpf: cpf, code: code, newPassword: newPassword)
            newPassword = ""
            confirmPassword = ""
            code = ""
            step = .done
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    public func back() {
        guard step == .code else { return }
        step = .identify
        code = ""
        newPassword = ""
        confirmPassword = ""
        errorMessage = nil
        notice = nil
    }

    static func message(for error: Error) -> String {
        switch error as? RegistrationError {
        case .invalidCPF: return String(localized: "That CPF isn't valid.")
        case .invalidEmail: return String(localized: "That e-mail doesn't look right.")
        case .invalidCode: return String(localized: "That code is wrong or has expired. Check it, or ask for a new one.")
        case .weakPassword: return String(localized: "Use a password with at least 8 characters.")
        case .tooManyAttempts: return String(localized: "Too many attempts. Wait a few minutes and try again.")
        case .offline: return String(localized: "No connection. Try again.")
        case .notConfigured: return String(localized: "Password reset isn't set up in this build.")
        default: return String(localized: "Something went wrong. Please try again.")
        }
    }
}
