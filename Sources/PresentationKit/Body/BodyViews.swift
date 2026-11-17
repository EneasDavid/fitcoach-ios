import Charts
import Domain
import SwiftUI

/// The student's body: weight, height and BMI up top, the trainer's bioimpedance readings below. The trainer can add a measurement;
/// the student sees the same screen read-only.
public struct BodyView: View {
    private let model: StudentBodyViewModel

    public init(model: StudentBodyViewModel) { self.model = model }

    public var body: some View {
        List {
            Section { summary }
            if model.showsChart { Section { chart } }
            Section {
                if model.entries.isEmpty && model.isLoaded {
                    Text(model.canEdit ? String(localized: "No measurements yet. Add the first one after a bioimpedance reading.")
                                       : String(localized: "Your trainer hasn't added a body measurement yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.entries, id: \.id) { entry in
                    NavigationLink {
                        BodyEntryView(entry: entry, heightCm: model.snapshot.heightCm)
                    } label: { row(entry) }
                    .accessibilityIdentifier("body-entry")
                }
            } header: { if !model.entries.isEmpty { Text(String(localized: "Measurements")) } }
        }
        .navigationTitle(String(localized: "Body"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if model.canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.startAdding() } label: { Label(String(localized: "Add measurement"), systemImage: "plus") }
                        .accessibilityIdentifier("add-measurement")
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.isAdding }, set: { model.isAdding = $0 })) { BodyMeasurementSheet(model: model) }
        .task { await model.load() }
    }

