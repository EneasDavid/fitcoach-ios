import Foundation

/// What a login identifier looks like. **The kind only decides which sign-in path and which shell to show.** It is never
/// authorisation: the backend must verify the account (and approve trainers), and the Firestore rules ignore any
/// client-supplied role — a student who types something CREF-shaped must not gain a single extra permission.
public enum CredentialKind: Equatable, Sendable {
    /// Brazilian taxpayer id, normalised to 11 digits.
    case cpf(String)
    /// Sports-professional registration, normalised to `NNNNNN-G/UF`.
    case cref(String)
    case unknown

    public var isRecognised: Bool { self != .unknown }
}

public protocol CredentialRecognizing: Sendable {
    func recognize(_ input: String) -> CredentialKind
}

/// Strategy: decides where each kind of credential goes. New credential types (e.g. an e-mail for staff) plug in as new
/// resolvers without touching the sign-in screen.
public protocol RoleResolving: Sendable {
    func role(for kind: CredentialKind) -> UserRole?
}

public struct CredentialRoleResolver: RoleResolving {
    public init() {}

    public func role(for kind: CredentialKind) -> UserRole? {
        switch kind {
        case .cpf: return .student
        case .cref: return .trainer
        case .unknown: return nil
        }
    }
}

public struct BrazilianCredentialRecognizer: CredentialRecognizing {
    public init() {}

    static let federativeUnits: Set<String> = [
        "AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO", "MA", "MT", "MS", "MG",
        "PA", "PB", "PR", "PE", "PI", "RJ", "RN", "RS", "RO", "RR", "SC", "SP", "SE", "TO",
    ]

    public func recognize(_ input: String) -> CredentialKind {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cref = Self.cref(trimmed) { return .cref(cref) }
        if let cpf = Self.cpf(trimmed) { return .cpf(cpf) }
        return .unknown
    }

    /// "012345-G/AL" for anything that is a valid CREF ("cref 12345 g/al" too), or `nil`.
    public static func normalizedCREF(_ input: String) -> String? { cref(input.trimmingCharacters(in: .whitespacesAndNewlines)) }

    /// The 11 digits of a valid CPF, or `nil`.
    public static func normalizedCPF(_ input: String) -> String? { cpf(input.trimmingCharacters(in: .whitespacesAndNewlines)) }

    // MARK: CPF — 11 digits (dots/dash optional) with two valid check digits

    static func cpf(_ text: String) -> String? {
        // Only digits and the usual punctuation: letters or slashes mean it is not a CPF.
        guard text.allSatisfy({ $0.isNumber || ".- ".contains($0) }) else { return nil }
        let digits = text.compactMap(\.wholeNumberValue)
        guard digits.count == 11, Set(digits).count > 1 else { return nil }
        func check(_ count: Int) -> Int {
            let sum = (0..<count).reduce(0) { $0 + digits[$1] * (count + 1 - $1) }
            return (sum * 10 % 11) % 10
        }
        return check(9) == digits[9] && check(10) == digits[10] ? digits.map(String.init).joined() : nil
    }

    /// "529.982.247-25"
    public static func formatted(cpf digits: String) -> String {
        guard digits.count == 11 else { return digits }
        let d = Array(digits)
        return "\(String(d[0..<3])).\(String(d[3..<6])).\(String(d[6..<9]))-\(String(d[9..<11]))"
    }

    // MARK: CREF — "012345-G/AL" (also "CREF 012345-G/AL", "012345 g/al"); G = graduate, P = provisional

    static func cref(_ text: String) -> String? {
        var body = text.uppercased()
        if body.hasPrefix("CREF") { body = String(body.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        // optional regional council number glued to the prefix ("CREF4/SP" style) is not a registration number
        guard let slash = body.lastIndex(of: "/") else { return nil }
        let unit = String(body[body.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
        guard federativeUnits.contains(unit) else { return nil }

        let head = String(body[..<slash]).trimmingCharacters(in: .whitespaces)
        guard let category = head.last, category == "G" || category == "P" else { return nil }
        let number = head.dropLast().trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        guard (4...6).contains(number.count), number.allSatisfy(\.isNumber) else { return nil }
        return "\(String(repeating: "0", count: 6 - number.count))\(number)-\(category)/\(unit)"
    }
}

// MARK: - Authentication port

public struct SignedInUser: Equatable, Sendable {
    public let userID: UserID
    public let role: UserRole
    public let displayName: String
    /// For a trainer who signed in with their CREF: the registration they typed, normalised. The app offers it as their professional details.
    public let cref: String?

    public init(userID: UserID, role: UserRole, displayName: String, cref: String? = nil) {
        self.userID = userID
        self.role = role
        self.displayName = displayName
        self.cref = cref
    }
}

public enum AuthenticationError: Error, Equatable, Sendable {
    case invalidCredentials
    /// This build has no authentication backend wired for the credential type.
    case notConfigured
    case offline
}

public protocol AuthenticationService: Sendable {
    func signIn(_ credential: CredentialKind, password: String) async throws -> SignedInUser
}

/// Puts the dots and the dash in a CPF as it is typed: "71488086427" → "714.880.864-27". Deleting a digit takes the punctuation back off, so
/// backspace never gets stuck behind a "." or a "-".
public enum CPFMask {
    /// For fields that only ever hold a CPF: anything that isn't a digit is dropped, at most 11 digits are kept.
    public static func apply(_ text: String) -> String {
        let digits = Array(text.filter(\.isASCII).filter(\.isNumber).prefix(11))
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index == 3 || index == 6 { result.append(".") }
            if index == 9 { result.append("-") }
            result.append(digit)
        }
        return result
    }

    /// For the sign-in field, which takes a CPF *or* a CREF ("012345-G/AL"). Anything with a letter or a slash is left alone; digits-only input
    /// is masked once it has more digits than a CREF number can have, so typing a CREF is never reshuffled.
    public static func loginIdentifier(_ text: String) -> String {
        guard text.allSatisfy({ $0.isNumber || ".- ".contains($0) }) else { return text }
        return text.filter(\.isNumber).count >= 7 ? apply(text) : text
    }
}

