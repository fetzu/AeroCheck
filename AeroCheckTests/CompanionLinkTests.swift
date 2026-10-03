import XCTest
import CoreLocation
@testable import AeroCheck

/// The Companion link's own life: how it comes back after the phone leaves, after a drop, after the
/// iPad's idle saving, and what the iPad streams over it.
///
/// The managers here are test ones: their own defaults suite and no Wi-Fi Aware. A listener or a browse
/// "starts" (the role and state are set, `listenerStarts` / `browseStarts` count it) and finds nothing;
/// connections are adopted through the same entry points the real ones use, with a send handler that
/// records what would have gone over the air.
@MainActor
final class CompanionLinkTests: XCTestCase {

    /// What the manager sent, in order. Sends happen on tasks of their own, hence the lock.
    final class SentMessages: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [CompanionMessage] = []

        var all: [CompanionMessage] { lock.withLock { messages } }
        func of(_ type: CompanionMessage.MessageType) -> [CompanionMessage] { all.filter { $0.type == type } }
        func clear() { lock.withLock { messages.removeAll() } }

        var handler: @Sendable (CompanionMessage) async throws -> Void {
            { [self] message in lock.withLock { messages.append(message) } }
        }
    }

    private struct Companion {
        let manager: CompanionConnectivityManager
        let appState: AppState
        /// Held here: the manager keeps its data sources weakly.
        let location: LocationManager
        let plans: FlightPlanManager
    }

    private func makeCompanion(role: CompanionRole) -> Companion {
        let manager = CompanionConnectivityManager(defaults: makeTestDefaults(), usesWiFiAware: false)
        let appState = makeTestAppState()
        appState.settings.enableCompanionMode = true
        let location = LocationManager()
        let plans = makeTestPlanManager()
        manager.configure(appState: appState, locationManager: location, flightPlanManager: plans)
        manager.pairedDevices = [CompanionPairedDevice(name: "Other device", pairingName: nil, deviceIDs: [7])]
        manager.currentRole = role
        addTeardownBlock { @MainActor in
            manager.disconnect()
            if appState.isFlightActive { appState.cancelFlight() }
        }
        return Companion(manager: manager, appState: appState, location: location, plans: plans)
    }

    /// The iPad listening, and the phone's connection taken.
    private func connectedMaster(sent: SentMessages = SentMessages()) throws -> (Companion, Int) {
        let companion = makeCompanion(role: .master)
        companion.manager.startListening()
        let generation = try XCTUnwrap(companion.manager.adoptMasterConnection(
            identity: CompanionPeerIdentity(deviceID: 7, name: "Pilot's iPhone"), send: sent.handler))
        return (companion, generation)
    }

    /// The phone looking for the iPad, and its connection made.
    private func connectedViewer(sent: SentMessages = SentMessages()) throws -> (Companion, Int) {
        let companion = makeCompanion(role: .viewer)
        companion.manager.connectToPairedDevice()
        let generation = companion.manager.connectionGeneration
        XCTAssertTrue(companion.manager.adoptViewerConnection(
            identity: CompanionPeerIdentity(deviceID: 3, name: "Club iPad"), generation: generation, send: sent.handler))
        return (companion, generation)
    }

    private var goodbye: CompanionMessage { CompanionMessage(type: .disconnect, payload: Data()) }

    /// Polls `condition` on the main actor until it holds or `timeout` runs out.
    private func eventually(within timeout: TimeInterval = 3, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: - The phone leaves and comes back (6.1.0)

    /// Companion mode off on the phone sends a goodbye. The iPad went "disconnected" on it, with its old
    /// listener still up but never taking the phone's next connection, and only toggling Companion mode
    /// on the iPad brought the phone back.
    func testTheIPadListensAgainWhenThePhoneLeaves() async throws {
        let (companion, generation) = try connectedMaster()
        let manager = companion.manager
        let starts = manager.listenerStarts

        XCTAssertFalse(manager.handleReceivedMessage(goodbye, generation: generation),
                       "the connection that said goodbye is not read any further")
        XCTAssertEqual(manager.connectionState, .connecting, "waiting for the phone, not disconnected")
        XCTAssertEqual(manager.currentRole, .master)
        XCTAssertNil(manager.peerLink)
        XCTAssertNil(manager.connectedDeviceName)

        // The goodbye's connection then closes; its receive loop's teardown comes in late.
        manager.handleDisconnection(generation: generation, reason: .receiveEnded)

        let rearmed = try await eventually { manager.listenerStarts == starts + 1 }
        XCTAssertTrue(rearmed, "a fresh listener")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(manager.listenerStarts, starts + 1, "once: the late teardown does not re-arm again")

        // Companion mode back on on the phone: its next connection is taken, nothing touched on the iPad.
        let next = try XCTUnwrap(manager.adoptMasterConnection(identity: CompanionPeerIdentity(deviceID: 7, name: nil),
                                                               send: { _ in }))
        XCTAssertGreaterThan(next, generation)
        XCTAssertEqual(manager.connectionState, .connected)
    }

    /// A drop the iPad notices itself (silence) re-arms once, whatever the dropped connection does after.
    func testADropReArmsTheListenerOnce() async throws {
        let (companion, generation) = try connectedMaster()
        let manager = companion.manager
        let starts = manager.listenerStarts

        manager.checkConnectionHealth(now: Date().addingTimeInterval(60))
        XCTAssertEqual(manager.connectionState, .connecting)
        manager.handleDisconnection(generation: generation, reason: .receiveEnded)
        XCTAssertFalse(manager.handleReceivedMessage(goodbye, generation: generation), "its frames are stale too")

        let rearmed = try await eventually { manager.listenerStarts == starts + 1 }
        XCTAssertTrue(rearmed)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(manager.listenerStarts, starts + 1)
        XCTAssertEqual(manager.connectionState, .connecting)
    }

    /// The idle saving (10 min up, no flight) ends the link and tells the phone, but the iPad listens on,
    /// so the phone can come back on its own later. It used to stop listening too.
    func testTheIdleSavingKeepsTheIPadListening() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        let manager = companion.manager
        XCTAssertFalse(companion.appState.isFlightActive)

        manager.checkConnectionHealth(now: Date().addingTimeInterval(-601))   // idle since then
        XCTAssertEqual(manager.connectionState, .connected)
        manager.checkConnectionHealth()
        XCTAssertEqual(manager.connectionState, .connecting, "listening, not disconnected")
        XCTAssertEqual(manager.currentRole, .master)
        let told = try await eventually { !sent.of(.disconnect).isEmpty }
        XCTAssertTrue(told, "the phone is told, so it stops until it is used again")

        let starts = manager.listenerStarts
        let rearmed = try await eventually { manager.listenerStarts == starts + 1 }
        XCTAssertTrue(rearmed)
        XCTAssertNotNil(manager.adoptMasterConnection(identity: CompanionPeerIdentity(deviceID: 7, name: nil),
                                                      send: { _ in }),
                        "the phone's next connection is taken")
    }

    func testAFlightKeepsTheLinkUpPastTheIdleTime() throws {
        let (companion, _) = try connectedMaster()
        companion.appState.settings.selectedRemoteAircraftId = nil
        companion.appState.settings.selectedAircraft = .wt9Dynamic
        companion.appState.startFlight()
        XCTAssertTrue(companion.appState.isFlightActive)
        companion.manager.checkConnectionHealth(now: Date().addingTimeInterval(-601))
        companion.manager.checkConnectionHealth()
        XCTAssertEqual(companion.manager.connectionState, .connected)
    }

    // MARK: - A listener that fails is started again (6.1.0)

    func testAFailedListenerIsRetriedNotAbandoned() async throws {
        let companion = makeCompanion(role: .master)
        let manager = companion.manager
        manager.startListening()
        let starts = manager.listenerStarts

        manager.listenerFailed(CocoaError(.featureUnsupported))
        XCTAssertEqual(manager.connectionState, .connecting, "still waiting for a phone: it was left disconnected")
        let retried = try await eventually(within: 4) { manager.listenerStarts == starts + 1 }
        XCTAssertTrue(retried, "another listener after the pause")
    }

    func testARetryPendingWhenTheUserDisconnectsStartsNothing() async throws {
        let companion = makeCompanion(role: .master)
        let manager = companion.manager
        manager.startListening()
        manager.listenerFailed(CocoaError(.featureUnsupported))
        manager.disconnect()
        let starts = manager.listenerStarts

        try await Task.sleep(for: .milliseconds(2_500))
        XCTAssertEqual(manager.listenerStarts, starts)
        XCTAssertEqual(manager.connectionState, .disconnected)
    }

    func testAListenerErrorUnderALiveLinkChangesNothing() throws {
        let (companion, _) = try connectedMaster()
        companion.manager.listenerFailed(CocoaError(.featureUnsupported))
        XCTAssertEqual(companion.manager.connectionState, .connected)
    }

    func testTheListenerRetryBacksOff() {
        let delays = (1...7).map { CompanionConnectivityManager.listenerRetryDelay(afterFailures: $0) }
        XCTAssertEqual(delays, [2, 4, 8, 16, 30, 30, 30])
    }

    // MARK: - The iPad ends the link (6.1.0)

    func testThePhoneStopsWhenTheIPadEndsTheLink() async throws {
        let (companion, generation) = try connectedViewer()
        let manager = companion.manager
        let browses = manager.browseStarts

        XCTAssertFalse(manager.handleReceivedMessage(goodbye, generation: generation))
        XCTAssertEqual(manager.connectionState, .disconnected, "the iPad said goodbye: no retry loop")
        manager.handleDisconnection(generation: generation, reason: .receiveEnded)
        XCTAssertEqual(manager.connectionState, .disconnected, "the closed connection's teardown is stale")

        try await Task.sleep(for: .milliseconds(2_500))
        XCTAssertEqual(manager.browseStarts, browses, "nothing looks for the iPad until the phone is used")
    }

    // MARK: - Riding out a short drop (6.1.0)

    /// Any frame from the iPad, as the phone hears it.
    private var aFrameFromTheIPad: CompanionMessage {
        CompanionMessage(type: .checklistUpdate, payload: Data(#"{"phaseTitle":"Taxi"}"#.utf8))
    }

    /// Two keep-alives lost in a row (5 s) ended the link; the stale banner still comes at 5 s, the
    /// link goes at 10.
    func testASilenceOfAFewSecondsKeepsTheLink() throws {
        let (companion, _) = try connectedMaster()
        let manager = companion.manager
        manager.checkConnectionHealth(now: Date().addingTimeInterval(6))
        XCTAssertEqual(manager.connectionState, .connected)
        XCTAssertEqual(CompanionTiming.streamStaleAfter, 5, "the banner's window is unchanged")
        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.linkSilenceLimit + 1))
        XCTAssertEqual(manager.connectionState, .connecting, "ten seconds of silence: the link goes")
    }

    func testAFewFailedSendsDoNotEndTheLink() throws {
        let (companion, generation) = try connectedMaster()
        let manager = companion.manager
        let now = Date()
        // One bad second: the flight data, the checklist and the plan.
        for offset in [0.0, 0.3, 0.9] {
            manager.noteSendFailure(generation: generation, error: CocoaError(.featureUnsupported),
                                    now: now.addingTimeInterval(offset))
        }
        XCTAssertEqual(manager.connectionState, .connected, "three failures in a row ended the link")
        manager.noteSendFailure(generation: generation, error: CocoaError(.featureUnsupported),
                                now: now.addingTimeInterval(CompanionTiming.linkSilenceLimit + 1))
        XCTAssertEqual(manager.connectionState, .connecting, "failing for ten seconds does")
    }

    /// The phone looking for the iPad again after a drop used to read `.connecting`, which the root
    /// shows the phone's ground screen for: it flashed on every short drop.
    func testAShortDropKeepsTheCompanionScreenUp() async throws {
        let (companion, generation) = try connectedViewer()
        let manager = companion.manager
        manager.handleReceivedMessage(aFrameFromTheIPad, generation: generation)
        let browses = manager.browseStarts

        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.linkSilenceLimit + 1))
        XCTAssertEqual(manager.connectionState, .reconnecting, "the Companion screen, its banner on")
        XCTAssertEqual(manager.currentRole, .viewer)

        let lookedAgain = try await eventually { manager.browseStarts == browses + 1 }
        XCTAssertTrue(lookedAgain, "looking for the iPad again")
        XCTAssertEqual(manager.connectionState, .reconnecting, "and still on the Companion screen while it does")

        // The iPad answers: back.
        XCTAssertTrue(manager.adoptViewerConnection(identity: CompanionPeerIdentity(deviceID: 3, name: nil),
                                                    generation: manager.connectionGeneration, send: { _ in }))
        manager.handleReceivedMessage(aFrameFromTheIPad, generation: manager.connectionGeneration)
        XCTAssertEqual(manager.connectionState, .connected)
    }

    func testTheCompanionScreenGivesWayAfterTheGrace() {
        let now = Date()
        XCTAssertEqual(CompanionTiming.reconnectGrace, 30)
        XCTAssertEqual(CompanionConnectivityManager.viewerLookingState(linkLostAt: now.addingTimeInterval(-29), now: now),
                       .reconnecting)
        XCTAssertEqual(CompanionConnectivityManager.viewerLookingState(linkLostAt: now.addingTimeInterval(-31), now: now),
                       .connecting, "past the grace: the phone's own screens, still looking")
        XCTAssertEqual(CompanionConnectivityManager.viewerLookingState(linkLostAt: nil, now: now), .connecting,
                       "no drop (a first connection): the phone's own screens")
    }

    /// A connection that never hears from the iPad went to a listener that is gone: given up after 5 s,
    /// and, never having been a link, it does not hold the Companion screen up.
    func testAConnectionTheIPadNeverAnswersIsGivenUpSooner() throws {
        let (companion, _) = try connectedViewer()
        let manager = companion.manager
        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.firstFrameLimit - 1))
        XCTAssertEqual(manager.connectionState, .connected)
        manager.checkConnectionHealth(now: Date().addingTimeInterval(CompanionTiming.firstFrameLimit + 1))
        XCTAssertEqual(manager.connectionState, .connecting)
    }

    // MARK: - Back from the background (6.1.0)

    func testBackFromTheBackgroundTheIPadListensAfresh() {
        let companion = makeCompanion(role: .master)
        let manager = companion.manager
        manager.startListening()
        let starts = manager.listenerStarts

        manager.appBecameActive()
        XCTAssertEqual(manager.listenerStarts, starts, "a system sheet gone: nothing restarted")
        manager.appWentToBackground()
        manager.appBecameActive()
        XCTAssertEqual(manager.listenerStarts, starts + 1, "a listener left over a suspension is started afresh")
        XCTAssertEqual(manager.connectionState, .connecting)
    }

    func testBackFromTheBackgroundThePhoneLooksAfresh() {
        let companion = makeCompanion(role: .viewer)
        let manager = companion.manager
        manager.connectToPairedDevice()
        let browses = manager.browseStarts
        manager.appWentToBackground()
        manager.appBecameActive()
        XCTAssertEqual(manager.browseStarts, browses + 1)
    }

    func testBackInTheForegroundWithNothingRunningAutoConnects() {
        // How a phone the iPad said goodbye to comes back: when it is used.
        let companion = makeCompanion(role: .viewer)
        let manager = companion.manager
        XCTAssertEqual(manager.connectionState, .disconnected)
        manager.appWentToBackground()
        manager.appBecameActive()
        XCTAssertNotEqual(manager.connectionState, .disconnected, "auto-connect started a listener or a browse")
    }

    // MARK: - The plan reaches the phone (6.1.0)

    /// LSZQ → LSZB at 5,000 ft and 100 kt, leaving in an hour: ETOs to anchor.
    private func armedPlan(on plans: FlightPlanManager) -> FlightPlan {
        var plan = FlightPlan(name: "LSZQ → LSZB", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.392, longitude: 7.030)),
            FlightPlanWaypoint(name: "LSZB", coordinate: .init(latitude: 46.914, longitude: 7.497)),
        ])
        plan.plannedDepartureTime = Date().addingTimeInterval(3_600)
        for i in plan.waypoints.indices {
            plan.waypoints[i].altitude = 5_000
            plan.waypoints[i].plannedGroundSpeed = 100
        }
        plan.calculateRouteData()
        plans.add(plan)
        plans.activateFlightPlan(plan)
        addTeardownBlock { @MainActor in plans.stopChronometer() }
        return plan
    }

    /// The last plan the phone was sent, decoded as the phone decodes it.
    private func lastPlan(_ sent: SentMessages) throws -> CompanionFlightPlanSnapshot? {
        try sent.of(.flightPlanUpdate).last.map {
            try JSONDecoder().decode(CompanionFlightPlanSnapshot.self, from: $0.payload)
        }
    }

    /// READY FOR LINE UP anchors the ETOs on the iPad. The phone showed --:-- until a reconnect sent it
    /// the whole plan again: the iPad resent the plan only for a new plan, a diversion, or once a
    /// waypoint had a time over.
    func testETOsAnchoredBeforeTheTakeoffReachThePhoneOnTheNextTick() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        let plan = armedPlan(on: companion.plans)
        let now = Date()
        companion.manager.streamTick(now: now)
        let first = try await eventually { !sent.of(.flightPlanUpdate).isEmpty }
        XCTAssertTrue(first)

        let lineUp = now.addingTimeInterval(120)
        companion.plans.anchorETOsOnLineUp(lineUp)
        let anchored = try XCTUnwrap(companion.plans.activeFlightPlan?.waypoints.last?.estimatedTimeOver)
        XCTAssertNotEqual(anchored, plan.waypoints.last?.estimatedTimeOver, "the anchor moved the ETOs")
        XCTAssertNil(companion.plans.activeFlightPlan?.waypoints.first { $0.actualTimeOver != nil },
                     "no time over yet: what kept the old check from sending")

        companion.manager.streamTick(now: now.addingTimeInterval(1))
        let arrived = try await eventually { (try? self.lastPlan(sent))??.waypoints.last?.estimatedTimeOver == anchored }
        XCTAssertTrue(arrived, "the anchored ETO goes on the next tick")
    }

    func testATimeOverTakenBackReachesThePhone() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        _ = armedPlan(on: companion.plans)
        var now = Date()
        companion.manager.streamTick(now: now)

        var marked = try XCTUnwrap(companion.plans.activeFlightPlan)
        marked.waypoints[0].actualTimeOver = now
        companion.plans.updateFlightPlan(marked)
        now += 1
        companion.manager.streamTick(now: now)
        let markSent = try await eventually { (try? self.lastPlan(sent))??.waypoints.first?.actualTimeOver != nil }
        XCTAssertTrue(markSent)

        // UNDO: no time over left anywhere, which the old check took for "nothing to send".
        var undone = marked
        undone.waypoints[0].actualTimeOver = nil
        companion.plans.updateFlightPlan(undone)
        now += 1
        companion.manager.streamTick(now: now)
        let undoSent = try await eventually {
            let plan = (try? self.lastPlan(sent)) ?? nil
            return plan != nil && plan?.waypoints.first?.actualTimeOver == nil
        }
        XCTAssertTrue(undoSent, "the phone sees the time over go")
    }

    func testAnUnchangedPlanIsSentAgainEveryFewSeconds() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        _ = armedPlan(on: companion.plans)
        let now = Date().addingTimeInterval(100)   // ahead of the stream's own timer
        companion.manager.streamTick(now: now)
        let first = try await eventually { sent.of(.flightPlanUpdate).count == 1 }
        XCTAssertTrue(first)

        companion.manager.streamTick(now: now.addingTimeInterval(1))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sent.of(.flightPlanUpdate).count, 1, "unchanged and not due: not sent")

        companion.manager.streamTick(now: now.addingTimeInterval(CompanionTiming.snapshotRefresh))
        let again = try await eventually { sent.of(.flightPlanUpdate).count == 2 }
        XCTAssertTrue(again, "due again: a datagram lost over UDP is not resent otherwise")
    }

    func testPlanSnapshotsDifferOnTheirTimes() {
        func snapshot(eto: Date?, ato: Date?) -> CompanionFlightPlanSnapshot {
            let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let wp = CompanionWaypoint(id: id, name: "LSZB", latitude: 46.9, longitude: 7.5, altitude: 1_700,
                                       frequency: nil, magneticCourse: 140, distance: 22, plannedGroundSpeed: 100,
                                       estimatedElapsedTime: 800, legEETExtra: nil, cumulativeEET: 800,
                                       estimatedTimeOver: eto, actualTimeOver: ato, remarks: "")
            return CompanionFlightPlanSnapshot(planId: id, planName: "Plan", waypoints: [wp], currentWaypointIndex: 0,
                                               totalDistance: 22, totalEET: 800, plannedDepartureTime: nil,
                                               chronometerStartTime: nil)
        }
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(snapshot(eto: t, ato: nil), snapshot(eto: t, ato: nil))
        XCTAssertNotEqual(snapshot(eto: nil, ato: nil), snapshot(eto: t, ato: nil), "an ETO is a change")
        XCTAssertNotEqual(snapshot(eto: t, ato: nil), snapshot(eto: t.addingTimeInterval(60), ato: nil))
        XCTAssertNotEqual(snapshot(eto: t, ato: t), snapshot(eto: t, ato: nil), "so is a time over taken back")
    }

    // MARK: - The checklist reaches the phone (6.1.0)

    /// The last checklist the phone was sent, decoded as the phone decodes it.
    private func lastChecklist(_ sent: SentMessages) throws -> CompanionChecklistSnapshot? {
        try sent.of(.checklistUpdate).last.map {
            try JSONDecoder().decode(CompanionChecklistSnapshot.self, from: $0.payload)
        }
    }

    /// A flight on the WT9 with the Memory test on: its TAXI is a memory check, the check before it a list.
    private func memoryTestFlight(_ appState: AppState) throws {
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = false
        appState.settings.stepByStepHighlighting = true
        appState.startFlight()
        try XCTSkipUnless(appState.isMemoryCheck(.taxi), "needs the WT9's memory checks")
        XCTAssertFalse(appState.isMemoryCheck(.afterEngineStart))
    }

    /// The check slot rides in the checklist snapshot as JSON, and JSONEncoder's key order changes from
    /// one encode to the next: every snapshot in flight differed from the last, so the "only when it
    /// changed" check never held there. Sorted keys, the same bytes.
    func testTheCheckSlotEncodesTheSameEveryTime() throws {
        let companion = makeCompanion(role: .master)
        try memoryTestFlight(companion.appState)
        companion.appState.currentPhase = .taxi
        let snapshots = (0..<20).map { _ in
            CompanionConnectivityManager.checklistSnapshot(of: companion.appState, mayStreamItemText: true)
        }
        XCTAssertNotNil(snapshots[0].checkSlotData)
        XCTAssertTrue(snapshots.allSatisfy { $0 == snapshots[0] })
    }

    /// The state goes at once when the phone connects, through the stream itself.
    func testThePhoneGetsTheStateTheMomentItConnects() async throws {
        let sent = SentMessages()
        _ = try connectedMaster(sent: sent)
        let both = try await eventually { !sent.of(.checklistUpdate).isEmpty && !sent.of(.flightData).isEmpty }
        XCTAssertTrue(both, "no tick needed")
    }

    /// The first memory check after the start showed on the phone as a list to tick. Likely: the phone
    /// still had the check before it, the update that moved on lost on the way, and an unchanged
    /// checklist was never sent again. It now is, every few seconds.
    func testAMemoryCheckReachesThePhoneEvenWhenItsFirstUpdateIsLost() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedMaster(sent: sent)
        try memoryTestFlight(companion.appState)
        let now = Date().addingTimeInterval(100)   // ahead of the stream's own timer
        companion.appState.currentPhase = .afterEngineStart
        companion.manager.streamTick(now: now)

        companion.appState.currentPhase = .taxi
        companion.manager.streamTick(now: now.addingTimeInterval(1))
        let moved = try await eventually { (try? self.lastChecklist(sent))??.memoryCheck == true }
        XCTAssertTrue(moved, "the move goes on the tick after it")
        sent.clear()   // ... and is lost on the way

        companion.manager.streamTick(now: now.addingTimeInterval(2))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sent.of(.checklistUpdate).isEmpty, "unchanged: not every second")

        companion.manager.streamTick(now: now.addingTimeInterval(1 + CompanionTiming.snapshotRefresh))
        let healed = try await eventually { (try? self.lastChecklist(sent)) != nil }
        XCTAssertTrue(healed, "sent again")
        let checklist = try XCTUnwrap(try lastChecklist(sent))
        XCTAssertEqual(checklist.phaseRawValue, ChecklistPhase.taxi.rawValue)
        XCTAssertTrue(checklist.memoryCheck, "a memory check, which the phone confirms with ✓ DONE")
        XCTAssertTrue(checklist.supportsMemoryConfirm)
        XCTAssertFalse(checklist.memoryCheckDone)
        XCTAssertTrue(checklist.items.isEmpty, "nothing to tick")
    }

    func testTheLinkEndsAreLoggedAsFixedText() {
        let ends: [CompanionConnectivityManager.LinkEnd] = [.peerLeft, .silence(12), .noFirstFrame, .sendFailing,
                                                            .receiveEnded, .idle(minutes: 10), .forgotten]
        XCTAssertEqual(ends.map(\.text), ["the peer left", "nothing heard for 12 s", "the iPad never answered",
                                          "sends failing", "the connection closed", "idle 10 min with no flight",
                                          "the device was forgotten"])
    }

    // MARK: - A listener restart waits for the old one (6.1.0)

    func testARestartWaitsForTheOldListenerToEnd() async {
        let quick = Task<Void, any Error> { try await Task.sleep(for: .milliseconds(200)) }
        let start = ContinuousClock.now
        let ended = await CompanionConnectivityManager.waitForEnd(of: quick, upTo: .seconds(3))
        XCTAssertTrue(ended)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "no longer than the old listener takes")
    }

    func testARestartDoesNotWaitForeverForAListenerThatHangs() async {
        let hung = Task<Void, any Error> { try? await Task.sleep(for: .seconds(60)) }
        defer { hung.cancel() }
        let start = ContinuousClock.now
        let ended = await CompanionConnectivityManager.waitForEnd(of: hung, upTo: .milliseconds(500))
        XCTAssertFalse(ended)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "the limit holds")
    }

    // MARK: - The phone's goodbye reaches the iPad (6.1.0)

    func testThePhonesGoodbyeGoesOutBeforeItsConnectionCloses() async {
        let connection = Task<Void, any Error> { try await Task.sleep(for: .seconds(60)) }
        let sent = SentMessages()
        let closedBeforeTheGoodbye = SentFlag()
        let send: @Sendable (CompanionMessage) async throws -> Void = { message in
            if connection.isCancelled { closedBeforeTheGoodbye.set() }
            try await Task.sleep(for: .milliseconds(50))   // a send takes a moment on the radio
            try await sent.handler(message)
        }
        let went = await CompanionConnectivityManager.sayGoodbye(goodbye, on: send, thenClose: connection,
                                                                 upTo: .seconds(2))
        XCTAssertTrue(went)
        XCTAssertEqual(sent.of(.disconnect).count, 1, "the iPad is told")
        XCTAssertFalse(closedBeforeTheGoodbye.isSet, "the connection was still open when the goodbye left")
        XCTAssertTrue(connection.isCancelled, "and closed after it")
    }

    func testAGoodbyeThatHangsDoesNotKeepTheConnectionOpen() async {
        let connection = Task<Void, any Error> { try await Task.sleep(for: .seconds(60)) }
        let hangs: @Sendable (CompanionMessage) async throws -> Void = { _ in try? await Task.sleep(for: .seconds(30)) }
        let start = ContinuousClock.now
        let went = await CompanionConnectivityManager.sayGoodbye(goodbye, on: hangs, thenClose: connection,
                                                                 upTo: .milliseconds(300))
        XCTAssertFalse(went)
        XCTAssertTrue(connection.isCancelled, "closed anyway")
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testAPhoneThatDisconnectsTellsTheIPad() async throws {
        let sent = SentMessages()
        let (companion, _) = try connectedViewer(sent: sent)
        companion.manager.disconnect()
        let told = try await eventually { !sent.of(.disconnect).isEmpty }
        XCTAssertTrue(told)
    }

    final class SentFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
