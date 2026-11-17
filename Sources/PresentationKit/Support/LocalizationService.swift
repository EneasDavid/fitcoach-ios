import Foundation

/// The one place that turns English training vocabulary into the device's language. Screens never hold hardcoded text:
/// compile-time strings go through the string catalog (`Localizable.xcstrings`), and *data-driven* English — terms that arrive
/// from a trainer, a catalogue or an older record — goes through this service. Injected (DIP) so tests and previews can pin a locale.
public protocol LocalizationProviding: Sendable {
    /// A single term ("Rest", "weight") in the user's language; unknown terms come back unchanged.
    func term(_ english: String) -> String
    /// Free text with every known English training term replaced (whole words only, capitalisation kept).
    func localizeTerms(in text: String) -> String
}

public struct LocalizationService: LocalizationProviding {
    private let bundle: Bundle
    private let languageCode: String
    private let glossaries: [String: [String: String]]

    public init(bundle: Bundle = .main, locale: Locale = .current, glossaries: [String: [String: String]] = TrainingGlossary.all) {
        self.bundle = bundle
        self.languageCode = locale.language.languageCode?.identifier ?? "en"
        self.glossaries = glossaries
    }

    public func term(_ english: String) -> String {
        // 1. The app's own catalogue (exact key) wins.
        let fromCatalogue = bundle.localizedString(forKey: english, value: nil, table: nil)
        if fromCatalogue != english { return fromCatalogue }
        // 2. The glossary of training terms, keeping the caller's capitalisation.
        guard let glossary = glossaries[languageCode], let translated = glossary[english.lowercased()] else { return english }
        return Self.matchCase(of: english, applying: translated)
    }

    public func localizeTerms(in text: String) -> String {
        guard let glossary = glossaries[languageCode] else { return text }
        var result = text
        // Longest terms first, so "rest day" is not eaten by "rest".
        for (english, translated) in glossary.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: english) + "\\b"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let matches = expression.matches(in: result, range: range).reversed()
            for match in matches {
                guard let swiftRange = Range(match.range, in: result) else { continue }
                result.replaceSubrange(swiftRange, with: Self.matchCase(of: String(result[swiftRange]), applying: translated))
            }
        }
        return result
    }

    static func matchCase(of source: String, applying translated: String) -> String {
        if source.count > 1, source == source.uppercased() { return translated.uppercased() }
        if let first = source.first, first.isUppercase { return translated.prefix(1).uppercased() + translated.dropFirst() }
        return translated
    }
}

public enum TrainingGlossary {
    public static let all: [String: [String: String]] = ["pt": portuguese]

    /// English training vocabulary → Brazilian Portuguese (lower-case keys).
    public static let portuguese: [String: String] = [
        "rest day": "dia de descanso", "rest": "descanso", "weight": "carga", "load": "carga", "set": "série", "sets": "séries",
        "rep": "repetição", "reps": "repetições", "completed": "concluído", "complete": "concluir", "workout": "treino",
        "exercise": "exercício", "warm-up": "aquecimento", "warm up": "aquecimento", "cool down": "volta à calma",
        "chest": "peito", "back": "costas", "legs": "pernas", "shoulders": "ombros", "arms": "braços", "abs": "abdômen",
        "barbell": "barra", "dumbbell": "halter", "cable": "cabo", "machine": "máquina", "bodyweight": "peso do corpo",
        "squat": "agachamento", "deadlift": "levantamento terra", "bench press": "supino reto", "pull-up": "barra fixa",
        "deload": "semana de recuperação", "superset": "bi-set", "failure": "falha", "tempo": "cadência",
    ]
}
