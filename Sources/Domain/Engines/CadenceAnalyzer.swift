import Foundation

/// A recurring (weekday, hour) the student habitually trains at. `weekday` follows `Calendar`: 1 = Sunday.
public struct TrainingSlot: Hashable, Comparable, Sendable {
    public let weekday: Int
    public let hour: Int

    public init(weekday: Int, hour: Int) {
        self.weekday = weekday
        self.hour = hour
    }

    public static func < (lhs: TrainingSlot, rhs: TrainingSlot) -> Bool {
        (lhs.weekday, lhs.hour) < (rhs.weekday, rhs.hour)
    }
}

/// Learns the student's training cadence from history and plans proactive local reminders.
/// Pure logic: scheduling itself is done by a `LocalNotificationScheduling` adapter from a
/// BGAppRefreshTask, so reminders keep adapting even if the app isn't opened.
public struct CadenceAnalyzer: Sendable {
    public var lookbackWeeks: Int
    public var minimumOccurrences: Int
    public var leadMinutes: Int
    public var horizonDays: Int

    public init(lookbackWeeks: Int = 8, minimumOccurrences: Int = 2, leadMinutes: Int = 30, horizonDays: Int = 7) {
        self.lookbackWeeks = lookbackWeeks
        self.minimumOccurrences = minimumOccurrences
        self.leadMinutes = leadMinutes
        self.horizonDays = horizonDays
    }

    public func typicalSlots(from logs: [WorkoutLog], now: Date, calendar: Calendar = .current) -> [TrainingSlot] {
        guard let cutoff = calendar.date(byAdding: .weekOfYear, value: -lookbackWeeks, to: now) else { return [] }
        var counts: [TrainingSlot: Int] = [:]
        for log in logs where log.status == .completed && !log.meta.isDeleted && log.startedAt >= cutoff {
            let parts = calendar.dateComponents([.weekday, .hour], from: log.startedAt)
            guard let weekday = parts.weekday, let hour = parts.hour else { continue }
            counts[TrainingSlot(weekday: weekday, hour: hour), default: 0] += 1
        }
        return counts.filter { $0.value >= minimumOccurrences }.keys.sorted()
    }

    /// Reminders for the next `horizonDays`, skipping slots in the past and days the student
    /// has already trained. Only the first reminder names the workout: later days can't be known
    /// yet because the sequence advances with what the student actually completes.
    public func reminders(slots: [TrainingSlot],
                          logs: [WorkoutLog],
                          nextWorkoutLabel: String?,
                          now: Date,
                          calendar: Calendar = .current) -> [LocalNotification] {
        let today = calendar.startOfDay(for: now)
        var result: [LocalNotification] = []

        for offset in 0..<horizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let trainedThatDay = logs.contains {
                $0.status == .completed && !$0.meta.isDeleted && calendar.isDate($0.effectiveDate, inSameDayAs: day)
            }
            guard !trainedThatDay else { continue }

            for slot in slots where slot.weekday == weekday {
                guard let slotTime = calendar.date(bySettingHour: slot.hour, minute: 0, second: 0, of: day),
                      let fire = calendar.date(byAdding: .minute, value: -leadMinutes, to: slotTime),
                      fire > now else { continue }

                let isFirst = result.isEmpty
                let comps = calendar.dateComponents([.year, .month, .day], from: day)
                let id = "training.reminder.\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0).\(slot.hour)"
                let body: String
                if isFirst, let label = nextWorkoutLabel {
                    body = String(localized: "Next up: \(label). Ready when you are.")
                } else {
                    body = String(localized: "Time to train. Open the app to see your next workout.")
                }
                result.append(LocalNotification(id: id,
                                                title: String(localized: "Training time"),
                                                body: body,
                                                fireDate: fire,
                                                category: LocalNotification.trainingReminderCategory,
                                                userInfo: ["deeplink": "fitcoach://workout/next"]))
            }
        }
        return result.sorted { ($0.fireDate ?? .distantFuture) < ($1.fireDate ?? .distantFuture) }
    }
}
