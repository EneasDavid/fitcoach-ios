import Testing
@testable import Domain

@Suite("Credential recognition (CPF → student, CREF → personal trainer)")
struct CredentialTests {
    let recognizer = BrazilianCredentialRecognizer()

    @Test("Valid CPFs are recognised with or without punctuation, and normalised to digits",
          arguments: ["529.982.247-25", "52998224725", " 529 982 247 25 ", "111.444.777-35"])
    func validCPF(input: String) {
        guard case .cpf(let digits) = recognizer.recognize(input) else { Issue.record("not a CPF: \(input)"); return }
        #expect(digits.count == 11 && digits.allSatisfy(\.isNumber))
    }

    @Test("Wrong check digits, repeated digits, wrong length and stray characters are not CPFs",
          arguments: ["529.982.247-26", "111.111.111-11", "000.000.000-00", "123.456.789-00", "5299822472", "529.982.247-255", "529.982.247-2a", ""])
    func invalidCPF(input: String) {
        #expect(recognizer.recognize(input) == .unknown)
    }

    @Test("CREF registrations are recognised in the usual spellings and normalised",
          arguments: [("012345-G/AL", "012345-G/AL"), ("012345-g/al", "012345-G/AL"), ("CREF 012345-G/AL", "012345-G/AL"),
                      ("12345 P/SP", "012345-P/SP"), ("cref1234-G/RJ", "001234-G/RJ"), ("  987654-G/DF ", "987654-G/DF")])
    func validCREF(input: String, normalised: String) {
        #expect(recognizer.recognize(input) == .cref(normalised))
    }

    @Test("Not a CREF: unknown state, wrong category, too few/many digits, no state",
          arguments: ["012345-G/XX", "012345-X/AL", "123-G/AL", "1234567-G/AL", "012345-G", "012345/AL", "G/AL", "abc"])
    func invalidCREF(input: String) {
        #expect(recognizer.recognize(input) == .unknown)
    }

    @Test("Roles follow the credential kind; unknown routes nowhere")
    func routing() {
        let resolver = CredentialRoleResolver()
        #expect(resolver.role(for: recognizer.recognize("529.982.247-25")) == .student)
        #expect(resolver.role(for: recognizer.recognize("012345-G/AL")) == .trainer)
        #expect(resolver.role(for: recognizer.recognize("hello@example.com")) == nil)
        #expect(CredentialKind.unknown.isRecognised == false && CredentialKind.cpf("1").isRecognised)
    }

    @Test("CPF display formatting")
    func formatting() {
        #expect(BrazilianCredentialRecognizer.formatted(cpf: "52998224725") == "529.982.247-25")
        #expect(BrazilianCredentialRecognizer.formatted(cpf: "123") == "123")
    }
}
