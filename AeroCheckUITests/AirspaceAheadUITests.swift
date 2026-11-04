import XCTest

/// AIRSPACE AHEAD (6.9.0, the page's ah-*) flown on the simulator's own airspace, which only a seeded simulator holds
/// (`CockpitPilot.onDeviceData`). ahead-grenchen goes LSZQ → W1 → GATE → X → LSZG at 4,500 ft: GATE is on the west
/// boundary of Grenchen's CTR, class D, so the mark wp2 is the moment the flight enters it.
final class AirspaceAheadUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// ah-1: the information state about five minutes out. ah-2: a tap opens what is at the entry. ah-3: amber from two
    /// minutes out, the minutes counting down. ah-4: gone once inside, with no flicker on the way.
    func testGrenchensCTRAheadThenInside() throws {
        let pilot = try CockpitPilot.onDeviceData(self, scenario: "ahead-grenchen", page: "690")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.departToClimb() else { return XCTFail("never reached the climb check") }
        pilot.showPane("map")

        let entry = s.mark("wp2")
        var tapped = false, amberShot = false
        let log = SlotEntry.watch(pilot, untilTrack: entry + 60) { reading in
            if !amberShot, reading.isCaution {
                amberShot = true
                pilot.shot("ah-3", "amber")
            }
            guard !tapped, reading.isAhead(of: "GRENCHEN"), !reading.isCaution, pilot.trackNow > entry - 280 else { return }
            tapped = true
            pilot.shot("ah-1", "information")
            pilot.tap(reading.identifier, timeout: 2)
            let card = pilot.waitFor("map.airspaceStack", timeout: 3) != nil
            pilot.shot("ah-2", "card")
            pilot.check("ah-2", card, "the slot's tap opens the airspace at the entry, at \(Int(pilot.trackNow)) s")
            pilot.check("ah-2", !pilot.texts(containing: "GRENCHEN").isEmpty,
                        "the card names Grenchen: \(pilot.texts(containing: "GRENCHEN"))")
            pilot.app.buttons["Close"].firstMatch.tap()
        }
        pilot.attach(SlotEntry.summary(log), name: "slot-ahead-grenchen")
        pilot.observed("ah-4", "the slot along the flight: \(SlotEntry.summary(log))")

        let grenchen = log.filter { $0.isAhead(of: "GRENCHEN") }
        let information = grenchen.first { !$0.isCaution }
        pilot.check("ah-1", information.map { $0.t >= entry - 330 && $0.t <= entry - 150 } ?? false,
                    "information \(information.map { "\"\($0.label)\" \(Int(entry - $0.t)) s before the CTR" } ?? "never shown")")

        let amber = grenchen.first { $0.isCaution }
        pilot.check("ah-3", amber.map { $0.t >= entry - 150 && $0.t <= entry } ?? false,
                    "amber \(amber.map { "\"\($0.label)\" \(Int(entry - $0.t)) s before the CTR" } ?? "never shown")")
        let minutes = grenchen.compactMap { CockpitPilot.minutes(in: $0.label) }
        pilot.check("ah-3", minutes.count > 1 && minutes == minutes.sorted(by: >), "the minutes count down: \(minutes)")
        if let amber {
            let back = grenchen.first { $0.t > amber.t && !$0.isCaution }
            pilot.check("ah-3", back == nil, "amber never steps back: \(back.map { "\($0)" } ?? "held")")
        }

        // Sixty seconds past the boundary: inside, and the fifteen seconds' hold is over.
        let inside = log.filter { $0.t > entry + 30 && $0.isAhead(of: "GRENCHEN") }
        pilot.check("ah-4", !grenchen.isEmpty && inside.isEmpty,
                    "inside the CTR: \(inside.isEmpty ? "no longer shown" : SlotEntry.summary(inside))")
        let spans = SlotEntry.spans(of: grenchen, in: log)
        pilot.check("ah-4", spans <= 1, "no flicker: \(spans) stretch(es) of the CTR's state")
    }
}

/// One change of MAP's status slot, as a replay reads it. Shared with the departure reminder's replays.
struct SlotEntry: CustomStringConvertible {
    let t: Double
    let identifier: String
    let label: String

    var state: String { identifier.replacingOccurrences(of: "status.", with: "") }
    var isCaution: Bool { identifier.hasSuffix(".caution") }
    func isAhead(of name: String) -> Bool { state.hasPrefix("airspaceAhead") && label.uppercased().contains(name) }
    var description: String { "\(Int(t)) s \(state) \"\(label)\"" }

    /// The slot watched on MAP until the track reaches `t`: an entry at each change, dark included. `each` is asked once
    /// at each new entry and may tap.
    static func watch(_ pilot: CockpitPilot, untilTrack t: Double, each: ((SlotEntry) -> Void)? = nil) -> [SlotEntry] {
        var log: [SlotEntry] = []
        var last: String?
        _ = pilot.waitUntil(timeout: max(1, (t - pilot.trackNow) / pilot.rate)) {
            let shown = pilot.mapStatus
            let key = shown.map { "\($0.state)|\($0.label)" } ?? "dark"
            guard key != last else { return false }
            last = key
            let entry = SlotEntry(t: pilot.trackNow, identifier: shown.map { "status.\($0.state)" } ?? "dark",
                                  label: shown?.label ?? "")
            log.append(entry)
            each?(entry)
            return false
        }
        return log
    }

    static func summary(_ log: [SlotEntry]) -> String {
        log.map(\.description).joined(separator: " → ")
    }

    /// How many unbroken stretches `some` makes in `log`: a state that drops and comes back counts twice. The pilot's own
    /// UNDO may cover it for six seconds without breaking it.
    static func spans(of some: [SlotEntry], in log: [SlotEntry]) -> Int {
        let times = Set(some.map(\.t))
        var count = 0, inside = false
        for entry in log {
            if times.contains(entry.t) {
                if !inside { count += 1 }
                inside = true
            } else if entry.state != "undo" {
                inside = false
            }
        }
        return count
    }
}
