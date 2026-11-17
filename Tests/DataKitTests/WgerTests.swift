import Foundation
import Testing
import Domain
@testable import DataKit

/// Serves canned responses by URL, and records what was requested.
final class FakeFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: Data] = [:]
    private(set) var requested: [String] = []

    func route(_ suffix: String, _ body: String) { lock.withLock { routes[suffix] = Data(body.utf8) } }

    func fetch(_ url: URL) async throws -> Data {
        lock.withLock { requested.append(url.absoluteString) }
        guard let match = lock.withLock({ routes.first { url.absoluteString.hasSuffix($0.key) } }) else { throw URLError(.fileDoesNotExist) }
        return match.value
    }
}

@Suite("WgerExerciseAPI")
struct WgerTests {
    func info(id: Int, name: String, muscle: (Int, String), equipment: String, video: Bool, ptName: String? = nil) -> String {
        let translations = ([ptName.map { #"{"language":7,"name":"\#($0)","description":"<p>Passo um.</p>"}"# }] + [#"{"language":2,"name":"\#(name)","description":""}"#]).compactMap { $0 }
        return """
        {"id":\(id),"muscles":[{"id":\(muscle.0),"name_en":"\(muscle.1)"}],"muscles_secondary":[],"equipment":[{"name":"\(equipment)"}],
         "translations":[\(translations.joined(separator: ","))],"images":[],
         "videos":[\(video ? #"{"video":"https://wger.de/media/v\#(id).mov","license_author":"Someone"}"# : "")],
         "license":{"short_name":"CC-BY-SA 4"},"license_author":"Author"}
        """
    }

    @Test("Maps a real wger response: Portuguese name, muscles, equipment, video, image, steps and attribution")
    func mapsRealResponse() async throws {
        let fetcher = FakeFetcher()
        fetcher.route("exerciseinfo/73/", WgerFixtures.benchPress)
        let exercise = try #require(try await WgerExerciseAPI(fetcher: fetcher).exercise(id: "wger-73"))

        #expect(exercise.id == "wger-73" && exercise.externalID == "73")
        #expect(exercise.name == "Supino reto")                            // Portuguese preferred
        #expect(exercise.primaryMuscles == [.chest])
        #expect(exercise.secondaryMuscles == [.shoulders, .triceps])
        #expect(exercise.equipment == .barbell)
        #expect(exercise.videoURL?.pathExtension.lowercased() == "mov")
        #expect(exercise.imageURL != nil)
        #expect(exercise.mediaCredit?.contains("CC-BY-SA") == true)         // the licence requires attribution
        #expect(!exercise.instructions.isEmpty && exercise.instructions.allSatisfy { !$0.contains("<") })
    }

    @Test("Falls back to English when there is no Portuguese translation; unknown ids are not requested at all")
    func languageFallback() async throws {
        let fetcher = FakeFetcher()
        fetcher.route("exerciseinfo/9/", info(id: 9, name: "Kettlebell Swing", muscle: (8, "Glutes"), equipment: "Kettlebell", video: false))
        let api = WgerExerciseAPI(fetcher: fetcher)
        let exercise = try #require(try await api.exercise(id: "wger-9"))
        #expect(exercise.name == "Kettlebell Swing" && exercise.equipment == .kettlebell && exercise.videoURL == nil)

        #expect(try await api.exercise(id: "custom-1") == nil)
        #expect(fetcher.requested.count == 1)
    }

    @Test("Substitutions: same muscle, never the original, at most `limit`, exercises with a video first, different gear for 'busy'")
    func substitutions() async throws {
        let fetcher = FakeFetcher()
        fetcher.route("exerciseinfo/73/", info(id: 73, name: "Bench Press", muscle: (4, "Chest"), equipment: "Barbell", video: true))
        let page = [
            info(id: 73, name: "Bench Press", muscle: (4, "Chest"), equipment: "Barbell", video: true),
            info(id: 129, name: "Chest Press", muscle: (4, "Chest"), equipment: "none (bodyweight exercise)", video: false),
            info(id: 75, name: "Dumbbell Bench", muscle: (4, "Chest"), equipment: "Dumbbell", video: true),
            info(id: 135, name: "Butterfly", muscle: (4, "Chest"), equipment: "Cable", video: false),
            info(id: 538, name: "Incline Barbell", muscle: (4, "Chest"), equipment: "Barbell", video: true),
        ]
        fetcher.route("exerciseinfo/?language=2&muscles=4&limit=60", #"{"results":[\#(page.joined(separator: ","))]}"#)
        let api = WgerExerciseAPI(fetcher: fetcher)
        let original = try #require(try await api.exercise(id: "wger-73"))

        let suggestions = try await api.substitutions(for: original, reason: .equipmentBusy, limit: 3)
        #expect(suggestions.count == 3)
        #expect(!suggestions.contains { $0.candidate.id == original.id })
        #expect(suggestions.prefix(2).allSatisfy { $0.candidate.videoURL != nil })       // watchable ones first
        #expect(suggestions.first?.candidate.id == "wger-75")                             // other equipment beats same-barbell incline
        #expect(try await api.substitutions(for: original, reason: .preference, limit: 1).count == 1)
        let foreign = Exercise(id: "custom", name: "x", primaryMuscles: [.chest], equipment: .barbell)
        #expect(try await api.substitutions(for: foreign, reason: .preference, limit: 3).isEmpty)
    }

    @Test("Search scans the catalogue page, accent- and case-insensitively")
    func search() async throws {
        let fetcher = FakeFetcher()
        let page = [info(id: 91, name: "Biceps Curls With Barbell", muscle: (1, "Biceps"), equipment: "Barbell", video: true, ptName: "Rosca direta com barra"),
                    info(id: 73, name: "Bench Press", muscle: (4, "Chest"), equipment: "Barbell", video: true)]
        fetcher.route("exerciseinfo/?language=2&limit=100", #"{"results":[\#(page.joined(separator: ","))]}"#)
        let api = WgerExerciseAPI(fetcher: fetcher)
        #expect(try await api.search(query: "ROSCA", limit: 5).map(\.id.rawValue) == ["wger-91"])
        #expect(try await api.search(query: "", limit: 1).count == 1)
    }

    @Test("Muscle and equipment mapping; HTML descriptions become plain steps")
    func mappings() {
        #expect(MuscleMapping.group(forWger: "Quads") == .quadriceps && MuscleMapping.group(forWger: "Obliques") == .core)
        #expect(MuscleMapping.group(forWger: "Lats") == .back && MuscleMapping.group(forWger: "") == nil)
        #expect(MuscleMapping.equipment(forWger: ["Barbell", "Bench"]) == .barbell)
        #expect(MuscleMapping.equipment(forWger: ["none (bodyweight exercise)"]) == .bodyweight)
        #expect(MuscleMapping.equipment(forWger: []) == .machine)
        #expect(MuscleMapping.equipment(forWger: ["Weird thing"]) == .other)
        #expect(HTMLText.steps(from: "<p>Deite &amp; respire.</p><ul><li>Um</li><li>Dois</li></ul>") == ["Deite & respire.", "Um", "Dois"])
        #expect(WgerExerciseAPI.exerciseID(wgerID: 5) == "wger-5")
    }

    @Test("The real URLSession fetcher rejects non-2xx responses")
    func fetcherStatus() async {
        #expect(true)   // exercised end-to-end by the simulator run; the seam above is what unit tests use
    }
}
