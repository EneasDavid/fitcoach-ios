import Domain
import SwiftUI

/// One finished workout, in full: when, how long, how it felt, then every exercise with every set — load, reps, effort, rest, time of day —
/// next to what the plan asked for. The student reads it as their record; the trainer reads the same screen for the student.
public struct SessionDetailView: View {
    private let record: SessionRecord
    private let photos: [SharedPhoto]

    public init(record: SessionRecord, photos: [SharedPhoto] = []) {
        self.record = record
        self.photos = photos
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                totals
                ForEach(record.blocks) { block in
                    switch block {
                    case .resistance(let exercise): ResistanceCard(exercise: exercise)
                    case .hiit(let hiit): hiitCard(hiit)
                    case .cardio(let cardio): cardioCard(cardio)
                    }
                }
                if !photos.isEmpty { photoStrip }
                if let note = record.note {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Note")).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        Text(verbatim: note)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                    .accessibilityIdentifier("session-note")
                }
            }
            .padding(16)
            .adaptiveContentWidth()
        }
        .background(Theme.background)
        .navigationTitle(record.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.startedAt, format: .dateTime.weekday(.wide).day().month(.wide).year()).font(.headline)
            HStack(spacing: 10) {
                if let end = record.completedAt {
                    Text(String(localized: "\(record.startedAt.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"))
                }
                if let minutes = record.minutes { Text(String(localized: "\(minutes) min")) }
                if let rpe = record.rpe { Text(String(localized: "Effort \(rpe)/10")) }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if let focus = record.focus { Label(focus.title, systemImage: focus == .strength ? "dumbbell" : "repeat").foregroundStyle(Theme.accent) }
                if record.isCoached { Label(String(localized: "With your trainer"), systemImage: "person.2.fill").foregroundStyle(Theme.accent) }
            }
            .font(.footnote.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("session-header")
    }

    private var totals: some View {
        HStack(alignment: .top) {
            total(String(localized: "Sets"), "\(record.totals.workingSets)", id: "session-total-sets")
            total(String(localized: "Reps"), "\(record.totals.reps)", id: "session-total-reps")
            total(String(localized: "Volume"), "\(LoadFormat.kg(record.totals.volumeKg)) kg", id: "session-total-volume")
            if let rest = record.totals.averageRestSeconds { total(String(localized: "Avg. rest"), SummaryFormat.seconds(rest), id: "session-total-rest") }
        }
        .card()
    }

    private func total(_ title: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.headline).minimumScaleFactor(0.7).lineLimit(1).accessibilityIdentifier(id)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hiitCard(_ hiit: SessionRecord.HIITRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: hiit.title).font(.headline)
            Text(String(localized: "\(hiit.rounds) rounds · \(SummaryFormat.seconds(hiit.seconds))")).font(.subheadline).foregroundStyle(.secondary)
            if let bpm = hiit.heartRate { Label("\(bpm) bpm", systemImage: "heart").font(.footnote).foregroundStyle(.secondary) }
            if let rpe = hiit.rpe { Text(String(localized: "Effort \(BodyFormat.number(rpe))/10")).font(.footnote).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func cardioCard(_ cardio: SessionRecord.CardioRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: cardio.modality).font(.headline)
            HStack(spacing: 12) {
                Text(verbatim: SummaryFormat.seconds(cardio.seconds))
                if let km = cardio.distanceKm { Text(verbatim: BodyFormat.number(km, digits: 2) + " km") }
                if let bpm = cardio.heartRate { Label("\(bpm) bpm", systemImage: "heart") }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var photoStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Photos")).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(photos, id: \.id) { item in
                        if let image = Avatar.image(from: item.photo) {
                            image.resizable().scaledToFill().frame(width: 140, height: 140).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .accessibilityLabel(String(localized: "Photo"))
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("session-photos")
    }
}

private struct ResistanceCard: View {
    let exercise: SessionRecord.ResistanceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: exercise.exercise).font(.headline).accessibilityIdentifier("session-exercise")
                if let replaced = exercise.replaced { Text(String(localized: "Replaced \(replaced)")).font(.footnote).foregroundStyle(Theme.warning) }
                if let prescription = exercise.prescription { Text(String(localized: "Plan: \(prescription)")).font(.footnote).foregroundStyle(.secondary) }
            }
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text(String(localized: "Set")).gridColumnAlignment(.leading)
                    Text(String(localized: "Load"))
                    Text(String(localized: "Reps"))
                    Text(String(localized: "Effort"))
                    Text(String(localized: "Rest"))
                    Text(String(localized: "Time"))
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(exercise.sets) { set in
                    GridRow {
                        Text(verbatim: set.isWarmup ? String(localized: "Warm-up") : "\(set.number)").gridColumnAlignment(.leading)
                            .foregroundStyle(set.isWarmup ? Color.secondary : Color.primary)
                            .accessibilityIdentifier("session-set")
                        Text(verbatim: "\(LoadFormat.kg(set.weightKg)) kg").foregroundStyle(set.loadReached == false ? Theme.warning : Color.primary)
                        Text(verbatim: set.prescribedReps.map { "\(set.reps) / \($0)" } ?? "\(set.reps)").foregroundStyle(set.repsInRange == false ? Theme.warning : Color.primary)
                        Text(verbatim: set.rpe.map { BodyFormat.number($0) } ?? "—")
                        Text(verbatim: set.restSeconds.map(SummaryFormat.seconds) ?? "—")
                        Text(set.time, format: .dateTime.hour().minute())
                    }
                    .font(.subheadline.monospacedDigit())
                }
            }
            HStack {
                Text(String(localized: "Volume \(LoadFormat.kg(exercise.volumeKg)) kg")).foregroundStyle(.secondary)
                Spacer()
                if let e1RM = exercise.bestE1RM { Text(String(localized: "Est. 1RM \(LoadFormat.kg(e1RM)) kg")).foregroundStyle(.secondary) }
            }
            .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