    private var summary: some View {
        let snapshot = model.snapshot
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                stat(String(localized: "Weight"), snapshot.weightKg.map { BodyFormat.number($0) + " kg" } ?? "—", id: "body-weight",
                     footnote: snapshot.weightChangeKg.map { BodyFormat.signedKg($0) })
                stat(String(localized: "Height"), snapshot.heightCm.map { BodyFormat.number($0) + " cm" } ?? "—", id: "body-height")
                stat(String(localized: "BMI"), snapshot.bmi.map { BodyFormat.bmi($0) } ?? "—", id: "body-bmi", footnote: snapshot.bmiCategory?.title)
            }
            if let latest = snapshot.latest, !latest.hasOnlyWeight {
                Divider()
                HStack(alignment: .top) {
                    stat(String(localized: "Body fat"), latest.resolvedBodyFatPercent.map { BodyFormat.number($0) + " %" } ?? "—", id: "body-fat")
                    stat(String(localized: "Lean mass"), latest.leanMassKg.map { BodyFormat.number($0) + " kg" } ?? "—", id: "body-lean")
                    stat(String(localized: "Fat mass"), latest.fatMassKg.map { BodyFormat.number($0) + " kg" } ?? "—", id: "body-fat-mass")
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

    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.availableMetrics.count > 1 {
                Picker(String(localized: "Show"), selection: Binding(get: { model.chartMetric }, set: { model.chartMetric = $0 })) {
                    ForEach(model.availableMetrics, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("body-chart-metric")
            }
            Chart(model.chartPoints) { point in
                LineMark(x: .value("Date", point.date), y: .value(model.chartMetric.title, point.value)).foregroundStyle(Theme.accent)
                PointMark(x: .value("Date", point.date), y: .value(model.chartMetric.title, point.value)).foregroundStyle(Theme.accent)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel(model.chartMetric.unit)
            .frame(height: 180)
        }
        .padding(.vertical, 4)
    }

    private func row(_ entry: BodyCompositionCheckpoint) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.recordedAt, format: .dateTime.day().month(.abbreviated).year()).font(.body)
                if let fat = entry.resolvedBodyFatPercent {
                    Text(String(localized: "Body fat \(BodyFormat.number(fat)) %")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: BodyFormat.number(entry.bodyWeightKg) + " kg").font(.body.weight(.medium))
                if let change = model.weightChange(for: entry) { Text(verbatim: BodyFormat.signedKg(change)).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Every value of one measurement.
public struct BodyEntryView: View {
    private let entry: BodyCompositionCheckpoint
    private let heightCm: Double?

    public init(entry: BodyCompositionCheckpoint, heightCm: Double?) {
        self.entry = entry
        self.heightCm = heightCm
    }

    public var body: some View {
        List {
            Section {
                ForEach(Array(entry.displayRows(heightCm: heightCm).enumerated()), id: \.offset) { _, row in
                    HStack { Text(verbatim: row.title).foregroundStyle(.secondary); Spacer(); Text(verbatim: row.value) }
                }
            }
            if let notes = entry.notes {
                Section { Text(verbatim: notes) } header: { Text(String(localized: "Notes")) }
            }
        }
        .navigationTitle(Text(entry.recordedAt, format: .dateTime.day().month(.abbreviated).year()))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// The form after a bioimpedance reading. Only the weight is required: scales differ, and a trainer may have just a few numbers.
public struct BodyMeasurementSheet: View {
    private let model: StudentBodyViewModel
    @Environment(\.dismiss) private var dismiss

    public init(model: StudentBodyViewModel) { self.model = model }

    public var body: some View {
        @Bindable var draft = model.draft
        NavigationStack {
            Form {
                Section {
                    DatePicker(String(localized: "Date"), selection: $draft.date, in: ...Date(), displayedComponents: [.date])
                    field(.weight, $draft.weight, id: "measurement-weight")
                    if let bmi = draft.bmiPreview(heightCm: model.snapshot.heightCm) {
                        HStack {
                            Text(String(localized: "BMI")).foregroundStyle(.secondary)
                            Spacer()
                            Text(verbatim: BodyFormat.bmi(bmi)).accessibilityIdentifier("measurement-bmi")
                        }
                    }
                }
                Section {
                    field(.bodyFat, $draft.bodyFat, id: "measurement-bodyfat")
                    field(.fatMass, $draft.fatMass, id: "measurement-fatmass")
                    field(.leanMass, $draft.leanMass, id: "measurement-leanmass")
                    field(.muscleMass, $draft.muscleMass, id: "measurement-muscle")
                    field(.water, $draft.water, id: "measurement-water")
                    field(.visceral, $draft.visceral, id: "measurement-visceral", decimals: false)
                    field(.bone, $draft.bone, id: "measurement-bone")
                    field(.metabolicRate, $draft.metabolicRate, id: "measurement-bmr", decimals: false)
                    field(.metabolicAge, $draft.metabolicAge, id: "measurement-metabolic-age", decimals: false)
                } header: { Text(String(localized: "Bioimpedance")) } footer: {
                    Text(String(localized: "Fill in what the scale gave you. Fat and lean mass are worked out from the body-fat percentage when you leave them blank."))
                }
                Section {
                    field(.waist, $draft.waist, id: "measurement-waist")
                    field(.hip, $draft.hip, id: "measurement-hip")
                } header: { Text(String(localized: "Tape measurements")) }
                Section {
                    TextField(String(localized: "Notes"), text: $draft.notes, axis: .vertical).lineLimit(1...4)
                }
                if let message = model.errorMessage {
                    Section { Text(verbatim: message).foregroundStyle(.red).accessibilityIdentifier("measurement-error") }
                }
            }
            .navigationTitle(String(localized: "Add measurement"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) { Task { await model.save() } }
                        .disabled(!draft.canSave || model.isSaving)
                        .accessibilityIdentifier("save-measurement")
                }
            }
        }
        .tint(Theme.accent)
    }

    private func field(_ field: BodyMeasurementDraft.Field, _ text: Binding<String>, id: String, decimals: Bool = true) -> some View {
        let invalid = model.draft.unreadable.contains(field)
        return HStack {
            Text(verbatim: field.title).foregroundStyle(invalid ? Color.red : Color.primary)
            Spacer()
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(decimals ? .decimalPad : .numberPad)
                #endif
                .frame(maxWidth: 110)
                .accessibilityIdentifier(id)
        }
    }
}
