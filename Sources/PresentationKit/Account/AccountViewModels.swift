import Domain
import Foundation
import Observation

/// Sign-in by CPF (student) or CREF (personal trainer). The identifier is classified as the user types, so the screen can say
/// which door it is about to open — and the backend's answer, not the guess, decides the role that is actually used.
@MainActor
@Observable
public final class SignInViewModel {
    public var identifier = ""
    public var password = ""
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let recognizer: any CredentialRecognizing
    @ObservationIgnored private let resolver: any RoleResolving
    @ObservationIgnored private let auth: any AuthenticationService
    @ObservationIgnored private let onSignedIn: @MainActor (SignedInUser) async -> Void

    public init(recognizer: any CredentialRecognizing = BrazilianCredentialRecognizer(),
                resolver: any RoleResolving = CredentialRoleResolver(),
                auth: any AuthenticationService,
                onSignedIn: @escaping @MainActor (SignedInUser) async -> Void) {
        self.recognizer = recognizer
        self.resolver = resolver
        self.auth = auth
        self.onSignedIn = onSignedIn
    }

    public var kind: CredentialKind { recognizer.recognize(identifier) }
    /// What the typed identifier looks like (a hint for the UI only).
    public var detectedRole: UserRole? { resolver.role(for: kind) }
    public var canSubmit: Bool { detectedRole != nil && !password.isEmpty && !isWorking }

    public var detectedLabel: String? {
        switch kind {
        case .cpf: return String(localized: "Student · CPF")
        case .cref: return String(localized: "Personal trainer · CREF")
        case .unknown: return nil
        }
    }

    public func submit() async {
        guard canSubmit else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let user = try await auth.signIn(kind, password: password)
            password = ""
            await onSignedIn(user)                          // the server-verified role is what routes the app
        } catch AuthenticationError.invalidCredentials {
            errorMessage = String(localized: "Wrong CPF/CREF or password.")
        } catch AuthenticationError.notConfigured {
            errorMessage = String(localized: "Sign-in isn't set up in this build.")
        } catch AuthenticationError.offline {
            errorMessage = String(localized: "No connection. Try again.")
        } catch {
            errorMessage = String(localized: "Something went wrong. Please try again.")
        }
    }
}

/// The profile / settings sheet behind the avatar at the top-left of every screen: who you are (name, photo), the data-saver
/// switch, connections, and log out — with a warning if edits haven't synced yet (signing out shreds the local copy).
@MainActor
@Observable
public final class ProfileViewModel {
    public let name: String
    public let role: UserRole
    public private(set) var photo: Data?
    public private(set) var dataSaverEnabled: Bool
    public private(set) var unsyncedChanges = 0
    public var isConfirmingLogout = false
    /// A trainer's CREF as their students see it (`NNNNNN-G/UF`).
    public private(set) var cref: String?
    public private(set) var crefError: String?

    @ObservationIgnored private let pendingChanges: () async -> Int
    @ObservationIgnored private let signOut: () async -> Void
    /// Stores (a processed copy of) the chosen photo and returns what was stored; `nil` removes it.
    @ObservationIgnored private let savePhoto: ((Data?) async -> Data?)?
    @ObservationIgnored private let saveDataSaver: ((Bool) -> Void)?
    /// Stores the trainer's CREF (already normalised; `nil` removes it). Only trainers get one.
    @ObservationIgnored private let saveCREF: ((String?) async -> Bool)?

    public init(name: String, role: UserRole, photo: Data? = nil, dataSaverEnabled: Bool = false, cref: String? = nil,
                pendingChanges: @escaping () async -> Int, signOut: @escaping () async -> Void,
                savePhoto: ((Data?) async -> Data?)? = nil, saveDataSaver: ((Bool) -> Void)? = nil,
                saveCREF: ((String?) async -> Bool)? = nil) {
        self.cref = cref
        self.saveCREF = saveCREF
        self.name = name
        self.role = role
        self.photo = photo
        self.dataSaverEnabled = dataSaverEnabled
        self.pendingChanges = pendingChanges
        self.signOut = signOut
        self.savePhoto = savePhoto
        self.saveDataSaver = saveDataSaver
    }

    public var initials: String { Avatar.initials(for: name) }
    public var roleTitle: String { role == .trainer ? String(localized: "Personal trainer") : String(localized: "Student") }
    public var canChangePhoto: Bool { savePhoto != nil }
    public var hasDataSaver: Bool { saveDataSaver != nil }

    public func setPhoto(_ data: Data?) async {
        guard let savePhoto else { return }
        photo = await savePhoto(data)
    }

    public var canEditCREF: Bool { saveCREF != nil }

