import Foundation
import UserNotifications

/// Local notifications for the flight thread. The app's first use of `UserNotifications` — everything
/// notification-shaped before this was an in-app banner, which is exactly why the one reminder that
/// matters (close your flight plan) could not exist.
///
/// Two reminders, and deliberately only two:
///
///  * **Close your flight plan.** Scheduled the moment a full-stop landing is detected on a thread
///    whose plan was filed. Skyguide's RCC alerts 30 minutes after the ETA on an unclosed VFR plan,
///    so this is the one piece of admin with a search-and-rescue consequence for forgetting it.
///  * **Preparation nudge.** A day before a scheduled departure, when there is still time to call for
///    PPR or file a plan.
///
/// Anything else the thread tracks is checked when the pilot opens the app; a companion that pings
/// all day gets its notifications turned off, and then the one that mattered is gone too.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    /// Whether the user has granted permission. Read for UI copy; never gate scheduling on a stale
    /// copy of it — `schedule…` re-checks with the system.
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Installed by the app so a notification action can reach the thread manager without this
    /// service knowing about it. Same indirection the app already uses for
    /// `FlightPlan.magneticDeclinationProvider`.
    var markFlightPlanClosedHandler: ((UUID) -> Void)?
    /// Called when the pilot taps the notification body, so the app can open that thread.
    var openThreadHandler: ((UUID) -> Void)?

    private let center = UNUserNotificationCenter.current()

    private enum Identifier {
        static func fplClose(_ threadId: UUID) -> String { "thread.\(threadId.uuidString).fplClose" }
        static func preparation(_ threadId: UUID) -> String { "thread.\(threadId.uuidString).prepare" }
    }

    private enum Category {
        static let flightPlanClose = "AEROCHECK_FPL_CLOSE"
    }

    private enum Action {
        static let markClosed = "AEROCHECK_MARK_FPL_CLOSED"
    }

    /// Userinfo key carrying the thread this notification belongs to.
    private static let threadIdKey = "threadId"

    private override init() {
        super.init()
    }

    // MARK: - Setup

    /// Registers the delegate and the actionable category. Safe to call more than once.
    func configure() {
        center.delegate = self
        let markClosed = UNNotificationAction(
            identifier: Action.markClosed,
            title: L10n.Thread.markFlightPlanClosed,
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Category.flightPlanClose,
            actions: [markClosed],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Ask for permission. Called when the pilot first follows a flight, not at launch — a cold
    /// permission prompt before the feature has been used is how you get denied.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            return granted
        } catch {
            AppLog.general.debugLine("Notification authorization failed: \(error.localizedDescription)")
            await refreshAuthorizationStatus()
            return false
        }
    }

    private func hasPermission() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    // MARK: - Scheduling

    /// Fire the close-your-flight-plan reminder shortly after landing.
    ///
    /// `delay` is small but non-zero on purpose: the aircraft is still rolling out when the detector
    /// fires, and a notification at that moment is both useless and distracting. Two minutes puts it
    /// somewhere around the after-landing checks.
    func scheduleFlightPlanCloseReminder(threadId: UUID, routeLabel: String, delay: TimeInterval = 120) async {
        guard await hasPermission() else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.Thread.closeFlightPlanTitle
        content.body = L10n.Thread.closeFlightPlanBody(routeLabel)
        content.sound = .default
        content.categoryIdentifier = Category.flightPlanClose
        content.userInfo = [Self.threadIdKey: threadId.uuidString]
        // Degrades to a normal notification when the time-sensitive entitlement is not provisioned,
        // so this is safe to set unconditionally.
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
        let request = UNNotificationRequest(identifier: Identifier.fplClose(threadId),
                                            content: content,
                                            trigger: trigger)
        do {
            try await center.add(request)
            AppLog.general.debugLine("Scheduled flight-plan close reminder for thread \(threadId)")
        } catch {
            AppLog.general.debugLine("Failed to schedule close reminder: \(error.localizedDescription)")
        }
    }

    /// Nudge the pilot a day before departure, while there is still time to act on what it finds.
    func schedulePreparationReminder(threadId: UUID,
                                     routeLabel: String,
                                     departure: Date,
                                     leadTime: TimeInterval = 24 * 60 * 60) async {
        guard await hasPermission() else { return }
        let fireDate = departure.addingTimeInterval(-leadTime)
        // A departure less than the lead time away has already missed this reminder; scheduling it in
        // the past would deliver it immediately, which reads as a bug.
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.Thread.prepareReminderTitle
        content.body = L10n.Thread.prepareReminderBody(routeLabel)
        content.sound = .default
        content.userInfo = [Self.threadIdKey: threadId.uuidString]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: Identifier.preparation(threadId),
                                            content: content,
                                            trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            AppLog.general.debugLine("Failed to schedule preparation reminder: \(error.localizedDescription)")
        }
    }

    // MARK: - Cancellation

    /// Drop the close reminder — the plan was closed, or the thread was finished or deleted.
    func cancelFlightPlanCloseReminder(threadId: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [Identifier.fplClose(threadId)])
        center.removeDeliveredNotifications(withIdentifiers: [Identifier.fplClose(threadId)])
    }

    func cancelPreparationReminder(threadId: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [Identifier.preparation(threadId)])
    }

    /// Everything belonging to one thread, for deletion.
    func cancelAll(threadId: UUID) {
        cancelFlightPlanCloseReminder(threadId: threadId)
        cancelPreparationReminder(threadId: threadId)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {

    /// Show the reminder even with the app in the foreground: a pilot who is looking at the app after
    /// landing is exactly the person who still has to close the plan.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let raw = userInfo[NotificationService.threadIdKey] as? String,
              let threadId = UUID(uuidString: raw) else { return }
        let actionIdentifier = response.actionIdentifier

        await MainActor.run {
            switch actionIdentifier {
            case "AEROCHECK_MARK_FPL_CLOSED":
                NotificationService.shared.markFlightPlanClosedHandler?(threadId)
            default:
                // Tapping the notification itself opens the thread.
                NotificationService.shared.openThreadHandler?(threadId)
            }
        }
    }
}
