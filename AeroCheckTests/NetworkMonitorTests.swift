import XCTest
@testable import AeroCheck

/// Unit tests for the v4.1.0 data-freshness connectivity policy. `DataRefreshGate` is pure, so every
/// branch is covered without a live network; `NetworkMonitor(stub:)` verifies the published snapshot
/// and convenience forwards.
final class NetworkMonitorTests: XCTestCase {

    private let wifi = NetworkConditions(isConnected: true, isWiFi: true, isExpensive: false, isConstrained: false)
    private let cellular = NetworkConditions(isConnected: true, isWiFi: false, isExpensive: true, isConstrained: false)
    private let cellularLowData = NetworkConditions(isConnected: true, isWiFi: false, isExpensive: true, isConstrained: true)
    private let wifiLowData = NetworkConditions(isConnected: true, isWiFi: true, isExpensive: false, isConstrained: true)
    private let offline = NetworkConditions.disconnected

    // MARK: - Small silent-refresh gate

    func testSmallRefreshAllowedOnWiFiRegardlessOfToggle() {
        XCTAssertTrue(DataRefreshGate.allowsSilentSmallRefresh(wifi, cellularUpdatesEnabled: true))
        XCTAssertTrue(DataRefreshGate.allowsSilentSmallRefresh(wifi, cellularUpdatesEnabled: false))
    }

    func testSmallRefreshOnCellularFollowsToggle() {
        XCTAssertTrue(DataRefreshGate.allowsSilentSmallRefresh(cellular, cellularUpdatesEnabled: true))
        XCTAssertFalse(DataRefreshGate.allowsSilentSmallRefresh(cellular, cellularUpdatesEnabled: false))
    }

    func testSmallRefreshNeverOnLowDataMode() {
        // Low Data Mode blocks a *silent* refresh even on Wi-Fi and even with cellular updates enabled.
        XCTAssertFalse(DataRefreshGate.allowsSilentSmallRefresh(wifiLowData, cellularUpdatesEnabled: true))
        XCTAssertFalse(DataRefreshGate.allowsSilentSmallRefresh(cellularLowData, cellularUpdatesEnabled: true))
    }

    func testSmallRefreshNeverWhenOffline() {
        XCTAssertFalse(DataRefreshGate.allowsSilentSmallRefresh(offline, cellularUpdatesEnabled: true))
    }

    // MARK: - Tile-download gate

    func testTileDownloadAllowedOnWiFiWithoutConfirmation() {
        XCTAssertTrue(DataRefreshGate.allowsTileDownload(wifi, userConfirmedCellular: false))
    }

    func testTileDownloadOnCellularRequiresConfirmation() {
        XCTAssertFalse(DataRefreshGate.allowsTileDownload(cellular, userConfirmedCellular: false))
        XCTAssertTrue(DataRefreshGate.allowsTileDownload(cellular, userConfirmedCellular: true))
    }

    func testTileDownloadNeverWhenOffline() {
        XCTAssertFalse(DataRefreshGate.allowsTileDownload(offline, userConfirmedCellular: true))
    }

    // MARK: - Monitor snapshot

    @MainActor
    func testStubMonitorPublishesSeededConditionsAndForwards() {
        let monitor = NetworkMonitor(stub: cellularLowData)
        XCTAssertEqual(monitor.conditions, cellularLowData)
        XCTAssertTrue(monitor.isConnected)
        XCTAssertFalse(monitor.isWiFi)
        XCTAssertTrue(monitor.isExpensive)
        XCTAssertTrue(monitor.isConstrained)
    }

    func testDisconnectedDefaultIsAllFalse() {
        let d = NetworkConditions.disconnected
        XCTAssertFalse(d.isConnected || d.isWiFi || d.isExpensive || d.isConstrained)
    }
}
