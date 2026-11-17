import Domain
import Foundation

// One-line descriptions shared by the workout overview, the "today" preview and the view models,
// so the same block never reads differently in two places.

public extension ResistanceBlock {
    /// "3 × 8–12 reps · 40 kg"
    var summaryLine: String {
        guard let low = sets.map(\.repsMin).min(), let high = sets.map(\.repsMax).max() else { return "" }
        let reps = low == high ? "\(low)" : "\(low)–\(high)"
        var text = String(localized: "\(sets.count) × \(reps) reps")
        let targets = Set(sets.compactMap(\.targetLoadKg))
        if targets.count == 1, let load = targets.first { text += " · \(LoadFormat.kg(load)) kg" }
        return text
    }
}

public extension HIITBlock {
    var summaryLine: String {
        String(localized: "\(rounds) rounds · \(workSeconds) s work / \(restSeconds) s rest")
    }
}

public extension CardioBlock {
    var summaryLine: String {
        var parts = [String(localized: "\(targetDurationSeconds / 60) min")]
        if let zone = targetZone { parts.append(String(localized: "Zone \(zone)")) }
        return parts.joined(separator: " · ")
    }
}

public extension WorkoutBlock {
    var previewTitle: String {
        switch self {
        case .resistance(let block): return block.exercise.name
        case .hiit(let block): return block.title
        case .cardio(let block): return block.modality.displayName
        case .unsupported: return String(localized: "Unsupported exercise block")
        }
    }

    var previewSummary: String {
        switch self {
        case .resistance(let block): return block.summaryLine
        case .hiit(let block): return block.summaryLine
        case .cardio(let block): return block.summaryLine
        case .unsupported: return String(localized: "Update the app to see this block")
        }
    }

    var previewIcon: String {
        switch self {
        case .resistance: return "dumbbell.fill"
        case .hiit: return "bolt.heart.fill"
        case .cardio(let block): return block.modality.systemImage
        case .unsupported: return "exclamationmark.triangle.fill"
        }
    }
}

public extension WorkoutTemplate {
    /// Rough duration for the "today" card: ~40 s of work per set plus the prescribed rest; HIIT and cardio as written.
    var estimatedMinutes: Int {
        let seconds = blocks.reduce(0) { total, block in
            switch block {
            case .resistance(let b): return total + b.sets.count * (40 + b.restSeconds)
            case .hiit(let b): return total + b.totalSeconds
            case .cardio(let b): return total + b.targetDurationSeconds
            case .unsupported: return total
            }
        }
        return max(5, Int((Double(seconds) / 300).rounded()) * 5)   // nearest 5 minutes
    }
}