    /// Blank removes it; anything else must be a real CREF ("012345-G/AL", also typed as "cref 12345 g/al").
    public func setCREF(_ text: String) async {
        guard let saveCREF else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalised: String?
        if trimmed.isEmpty {
            normalised = nil
        } else if let valid = BrazilianCredentialRecognizer.normalizedCREF(trimmed) {
            normalised = valid
        } else {
            crefError = String(localized: "That CREF doesn't look right. It looks like 012345-G/AL.")
            return
        }
        if await saveCREF(normalised) {
            cref = normalised
            crefError = nil
        } else {
            crefError = String(localized: "Couldn't save the CREF.")
        }
    }

    public func setDataSaver(_ on: Bool) {
        dataSaverEnabled = on
        saveDataSaver?(on)
    }

    public func requestLogout() async {
        unsyncedChanges = await pendingChanges()
        if unsyncedChanges > 0 { isConfirmingLogout = true } else { await signOut() }
    }

    public func confirmLogout() async {
        isConfirmingLogout = false
        await signOut()
    }
}

// MARK: - First access (the student's very first login)

/// The personal registered the student with CPF + name. The student's first login repeats those two (proving they are the person
/// the trainer meant), then fills in the rest: e-mail, age, gender, height, weight and a password.
@MainActor
@Observable
public final class FirstAccessViewModel {
    public enum Step: Equatable, Sendable { case identify, profile }

    public var cpf = ""
    public var fullName = ""
    public var email = ""
    public var ageText = ""
    public var gender: Gender = .preferNotToSay
    public var heightText = ""
    public var weightText = ""
    public var password = ""
    public var confirmPassword = ""

    public private(set) var step: Step = .identify
    public private(set) var trainerName: String?
    public private(set) var isWorking = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let service: any FirstAccessService
    @ObservationIgnored private let onSignedIn: @MainActor (SignedInUser) async -> Void
    @ObservationIgnored private var ticket: ClaimTicket?

    public init(service: any FirstAccessService, onSignedIn: @escaping @MainActor (SignedInUser) async -> Void) {
        self.service = service
        self.onSignedIn = onSignedIn
    }

    public var cpfIsValid: Bool { (try? RegistrationRules.cpf(cpf)) != nil }
    public var canContinue: Bool { cpfIsValid && (try? RegistrationRules.fullName(fullName)) != nil && !isWorking }
    public var age: Int? { Int(ageText.trimmingCharacters(in: .whitespaces)) }
    /// Centimetres. A student who types 1.78 (metres) is understood too.
    public var heightCm: Double? {
        guard let typed = DecimalInput.parse(heightText) else { return nil }
        return typed < 3 ? typed * 100 : typed
    }
    public var weightKg: Double? { DecimalInput.parse(weightText) }
    public var passwordsMatch: Bool { !password.isEmpty && password == confirmPassword }
    public var canSubmit: Bool {
        guard let age, let heightCm, let weightKg else { return false }
        return !email.isEmpty && RegistrationRules.ageRange.contains(age)
            && RegistrationRules.heightRangeCm.contains(heightCm) && RegistrationRules.weightRangeKg.contains(weightKg) && password.count >= RegistrationRules.minimumPasswordLength && passwordsMatch && !isWorking
    }

    public func continueTapped() async {
        guard canContinue else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let claimed = try await service.claim(cpf: cpf, fullName: fullName)
            ticket = claimed
            trainerName = claimed.trainerName
            step = .profile
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    public func back() {
        step = .identify
        ticket = nil
        errorMessage = nil
    }

    public func submit() async {
        guard canSubmit, let ticket, let age, let heightCm, let weightKg else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let user = try await service.complete(ticket, profile: NewStudentProfile(email: email, age: age, gender: gender, heightCm: heightCm, weightKg: weightKg),
                                                  password: password)
            password = ""
            confirmPassword = ""
            await onSignedIn(user)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    static func message(for error: Error) -> String {
        switch error as? RegistrationError {
        case .notFound: return String(localized: "We couldn't find a registration with that CPF and name. Check them with your personal trainer.")
        case .alreadyClaimed: return String(localized: "This registration was already used. Go back and sign in.")
        case .invalidCPF: return String(localized: "That CPF isn't valid.")
        case .invalidName: return String(localized: "Enter your full name, as your personal registered it.")
        case .invalidEmail: return String(localized: "That e-mail doesn't look right.")
        case .invalidAge: return String(localized: "Enter an age between 12 and 100.")
        case .invalidHeight: return String(localized: "Enter your height in centimetres, like 175.")
        case .invalidWeight: return String(localized: "Enter your weight in kilograms, like 70.5.")
        case .weakPassword: return String(localized: "Use a password with at least 8 characters.")
        case .offline: return String(localized: "No connection. Try again.")
        case .notConfigured: return String(localized: "First access isn't set up in this build.")
        case .tooManyAttempts: return String(localized: "Too many attempts. Wait a moment and try again.")
        default: return String(localized: "Something went wrong. Please try again.")
        }
    }
}

public extension Gender {
    var title: String {
        switch self {
        case .female: return String(localized: "Female")
        case .male: return String(localized: "Male")
        case .other: return String(localized: "Other")
        case .preferNotToSay: return String(localized: "Prefer not to say")
        }
    }
}
