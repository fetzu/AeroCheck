import UserNotifications
import XCTest
@testable import AeroCheck

/// What a notification does with the app open: a banner, except in flight outside Preflight and At the
/// Hangar, when it waits in Notification Center for the flight to get there or end. (6.2.0, the author,
/// device check 7 Oct)
@MainActor
final class NotificationPresentationTests: XCTestCase {
    private var savedGate: (() -> Bool)?

    override func setUp() async throws {
        savedGate = NotificationService.shared.mayInterrupt
    }

    override func tearDown() async throws {
        NotificationService.shared.mayInterrupt = savedGate
        NotificationService.shared.releaseHeld()
    }

    func testOnlyPreflightAndAtTheHangarMayInterruptAFlight() {
        for phase in ChecklistPhase.allCases {
            let calm = phase == .preflight || phase == .hangar
            XCTAssertEqual(NotificationPresentationRule.mayInterrupt(isFlightActive: true, phase: phase), calm, "\(phase)")
            XCTAssertTrue(NotificationPresentationRule.mayInterrupt(isFlightActive: false, phase: phase), "no flight, \(phase)")
        }
    }

    func testAHeldNotificationWaitsInNotificationCentreThenShows() {
        let service = NotificationService.shared
        var calm = false
        service.mayInterrupt = { calm }
        let content = UNMutableNotificationContent()
        content.title = "Flight tomorrow"
        let request = UNNotificationRequest(identifier: "test.\(UUID().uuidString).prepare", content: content, trigger: nil)

        XCTAssertEqual(service.presentation(for: request), [.list], "in Notification Center only")
        XCTAssertEqual(service.presentation(for: request), [.list])
        XCTAssertEqual(service.held.map(\.identifier), [request.identifier], "held once")

        service.releaseHeld()
        XCTAssertEqual(service.held.count, 1, "still in flight: kept")

        calm = true
        XCTAssertEqual(service.presentation(for: request), [.banner, .sound], "At the Hangar: a banner")
        service.releaseHeld()
        XCTAssertTrue(service.held.isEmpty, "shown again once a banner may interrupt")
    }

    func testANotificationOpenedMeanwhileIsNotShownAgain() {
        let service = NotificationService.shared
        service.mayInterrupt = { false }
        let request = UNNotificationRequest(identifier: "test.\(UUID().uuidString).fplClose", content: UNNotificationContent(),
                                            trigger: nil)
        XCTAssertEqual(service.presentation(for: request), [.list])
        service.forgetHeld(identifier: request.identifier)
        XCTAssertTrue(service.held.isEmpty)
    }

    func testWithoutAGateEveryBannerShows() {
        NotificationService.shared.mayInterrupt = nil
        let request = UNNotificationRequest(identifier: "test.\(UUID().uuidString)", content: UNNotificationContent(), trigger: nil)
        XCTAssertEqual(NotificationService.shared.presentation(for: request), [.banner, .sound])
    }
}
