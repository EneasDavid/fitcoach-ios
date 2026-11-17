import Domain
import Foundation
import SwiftUI
import Testing
@testable import PresentationKit

@Suite("Forgot password")
@MainActor
struct PasswordResetTests {
    actor Service: PasswordResetting {
        private(set) var requests: [(String, String)] = []
        private(set) var confirmations: [(String, String, String)] = []
        private var requestError: RegistrationError?
        private var confirmError: RegistrationError?
        nonisolated let demoCode: String?

        init(demoCode: String? = nil) { self.demoCode = demoCode }
        func fail(request: RegistrationError? = nil, confirm: RegistrationError? = nil) { requestError = request; confirmError = confirm }
        func requestReset(cpf: String, email: String) async throws {
            if let requestError { throw requestError }
            requests.append((cpf, email))
        }
        func confirmReset(cpf: String, code: String, newPassword: String) async throws {
            if let confirmError { throw confirmError }
            confirmations.append((cpf, code, newPassword))
        }
    }

    func make(_ service: Service = Service()) -> PasswordResetViewModel { PasswordResetViewModel(service: service) }

    @Test("Step 1 needs a valid CPF and a well-formed e-mail; the screen says the CPF is valid as you type")
    func identify() {
        let model = make()
        #expect(!model.canRequest && !model.cpfIsValid && !model.emailIsValid)
        model.cpf = "529.982.247-25"; #expect(model.cpfIsValid && !model.canRequest)
        model.email = "maria"; #expect(!model.canRequest)
        model.email = "maria@example.com"; #expect(model.canRequest)
        model.cpf = "123.456.789-00"; #expect(!model.canRequest)
    }

    @Test("The notice after asking for a code never says whether the CPF and e-mail matched")
    func noticeDoesNotConfirm() async {
        let service = Service()
        let model = make(service)
        model.cpf = "529.982.247-25"; model.email = "maria@example.com"
        await model.requestTapped()
        #expect(model.step == .code && model.errorMessage == nil)
        let notice = model.notice ?? ""
        #expect(notice.localizedCaseInsensitiveContains("if"))
        #expect(await service.requests.count == 1)
    }

    @Test("Step 2 needs a six-digit code and a matching password of 8+ characters; success ends on 'done' and wipes the secrets")
    func confirm() async {
        let service = Service()
        let model = make(service)
        model.cpf = "529.982.247-25"; model.email = "maria@example.com"
        await model.requestTapped()

        #expect(!model.canConfirm)
        model.code = "12345"; model.newPassword = "longenough"; model.confirmPassword = "longenough"; #expect(!model.canConfirm)
        model.code = "123456"; model.confirmPassword = "different"; #expect(!model.canConfirm)
        model.confirmPassword = "longenough"; #expect(model.canConfirm)
        model.code = "123 456"; #expect(model.canConfirm)                                       // spaces are fine
        model.code = "abcdef"; #expect(!model.canConfirm)
        model.code = "123456"; model.newPassword = "short"; model.confirmPassword = "short"; #expect(!model.canConfirm)
        model.newPassword = "longenough"; model.confirmPassword = "longenough"

        await model.confirmTapped()
        #expect(model.step == .done && model.errorMessage == nil)
        #expect(model.newPassword.isEmpty && model.confirmPassword.isEmpty && model.code.isEmpty)
        let sent = await service.confirmations.first
        #expect(sent?.0 == "529.982.247-25" && sent?.1 == "123456" && sent?.2 == "longenough")
    }

    @Test("Each failure has its own plain message and keeps the student on the step they were on")
    func failures() async {
        let service = Service()
        let model = make(service)
        model.cpf = "529.982.247-25"; model.email = "maria@example.com"
        for error in [RegistrationError.offline, .tooManyAttempts, .notConfigured, .invalidEmail] {
            await service.fail(request: error)
            await model.requestTapped()
            #expect(model.step == .identify && model.errorMessage?.isEmpty == false)
        }
        await service.fail()
        await model.requestTapped()
        model.code = "123456"; model.newPassword = "longenough"; model.confirmPassword = "longenough"
        for error in [RegistrationError.invalidCode, .tooManyAttempts, .weakPassword, .offline] {
            await service.fail(confirm: error)
            await model.confirmTapped()
            #expect(model.step == .code && model.errorMessage?.isEmpty == false)
            #expect(model.newPassword == "longenough")                                           // what was typed is kept for another try
        }
        let messages = Set([RegistrationError.invalidCode, .tooManyAttempts, .weakPassword, .offline].map { PasswordResetViewModel.message(for: $0) })
        #expect(messages.count == 4)
    }

    @Test("Going back clears the code and the new password, and a fresh code can be requested again")
    func backAndResend() async {
        let service = Service()
        let model = make(service)
        model.cpf = "529.982.247-25"; model.email = "maria@example.com"
        await model.requestTapped()
        model.code = "123456"; model.newPassword = "longenough"; model.confirmPassword = "longenough"
        await model.requestTapped()                                                              // "send a new code"
        #expect(await service.requests.count == 2 && model.step == .code)
        model.back()
        #expect(model.step == .identify && model.code.isEmpty && model.newPassword.isEmpty && model.confirmPassword.isEmpty && model.notice == nil)
        model.back()                                                                             // nothing to go back to
        #expect(model.step == .identify)
    }

    @Test("Production shows no code; a demo build shows the tester the code")
    func demoCode() {
        #expect(make(Service()).demoCode == nil)
        #expect(make(Service(demoCode: "123456")).demoCode == "123456")
    }

    @Test("The screens render in every step, and the sign-in screen offers the way in")
    func renders() async {
        let service = Service(demoCode: "123456")
        let model = make(service)
        _ = PasswordResetView(model: model, onBack: {}, onDone: { _ in }).body
        model.cpf = "529.982.247-25"; model.email = "maria@example.com"
        await model.requestTapped()
        _ = PasswordResetView(model: model, onBack: {}, onDone: { _ in }).body
        model.code = "123456"; model.newPassword = "longenough"; model.confirmPassword = "longenough"
        await model.confirmTapped()
        _ = PasswordResetView(model: model, onBack: {}, onDone: { _ in }).body
        let signIn = SignInViewModel(auth: StubAuth(), onSignedIn: { _ in })
        _ = SignInView(model: signIn, onFirstAccess: {}, onForgotPassword: {}, notice: "Password changed.", prefill: "529.982.247-25").body
    }

    struct StubAuth: AuthenticationService {
        func signIn(_ credential: CredentialKind, password: String) async throws -> SignedInUser { throw AuthenticationError.invalidCredentials }
    }
}
