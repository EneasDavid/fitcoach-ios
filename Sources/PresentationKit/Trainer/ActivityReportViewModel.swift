import Domain
import Foundation
import Observation
import SwiftUI

/// The trainer's "what has this student done" report: app workouts plus whatever Strava activities the student chose to share.
/// The *backend* decides whether the Strava part is visible (rules + the student's switch); this model just reports
/// what arrived, so a student who shares nothing simply shows app workouts.
@MainActor
@Observable
public final class ActivityReportViewModel {
    public enum Period: Int, CaseIterable, Sendable {
        case week = 7, month = 30
        public var title: String { self == .week ? String(localized: "7 days") : String(localized: "30 days") }
    }

    public var period: Period = .week
    public private(set) var report: ActivityReport?

    @ObservationIgnored private let studentID: UserID
    @ObservationIgnored private let logs: any WorkoutLogRepository
    @ObservationIgnored private let activities: any ExternalActivityRepository
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let builder: ActivityReportBuilder

    public init(studentID: UserID, logs: any WorkoutLogRepository, activities: any ExternalActivityRepository,
                now: @escaping () -> Date = { Date() }, calendar: Calendar = .current) {
        self.studentID = studentID
        self.logs = logs
        self.activities = activities
        self.now = now
        self.builder = ActivityReportBuilder(calendar: calendar)
    }

    public func load() async {
        let end = now()
        let start = end.addingTimeInterval(-TimeInterval(period.rawValue) * 86_400)
        let interval = DateInterval(start: start, end: end)
        let history = (try? await logs.logs(studentID: studentID, planID: nil, since: start)) ?? []
        let external = (try? await activities.activities(studentID: studentID, since: start)) ?? []
        report = builder.build(logs: history, activities: external, period: interval, includeExternal: true)
    }

    public func select(_ period: Period) async {
        self.period = period
        await load()
    }

    public var hasStravaEntries: Bool { report?.countBySource[.strava, default: 0] ?? 0 > 0 }
}

public struct ActivityReportView: View {
    private let model: ActivityReportViewModel

    public init(model: ActivityReportViewModel) { self.model = model }

    public var body: some View {
        List {
            Section {
                Picker(String(localized: "Period"), selection: Binding(get: { model.period }, set: { value in Task { await model.select(value) } })) {
                    ForEach(ActivityReportViewModel.Period.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("report-period")
            }
            if let report = model.report {
                Section {
                    HStack {
                        summary(String(localized: "Sessions"), "\(report.sessions)")
                        summary(String(localized: "Active days"), "\(report.activeDays)")
                        summary(String(localized: "Time"), String(localized: "\(report.totalSeconds / 60) min"))
                        if report.totalDistanceMeters > 0 {
                            summary(String(localized: "Distance"), "\((report.totalDistanceMeters / 1_000).formatted(.number.precision(.fractionLength(0...1)))) km")
                        }
                    }
                }
                Section {
                    ForEach(report.entries) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: entry.source == .strava ? "figure.run" : "figure.strengthtraining.traditional")
                                .foregroundStyle(Theme.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: entry.title)
                                Text(entry.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(localized: "\(entry.durationSeconds / 60) min")).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if !model.hasStravaEntries {
                        Text(String(localized: "Strava activities appear here when the student connects Strava and chooses to share them."))
                    }
                }
            }
        }
        .task { await model.load() }
    }

    private func summary(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value).font(.headline)
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
