import Foundation

/// Reads a number the way people type it: "70", "70.5" and "70,5" all work (the decimal pad of a Portuguese phone shows a comma).
public enum DecimalInput {
    public static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    /// The inverse, for pre-filling a field: 70 → "70", 70.5 → "70.5" (never a trailing ".0"), using the phone's decimal mark.
    public static func format(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(locale))
    }
}
