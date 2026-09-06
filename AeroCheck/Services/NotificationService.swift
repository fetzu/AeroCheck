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
    /// `nonisolated` because the `UNUserNotificationCenterDelegate` callback that reads it is
    /// nonisolated — it runs wherever the system delivers the tap. A `String` constant is Sendable,
    /// so there is nothing to protect and the isolation was only ever in the way.
    nonisolated private static let threadIdKey = "threadId"

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
    /// somewhere around the after-landing checks — that is `postFlightDelay`, used when the pilot
    /// has already pressed END FLIGHT and is sitting with the app open.
    ///
    /// `landingDelay` is the safety net for the pilot who lands, shuts down and walks away without
    /// pressing anything. It has to be long enough not to fire during the roll-out and short enough
    /// to leave usable margin inside the 30-minute RCC window, so it sits at the halfway mark.
    /// Scheduling replaces by identifier, so a later END FLIGHT simply supersedes it.
    static let postFlightDelay: TimeInterval = 120
    static let landingDelay: TimeInterval = 15 * 60

    func scheduleFlightPlanCloseReminder(threadId: UUID, routeLabel: String,
                                         delay: TimeInterval = NotificationService.postFlightDelay) async {
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
    /// How close to departure the nudge stops being worth sending. Below this the pilot is already
    /// on their way and a "flight tomorrow" banner is noise.
    static let minimumPreparationLead: TimeInterval = 60 * 60

    func schedulePreparationReminder(threadId: UUID,
                                     routeLabel: String,
                                     departure: Date,
                                     leadTime: TimeInterval = 24 * 60 * 60) async {
        guard await hasPermission() else { return }
        let now = Date()
        let ideal = departure.addingTimeInterval(-leadTime)
        // A departure less than the lead time away has already missed the IDEAL moment — but
        // dropping the reminder outright was worse than firing it late. The app's own pre-filled
        // departure is "tomorrow at 10:00", so every planning session after 10:00 (i.e. the normal
        // evening one) produced a fire date in the past and silently got nothing, under UI copy
        // saying the toggle exists precisely because of this reminder. Slide it to a short delay
        // instead, and only give up when the departure itself is too close for the nudge to be
        // worth anything. (review F18)
        let fireDate = ideal > now ? ideal : now.addingTimeInterval(Self.minimumPreparationLead)
        guard fireDate > now, departure.timeIntervalSince(fireDate) >= Self.minimumPreparationLead else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.Thread.prepareReminderTitle
        content.body = L10n.Thread.prepareReminderBody(routeLabel)
        content.sound = .default
        content.userInfo = [Self.threadIdKey: threadId.uuidString]

        // An absolute instant, not wall-clock components. `UNCalendarNotificationTrigger` with no
        // time zone on its components is re-evaluated in whatever zone the device is in when it
        // fires, so a pilot who plans in Switzerland and travels before the flight got the nudge an
        // hour out. The fire date is already known exactly; there is nothing to re-derive.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireDate.timeIntervalSinceNow),
                                                        repeats: false)
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
        // Also clear a banner already sitting in Notification Center — otherwise "Flight tomorrow"
        // outlives the flight being cancelled or deleted, same as the close reminder above.
        center.removeDeliveredNotifications(withIdentifiers: [Identifier.preparation(threadId)])
    }

    /// Everything belonging to one thread, for deletion.
    func cancelAll(threadId: UUID) {
        cancelFlightPlanCloseReminder(threadId: threadId)
        cancelPreparationReminder(threadId: threadId)
    }

    // MARK: - Deferred actions

    /// Actions that arrived before the app could act on them.
    ///
    /// Registering the delegate at launch fixes half the problem; the other half is that the
    /// handlers reach a `FlightThreadManager` whose `threads` array is still being read off disk
    /// (iCloud-backed, so seconds). Both handlers start with a `firstIndex(where:)` that finds
    /// nothing in an empty array and returns silently — so the pilot's "Mark flight plan closed"
    /// was accepted by iOS and then dropped by the app. Queue instead, and replay once the handlers
    /// and the threads exist. (review F17)
    fileprivate enum PendingAction {
        case markClosed(UUID)
        case open(UUID)
    }

    private var pendingActions: [PendingAction] = []

    fileprivate func enqueueOrRun(_ action: PendingAction) {
        switch action {
        case .markClosed(let id):
            guard let handler = markFlightPlanClosedHandler else { pendingActions.append(action); return }
            handler(id)
        case .open(let id):
            guard let handler = openThreadHandler else { pendingActions.append(action); return }
            handler(id)
        }
    }

    /// Replay anything queued before the handlers were wired. Idempotent.
    func drainPendingActions() {
        let queued = pendingActions
        pendingActions = []
        for action in queued { enqueueOrRun(action) }
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
                NotificationService.shared.enqueueOrRun(.markClosed(threadId))
            default:
                // Tapping the notification itself opens the thread.
                NotificationService.shared.enqueueOrRun(.open(threadId))
            }
        }
    }
}
