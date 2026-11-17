import Charts
import Domain
import SwiftUI

public struct StudentSummaryView: View {
    private let model: StudentSummaryViewModel

    public init(model: StudentSummaryViewModel) { self.model = model }

    public var body: some View {
        List {
            if let summary = model.summary, !summary.isEmpty {
                Section { overview(summary) }
                if !summary.alerts.isEmpty { Section { alerts(summary.alerts) } header: { Text(String(localized: "Needs attention")) } }
                Section { weekly } header: { Text(String(localized: "Week by week")) }
                if summary.prescription != nil || summary.rest != nil { Section { execution(summary) } header: { Text(String(localized: "Following the plan")) } }
                Section { exercises(summary.exercises) } header: { Text(String(localized: "Exercises")) } footer: {
                    Text(String(localized: "Estimated 1RM from the best set of each workout. “No new best” means none of the last 3 workouts beat the earlier ones."))
                }
                if !model.muscleRows.isEmpty {
                    Section { muscles } header: { Text(String(localized: "Sets per muscle · last 7 days")) } footer: {
                        Text(String(localized: "A common reference for muscle growth is 10–20 hard sets per muscle a week."))
                    }
                }
            } else if model.isLoaded {
                ContentUnavailableView(String(localized: "No workouts yet"), systemImage: "chart.bar",
                                       description: Text(String(localized: "The summary appears after the student's first finished workout.")))
            }
        }
        .navigationTitle(String(localized: "Summary"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    // MARK: Pieces

    private func overview(_ summary: TrainingSummary) -> some View {
        let thisWeek = summary.weeks.last
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                stat(String(localized: "Attendance"), summary.adherence.map { SummaryFormat.percent($0.ratio) } ?? "—", id: "summary-adherence",
                     footnote: summary.adherence.map { String(localized: "\($0.completed) of \($0.planned) workouts · 4 weeks") })
                stat(String(localized: "Last workout"), summary.daysSinceLastSession.map(SummaryFormat.daysAgo) ?? "—", id: "summary-last")
            }
            Divider()
            HStack(alignment: .top) {
                stat(String(localized: "Weekly effort"), summary.workloadRatio.map { BodyFormat.number($0) + "×" } ?? "—", id: "summary-workload",
                     footnote: summary.workloadZone?.title ?? String(localized: "Needs 3 weeks of history"))
                stat(String(localized: "This week"), thisWeek.map { BodyFormat.number($0.volumeLoadKg, digits: 0) + " kg" } ?? "—", id: "summary-week-volume",
                     footnote: thisWeek.map { String(localized: "\($0.sessions) workouts · \($0.workingSets) sets") })
            }
            if summary.averageLoadPerRepKg != nil || summary.volumePerMinuteKg != nil {
                Divider()
                HStack(alignment: .top) {
                    stat(String(localized: "Load per rep"), summary.averageLoadPerRepKg.map { BodyFormat.number($0) + " kg" } ?? "—", id: "summary-intensity")
                    stat(String(localized: "Work per minute"), summary.volumePerMinuteKg.map { BodyFormat.number($0, digits: 0) + " kg" } ?? "—", id: "summary-density")
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func stat(_ title: String, _ value: String, id: String, footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.footnote).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title3.weight(.semibold)).minimumScaleFactor(0.7).lineLimit(1).accessibilityIdentifier(id)
            if let footnote { Text(verbatim: footnote).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alerts(_ alerts: [TrainingAlert]) -> some View {
        ForEach(Array(alerts.enumerated()), id: \.offset) { _, alert in
            Label { Text(verbatim: alert.message) } icon: { Image(systemName: alert.systemImage).foregroundStyle(Theme.warning) }
                .accessibilityIdentifier("summary-alert")
        }
    }

    private var weekly: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            Picker(String(localized: "Show"), selection: $model.measure) {
                ForEach(StudentSummaryViewModel.WeekMeasure.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("summary-measure")
            Chart(model.chartWeeks) { week in
                BarMark(x: .value("Week", week.weekStart, unit: .weekOfYear), y: .value(model.measure.title, model.chartValue(week)))
                    .foregroundStyle(Theme.accent)
            }
            .chartYAxisLabel(model.measure.unit)
            .frame(height: 170)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func execution(_ summary: TrainingSummary) -> some View {
        if let prescription = summary.prescription {
            row(String(localized: "Sets done"), SummaryFormat.percent(prescription.completionRatio), id: "summary-sets-done",
                detail: String(localized: "\(prescription.setsDone) of \(prescription.setsPrescribed)"))
            if let reps = prescription.repRangeRatio { row(String(localized: "Reps in the planned range"), SummaryFormat.percent(reps), id: "summary-reps-range") }
            if let load = prescription.loadTargetRatio { row(String(localized: "Planned load reached"), SummaryFormat.percent(load), id: "summary-load-target") }
        }
        if let rest = summary.rest {
            row(String(localized: "Rest on target"), SummaryFormat.percent(rest.onTargetRatio), id: "summary-rest",
                detail: String(localized: "\(SummaryFormat.seconds(rest.averageTakenSeconds)) taken · \(SummaryFormat.seconds(rest.averagePrescribedSeconds)) planned"))
        }
    }

    private func row(_ title: String, _ value: String, id: String, detail: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                if let detail { Text(verbatim: detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(verbatim: value).font(.body.weight(.semibold)).accessibilityIdentifier(id)
        }
    }

    private func exercises(_ trends: [ExerciseTrend]) -> some View {
        ForEach(trends) { trend in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: trend.exercise.name)
                    HStack(spacing: 8) {
                        Text(String(localized: "\(trend.sessions) workouts")).foregroundStyle(.secondary)
                        if trend.personalRecords > 0 { Label(String(localized: "\(trend.personalRecords) new bests"), systemImage: "trophy").foregroundStyle(Theme.accent) }
                        if trend.isStagnant { Label(String(localized: "No new best"), systemImage: "equal.circle").foregroundStyle(Theme.warning) }
                    }
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: BodyFormat.number(trend.latestE1RM) + " kg").font(.body.weight(.semibold))
                    if let change = trend.changePercent {
                        Text(verbatim: change.formatted(.number.precision(.fractionLength(0...1)).sign(strategy: .always())) + "%")
                            .font(.caption).foregroundStyle(abs(change) < 0.05 ? Color.secondary : (change > 0 ? Theme.success : Theme.warning))
                    }
                }
            }
            .accessibilityIdentifier("summary-exercise")
        }
    }

    private var muscles: some View {
        ForEach(model.muscleRows, id: \.muscle) { row in
            HStack { Text(verbatim: row.muscle.displayName); Spacer(); Text(verbatim: "\(row.sets)").font(.body.weight(.semibold)) }
        }
    }
}
