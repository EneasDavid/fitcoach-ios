import Foundation

/// After a workout: pull the listening history around it (if Spotify is connected and the student allows it),
/// keep those plays, and publish the shareable card.
///
/// Music is garnish: any failure there (offline, token expired, rate limit) is swallowed and the post is still
/// created from whatever plays are already stored. A flaky music API can never block "Workout saved".
public struct PublishWorkoutPostUseCase: Sendable {
    public let logs: any WorkoutLogRepository
    public let posts: any PostRepository
    public let plays: any TrackPlayRepository
    public let music: (any MusicHistoryProviding)?
    public let composer: PostComposer
    public let now: @Sendable () -> Date

    /// Spotify only returns the last ~50 plays, so ask for a little before the workout started.
    static let lookback: TimeInterval = 15 * 60

    public init(logs: any WorkoutLogRepository, posts: any PostRepository, plays: any TrackPlayRepository,
                music: (any MusicHistoryProviding)? = nil, composer: PostComposer = PostComposer(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.logs = logs
        self.posts = posts
        self.plays = plays
        self.music = music
        self.composer = composer
        self.now = now
    }

    @discardableResult
    public func execute(log: WorkoutLog, deviceID: String, includeMusic: Bool) async throws -> ActivityPost {
        let window = composer.analytics.window(of: log)
        let from = window.start.addingTimeInterval(-Self.lookback)

        var found: [TrackPlay] = []
        if includeMusic, let music {
            if await music.isConnected, let fetched = try? await music.recentlyPlayed(after: from) {
                try? await plays.save(fetched)
                found = fetched
            }
            if let stored = try? await plays.plays(studentID: log.studentID, from: from, to: window.end) {
                found = Self.merge(found, stored)
            }
        }

        let history = try await logs.logs(studentID: log.studentID, planID: nil, since: nil)
        var post = composer.workoutPost(log: log, history: history, plays: found, deviceID: deviceID, now: now())
        // Publishing again must never erase the photo the student attached to this card.
        post.photo = try? await posts.posts(studentID: log.studentID).first { $0.id == post.id }?.photo
        return try await posts.save(post)
    }

    static func merge(_ a: [TrackPlay], _ b: [TrackPlay]) -> [TrackPlay] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0.id).inserted }
    }
}
