import AudioToolbox
import Domain
import Foundation
import PresentationKit
import UIKit
import UserNotifications

// NOT COMPILED IN THE AUTHORING ENVIRONMENT (UIKit / iOS SDK) — see README → "Verification status".

/// `LocalNotificationScheduling` over `UNUserNotificationCenter`.
struct UserNotificationScheduler: LocalNotificationScheduling {
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func post(_ notification: LocalNotification) async throws {
        try await center.add(Self.request(for: notification))
    }

    func cancel(ids: [String]) async throws {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    /// Replaces the pending set for one category atomically-enough for reminders: remove ours, add the new ones.
    /// iOS caps pending local notifications at 64; reminders are bounded by `CadenceAnalyzer.horizonDays` (7).
    func replacePending(category: String, with notifications: [LocalNotification]) async throws {
        let pending = await center.pendingNotificationRequests()
        let stale = pending.filter { $0.content.categoryIdentifier == category }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for notification in notifications {
            try await center.add(Self.request(for: notification))
        }
    }

    private static func request(for notification: LocalNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = notification.category
        content.userInfo = notification.userInfo
        content.interruptionLevel = notification.category == LocalNotification.arrivalCategory ? .timeSensitive : .active

        let trigger: UNNotificationTrigger
        if let date = notification.fireDate {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)   // "now"
        }
        return UNNotificationRequest(identifier: notification.id, content: content, trigger: trigger)
    }
}

/// Haptics, sound and the background rest alert for `PresentationKit`.
@MainActor
final class SystemFeedback: FeedbackProviding {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let notification = UINotificationFeedbackGenerator()
    private let restAlertID = "rest.alert"

    func warning() { notification.notificationOccurred(.warning) }

    func setLogged() {
        light.impactOccurred()
    }

    func restFinished() {
        notification.notificationOccurred(.success)
        AudioServicesPlaySystemSound(1057)                  // short "tink"; respects the silent switch via system sounds
    }

    func intervalChanged() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        AudioServicesPlaySystemSound(1104)
    }

    /// While the app is suspended the in-app timer can't fire, so a local notification covers the end of rest.
    func scheduleRestAlert(at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Rest is over")
        content.body = String(localized: "Time for your next set.")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: restAlertID, content: content, trigger: trigger))
    }

    func cancelRestAlert() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [restAlertID])
    }
}

/// Foreground presentation + notification taps → deep links (`fitcoach://workout/start?checkIn=…`).
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private let continuation: AsyncStream<URL>.Continuation
    let deepLinks: AsyncStream<URL>

    override init() {
        (deepLinks, continuation) = AsyncStream.makeStream(of: URL.self)
        super.init()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let raw = response.notification.request.content.userInfo["deeplink"] as? String, let url = URL(string: raw), url.scheme == "fitcoach" {
            continuation.yield(url)     // only our own scheme is ever routed
        }
    }
}
