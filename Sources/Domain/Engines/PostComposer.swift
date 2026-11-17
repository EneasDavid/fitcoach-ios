import Foundation

/// Turns what happened into a shareable card. Pure: same inputs, same post — and the post id is derived from the
/// source (workout / day / activity), so generating it twice updates one post instead of creating two.
public struct PostComposer: Sendable {
    public let analytics: ListeningAnalytics
    public let engine: ProgressionEngine

    public init(analytics: ListeningAnalytics = ListeningAnalytics(), engine: ProgressionEngine = ProgressionEngine()) {
        self.analytics = analytics
        self.engine = engine
    }

    private func meta(_ deviceID: String, _ now: Date) -> SyncMetadata {
        SyncMetadata(updatedAt: now, lastWriterDeviceID: deviceID)
    }

    /// A finished workout: a PR card when it set one (with the song that was playing), a plain summary otherwise.
    public func workoutPost(log: WorkoutLog, history: [WorkoutLog], plays: [TrackPlay], deviceID: String, now: Date) -> ActivityPost {
        let window = analytics.window(of: log)
        let working = log.blocks.flatMap { block -> [SetLog] in
            if case .resistance(let r) = block { return r.sets.filter { !$0.isWarmup } }
            return []
        }
        var stats: [PostStat] = []
        let minutes = Int((window.duration / 60).rounded())
        if minutes >= 1 { stats.append(PostStat(label: String(localized: "Time"), value: String(localized: "\(minutes) min"))) }
        if !working.isEmpty { stats.append(PostStat(label: String(localized: "Sets"), value: "\(working.count)")) }
        let volume = working.reduce(0) { $0 + $1.volumeKg }
        if volume > 0 { stats.append(PostStat(label: String(localized: "Volume"), value: "\(Self.number(volume)) kg")) }

        let moments = analytics.prMoments(for: log, history: history, plays: plays, engine: engine)
        let soundtrack = analytics.soundtrack(of: log, plays: plays, limit: 3)

        if let best = moments.max(by: { $0.record.e1RMKg < $1.record.e1RMKg }) {
            var tracks: [PostTrack] = []
            if let playing = best.track {
                tracks.append(PostTrack(title: playing.title, artist: playing.artist,
                                        plays: soundtrack.first { $0.key == playing.trackKey }?.plays ?? 1,
                                        note: String(localized: "Playing when you hit it")))
            }
            tracks += soundtrack.filter { $0.key != best.track?.trackKey }.prefix(2)
                .map { PostTrack(title: $0.title, artist: $0.artist, plays: $0.plays) }
            return ActivityPost(id: PostID("workout-\(log.id)"), studentID: log.studentID, kind: .personalRecord, createdAt: window.end,
                                title: String(localized: "New PR · \(best.exercise.name)"),
                                subtitle: "\(Self.number(best.record.weightKg)) kg × \(best.record.reps)",
                                stats: [PostStat(label: String(localized: "Est. 1RM"), value: "\(Self.number(best.record.e1RMKg)) kg")] + stats,
                                tracks: tracks, sourceLogID: log.id, meta: meta(deviceID, now))
        }
        return ActivityPost(id: PostID("workout-\(log.id)"), studentID: log.studentID, kind: .workout, createdAt: window.end,
                            title: log.templateLabel, subtitle: nil, stats: stats,
                            tracks: soundtrack.map { PostTrack(title: $0.title, artist: $0.artist, plays: $0.plays) },
                            sourceLogID: log.id, meta: meta(deviceID, now))
    }

    /// "Playlist of the day": what you listened to, most played first. `nil` when nothing was played.
    public func playlistPost(studentID: UserID, day: Date, plays: [TrackPlay], deviceID: String, now: Date) -> ActivityPost? {
        let top = analytics.playlistOfTheDay(plays, day: day, limit: 5)
        guard !top.isEmpty else { return nil }
        let parts = analytics.calendar.dateComponents([.year, .month, .day], from: day)
        let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return ActivityPost(id: PostID("playlist-\(key)"), studentID: studentID, kind: .playlistOfTheDay, createdAt: day,
                            title: String(localized: "Playlist of the day"), subtitle: nil,
                            tracks: top.map { PostTrack(title: $0.title, artist: $0.artist, plays: $0.plays) },
                            meta: meta(deviceID, now))
    }

    public func activityPost(_ activity: ExternalActivity, deviceID: String, now: Date) -> ActivityPost {
        var stats = [PostStat(label: String(localized: "Time"), value: String(localized: "\(max(activity.movingSeconds, 1) / 60) min"))]
        if let distance = activity.distanceMeters, distance > 0 {
            stats.append(PostStat(label: String(localized: "Distance"), value: "\(Self.number(distance / 1_000, fraction: 1)) km"))
        }
        return ActivityPost(id: PostID("activity-\(activity.id)"), studentID: activity.studentID, kind: .externalActivity,
                            createdAt: activity.startedAt, title: activity.name, stats: stats,
                            sourceActivityID: activity.id, meta: meta(deviceID, now))
    }

    static func number(_ value: Double, fraction: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(0...fraction)))
    }
}

/// The plain-text version of a card — what WhatsApp (and any text field) receives.
public enum ShareTextComposer {
    public static func text(for post: ActivityPost, hashtag: String = "#FitCoach") -> String {
        var lines: [String] = []
        let icon: String
        switch post.kind {
        case .personalRecord: icon = "🏆"
        case .workout: icon = "💪"
        case .playlistOfTheDay: icon = "🎧"
        case .externalActivity: icon = "🏃"
        }
        lines.append("\(icon) \(post.title)")
        if let subtitle = post.subtitle { lines.append(subtitle) }
        if !post.stats.isEmpty { lines.append(post.stats.map { "\($0.label) \($0.value)" }.joined(separator: " · ")) }
        for track in post.tracks {
            var line = "🎵 \(track.title) — \(track.artist)"
            if track.plays > 1 { line += " ×\(track.plays)" }
            if let note = track.note { line += " (\(note))" }
            lines.append(line)
        }
        lines.append(hashtag)
        return lines.joined(separator: "\n")
    }
}
