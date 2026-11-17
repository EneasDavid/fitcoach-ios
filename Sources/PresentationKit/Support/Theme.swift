import Domain
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Colours (follow the system light/dark appearance automatically)

extension Color {
    /// A colour that resolves differently in light and dark appearance — no asset catalogue needed.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #else
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light) })
        #endif
    }
}

/// Design tokens. Everything is semantic, so light/dark (and Increase Contrast) just work.
public enum Theme {
    /// Brand green: deeper in light mode for contrast on white, brighter in dark mode.
    public static let accent = Color(light: Color(red: 0.0, green: 0.60, blue: 0.46), dark: Color(red: 0.25, green: 0.86, blue: 0.64))
    public static let onAccent = Color(light: .white, dark: Color(red: 0.0, green: 0.16, blue: 0.11))
    public static let rest = Color(light: Color(red: 0.25, green: 0.33, blue: 0.95), dark: Color(red: 0.55, green: 0.62, blue: 1.0))
    public static let warning = Color.orange
    public static let success = Color.green

    #if canImport(UIKit)
    public static let background = Color(uiColor: .systemGroupedBackground)
    public static let card = Color(uiColor: .secondarySystemGroupedBackground)
    public static let field = Color(uiColor: .tertiarySystemFill)
    public static let separator = Color(uiColor: .separator)
    #else
    public static let background = Color(nsColor: .windowBackgroundColor)
    public static let card = Color(nsColor: .controlBackgroundColor)
    public static let field = Color.primary.opacity(0.08)
    public static let separator = Color.primary.opacity(0.15)
    #endif

    public static let cornerRadius: CGFloat = 20
}

// MARK: - Building blocks

public extension View {
    /// The standard rounded surface used for every section.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

/// Full-width primary action (e.g. "Start workout", "Complete set").
public struct PrimaryButtonStyle: ButtonStyle {
    private let tint: Color

    public init(tint: Color = Theme.accent) { self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, tint: tint)
    }

    private struct ButtonBody: View {
        let configuration: Configuration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(isEnabled ? Theme.onAccent : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(isEnabled ? tint.opacity(configuration.isPressed ? 0.8 : 1) : Theme.field,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Quieter action that still has a big touch target.
public struct SoftButtonStyle: ButtonStyle {
    private let tint: Color

    public init(tint: Color = Theme.accent) { self.tint = tint }

    public func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, tint: tint)
    }

    private struct ButtonBody: View {
        let configuration: Configuration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(tint.opacity(configuration.isPressed ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// Round −/+ button for steppers.
struct RoundIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .frame(width: 44, height: 44)
            .background(Theme.field.opacity(configuration.isPressed ? 2 : 1), in: Circle())
            .foregroundStyle(.primary)
    }
}

/// Small rounded label, used for muscles, equipment and statuses.
public struct Chip: View {
    private let text: String
    private let systemImage: String?
    private let tint: Color
    private let filled: Bool

    public init(_ text: String, systemImage: String? = nil, tint: Color = .secondary, filled: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.filled = filled
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2.weight(.bold)) }
            Text(verbatim: text).font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(filled ? Theme.onAccent : tint)
        .background(filled ? tint : tint.opacity(0.14), in: Capsule())
    }
}

/// Circular countdown: big digits in the middle, a ring that drains around them.
public struct TimerRing: View {
    private let progress: Double
    private let tint: Color
    private let lineWidth: CGFloat
    private let content: AnyView

    public init<Content: View>(progress: Double, tint: Color, lineWidth: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.progress = progress
        self.tint = tint
        self.lineWidth = lineWidth
        self.content = AnyView(content())
    }

    public var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, 1 - progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
            content
        }
    }
}

// MARK: - Display names (localised)

public extension MuscleGroup {
    var displayName: String {
        switch self {
        case .chest: return String(localized: "Chest")
        case .back: return String(localized: "Back")
        case .shoulders: return String(localized: "Shoulders")
        case .biceps: return String(localized: "Biceps")
        case .triceps: return String(localized: "Triceps")
        case .forearms: return String(localized: "Forearms")
        case .quadriceps: return String(localized: "Quadriceps")
        case .hamstrings: return String(localized: "Hamstrings")
        case .glutes: return String(localized: "Glutes")
        case .calves: return String(localized: "Calves")
        case .core: return String(localized: "Core")
        case .fullBody: return String(localized: "Full body")
        }
    }
}

public extension Equipment {
    var displayName: String {
        switch self {
        case .barbell: return String(localized: "Barbell")
        case .dumbbell: return String(localized: "Dumbbell")
        case .machine: return String(localized: "Machine")
        case .cable: return String(localized: "Cable")
        case .bodyweight: return String(localized: "Bodyweight")
        case .kettlebell: return String(localized: "Kettlebell")
        case .band: return String(localized: "Band")
        case .cardioMachine: return String(localized: "Cardio machine")
        case .other: return String(localized: "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .bodyweight: return "figure.strengthtraining.functional"
        case .cardioMachine: return "figure.indoor.cycle"
        default: return "dumbbell.fill"
        }
    }
}

public enum LoadFormat {
    /// 60 → "60", 62.5 → "62.5" in English and "62,5" in Portuguese — the decimal mark follows the phone's language. Never "60.0",
    /// never a thousands separator (a load is typed back into a field).
    public static func kg(_ value: Double, locale: Locale = .current) -> String {
        ((value * 100).rounded() / 100).formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))
    }
}
