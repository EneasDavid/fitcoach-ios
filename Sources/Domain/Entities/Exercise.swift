import Foundation

public enum MuscleGroup: String, Codable, Sendable, CaseIterable {
    case chest, back, shoulders, biceps, triceps, forearms
    case quadriceps, hamstrings, glutes, calves, core, fullBody
}

public enum Equipment: String, Codable, Sendable, CaseIterable {
    case barbell, dumbbell, machine, cable, bodyweight, kettlebell, band, cardioMachine, other
}

/// Catalogue entry, usually hydrated from the external exercise database (via our proxy).
public struct Exercise: Identifiable, Codable, Equatable, Sendable {
    public var id: ExerciseID
    /// Identifier in the third-party catalogue (used for cache invalidation / re-hydration).
    public var externalID: String?
    public var name: String
    public var primaryMuscles: [MuscleGroup]
    public var secondaryMuscles: [MuscleGroup]
    public var equipment: Equipment
    public var imageURL: URL?
    public var videoURL: URL?
    public var instructions: [String]
    /// Attribution required by the media's licence (e.g. "Goulart · CC BY-SA 4"). Always shown next to the media.
    public var mediaCredit: String?

    public init(id: ExerciseID,
                externalID: String? = nil,
                name: String,
                primaryMuscles: [MuscleGroup],
                secondaryMuscles: [MuscleGroup] = [],
                equipment: Equipment,
                imageURL: URL? = nil,
                videoURL: URL? = nil,
                instructions: [String] = [],
                mediaCredit: String? = nil) {
        self.id = id
        self.externalID = externalID
        self.name = name
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.imageURL = imageURL
        self.videoURL = videoURL
        self.instructions = instructions
        self.mediaCredit = mediaCredit
    }
}

/// Denormalised snapshot embedded in plans and logs, so history stays readable even if the
/// catalogue entry is renamed or removed.
public struct ExerciseRef: Codable, Equatable, Hashable, Sendable {
    public var id: ExerciseID
    public var name: String

    public init(id: ExerciseID, name: String) {
        self.id = id
        self.name = name
    }

    public init(_ exercise: Exercise) {
        self.init(id: exercise.id, name: exercise.name)
    }
}

public enum SubstitutionReason: String, Codable, Sendable {
    case equipmentBusy, equipmentUnavailable, injury, preference
}

public struct ExerciseSubstitution: Equatable, Sendable {
    public let original: ExerciseID
    public let candidate: Exercise
    /// 0...1, higher is a closer stimulus match.
    public let score: Double
    public let reason: SubstitutionReason

    public init(original: ExerciseID, candidate: Exercise, score: Double, reason: SubstitutionReason) {
        self.original = original
        self.candidate = candidate
        self.score = score
        self.reason = reason
    }
}

/// Local fallback ranking used when the external catalogue returns no (or no offline) recommendations.
/// Scores candidates by muscle overlap, then by equipment relevance to the substitution reason.
public struct SubstitutionRecommender: Sendable {
    public init() {}

    public func rank(original: Exercise,
                     candidates: [Exercise],
                     reason: SubstitutionReason,
                     limit: Int = 5) -> [ExerciseSubstitution] {
        let originalPrimary = Set(original.primaryMuscles)
        let originalSecondary = Set(original.secondaryMuscles)

        let scored: [ExerciseSubstitution] = candidates.compactMap { candidate in
            guard candidate.id != original.id else { return nil }
            let primary = Set(candidate.primaryMuscles)
            guard !primary.isDisjoint(with: originalPrimary) else { return nil }

            let primaryJaccard = Double(primary.intersection(originalPrimary).count)
                / Double(primary.union(originalPrimary).count)
            let secondary = Set(candidate.secondaryMuscles)
            let secondaryOverlap = originalSecondary.isEmpty
                ? 0
                : Double(secondary.intersection(originalSecondary).count) / Double(originalSecondary.count)

            let sameEquipment = candidate.equipment == original.equipment
            let equipmentScore: Double
            switch reason {
            case .equipmentBusy, .equipmentUnavailable: equipmentScore = sameEquipment ? 0 : 1
            case .injury, .preference: equipmentScore = sameEquipment ? 1 : 0.4
            }

            let score = 0.6 * primaryJaccard + 0.1 * secondaryOverlap + 0.3 * equipmentScore
            return ExerciseSubstitution(original: original.id, candidate: candidate, score: score, reason: reason)
        }

        return scored
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.candidate.name < rhs.candidate.name
            }
            .prefix(limit)
            .map { $0 }
    }
}
