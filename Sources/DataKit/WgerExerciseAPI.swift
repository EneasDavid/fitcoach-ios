import Domain
import Foundation

/// Minimal HTTP seam so the API client is testable without a network.
public protocol HTTPFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}

/// `RemoteExerciseAPI` backed by the open **wger** exercise database (https://wger.de): demonstration videos,
/// images, primary/secondary muscles, equipment and translations (including Portuguese).
///
/// Licence: wger exercise content is CC-BY-SA; every `Exercise` carries `mediaCredit` and the UI must show it.
/// `baseURL` is injectable so production can point at the app's own caching proxy (Cloud Function) instead.
public struct WgerExerciseAPI: RemoteExerciseAPI {
    private let baseURL: URL
    private let fetcher: any HTTPFetching
    /// Preferred translation languages, best first (wger ids: 7 = Portuguese, 2 = English).
    private let languages: [Int]
    private let recommender = SubstitutionRecommender()

    public init(baseURL: URL = URL(string: "https://wger.de/api/v2")!,
                fetcher: any HTTPFetching = URLSessionFetcher(),
                languages: [Int] = [7, 2]) {
        self.baseURL = baseURL
        self.fetcher = fetcher
        self.languages = languages
    }

    public static func exerciseID(wgerID: Int) -> ExerciseID { ExerciseID("wger-\(wgerID)") }

    // MARK: RemoteExerciseAPI

    public func exercise(id: ExerciseID) async throws -> Exercise? {
        guard id.rawValue.hasPrefix("wger-"), let wgerID = Int(id.rawValue.dropFirst(5)) else { return nil }
        return try await info(wgerID: wgerID)?.exercise
    }

    /// wger exposes no server-side name search, so this scans the first catalogue pages. It's a convenience
    /// for the picker; the offline cache (`CachedExerciseCatalogRepository`) serves repeat searches.
    public func search(query: String, limit: Int) async throws -> [Exercise] {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let page = try await list(path: "exerciseinfo/?language=2&limit=100")
        return page.compactMap { entry -> Exercise? in
            let name = entry.exercise.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return needle.isEmpty || name.contains(needle) ? entry.exercise : nil
        }
        .prefix(limit).map { $0 }
    }

    /// Up to `limit` alternatives that train the same primary muscle, ranked by on-device muscle/equipment scoring.
    /// Exercises with a demonstration video are preferred, so every suggestion is something the student can watch.
    public func substitutions(for exercise: Exercise, reason: SubstitutionReason, limit: Int) async throws -> [ExerciseSubstitution] {
        guard exercise.id.rawValue.hasPrefix("wger-"), let wgerID = Int(exercise.id.rawValue.dropFirst(5)),
              let original = try await info(wgerID: wgerID), let muscle = original.primaryMuscleIDs.first else { return [] }
        let candidates = try await list(path: "exerciseinfo/?language=2&muscles=\(muscle)&limit=60")
        let ranked = recommender.rank(original: exercise, candidates: candidates.map(\.exercise), reason: reason, limit: 60)
        let withVideo = ranked.filter { $0.candidate.videoURL != nil }
        let without = ranked.filter { $0.candidate.videoURL == nil }
        return Array((withVideo + without).prefix(limit))
    }

    // MARK: Fetching & mapping

    private func info(wgerID: Int) async throws -> Entry? {
        let data = try await fetcher.fetch(baseURL.appendingPathComponent("exerciseinfo/\(wgerID)/"))
        return try Self.decode(data, languages: languages)
    }

    private func list(path: String) async throws -> [Entry] {
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else { return [] }
        let data = try await fetcher.fetch(url)
        let page = try JSONDecoder().decode(Page.self, from: data)
        return page.results.compactMap { Self.entry(from: $0, languages: languages) }
    }

    struct Entry {
        let exercise: Exercise
        let primaryMuscleIDs: [Int]
    }

    static func decode(_ data: Data, languages: [Int]) throws -> Entry? {
        entry(from: try JSONDecoder().decode(Info.self, from: data), languages: languages)
    }

    static func entry(from info: Info, languages: [Int]) -> Entry? {
        let translation = languages.lazy.compactMap { language in info.translations.first { $0.language == language && !$0.name.isEmpty } }.first
            ?? info.translations.first { !$0.name.isEmpty }
        guard let translation else { return nil }

        let primary = info.muscles.compactMap { MuscleMapping.group(forWger: $0.name_en) }
        let secondary = info.muscles_secondary.compactMap { MuscleMapping.group(forWger: $0.name_en) }.filter { !primary.contains($0) }
        let video = info.videos.first.flatMap { URL(string: $0.video) }
        let image = (info.images.first { $0.is_main == true } ?? info.images.first).flatMap { URL(string: $0.image) }
        let credit = [info.videos.first?.license_author ?? info.license_author, info.license?.short_name]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")

        let exercise = Exercise(id: exerciseID(wgerID: info.id),
                                externalID: String(info.id),
                                name: translation.name,
                                primaryMuscles: Array(NSOrderedSet(array: primary)) as? [MuscleGroup] ?? primary,
                                secondaryMuscles: Array(NSOrderedSet(array: secondary)) as? [MuscleGroup] ?? secondary,
                                equipment: MuscleMapping.equipment(forWger: info.equipment.map(\.name)),
                                imageURL: image,
                                videoURL: video,
                                instructions: HTMLText.steps(from: translation.description ?? ""),
                                mediaCredit: credit.isEmpty ? nil : credit)
        return Entry(exercise: exercise, primaryMuscleIDs: info.muscles.map(\.id))
    }

    // MARK: Wire format (only the fields we use)

    struct Page: Decodable { let results: [Info] }

    struct Info: Decodable {
        struct Muscle: Decodable { let id: Int; let name_en: String }
        struct Equipment: Decodable { let name: String }
        struct Translation: Decodable { let language: Int; let name: String; let description: String? }
        struct Image: Decodable { let image: String; let is_main: Bool? }
        struct Video: Decodable { let video: String; let license_author: String? }
        struct License: Decodable { let short_name: String }

        let id: Int
        let muscles: [Muscle]
        let muscles_secondary: [Muscle]
        let equipment: [Equipment]
        let translations: [Translation]
        let images: [Image]
        let videos: [Video]
        let license: License?
        let license_author: String?
    }
}

enum MuscleMapping {
    static func group(forWger name: String) -> MuscleGroup? {
        switch name.lowercased() {
        case "chest": return .chest
        case "shoulders": return .shoulders
        case "biceps": return .biceps
        case "triceps": return .triceps
        case "abs", "obliques": return .core
        case "quads": return .quadriceps
        case "hamstrings": return .hamstrings
        case "glutes": return .glutes
        case "calves": return .calves
        case "lats", "traps", "lower back": return .back
        case "forearms": return .forearms
        default: return nil
        }
    }

    static func equipment(forWger names: [String]) -> Equipment {
        let lowered = names.map { $0.lowercased() }
        func has(_ word: String) -> Bool { lowered.contains { $0.contains(word) } }
        if has("barbell") || has("sz-bar") { return .barbell }
        if has("dumbbell") { return .dumbbell }
        if has("cable") { return .cable }
        if has("kettlebell") { return .kettlebell }
        if has("band") { return .band }
        if has("none") || has("bodyweight") || has("pull-up") { return .bodyweight }
        return lowered.isEmpty ? .machine : .other
    }
}

/// wger descriptions are small HTML fragments; turn them into plain, readable steps.
enum HTMLText {
    static func steps(from html: String) -> [String] {
        var text = html
            .replacingOccurrences(of: "</li>", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
