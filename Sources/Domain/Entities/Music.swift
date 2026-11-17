import Foundation

public enum MusicProvider: String, Codable, Sendable, CaseIterable {
    case spotify
}

/// One time a track was played. Tracks only — no podcasts, no playlists, no account data.
///
/// `id` is deterministic (provider + track + start second), so importing the same listening history twice —
/// which is exactly what happens when two syncs overlap — can never double-count a play.
public struct TrackPlay: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var provider: MusicProvider
    public var trackID: String
    public var title: String
    public var artist: String
    public var startedAt: Date
    public var durationSeconds: Int

    public init(provider: MusicProvider, trackID: String, title: String, artist: String, startedAt: Date, durationSeconds: Int) {
        self.provider = provider
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.startedAt = startedAt
        self.durationSeconds = max(durationSeconds, 0)
        self.id = "\(provider.rawValue):\(trackID):\(Int(startedAt.timeIntervalSince1970))"
    }

    public var endsAt: Date { startedAt.addingTimeInterval(TimeInterval(durationSeconds)) }
    /// The same song, whichever play it was.
    public var trackKey: String { "\(provider.rawValue):\(trackID)" }

    public func isPlaying(at date: Date) -> Bool { date >= startedAt && date < endsAt }
    public func overlaps(_ interval: DateInterval) -> Bool { startedAt < interval.end && endsAt > interval.start }
}

/// A song and how many times it was played in some window.
public struct TrackStat: Equatable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let artist: String
    public let plays: Int
    public let lastPlayedAt: Date

    public init(key: String, title: String, artist: String, plays: Int, lastPlayedAt: Date) {
        self.key = key
        self.title = title
        self.artist = artist
        self.plays = plays
        self.lastPlayedAt = lastPlayedAt
    }
}

/// "You were listening to this when you set that record."
public struct PRMoment: Equatable, Sendable, Identifiable {
    public var id: String { "\(record.logID)-\(exercise.id)" }
    public let exercise: ExerciseRef
    public let record: PersonalRecord
    public let achievedAt: Date
    public let track: TrackPlay?

    public init(exercise: ExerciseRef, record: PersonalRecord, achievedAt: Date, track: TrackPlay?) {
        self.exercise = exercise
        self.record = record
        self.achievedAt = achievedAt
        self.track = track
    }
}
