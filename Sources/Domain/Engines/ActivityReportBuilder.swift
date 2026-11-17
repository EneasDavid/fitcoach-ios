import Foundation

public struct ReportEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let source: ActivitySource
    public let date: Date
    public let title: String
    public let durationSeconds: Int
    public let distanceMeters: Double?
}

/// What the trainer sees for one student and one period: app workouts plus (with consent) Strava activities.
public struct ActivityReport: Equatable, Sendable {
    public let period: DateInterval
    /// Newest first.
    public let entries: [ReportEntry]
    public let activeDays: Int
    public let totalSeconds: Int
    public let totalDistanceMeters: Double
    public let countBySource: [ActivitySource: Int]
    /// External activities left out because the student has not shared them — surfaced so the UI can say
    /// "this student hasn't shared Strava" instead of silently showing less.
    public let externalWithheld: Bool

    public var sessions: Int { entries.count }
}

public struct ActivityReportBuilder: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// - Parameter includeExternal: the student's `shareWithTrainer` consent (and the server-side policy flag).
    ///   When false, external activities are never even looked at.
    public func build(logs: [WorkoutLog], activities: [ExternalActivity], period: DateInterval, includeExternal: Bool) -> ActivityReport {
        var entries: [ReportEntry] = []
        var appIntervals: [DateInterval] = []

        for log in logs where log.status == .completed && !log.meta.isDeleted && period.contains(log.effectiveDate) {
            let interval = DateInterval(start: log.startedAt, end: max(log.completedAt ?? log.startedAt, log.startedAt))
            appIntervals.append(interval)
            entries.append(ReportEntry(id: "app-\(log.id)", source: .fitCoach, date: log.startedAt, title: log.templateLabel,
                                       durationSeconds: Int(interval.duration), distanceMeters: nil))
        }

        var withheld = false
        for activity in activities where !activity.meta.isDeleted && period.contains(activity.startedAt) {
            guard includeExternal else { withheld = true; continue }
            // The watch's "Weight training" for a session the app already logged is the same workout: count it once.
            if activity.isStrengthTraining, appIntervals.contains(where: { $0.intersects(activity.interval) }) { continue }
            entries.append(ReportEntry(id: "ext-\(activity.id)", source: activity.source, date: activity.startedAt, title: activity.name,
                                       durationSeconds: activity.movingSeconds, distanceMeters: activity.distanceMeters))
        }

        entries.sort { $0.date > $1.date }
        var bySource: [ActivitySource: Int] = [:]
        for entry in entries { bySource[entry.source, default: 0] += 1 }

        return ActivityReport(period: period, entries: entries,
                              activeDays: Set(entries.map { calendar.startOfDay(for: $0.date) }).count,
                              totalSeconds: entries.reduce(0) { $0 + $1.durationSeconds },
                              totalDistanceMeters: entries.reduce(0) { $0 + ($1.distanceMeters ?? 0) },
                              countBySource: bySource, externalWithheld: withheld)
    }
}
