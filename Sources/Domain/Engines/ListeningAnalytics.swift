import Foundation

/// Pure functions over the listening history the app has observed. Play counts are *observed* counts (what we
/// imported), not the provider's lifetime counts — no streaming API exposes those.
public struct ListeningAnalytics: Sendable {
    public var calendar: Calendar
    /// A track that began before the window but is still playing when it opens counts as part of it.
    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Unique plays only (re-imports can't inflate counts), grouped by song, most played first, ties by recency.
    public func topTracks(_ plays: [TrackPlay], limit: Int = 10) -> [TrackStat] {
        var seen = Set<String>()
        var grouped: [String: (title: String, artist: String, count: Int, last: Date)] = [:]
        for play in plays where seen.insert(play.id).inserted {
            var entry = grouped[play.trackKey] ?? (play.title, play.artist, 0, .distantPast)
            entry.count += 1
            entry.last = max(entry.last, play.startedAt)
            grouped[play.trackKey] = entry
        }
        return grouped
            .map { TrackStat(key: $0.key, title: $0.value.title, artist: $0.value.artist, plays: $0.value.count, lastPlayedAt: $0.value.last) }
            .sorted { ($0.plays, $0.lastPlayedAt, $1.key) > ($1.plays, $1.lastPlayedAt, $0.key) }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    /// "Playlist of the day": the songs played on that calendar day.
    public func playlistOfTheDay(_ plays: [TrackPlay], day: Date, limit: Int = 10) -> [TrackStat] {
        topTracks(plays.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }, limit: limit)
    }

    /// The song that was playing at `date`, if any. With overlapping plays (two devices) the latest start wins.
    public func track(at date: Date, in plays: [TrackPlay]) -> TrackPlay? {
        plays.filter { $0.isPlaying(at: date) }.max { $0.startedAt < $1.startedAt }
    }

    /// When the session happened: start → completion (or the last logged set for one that wasn't finished).
    public func window(of log: WorkoutLog) -> DateInterval {
        let lastSet = log.blocks.compactMap { block -> Date? in
            if case .resistance(let r) = block { return r.sets.map(\.completedAt).max() }
            return nil
        }.max()
        let end = max(log.completedAt ?? lastSet ?? log.startedAt, log.startedAt)
        return DateInterval(start: log.startedAt, end: end)
    }

    /// What played during the workout.
    public func soundtrack(of log: WorkoutLog, plays: [TrackPlay], limit: Int = 5) -> [TrackStat] {
        let window = window(of: log)
        return topTracks(plays.filter { $0.overlaps(window) }, limit: limit)
    }

    /// Every personal record set in `log`, with the song that was playing when the set was completed.
    /// `history` may or may not contain `log`; deload sessions can never be records (the engine excludes them).
    public func prMoments(for log: WorkoutLog,
                          history: [WorkoutLog],
                          plays: [TrackPlay],
                          engine: ProgressionEngine = ProgressionEngine()) -> [PRMoment] {
        let all = history.filter { $0.id != log.id } + [log]
        var moments: [PRMoment] = []
        var done = Set<ExerciseID>()

        for case .resistance(let performed) in log.blocks where done.insert(performed.exercise.id).inserted {
            let series = engine.series(for: performed.exercise.id, logs: all)
            guard let record = series.personalRecords.last(where: { $0.logID == log.id }) else { continue }

            let sets = log.blocks.flatMap { block -> [SetLog] in
                if case .resistance(let r) = block, r.exercise.id == performed.exercise.id { return r.sets }
                return []
            }.filter { !$0.isWarmup }
            let set = sets.first { $0.weightKg == record.weightKg && $0.reps == record.reps }
                ?? sets.max { ($0.weightKg, $0.reps) < ($1.weightKg, $1.reps) }
            let when = set?.completedAt ?? log.completedAt ?? log.startedAt

            moments.append(PRMoment(exercise: performed.exercise, record: record, achievedAt: when, track: track(at: when, in: plays)))
        }
        return moments.sorted { $0.achievedAt < $1.achievedAt }
    }
}
