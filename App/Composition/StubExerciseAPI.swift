import DataKit
import Domain
import Foundation

/// Deterministic, offline catalogue for UI tests (`-UITestStubCatalog`): no network, no media, three fixed
/// substitutes — so XCUITests can assert on the substitution UI without depending on wger.de.
struct StubExerciseAPI: RemoteExerciseAPI {
    private let library: [Exercise] = [
        Exercise(id: "wger-73", name: "Supino reto", primaryMuscles: [.chest], secondaryMuscles: [.shoulders, .triceps], equipment: .barbell,
                 videoURL: URL(string: "https://example.invalid/bench-press.mp4"),
                 instructions: ["Deite no banco com os pés firmes no chão.", "Desça a barra até o peito.", "Empurre até estender os braços."]),
        Exercise(id: "wger-75", name: "Supino com halteres", primaryMuscles: [.chest], secondaryMuscles: [.triceps], equipment: .dumbbell),
        Exercise(id: "wger-538", name: "Supino inclinado com barra", primaryMuscles: [.chest], secondaryMuscles: [.shoulders], equipment: .barbell),
        Exercise(id: "wger-194", name: "Fundos", primaryMuscles: [.chest, .triceps], equipment: .bodyweight),
        Exercise(id: "wger-135", name: "Voador (crucifixo na máquina)", primaryMuscles: [.chest], equipment: .machine),
        Exercise(id: "wger-246", name: "Tríceps testa com barra EZ", primaryMuscles: [.triceps], equipment: .barbell),
    ]

    func exercise(id: ExerciseID) async throws -> Exercise? { library.first { $0.id == id } }

    func search(query: String, limit: Int) async throws -> [Exercise] {
        Array(library.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.prefix(limit))
    }

    func substitutions(for exercise: Exercise, reason: SubstitutionReason, limit: Int) async throws -> [ExerciseSubstitution] {
        SubstitutionRecommender().rank(original: exercise, candidates: library, reason: reason, limit: limit)
    }
}
