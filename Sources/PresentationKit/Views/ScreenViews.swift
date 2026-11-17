import Charts
import Domain
import SwiftUI

// MARK: - Progression chart (trainer dashboard)

/// Working sessions form the line; deload sessions are drawn as hollow diamonds *off* the line, so a
/// planned light week is visibly "not a regression" and never drags the curve down.
public struct ProgressionChartView: View {
    private let series: ProgressionSeries

    public init(series: ProgressionSeries) {
        self.series = series
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            Chart {
                ForEach(series.trendPoints) { point in
                    if let e1rm = point.bestE1RMKg {
                        LineMark(x: .value("Date", point.date), y: .value("Estimated 1RM (kg)", e1rm))
                            .foregroundStyle(by: .value("Session", "Working"))
                        PointMark(x: .value("Date", point.date), y: .value("Estimated 1RM (kg)", e1rm))
                            .foregroundStyle(by: .value("Session", "Working"))
                    }
                }
                ForEach(series.deloadPoints) { point in
                    if let e1rm = point.bestE1RMKg {
                        PointMark(x: .value("Date", point.date), y: .value("Estimated 1RM (kg)", e1rm))
                            .symbol(.diamond)
                            .foregroundStyle(by: .value("Session", "Deload (excluded)"))
                    }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(minHeight: 200)
            .accessibilityIdentifier("progression-chart")
        }
    }

    private var summary: some View {
        HStack(spacing: 16) {
            switch series.verdict {
            case .progressing: Label(String(localized: "Progressing"), systemImage: "arrow.up.right").foregroundStyle(.green)
            case .plateau: Label(String(localized: "Plateau"), systemImage: "arrow.right").foregroundStyle(.orange)
            case .regressing: Label(String(localized: "Regressing"), systemImage: "arrow.down.right").foregroundStyle(.red)
            case .insufficientData: Label(String(localized: "Not enough data"), systemImage: "ellipsis").foregroundStyle(.secondary)
            }
            if let trend = series.trend {
                Text(String(format: "%+.1f%% / week", trend.slopePercentPerWeek)).font(.footnote.monospacedDigit())
            }
            if !series.personalRecords.isEmpty {
                Label("\(series.personalRecords.count) PR", systemImage: "trophy").font(.footnote)
            }
        }
        .font(.subheadline.weight(.semibold))
    }
}

// MARK: - Sync badge

/// Truthful "pending / offline / synced" indicator driven by the dispatcher's status stream.
public struct SyncBadge: View {
    private let pending: Int
    private let isOnline: Bool
    private let failed: Int

    public init(pending: Int, failed: Int = 0, isOnline: Bool) {
        self.pending = pending
        self.failed = failed
        self.isOnline = isOnline
    }

    public var body: some View {
        Group {
            if failed > 0 {
                Label(String(localized: "\(failed) failed"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if !isOnline {
                Label(pending > 0 ? String(localized: "Offline · \(pending) waiting") : String(localized: "Offline"), systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            } else if pending > 0 {
                Label(String(localized: "Syncing \(pending)"), systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
            } else {
                Label(String(localized: "Up to date"), systemImage: "checkmark.icloud").foregroundStyle(.green)
            }
        }
        .font(.caption.weight(.medium))
        .accessibilityIdentifier("sync-badge")
    }
}
