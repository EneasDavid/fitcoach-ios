import Network
import PresentationKit
import UIKit

/// Feeds `MediaPolicy` with what the phone is doing: **is it on Wi-Fi?** (not cellular / hotspot / Low Data Mode), Low Power Mode,
/// and the system's Reduce Motion switch. This is what makes "reduce motion & data" kick in by itself off Wi-Fi.
@MainActor
final class MediaEnvironmentObserver {
    private let policy: MediaPolicy
    private let monitor = NWPathMonitor()
    private var tokens: [NSObjectProtocol] = []
    /// `-UITestCellular`: pretend to be on mobile data (the simulator is always on the Mac's Wi-Fi/ethernet).
    private let forceCellular: Bool

    init(policy: MediaPolicy, forceCellular: Bool = false) {
        self.policy = policy
        self.forceCellular = forceCellular
    }

    func start() {
        policy.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        policy.isReduceMotion = UIAccessibility.isReduceMotionEnabled
        policy.isUnmetered = !forceCellular

        monitor.pathUpdateHandler = { [weak self] path in
            // "Expensive" = cellular or a personal hotspot; "constrained" = Low Data Mode. Neither is Wi-Fi we may spend freely.
            let unmetered = !(path.isExpensive || path.isConstrained)
            Task { @MainActor in
                guard let self else { return }
                self.policy.isUnmetered = unmetered && !self.forceCellular
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.fitcoach.media-path"))

        tokens.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.policy.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
        tokens.append(NotificationCenter.default.addObserver(forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.policy.isReduceMotion = UIAccessibility.isReduceMotionEnabled }
        })
    }

    deinit {
        monitor.cancel()
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}
