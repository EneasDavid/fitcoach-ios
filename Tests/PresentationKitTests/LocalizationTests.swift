import Foundation
import Testing
@testable import PresentationKit

@Suite("LocalizationService")
struct LocalizationServiceTests {
    let pt = LocalizationService(bundle: Bundle(for: BundleToken.self), locale: Locale(identifier: "pt-BR"))
    let en = LocalizationService(bundle: Bundle(for: BundleToken.self), locale: Locale(identifier: "en-US"))
    final class BundleToken {}

    @Test("English training terms become Portuguese, keeping the capitalisation")
    func terms() {
        #expect(pt.term("Rest") == "Descanso")
        #expect(pt.term("weight") == "carga")
        #expect(pt.term("SET") == "SÉRIE")
        #expect(pt.term("Completed") == "Concluído")
        #expect(pt.term("Squat") == "Agachamento")
    }

    @Test("Unknown terms and other locales are left alone")
    func passthrough() {
        #expect(pt.term("Spaceship") == "Spaceship")
        #expect(en.term("Rest") == "Rest" && en.localizeTerms(in: "Rest between sets") == "Rest between sets")
    }

    @Test("Free text is translated word by word; longer terms win, whole words only")
    func freeText() {
        #expect(pt.localizeTerms(in: "Rest 90 s between sets") == "Descanso 90 s between séries")
        #expect(pt.localizeTerms(in: "Take a rest day") == "Take a dia de descanso")          // 'rest day' beats 'rest'
        #expect(pt.localizeTerms(in: "Reset the setup") == "Reset the setup")                // no partial-word hits
        #expect(pt.localizeTerms(in: "Completed: 3 sets") == "Concluído: 3 séries")
    }

    @Test("The glossary has no empty entries and lower-case keys")
    func glossaryIsClean() {
        for (key, value) in TrainingGlossary.portuguese {
            #expect(!value.isEmpty && key == key.lowercased())
        }
    }
}

/// Guards the "no hardcoded strings" rule: every user-visible literal in the app and in PresentationKit/Domain must exist in
/// `Localizable.xcstrings` with a Portuguese translation. A new `Text("…")` without a translation fails this test.
@Suite("Localization coverage")
struct LocalizationCoverageTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func catalogue() throws -> [String: String] {
        let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        var result: [String: String] = [:]
        for (key, entry) in strings {
            let unit = ((entry["localizations"] as? [String: Any])?["pt-BR"] as? [String: Any])?["stringUnit"] as? [String: Any]
            if let value = unit?["value"] as? String { result[key] = value }
        }
        return result
    }

    /// Replaces each `\( … )` (with nested parentheses) by U+0000.
    static func placeholders(_ literal: String) -> String {
        var out = "", depth = 0
        var index = literal.startIndex
        while index < literal.endIndex {
            let next = literal.index(after: index)
            if depth == 0, literal[index] == "\\", next < literal.endIndex, literal[next] == "(" {
                depth = 1; out.append("\u{0}"); index = literal.index(after: next); continue
            }
            if depth > 0 {
                if literal[index] == "(" { depth += 1 } else if literal[index] == ")" { depth -= 1 }
            } else {
                out.append(literal[index])
            }
            index = next
        }
        return out
    }

    static func sourceLiterals() throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"(?:String\(localized:|\b(?:Text|Label|Button|Toggle|Picker|TextField|SecureField|ProgressView|ContentUnavailableView|navigationTitle|confirmationDialog|Section|Menu)\()\s*"((?:[^"\\]|\\.)*)""#)
        var found = Set<String>()
        for folder in ["Sources", "App"] {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range(at: 1), in: text) else { continue }
                    let literal = placeholders(String(text[range]))
                    // Pure interpolations ("\(count)") and non-words are not translatable text.
                    if literal.filter(\.isLetter).count >= 2 { found.insert(literal) }
                }
            }
        }
        return found
    }

    static func matches(_ literal: String, in keys: Set<String>) -> Bool {
        // A literal "%" in the source is written "%%" in the catalogue once the string has interpolations (it is a format string then).
        let parts = literal.components(separatedBy: "\u{0}").map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: "%", with: "%{1,2}") }
        let regex = "^" + parts.joined(separator: "(?:%@|%lld|%lf)") + "$"
        return keys.contains { $0.range(of: regex, options: .regularExpression) != nil }
    }

    @Test("Every user-visible string has a Portuguese translation")
    func everyStringIsTranslated() throws {
        let catalogue = try Self.catalogue()
        let literals = try Self.sourceLiterals()
        #expect(literals.count > 150)                                              // the scan really found the app's strings
        let missing = literals.filter { !Self.matches($0, in: Set(catalogue.keys)) }.sorted()
        #expect(missing.isEmpty, "Missing pt-BR translations: \(missing)")
    }

    @Test("No catalogue entry is empty, and placeholders survive translation")
    func catalogueIsSane() throws {
        for (key, value) in try Self.catalogue() {
            #expect(!value.isEmpty, "empty translation for \(key)")
            let count = { (text: String) in ["%@", "%lld", "%lf"].reduce(0) { $0 + text.components(separatedBy: $1).count - 1 } }
            #expect(count(key) == count(value), "placeholder mismatch: \(key) → \(value)")
        }
    }
}
