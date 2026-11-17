import Foundation

/// Trainer-dashboard view of "did the student do what was prescribed?".
public struct AdherenceReport: Equatable, Sendable {
    public let sessionsExpected: Int
    public let sessionsCompleted: Int
    public let setsPrescribed: Int
    public let setsCompleted: Int
    public let repsTarget: Int
    public let repsCompleted: Int
    public let averagePrescribedRestSeconds: Double?
    public let averageActualRestSeconds: Double?
    /// Share of timed sets whose rest landed within 75 %…150 % of the prescription.
    public let restComplianceRate: Double?

    public var sessionAdherence: Double { sessionsExpected == 0 ? 0 : min(1, Double(sessionsCompleted) / Double(sessionsExpected)) }
    public var setCompletion: Double { setsPrescribed == 0 ? 0 : Double(setsCompleted) / Double(setsPrescribed) }
    public var repCompletion: Double { repsTarget == 0 ? 0 : Double(repsCompleted) / Double(repsTarget) }
}

public struct AdherenceCalculator: Sendable {
    public var restTolerance: ClosedRange<Double>

    public init(restTolerance: ClosedRange<Double> = 0.75...1.5) {
        self.restTolerance = restTolerance
    }

    /// - Parameter interval: the reporting window (e.g. the last 4 weeks).
    public func report(plan: WorkoutPlan, logs: [WorkoutLog], interval: DateInterval) -> AdherenceReport {
        let weeks = max(1, Int((interval.duration / (7 * 86_400)).rounded(.up)))
        let expected = plan.targetSessionsPerWeek * weeks

        let sessions = logs.filter {
            $0.planID == plan.id && $0.status == .completed && !$0.meta.isDeleted && interval.contains($0.effectiveDate)
        }

        var setsPrescribed = 0, setsCompleted = 0, repsTarget = 0, repsCompleted = 0
        var prescribedRest: [Double] = []
        var actualRest: [Double] = []
        var restHits = 0, restSamples = 0

        for session in sessions {
            guard let template = plan.template(id: session.templateID) else { continue }
            for case .resistance(let block) in template.blocks {
                setsPrescribed += block.sets.count
                repsTarget += block.sets.reduce(0) { $0 + $1.repsMin }
                prescribedRest.append(Double(block.restSeconds))

                guard let logged = session.blocks.compactMap({ entry -> ResistanceLog? in
                    if case .resistance(let log) = entry, log.blockID == block.id { return log }
                    return nil
                }).first else { continue }

                let working = logged.sets.filter { !$0.isWarmup }
                setsCompleted += min(working.count, block.sets.count)
                repsCompleted += working.reduce(0) { $0 + $1.reps }

                for set in working {
                    guard let rest = set.restTakenSeconds, block.restSeconds > 0 else { continue }
                    actualRest.append(Double(rest))
                    restSamples += 1
                    if restTolerance.contains(Double(rest) / Double(block.restSeconds)) { restHits += 1 }
                }
            }
        }

        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }

        return AdherenceReport(sessionsExpected: expected,
                               sessionsCompleted: sessions.count,
                               setsPrescribed: setsPrescribed,
                               setsCompleted: setsCompleted,
                               repsTarget: repsTarget,
                               repsCompleted: repsCompleted,
                               averagePrescribedRestSeconds: mean(prescribedRest),
                               averageActualRestSeconds: mean(actualRest),
                               restComplianceRate: restSamples == 0 ? nil : Double(restHits) / Double(restSamples))
    }
}
