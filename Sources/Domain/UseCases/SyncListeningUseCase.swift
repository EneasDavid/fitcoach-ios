import Foundation

/// Imports the day's listening history and keeps "Playlist of the day" up to date.
///
/// Spotify only returns the last ~50 plays, so this runs whenever the app has a chance (a workout finishing, the feed opening,
/// a background refresh) and everything imported is stored. A post is only created once there is something worth showing
/// (`minimumTracks`), so an almost-empty day doesn't litter the feed. Entirely opt-in: with music off nothing is requested.
public struct SyncListeningUseCase: Sendable {
    public let music: any MusicHistoryProviding
    public let plays: any TrackPlayRepository
    public let posts: any PostRepository
    public let composer: PostComposer
    public let minimumTracks: Int
    public let now: @Sendable () -> Date

    public init(music: any MusicHistoryProviding, plays: any TrackPlayRepository, posts: any PostRepository,
                composer: PostComposer = PostComposer(), minimumTracks: Int = 3, now: @escaping @Sendable () -> Date = { Date() }) {
        self.music = music
        self.plays = plays
        self.posts = posts
        self.composer = composer
        self.minimumTracks = minimumTracks
        self.now = now
    }

    /// - Returns: the playlist post when one was created or refreshed.
    @discardableResult
    public func execute(studentID: UserID, deviceID: String, includeMusic: Bool) async throws -> ActivityPost? {
        guard includeMusic, await music.isConnected else { return nil }
        let moment = now()
        let calendar = composer.analytics.calendar
        let dayStart = calendar.startOfDay(for: moment)

        // Import. A failure here (offline, rate limit, revoked token) is not fatal: use what is already stored.
        if let fetched = try? await music.recentlyPlayed(after: dayStart) { try? await plays.save(fetched) }

        let today = try await plays.plays(studentID: studentID, from: dayStart, to: moment)
        guard Set(today.map(\.trackKey)).count >= minimumTracks else { return nil }
        guard var post = composer.playlistPost(studentID: studentID, day: moment, plays: today, deviceID: deviceID, now: moment) else { return nil }
        post.photo = try? await posts.posts(studentID: studentID).first { $0.id == post.id }?.photo
        return try await posts.save(post)
    }
}
