import Domain
import SwiftUI

/// History: a month calendar with a mark on every day you trained, and what you did on the selected day underneath.
public struct HistoryView: View {
    private let model: HistoryViewModel
    private let profileButton: AnyView?
    private let calendar: Calendar
    private let embedded: Bool

    /// - Parameter embedded: shown inside someone else's navigation stack (the trainer's student screen): no stack or avatar of its own.
    public init(model: HistoryViewModel, profileButton: AnyView? = nil, calendar: Calendar = .current, embedded: Bool = false) {
        self.model = model
        self.profileButton = profileButton
        self.calendar = calendar
        self.embedded = embedded
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    public var body: some View {
        if embedded { content } else { NavigationStack { content.toolbar { ProfileToolbarSlot(profileButton ?? AnyView(EmptyView())) } } }
    }

    private var content: some View {
        ScrollView {
                VStack(spacing: 20) {
                    monthHeader
                    VStack(spacing: 8) {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                                Text(verbatim: symbol).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(Array(model.cells.enumerated()), id: \.offset) { _, day in
                                if let day { DayCell(day: day, isSelected: day.id == model.selectedDay, calendar: calendar) { model.select(day.id) } }
                                else { Color.clear.frame(height: 42) }
                            }
                        }
                    }
                    .card()

                    sessions
                }
                .padding(16)
                .adaptiveContentWidth()
            }
            .background(Theme.background)
            .navigationTitle(String(localized: "History"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(embedded ? .inline : .automatic)
            #endif
            .task { await model.run() }
    }

    private var monthHeader: some View {
        HStack {
            Button { model.previousMonth() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel(String(localized: "Previous month"))
                .accessibilityIdentifier("history-previous")
            Spacer()
            VStack(spacing: 2) {
                Text(verbatim: model.monthTitle).font(.headline.weight(.semibold)).accessibilityIdentifier("history-month")
                let summary = model.monthSummary
                if summary.workouts > 0 {
                    Text(String(localized: "\(summary.workouts) workouts · \(summary.days) days")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.nextMonth() } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .disabled(!model.canGoForward)
                .accessibilityLabel(String(localized: "Next month"))
                .accessibilityIdentifier("history-next")
        }
    }

    @ViewBuilder private var sessions: some View {
        let items = model.selectedRecords
        if items.isEmpty {
            Text(model.isLoaded && model.monthSummary.workouts == 0
                 ? String(localized: "No workouts this month.")
                 : String(localized: "Pick a day with a mark to see what was done."))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 8)
                .accessibilityIdentifier("history-empty")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let day = model.selectedDay {
                    Text(day, format: .dateTime.weekday(.wide).day().month(.wide)).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(items) { record in
                    NavigationLink {
                        SessionDetailView(record: record, photos: model.photos(for: record))
                    } label: {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: record.title).font(.headline).foregroundStyle(.primary)
                                HStack(spacing: 14) {
                                    if let minutes = record.minutes { Label(String(localized: "\(minutes) min"), systemImage: "clock") }
                                    Label(String(localized: "\(record.totals.workingSets) sets"), systemImage: "list.number")
                                    if record.totals.volumeKg > 0 { Label("\(LoadFormat.kg(record.totals.volumeKg)) kg", systemImage: "scalemass") }
                                }
                                .font(.footnote).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                                HStack(spacing: 10) {
                                    if let rpe = record.rpe { Text(String(localized: "Effort \(rpe)/10")) }
                                    if record.isCoached { Label(String(localized: "With your trainer"), systemImage: "person.2.fill").foregroundStyle(Theme.accent) }
                                }
                                .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .card()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("history-session-\(record.id)")
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: HistoryViewModel.Day
    let isSelected: Bool
    let calendar: Calendar
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: "\(day.number)")
                .font(.subheadline.weight(day.hasWorkout || day.isToday ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.onAccent : (day.hasWorkout ? Theme.accent : Color.primary))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background {
                    if isSelected { Circle().fill(Theme.accent) }
                    else if day.hasWorkout { Circle().fill(Theme.accent.opacity(0.16)) }
                    else if day.isToday { Circle().stroke(Theme.separator, lineWidth: 1.5) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.id.formatted(.dateTime.weekday(.wide).day().month(.wide)) + (day.hasWorkout ? ", " + String(localized: "workout done") : ""))
        .accessibilityIdentifier("day-\(HistoryViewModel.identifier(for: day.id, calendar: calendar))\(day.hasWorkout ? "-done" : "")")
    }
}

/// The workouts that are *not* today's — B, C, D… — collapsed by default; open one to see its exercises. Together with the hero card
/// above it, the student sees every workout in the plan, and nothing is shown twice.
public struct WorkoutListSection: View {
    private let templates: [WorkoutTemplate]

    /// - Parameters:
    ///   - templates: the whole plan, in order.
    ///   - nextID: today's workout (it has the hero card, so it isn't repeated here).
    public init(templates: [WorkoutTemplate], nextID: TemplateID?) {
        self.templates = templates.filter { $0.id != nextID }
    }

    public var body: some View {
        if !templates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Other workouts")).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                VStack(spacing: 0) {
                    ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(template.blocks) { block in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: block.previewTitle).font(.subheadline)
                                        Text(verbatim: block.previewSummary).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: template.label).font(.body.weight(.medium)).foregroundStyle(.primary)
                                Text(String(localized: "\(template.blocks.count) exercises · ~\(template.estimatedMinutes) min")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("workout-row-\(template.id)")
                        if index < templates.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }
        }
    }
}
