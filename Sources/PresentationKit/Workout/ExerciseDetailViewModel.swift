import Domain
import Foundation
import Observation

/// What the exercise screen shows besides the sets: demonstration video, trained muscles, how-to steps and up to
/// three substitutes. Loaded from the catalogue (cache first, so it keeps working offline once seen).
@MainActor
@Observable
public final class ExerciseDetailViewModel {
    public enum State: Equatable, Sendable { case idle, loading, loaded, unavailable }

    /// The most substitutes ever offered.
    public static let maxSubstitutions = 3

    public let plannedRef: ExerciseRef
    public private(set) var shownRef: ExerciseRef
    public private(set) var planned: Exercise?
    /// The exercise being performed right now (the planned one, or the substitute the student picked).
    public private(set) var shown: Exercise?
    public private(set) var substitutions: [ExerciseSubstitution] = []
    public private(set) var state: State = .idle

    @ObservationIgnored private let catalog: (any ExerciseCatalogRepository)?

    public init(planned: ExerciseRef, shown: ExerciseRef? = nil, catalog: (any ExerciseCatalogRepository)?) {
        self.plannedRef = planned
        self.shownRef = shown ?? planned
        self.catalog = catalog
    }

    public var isSubstituted: Bool { shownRef.id != plannedRef.id }
    public var title: String { shown?.name ?? shownRef.name }
    public var primaryMuscles: [MuscleGroup] { shown?.primaryMuscles ?? [] }
    public var secondaryMuscles: [MuscleGroup] { shown?.secondaryMuscles ?? [] }

    public func load() async {
        guard state != .loading else { return }
        guard let catalog else { state = .unavailable; return }
        state = .loading

        planned = try? await catalog.exercise(id: plannedRef.id)
        shown = isSubstituted ? try? await catalog.exercise(id: shownRef.id) : planned
        if let planned {
            let found = (try? await catalog.substitutions(for: planned, reason: .equipmentBusy, limit: Self.maxSubstitutions)) ?? []
            substitutions = Array(found.filter { $0.candidate.id != planned.id }.prefix(Self.maxSubstitutions))
        }
        state = (planned == nil && shown == nil) ? .unavailable : .loaded
    }

    public func retry() async {
        state = .idle
        await load()
    }

    public func select(_ exercise: Exercise) {
        shown = exercise
        shownRef = ExerciseRef(exercise)
    }

    public func revert() {
        shown = planned
        shownRef = plannedRef
    }
}
