import Observation
import SwiftUI

/// Decides whether videos may start by themselves and whether the UI may animate.
///
/// **Reduce motion & data.** When the student switches it on — or the phone is *not on Wi-Fi* (cellular / hotspot / Low Data Mode,
/// which iOS reports as "expensive" or "constrained") — videos start **paused** and download only after a tap, and decorative
/// animations are dropped. The Wi-Fi rule is automatic: nobody should burn their mobile data on a demo clip without choosing to.
/// Low Power Mode and the system's *Reduce Motion* switch are honoured the same way.
@MainActor
@Observable
public final class MediaPolicy {
    public enum Reason: Equatable, Sendable {
        case yourSetting, mobileData, lowPowerMode, reduceMotion

        public var caption: String {
            switch self {
            case .yourSetting: return String(localized: "Paused to save data · tap to play")
            case .mobileData: return String(localized: "Not on Wi-Fi · tap to play")
            case .lowPowerMode: return String(localized: "Low Power Mode · tap to play")
            case .reduceMotion: return String(localized: "Reduce Motion is on · tap to play")
            }
        }
    }

    /// The student's own switch.
    public var dataSaverEnabled: Bool
    /// `true` on Wi-Fi/ethernet; `false` on cellular, personal hotspot or Low Data Mode.
    public var isUnmetered: Bool
    public var isLowPowerMode: Bool
    public var isReduceMotion: Bool

    public init(dataSaverEnabled: Bool = false, isUnmetered: Bool = true, isLowPowerMode: Bool = false, isReduceMotion: Bool = false) {
        self.dataSaverEnabled = dataSaverEnabled
        self.isUnmetered = isUnmetered
        self.isLowPowerMode = isLowPowerMode
        self.isReduceMotion = isReduceMotion
    }

    /// Why videos are not starting by themselves (the first matching reason), or `nil` when they may.
    public var pauseReason: Reason? {
        if dataSaverEnabled { return .yourSetting }
        if !isUnmetered { return .mobileData }
        if isLowPowerMode { return .lowPowerMode }
        if isReduceMotion { return .reduceMotion }
        return nil
    }

    public var allowsAutoplay: Bool { pauseReason == nil }
    /// Posters are data too: skipped while saving data.
    public var allowsPosterDownload: Bool { pauseReason == nil || pauseReason == .lowPowerMode || pauseReason == .reduceMotion }
    public var animationsEnabled: Bool { !dataSaverEnabled && !isReduceMotion }

    public func animation(_ base: Animation) -> Animation? { animationsEnabled ? base : nil }
}
