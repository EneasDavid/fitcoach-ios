import Domain
import Foundation
import Observation

/// The student's training history as a month calendar: every day with a finished workout is marked, and tapping a day lists what was done.
@MainActor
@Observable
public final class HistoryViewModel {
    public struct Day: Identifiable, Equatable, Sendable {
        /// Start of the day.
        public let id: Date
        public let number: Int
        public let sessionCount: Int
        public let isToday: Bool
        public var hasWorkout: Bool { sessionCount > 0 }
    }

    public struct Session: Identifiable, Equatable, Sendable {
        public let id: LogID
        public let title: String
        public let startedAt: Date
        public let minutes: Int?
        public let sets: Int
        public let volumeKg: Double
        public let rpe: Int?
        public let focus: TrainingFocus?
    }

    public private(set) var displayedMonth: Date
    public private(set) var selectedDay: Date?
    public private(set) var isLoaded = false

    /// The photos the student attached to their cards (the trainer sees them next to that day's sets).
    public private(set) var photos: [SharedPhoto] = []

    @ObservationIgnored private let studentID: UserID
    @ObservationIgnored private let logs: any WorkoutLogRepository
    @ObservationIgnored private let planProvider: (() async -> WorkoutPlan?)?
    @ObservationIgnored private let photoSource: (any SharedPhotoRepository)?
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var completed: [WorkoutLog] = []
    @ObservationIgnored private var plan: WorkoutPlan?

    /// - Parameters:
    ///   - plan: the student's current plan, to show what was asked next to what was done (optional: a record is complete without it).
    ///   - photos: where to read the student's shared photos from (the trainer's view; the student's own cards already hold theirs).
    public init(studentID: UserID, logs: any WorkoutLogRepository, plan: (() async -> WorkoutPlan?)? = nil, photos: (any SharedPhotoRepository)? = nil,
                calendar: Calendar = .current, now: @escaping () -> Date = { Date() }) {
        self.studentID = studentID
        self.logs = logs
        self.planProvider = plan
        self.photoSource = photos
        self.calendar = calendar
        self.now = now
        self.displayedMonth = Self.monthStart(of: now(), calendar: calendar)
    }

    public func run() async {
        plan = await planProvider?()
        let studentID = self.studentID
        // The photos stream rides along for as long as the logs stream is being read.
        let photoTask: Task<Void, Never>? = photoSource.map { source in
            Task { @MainActor [weak self] in
                for await all in source.observePhotos(studentID: studentID) { self?.photos = all.filter { !$0.photo.isEmpty } }
            }
        }
        defer { photoTask?.cancel() }
        for await all in logs.observeLogs(studentID: studentID) {
            completed = all.filter { $0.status == .completed && !$0.meta.isDeleted }
            isLoaded = true
            if selectedDay == nil { selectDefaultDay() }
        }
    }

    // MARK: Calendar

    private static func monthStart(of date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Formatted with the model's own calendar and time zone, so "March" is March wherever the device (or a test) happens to be.
    public var monthTitle: String {
        displayedMonth.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.wide).year())
    }

    /// One letter per weekday, starting at the calendar's first weekday (Sunday or Monday depending on the region).
    public var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    /// The month as a grid: `nil`s pad the first week so day 1 lands under its weekday.
    public var cells: [Day?] {
        guard let days = calendar.range(of: .day, in: .month, for: displayedMonth) else { return [] }
        let leading = (calendar.component(.weekday, from: displayedMonth) - calendar.firstWeekday + 7) % 7
        let today = calendar.startOfDay(for: now())
        let counts = sessionCounts()
        var grid: [Day?] = Array(repeating: nil, count: leading)
        for number in days {
            guard let date = calendar.date(byAdding: .day, value: number - 1, to: displayedMonth) else { continue }
            grid.append(Day(id: date, number: number, sessionCount: counts[date] ?? 0, isToday: date == today))
        }
        return grid
    }

    public var canGoForward: Bool { displayedMonth < Self.monthStart(of: now(), calendar: calendar) }

    public func previousMonth() { move(by: -1) }
    public func nextMonth() { if canGoForward { move(by: 1) } }

    private func move(by months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: displayedMonth) else { return }
        displayedMonth = Self.monthStart(of: next, calendar: calendar)
        selectDefaultDay()
    }

    /// The latest day of the shown month that has a workout (so the list under the calendar is never empty for no reason).
    private func selectDefaultDay() {
        selectedDay = sessionCounts().keys.filter { $0 >= displayedMonth && calendar.isDate($0, equalTo: displayedMonth, toGranularity: .month) }.max()
    }

    public func select(_ day: Date) { selectedDay = calendar.startOfDay(for: day) }

    private func sessionCounts() -> [Date: Int] {
        completed.reduce(into: [:]) { counts, log in counts[calendar.startOfDay(for: log.effectiveDate), default: 0] += 1 }
    }

    // MARK: What was done

    public var monthSummary: (workouts: Int, days: Int) {
        let inMonth = completed.filter { calendar.isDate($0.effectiveDate, equalTo: displayedMonth, toGranularity: .month) }
        return (inMonth.count, Set(inMonth.map { calendar.startOfDay(for: $0.effectiveDate) }).count)
    }

    public var selectedSessions: [Session] {
        guard let selectedDay else { return [] }
        return completed
            .filter { calendar.isDate($0.effectiveDate, inSameDayAs: selectedDay) }
            .sorted { $0.startedAt < $1.startedAt }
            .map { log in
                let sets = log.blocks.flatMap { block -> [SetLog] in
                    if case .resistance(let performed) = block { return performed.sets.filter { !$0.isWarmup } }
                    return []
                }
                let minutes = log.completedAt.map { Int($0.timeIntervalSince(log.startedAt) / 60) }.flatMap { $0 >= 1 ? $0 : nil }
                return Session(id: log.id, title: log.templateLabel, startedAt: log.startedAt, minutes: minutes, sets: sets.count,
                               volumeKg: sets.reduce(0) { $0 + $1.volumeKg }, rpe: log.sessionRPE, focus: log.focus)
            }
    }

    /// Every recorded detail of the selected day's workouts, earliest first.
    public var selectedRecords: [SessionRecord] {
        guard let selectedDay else { return [] }
        return completed
            .filter { calendar.isDate($0.effectiveDate, inSameDayAs: selectedDay) }
            .sorted { $0.startedAt < $1.startedAt }
            .map { SessionRecordBuilder.build($0, plan: plan) }
    }

    public func photos(for record: SessionRecord) -> [SharedPhoto] { photos.filter { $0.logID == record.id } }

    public static func identifier(for day: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
