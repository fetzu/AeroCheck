import SwiftUI
import XCTest
import CoreLocation
@testable import AeroCheck

/// The act band (6.2): four slots under every page of the Cockpit, in four frames that never move, the
/// roles following the page and the flight. Until 6.2 each pane had a thumb bar of its own, and the
/// checklist's laid itself out again with the phase: CHECK at the right end, the phase's action, FREDA
/// or the circuit buttons coming and going, so nothing stayed where the thumb had learned it.
@MainActor
final class CockpitActBandTests: XCTestCase {

    // MARK: - Roles

    private let everyPhase = ChecklistPhase.allCases

    func testOnTheChecklistCHECKIsSecondDEFERThirdAndMoreLastInEveryPhase() {
        for phase in everyPhase {
            for route in [false, true] {
                for circuits in [false, true] {
                    for diverting in [false, true] {
                        let roles = ActBandRoles.make(page: .checklist, phase: phase, hasRoute: route,
                                                      diverting: diverting, circuits: circuits)
                        let where_ = "\(phase), route \(route), circuits \(circuits), diverting \(diverting)"
                        XCTAssertEqual(roles.count, 4, where_)
                        XCTAssertEqual(roles[1], .checklistPrimary, where_)
                        XCTAssertEqual(roles[2], .deferItem(enabled: true), where_)
                        XCTAssertEqual(roles[3], .more(withDivert: route), "Divert in More with a leg to fly: \(where_)")
                    }
                }
            }
        }
    }

    func testTheChecklistsFirstSlotIsThePhasesActionThenFREDAThenTheCheckSlot() {
        func first(_ phase: ChecklistPhase, circuits: Bool = false) -> ActSlotRole {
            ActBandRoles.make(page: .checklist, phase: phase, hasRoute: true, circuits: circuits)[0]
        }
        XCTAssertEqual(first(.engineStart), .engineStart)
        XCTAssertEqual(first(.shutdown), .engineShutdown)
        XCTAssertEqual(first(.cruise), .freda)
        XCTAssertEqual(first(.cruise, circuits: true), .checkSlot, "no FREDA in circuits")
        for phase in everyPhase where ![.engineStart, .shutdown, .cruise].contains(phase) {
            XCTAssertEqual(first(phase), .checkSlot, "\(phase): the check slot, its tap the current item (Q11)")
            XCTAssertEqual(first(phase, circuits: true), .checkSlot, "\(phase) in circuits")
        }
    }

    func testDEFERKeepsItsSlotDimmedWhenThereIsNothingToDefer() {
        let roles = ActBandRoles.make(page: .checklist, phase: .climb, hasRoute: false, canDefer: false)
        XCTAssertEqual(roles[2], .deferItem(enabled: false))
    }

    func testOnTheMapTheCheckSlotIsFirstAndMoreLastInEveryPhase() {
        for phase in everyPhase {
            for route in [false, true] {
                for circuits in [false, true] {
                    for landingShown in [false, true] {
                        let roles = ActBandRoles.make(page: .map, phase: phase, hasRoute: route, circuits: circuits,
                                                      landingShown: landingShown)
                        let where_ = "\(phase), route \(route), circuits \(circuits), landing shown \(landingShown)"
                        XCTAssertEqual(roles.count, 4, where_)
                        XCTAssertEqual(roles[0], .checkSlot, where_)
                        guard case .more = roles[3] else { return XCTFail("S4 is More: \(where_)") }
                    }
                }
            }
        }
    }

    func testTheMapWithARouteHasMARKAndDivert() {
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .cruise, hasRoute: true),
                       [.checkSlot, .mark, .divert(enabled: true, diverting: false), .more(withDivert: false)])
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .cruise, hasRoute: true, diverting: true)[2],
                       .divert(enabled: true, diverting: true), "amber while diverting")
        // On the ground too, as the map's bottom row had them in flight.
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .taxi, hasRoute: true)[1], .mark)
        // Every waypoint passed: MARK keeps its place, Divert its own, dimmed.
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .afterLanding, hasRoute: true, routeFlown: true),
                       [.checkSlot, .mark, .divert(enabled: false, diverting: false), .more(withDivert: false)])
    }

    /// ROUTE has MAP's slots: the legs it lists are the ones MARK marks and Divert leaves. (6.2)
    func testROUTEHasTheMapsSlotsInEveryPhase() {
        for phase in everyPhase {
            for route in [false, true] {
                for circuits in [false, true] {
                    for landingShown in [false, true] {
                        for diverting in [false, true] {
                            XCTAssertEqual(
                                ActBandRoles.make(page: .route, phase: phase, hasRoute: route, diverting: diverting,
                                                  circuits: circuits, landingShown: landingShown),
                                ActBandRoles.make(page: .map, phase: phase, hasRoute: route, diverting: diverting,
                                                  circuits: circuits, landingShown: landingShown),
                                "\(phase), route \(route), circuits \(circuits), landing \(landingShown), diverting \(diverting)")
                        }
                    }
                }
            }
        }
    }

    func testTheMapWithoutARouteHasRoutesAndDivertDimmed() {
        for circuits in [false, true] {
            XCTAssertEqual(ActBandRoles.make(page: .map, phase: .climb, hasRoute: false, circuits: circuits),
                           [.checkSlot, .routes, .divert(enabled: false, diverting: false), .more(withDivert: false)])
        }
    }

    func testFromTheApproachTheRunwaysButtonsTakeMARKAndDivertsSlots() {
        for phase in [ChecklistPhase.approach, .landing] {
            for circuits in [false, true] {
                XCTAssertEqual(ActBandRoles.make(page: .map, phase: phase, hasRoute: true, circuits: circuits),
                               [.checkSlot, .goAround, .touchAndGo, .more(withDivert: true)], "\(phase), Divert in More")
                XCTAssertEqual(ActBandRoles.make(page: .map, phase: phase, hasRoute: false, circuits: circuits),
                               [.checkSlot, .goAround, .touchAndGo, .more(withDivert: false)], "\(phase), no route")
            }
        }
        // From circuit height, whatever the phase says: the landing check is shown.
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .climb, hasRoute: false, circuits: true, landingShown: true),
                       [.checkSlot, .goAround, .touchAndGo, .more(withDivert: false)])
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .descent, hasRoute: true, landingShown: true)[1], .goAround)
    }

    // MARK: - The four frames

    /// The band's row on each device: the screen less its padding (16 pt each side on the iPad, 12 on
    /// the phone).
    private enum Row {
        static let iPadPortrait: CGFloat = 820 - 32
        static let iPadOnItsSide: CGFloat = 1180 - 32
        static let iPhone17Pro: CGFloat = 402 - 24
    }

    func testTheFourFramesComeFromTheWidthAlone() {
        for (width, scale) in [(Row.iPadPortrait, CockpitScale.kneeboard), (Row.iPadOnItsSide, .kneeboard),
                               (Row.iPhone17Pro, .phone)] {
            let metrics = ActBandMetrics.make(layout: scale == .phone ? .narrow : .wide, scale: scale)
            let f = ActBandLayout.frames(width: width, metrics: metrics)
            XCTAssertEqual(f.count, 4)
            XCTAssertEqual(f[0].minX, 0)
            XCTAssertEqual(f[3].maxX, width, accuracy: 0.001, "the row's width at \(width) pt")
            XCTAssertEqual(f[0].width, f[1].width, "S1 and S2 share what S3 and S4 leave")
            XCTAssertEqual(f[2].width, metrics.narrowWidth)
            XCTAssertEqual(f[3].width, metrics.narrowWidth)
            for (a, b) in zip(f, f.dropFirst()) {
                XCTAssertEqual(b.minX - a.maxX, metrics.spacing, accuracy: 0.001)
            }
            XCTAssertEqual(Set(f.map(\.height)), [metrics.height], "one height: the thumb's")
            XCTAssertEqual(metrics.height, CockpitType.size(kneeboard: 104, phone: 92, scale: scale))
        }
        // The iPad in portrait: about 250 pt for the slot and CHECK, MARK or GO AROUND; on its side the
        // same frame, wider.
        let iPad = ActBandLayout.frames(width: Row.iPadPortrait, metrics: .make(layout: .wide, scale: .kneeboard))
        XCTAssertGreaterThan(iPad[0].width, 240)
        // The phone: about 100 pt for the slot and CHECK, its item on two lines.
        let phone = ActBandLayout.frames(width: Row.iPhone17Pro, metrics: .make(layout: .narrow, scale: .phone))
        XCTAssertGreaterThanOrEqual(phone[0].width, 98)
        // There, the check slot's "CRUISE CHECK" stays on one line (at most 0.6 of its 19 pt) over its
        // tick, "✓ 14:24", as beside MARK before the band; at 95 pt the tick went.
        XCTAssertLessThanOrEqual(ActBandMetrics.textWidth("CRUISE CHECK", size: 19) * 0.6, phone[0].width - 2 * 6)
    }

    func testThePhoneOnItsSideHasS3OverS4AtHalfHeight() {
        let metrics = ActBandMetrics.make(layout: .columns, scale: .phone)
        let width: CGFloat = 402 - 24
        let f = ActBandLayout.frames(width: width, metrics: metrics)
        XCTAssertEqual(f[2].minX, f[3].minX, "one above the other")
        XCTAssertEqual(f[2].maxX, width, accuracy: 0.001)
        XCTAssertEqual(f[2].height, (92 - 8) / 2)
        XCTAssertEqual(f[3].maxY, 92, accuracy: 0.001, "the band's height, as the thumb row's was")
        XCTAssertEqual(f[0].height, 92)
        XCTAssertEqual(f[0].width, f[1].width)
        XCTAssertGreaterThan(f[0].width, 130, "the slot and MARK keep the room they had")
    }

    /// S3 holds TOUCH-AND-GO on two lines and "Dérouter" at the in-flight label size or larger, on the
    /// iPad and on the phone, and so does every other word of the narrow slots but the phone's French
    /// DEFER ("REPORTER", a little smaller).
    func testTheNarrowSlotsHoldTheirWordsAtTheLabelSize() {
        XCTAssertTrue((120...150).contains(ActBandMetrics.narrowWidth(scale: .kneeboard)))
        XCTAssertTrue((72...80).contains(ActBandMetrics.narrowWidth(scale: .phone)))
        for scale in [CockpitScale.kneeboard, .phone] {
            let room = ActBandMetrics.narrowWidth(scale: scale) - 2 * ActBandMetrics.narrowPadding(scale)
            let size = CockpitType.label(for: scale)
            var words = ["TOUCH-", "AND-GO", "Dérouter", "POSÉ-", "DÉCOLLÉ", "Divert", "More", "Plus", "DEFER"]
            words += ["en", "fr"].flatMap { language in
                ActBandText.twoLines(localizedString(key: "checklist.touchAndGo", language: language))
                    .components(separatedBy: "\n")
            }
            words.append(localizedString(key: "act.divert", language: "fr"))
            for word in words {
                XCTAssertLessThanOrEqual(ActBandMetrics.textWidth(word, size: size), room, "\(word) at \(size) pt, \(scale)")
                // As SwiftUI sets it too.
                let text = Text(verbatim: word).font(.aero(size: size, weight: .bold)).fixedSize()
                XCTAssertLessThanOrEqual(UIHostingController(rootView: text).sizeThatFits(in: CGSize(width: 1_000, height: 100)).width,
                                         room + 0.5, "\(word) as drawn, \(scale)")
            }
        }
        XCTAssertEqual(localizedString(key: "act.divert", language: "fr"), "Dérouter", "the verb on the button")
        XCTAssertEqual(localizedString(key: "act.divert", language: "en"), "Divert")
        // The iPad's French DEFER fits as well; on the phone it is the one word that shrinks a little.
        let reporter = ActBandMetrics.textWidth("REPORTER", size: CockpitType.label(for: .kneeboard))
        XCTAssertLessThanOrEqual(reporter, ActBandMetrics.narrowWidth(scale: .kneeboard) - 2 * ActBandMetrics.narrowPadding(.kneeboard))
        let phoneRoom = ActBandMetrics.narrowWidth(scale: .phone) - 2 * ActBandMetrics.narrowPadding(.phone)
        XCTAssertGreaterThan(phoneRoom / ActBandMetrics.textWidth("REPORTER", size: 17), 0.85)
    }

    /// TOUCH-AND-GO held to confirm, in the iPad's narrow slot: its two lines and "Hold to confirm" under
    /// them (two lines too in French) inside the band's height, in both languages. At the hold button's
    /// own sizes the four lines took about 108 pt of the iPad's 104.
    func testTouchAndGoHeldFitsTheNarrowSlot() {
        func height(_ text: String, size: CGFloat, lines: Int, width: CGFloat) -> CGFloat {
            let view = Text(verbatim: text).font(.aero(size: size, weight: .bold)).lineLimit(lines)
                .multilineTextAlignment(.center).minimumScaleFactor(0.7)
            return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 1_000)).height
        }
        // The phone's is set to fit (`ActFace`): `testEveryRolesWordsFitThePhonesSlots`.
        do {
            let scale = CockpitScale.kneeboard
            let room = ActBandMetrics.narrowWidth(scale: scale) - 2 * ActBandMetrics.narrowPadding(scale)
            let label = CockpitType.label(for: scale)
            for language in ["en", "fr"] {
                let title = ActBandText.twoLines(localizedString(key: "checklist.touchAndGo", language: language))
                let hint = localizedString(key: "checklist.holdToConfirm", language: language)
                let total = height(title, size: label, lines: 2, width: room) + 2
                    + height(hint, size: label * 0.75, lines: 2, width: room)
                XCTAssertLessThanOrEqual(total, CockpitType.size(kneeboard: 104, phone: 92, scale: scale) - 8,
                                         "\(language), \(scale): \(total) pt")
            }
        }
    }

    func testTwoWordsBreakAtTheirMiddle() {
        XCTAssertEqual(ActBandText.twoLines("TOUCH-AND-GO"), "TOUCH-\nAND-GO")
        XCTAssertEqual(ActBandText.twoLines("POSÉ-DÉCOLLÉ"), "POSÉ-\nDÉCOLLÉ")
        XCTAssertEqual(ActBandText.twoLines("GO AROUND"), "GO\nAROUND")
        XCTAssertEqual(ActBandText.twoLines("REMISE DE GAZ"), "REMISE\nDE GAZ")
        XCTAssertEqual(ActBandText.twoLines("DEFER"), "DEFER", "nowhere to break")
        XCTAssertEqual(ActBandText.twoLines("-GO"), "-GO")
    }

    // MARK: - The band as drawn

    /// Every role set the Cockpit shows, drawn: the four slots in the same four frames, each button as
    /// big as its frame and no bigger, at the iPad's portrait and landscape widths on an iPad, at an
    /// iPhone 17 Pro's and a Pro Max's on an iPhone (a button sizes itself to the device it runs on, so
    /// each device checks its own). On the old thumb bars CHECK was at the right end of the checklist's
    /// and the row changed by phase; MARK was second on the map's.
    func testEveryRoleSetLaysOutInTheSameFourFrames() {
        let cases = [(CGFloat(820), CockpitLayout.wide, CockpitScale.kneeboard), (1180, .wide, .kneeboard),
                     (402, .narrow, .phone), (440, .narrow, .phone)].filter { $0.2 == CockpitScale.current }
        for (screen, layout, scale) in cases {
            let services = makeServices()
            startFlight(services.appState)
            let metrics = ActBandMetrics.make(layout: layout, scale: scale)
            let expected = ActBandLayout.frames(width: screen - (layout == .wide ? 32 : 24), metrics: metrics)
            var roleSets: Set<String> = []
            func draw(_ name: String, page: CockpitPane, _ set: () -> Void) {
                set()
                let slotRoles = roles(page, services)
                roleSets.insert("\(slotRoles)")
                let frames = bandFrames(page: page, layout: layout, scale: scale, width: screen, services: services)
                XCTAssertEqual(frames, expected, "\(name) at \(screen) pt: \(slotRoles)")
            }
            let app = services.appState
            draw("preflight", page: .checklist) { app.currentPhase = .preflight }
            draw("engine start", page: .checklist) { app.currentPhase = .engineStart }
            draw("cruise, FREDA", page: .checklist) { app.currentPhase = .cruise }
            draw("cruise done, NEXT", page: .checklist) {
                app.markLastItemComplete(learningMode: app.effectiveLearningMode)
            }
            draw("shutdown", page: .checklist) { app.currentPhase = .shutdown }
            draw("map, no route", page: .map) { app.currentPhase = .cruise }
            draw("map, route", page: .map) { self.armRoute(services.flightPlanManager) }
            draw("map, landing", page: .map) { app.currentPhase = .landing }
            draw("map, landing in circuits", page: .map) { app.isCircuitMode = true }
            draw("checklist, landing in circuits", page: .checklist) {}
            XCTAssertGreaterThanOrEqual(roleSets.count, 8, "as many role sets, one frame each: \(roleSets.sorted())")
        }
    }

    // MARK: - The words on the phone

    /// The phone's words are broken between words, never inside one: a separator never ends or starts a
    /// line (the break takes its place), a number stays with its noun, a French colon with its word. On
    /// main before this, SwiftUI broke them where it liked: "LSGC ·" over "1:42", "2" over "éléments",
    /// "SAIGNELÉGI" over "ER", "NAV" over "- ACL". (6.2)
    func testThePhonesWordsBreakBetweenWordsOnly() {
        let block = ActFaceBlock(text: "", size: 17)
        func lines(_ text: String, _ width: CGFloat) -> [String] {
            ActFace.lines(text, size: 17, block: block, width: width)
        }
        XCTAssertEqual(lines("NAV - ACL", 300), ["NAV - ACL"], "the separator kept inside a line")
        XCTAssertEqual(lines("NAV - ACL", 60), ["NAV", "ACL"], "where the words break, the break replaces it")
        XCTAssertEqual(lines("LSGC · 1:42", 60), ["LSGC", "1:42"])
        XCTAssertEqual(lines("2\u{00A0}éléments", 60), ["2\u{00A0}éléments"], "a number stays with its noun")
        XCTAssertEqual(lines("SUIVANT : DESCENTE", 90), ["SUIVANT\u{00A0}:", "DESCENTE"], "the colon stays with its word")
        XCTAssertEqual(lines("SAIGNELÉGIER", 60), ["SAIGNELÉGIER"], "a word is never broken")
        XCTAssertEqual(lines("TOUCH-\nAND-GO", 300), ["TOUCH-", "AND-GO"], "a break asked for is kept")
        // The catalog's counts carry the no-break space, in both languages.
        for language in ["en", "fr"] {
            for count in [1, 2, 12] {
                XCTAssertFalse(plural("%lld items", count, language).contains(" "), "\(language) \(count) items")
                XCTAssertFalse(plural("%lld deferred items", count, language).hasPrefix("\(count) "))
            }
            XCTAssertTrue(format("freda.inMinutes", language, 10).hasSuffix("10\u{00A0}min"), language)
        }
    }

    /// A word wider than the slot is set as large as it fits, on its line, never cut; everything else
    /// keeps its size or takes another line first.
    func testAWordWiderThanTheSlotIsSetAsLargeAsItFits() throws {
        let room: CGFloat = 84
        let name = ActFaceBlock(text: "SAIGNELÉGIER", size: 17)
        let set = try XCTUnwrap(ActFace.set([name], width: room, height: 84, spacing: 2).first)
        XCTAssertEqual(set.lines, ["SAIGNELÉGIER"])
        XCTAssertLessThanOrEqual(ActFace.width("SAIGNELÉGIER", size: set.size, block: name), room)
        XCTAssertGreaterThan(ActFace.width("SAIGNELÉGIER", size: set.size + 0.5, block: name), room, "as large as fits")
        // Two words take two lines at their size rather than one line smaller.
        let item = ActFaceBlock(text: "Quantité carburant", size: 17, maxLines: 3)
        XCTAssertEqual(ActFace.set([item], width: room, height: 84, spacing: 2).first,
                       ActFace.Setting(lines: ["Quantité", "carburant"], roomLines: ["Quantité", "carburant"], size: 17))
    }

    /// Every role the band can show, in English and in French, on an iPhone 17e, 17 and 17 Pro Max in
    /// portrait and in the column on its side: each line within the slot's inset, the lines within its
    /// height, no separator at either end of a line, no number left at the end of one, and nothing under
    /// the in-flight label size (17 pt) but a word wider than the slot at that size, set as large as it
    /// fits, or a slot whose height is full at the floor (the hold hint has its own, three quarters of it).
    /// On main before this the check slot's text kept 6 pt, the joined MARK line broke at its dot, and
    /// the item count, a long name and ENGINE START were cut or broken.
    func testEveryRolesWordsFitThePhonesSlots() {
        var cases = 0
        for language in ["en", "fr"] {
            for slot in Self.wideSlots {
                for face in wideFaces(language) {
                    check(face, in: slot, language: language)
                    cases += 1
                }
            }
            for slot in Self.narrowSlots {
                for face in narrowFaces(language, half: slot.height < 60) {
                    check(face, in: slot, language: language)
                    cases += 1
                }
            }
        }
        XCTAssertGreaterThan(cases, 1_500)
    }

    /// The lines as SwiftUI draws them: each on one line, as wide as `ActFace` measured it, so the face
    /// shows what was set (the narrowest phone, every face).
    func testSwiftUIDrawsEachLineAsSet() throws {
        let slot = try XCTUnwrap(Self.wideSlots.first)
        var drawn: Set<String> = []
        for language in ["en", "fr"] {
            for face in wideFaces(language) {
                let room = slot.width - 2 * face.inset
                let settings = ActFace.set(face.blocks, width: room, height: slot.height - 2 * face.verticalInset,
                                           spacing: face.spacing)
                for (block, setting) in zip(face.blocks, settings) {
                    for line in setting.lines where drawn.insert("\(line)|\(setting.size)|\(block.bold)|\(block.monospaced)").inserted {
                        let text = Text(verbatim: line)
                            .font(.aero(size: setting.size, weight: block.bold ? .bold : .regular,
                                        design: block.monospaced ? .monospaced : nil))
                            .fixedSize()
                        let size = UIHostingController(rootView: text).sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
                        XCTAssertLessThanOrEqual(size.width, room + 0.5, "\(line) at \(setting.size) pt")
                        XCTAssertEqual(size.height, ActFace.lineHeight(size: setting.size, block: block), accuracy: 1,
                                       "\(line): one line")
                    }
                }
            }
        }
        XCTAssertGreaterThan(drawn.count, 100)
    }

    // MARK: The phone's slots and faces

    private struct PhoneSlot {
        let name: String
        let width: CGFloat
        let height: CGFloat
    }

    /// S1 and S2: on an iPhone 17e, 17 and 17 Pro Max in portrait, and in the column on its side.
    private static var wideSlots: [PhoneSlot] {
        let portrait = [("17e", CGFloat(390)), ("17", 402), ("17 Pro Max", 440)].map { name, screen -> PhoneSlot in
            let frame = ActBandLayout.frames(width: screen - 24, metrics: .make(layout: .narrow, scale: .phone))[0]
            return PhoneSlot(name: "iPhone \(name)", width: frame.width, height: frame.height)
        }
        let column = ActBandLayout.frames(width: FlightView.cockpitColumnWidth - 24,
                                          metrics: .make(layout: .columns, scale: .phone))[0]
        return portrait + [PhoneSlot(name: "the column", width: column.width, height: column.height)]
    }

    /// S3: in portrait, and at half height on its side.
    private static var narrowSlots: [PhoneSlot] {
        let portrait = ActBandLayout.frames(width: 402 - 24, metrics: .make(layout: .narrow, scale: .phone))[2]
        let column = ActBandLayout.frames(width: FlightView.cockpitColumnWidth - 24,
                                          metrics: .make(layout: .columns, scale: .phone))[2]
        return [PhoneSlot(name: "S3", width: portrait.width, height: portrait.height),
                PhoneSlot(name: "S3 on its side", width: column.width, height: column.height)]
    }

    /// A slot's words as one of the band's views sets them, with its inset.
    private struct Face {
        let name: String
        let blocks: [ActFaceBlock]
        var inset: CGFloat = ActFace.inset
        var verticalInset: CGFloat = 3
        var spacing: CGFloat = 2
    }

    private static let phases = ["preflight", "beforeEngineStart", "engineStart", "afterEngineStart", "taxi", "runup",
                                 "beforeDeparture", "lineUp", "climb", "cruise", "descent", "approach", "landing",
                                 "afterLanding", "shutdown", "hangar"]

    /// Every face S1 and S2 can show, in `language`, built as the views build them.
    private func wideFaces(_ language: String) -> [Face] {
        func t(_ key: String) -> String { localizedString(key: key, language: language) }
        let checks = Self.phases.map { t("phase.short.\($0)") }
        var faces: [Face] = []
        // The check slot: every check's name over every line a check can have, and the names and lines
        // that go together (an action first, READY FOR LINE UP, FREDA).
        var pairs: [(String, String)] = []
        let lines = [1, 2, 9, 10, 12].map { plural("%lld items", $0, language) }
            + [t("cockpit.fromMemory"), t("checkSlot.nothingToPress"), t("checkSlot.nextCheck"), t("cockpit.allChecked"),
               t("checkSlot.owedShort")]
        for check in checks { pairs += lines.map { (check, $0) } }
        pairs += [(t("phase.short.engineStart"), format("checkSlot.actionFirst", language, t("checklist.engineStart"))),
                  (t("phase.short.shutdown"), format("checkSlot.actionFirst", language, t("checklist.engineShutdown"))),
                  (t("checklist.readyForLineUp"), format("cockpit.thenCheck", language, t("phase.short.lineUp"))),
                  (L10n.Freda.name, L10n.Freda.flowCompact),
                  (L10n.Freda.tickedStacked(t("phase.short.cruise"), "00:00"), format("freda.inMinutes", language, 10)),
                  (L10n.Freda.tickedStacked(L10n.Freda.name, "00:00"), format("freda.inMinutes", language, 10))]
        for (title, line) in pairs {
            faces.append(Face(name: "check slot: \(title) / \(line)",
                              blocks: CheckSlotLabel.phoneBlocks(title: title, line: line)))
        }
        // S2 on CHECKLIST: CHECK with every item of the bundled checklist, ✓ DONE, NEXT, READY FOR LINE UP,
        // END FLIGHT, as `ActChecklistPrimary` gives them.
        func thumb(_ title: String, _ subtitle: String? = nil, titleLines: Int = 3, subtitleLines: Int = 2) -> Face {
            let button = CockpitThumbButton(title: title, subtitle: subtitle, style: .outlined(tint: .cyan),
                                            titleLines: titleLines, subtitleLines: subtitleLines, fitted: true) {}
            return Face(name: "\(title) / \(subtitle ?? "")", blocks: button.fittedBlocks)
        }
        for item in bundledChallenges(language) {
            faces.append(thumb(t("cockpit.check"), item, titleLines: 1, subtitleLines: 3))
        }
        for check in checks {
            faces.append(thumb(format("cockpit.memoryCheckDone", language, check), t("cockpit.fromMemory")))
            faces.append(thumb(format("cockpit.next", language, check), t("cockpit.allChecked")))
            for count in [1, 2, 12] {
                faces.append(thumb(format("cockpit.next", language, check), plural("%lld deferred items", count, language)))
            }
        }
        faces.append(thumb(t("checklist.readyForLineUp"), format("cockpit.thenCheck", language, t("phase.short.lineUp"))))
        faces.append(thumb(t("button.endFlight")))
        faces.append(thumb(t("ground.plan.routes"), titleLines: 2))
        // S1: ENGINE START and SHUTDOWN, FREDA counting and due.
        for key in ["checklist.engineStart", "checklist.engineShutdown"] {
            faces.append(Face(name: key, blocks: TimestampActionButton.fittedBlocks(title: t(key))))
        }
        for line in ["10:00", "0:05", L10n.Freda.flowCompact] {
            faces.append(Face(name: "FREDA \(line)", blocks: FredaThumbButton.phoneBlocks(line: line)))
        }
        // S2 on MAP: START LEG, MARK with a short and a long name and the leg time; GO AROUND held and in
        // circuits.
        faces.append(Face(name: "START LEG", blocks: ActMarkButton.phoneBlocks(title: t("nav.startLegTimer"), name: nil, time: nil)))
        for name in ["LSGC", "SAIGNELÉGIER", "COL DES MOSSES", ""] {
            for time in ["0:05", "12:34", "12:34 ‖", "1:02:03 ‖"] {
                faces.append(Face(name: "MARK \(name) \(time)",
                                  blocks: ActMarkButton.phoneBlocks(title: t("nav.mark"), name: name, time: time)))
            }
        }
        let goAround = ActBandText.twoLines(t("checklist.goAround"))
        faces.append(Face(name: "GO AROUND held",
                          blocks: HoldToConfirmButton.fittedBlocks(title: goAround, titleLines: 2, showsHint: true,
                                                                   hint: t("checklist.holdToConfirm"))))
        faces.append(thumb(goAround, titleLines: 2))
        return faces
    }

    /// What S3 can hold in a set face: TOUCH-AND-GO, held (no hint at half height) and in circuits.
    private func narrowFaces(_ language: String, half: Bool) -> [Face] {
        let title = ActBandText.twoLines(localizedString(key: "checklist.touchAndGo", language: language))
        let held = HoldToConfirmButton.fittedBlocks(title: title, titleLines: 2, showsHint: !half,
                                                    hint: localizedString(key: "checklist.holdToConfirm", language: language))
        let circuits = CockpitThumbButton(title: title, style: .outlined(tint: .cyan), titleLines: 2, fitted: true) {}
        return [Face(name: "TOUCH-AND-GO held", blocks: held, inset: ActBandMetrics.narrowPadding(.phone)),
                Face(name: "TOUCH-AND-GO", blocks: circuits.fittedBlocks, inset: ActBandMetrics.narrowPadding(.phone))]
    }

    private func check(_ face: Face, in slot: PhoneSlot, language: String) {
        let room = slot.width - 2 * face.inset
        let height = slot.height - 2 * face.verticalInset
        let settings = ActFace.set(face.blocks, width: room, height: height, spacing: face.spacing)
        let where_ = "\(language), \(slot.name), \(face.name)"
        XCTAssertEqual(settings.count, face.blocks.count, where_)
        var total = face.spacing * CGFloat(max(0, face.blocks.count - 1))
        // Whether the slot holds the words at the floors at all: then nothing is set under them.
        let fitsAtFloors = Self.fitsAtFloors(face.blocks, width: room, height: height, spacing: face.spacing)
        for (block, setting) in zip(face.blocks, settings) {
            total += CGFloat(setting.roomLines.count) * ActFace.lineHeight(size: setting.size, block: block)
            XCTAssertLessThanOrEqual(setting.lines.count, setting.roomLines.count, "\(where_): within its room")
            for line in setting.lines + setting.roomLines {
                XCTAssertLessThanOrEqual(ActFace.width(line, size: setting.size, block: block), room + 0.01,
                                         "\(where_): \"\(line)\" within the inset")
                let words = line.split(separator: " ")
                if let first = words.first, let last = words.last {
                    XCTAssertFalse(first.allSatisfy { ActFace.separators.contains($0) || $0 == ":" },
                                   "\(where_): \"\(line)\" starts with a separator")
                    XCTAssertFalse(last.allSatisfy { ActFace.separators.contains($0) }, "\(where_): \"\(line)\" ends with one")
                }
            }
            // A number never ends a line its noun doesn't.
            for line in setting.lines.dropLast() {
                XCTAssertNil(Int(line.split(separator: " ").last.map(String.init) ?? ""), "\(where_): \"\(line)\" ends on a number")
            }
            // Every word shown, none cut: the words of the lines are the text's, separators aside.
            let shown = setting.lines.joined(separator: " ").split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" })
                .filter { !$0.allSatisfy { ActFace.separators.contains($0) } }
            let written = block.text.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" || $0 == "\n" })
                .filter { !$0.allSatisfy { ActFace.separators.contains($0) } }
            XCTAssertEqual(shown, written, "\(where_): every word, whole")
            // The floor, wherever the slot holds the words at it.
            if fitsAtFloors {
                XCTAssertGreaterThanOrEqual(setting.size, block.effectiveFloor - 0.01,
                                            "\(where_): \(block.text) under \(block.effectiveFloor) pt where it fits at it")
            }
            // Never smaller than its widest word needs, unless the slot's height asks.
            let widest = ActFace.unbreakable(block.room ?? block.text)
                .map { ActFace.width($0, size: block.size, block: block) }.max() ?? 0
            XCTAssertGreaterThan(setting.size, min(block.effectiveFloor, block.size * room / max(widest, 1)) * 0.6,
                                 "\(where_): \(block.text) at \(setting.size) pt")
        }
        XCTAssertLessThanOrEqual(total, height + 0.01, "\(where_): within the slot's height")
    }

    /// Whether `blocks` fit `width` × `height` with every one at its floor, on its most lines.
    private static func fitsAtFloors(_ blocks: [ActFaceBlock], width: CGFloat, height: CGFloat, spacing: CGFloat) -> Bool {
        var total = spacing * CGFloat(max(0, blocks.count - 1))
        for block in blocks {
            let text = block.room ?? block.text
            let lines = ActFace.lines(text, size: block.effectiveFloor, block: block, width: width)
            let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false).count
            guard lines.count <= max(paragraphs, block.maxLines),
                  lines.allSatisfy({ ActFace.width($0, size: block.effectiveFloor, block: block) <= width }) else { return false }
            total += CGFloat(lines.count) * ActFace.lineHeight(size: block.effectiveFloor, block: block)
        }
        return total <= height + 0.01
    }

    /// The challenges of the bundled checklist in `language`: what CHECK names.
    private func bundledChallenges(_ language: String) -> [String] {
        let name = language == "fr" ? "wt9-dynamic-bundled-fr" : "wt9-dynamic-bundled"
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) else {
            XCTFail("the bundled \(language) checklist")
            return []
        }
        var challenges: [String] = []
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for (key, value) in dictionary {
                    if key == "challenge", let text = value as? String { challenges.append(text) } else { walk(value) }
                }
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        return Array(Set(challenges)).sorted()
    }

    /// A count in `language`'s plural, read from its catalog: "2 éléments".
    private func plural(_ key: String, _ count: Int, _ language: String) -> String {
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil,
                                        localization: language),
              let table = NSDictionary(contentsOf: url) as? [String: Any],
              let entry = table[key] as? [String: Any],
              let rule = entry["value"] as? [String: Any] else {
            XCTFail("\(key) in \(language)")
            return key
        }
        let one = count == 1 || (language == "fr" && count == 0)
        let format = (one ? rule["one"] : rule["other"]) as? String ?? key
        return String(format: format, count)
    }

    private func format(_ key: String, _ language: String, _ arguments: CVarArg...) -> String {
        String(format: localizedString(key: key, language: language), arguments: arguments)
    }

    // MARK: - What the band owns

    func testMARKIsOfferedBackAndTakenBack() throws {
        let manager = activePlan()
        manager.markWaypoint()                                  // the departure, at the take-off
        manager.startChronometer()
        manager.restoreLegTimer(.init(accumulated: 0, startTime: Date().addingTimeInterval(-200)))
        let before = try XCTUnwrap(manager.legTimerSnapshot)
        let nav = CockpitNavState()

        nav.markWaypoint(in: manager, animated: false)
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 2)
        let offer = try XCTUnwrap(nav.undoOffer)
        XCTAssertTrue(offer.message.contains("LSGC"), offer.message)
        XCTAssertEqual(offer.style, .filled, "the pilot's own tap: filled")

        offer.undo()
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 1, "LSGC the target again")
        XCTAssertNil(manager.activeFlightPlan?.waypoints[1].actualTimeOver)
        XCTAssertEqual(manager.legTimerSnapshot, before)
    }

    func testMARKWithNothingLeftToMarkDoesNothing() {
        let manager = activePlan()
        for _ in 0..<3 { manager.markWaypoint() }
        XCTAssertTrue(manager.isFlightPlanCompleted)
        let nav = CockpitNavState()
        nav.markWaypoint(in: manager, animated: false)
        XCTAssertNil(nav.undoOffer)
    }

    func testTheLegTimerResetIsOfferedBack() throws {
        let manager = activePlan()
        manager.restoreLegTimer(.init(accumulated: 125, startTime: nil))
        let nav = CockpitNavState()
        nav.resetLegTimer(in: manager, animated: false)
        XCTAssertEqual(manager.chronometerElapsed, 0)
        let offer = try XCTUnwrap(nav.undoOffer)
        XCTAssertEqual(offer.message, L10n.Nav.legTimerReset)
        offer.undo()
        XCTAssertEqual(manager.chronometerElapsed, 125)
    }

    func testDivertOpensOnTheFieldAndTheRequestsCountAndALegIsShown() {
        let nav = CockpitNavState()
        nav.openDivert("LSGC")
        XCTAssertTrue(nav.showDivert)
        XCTAssertEqual(nav.divertPreselect, "LSGC")
        nav.openDivert(nil)
        XCTAssertNil(nav.divertPreselect, "the band's Divert opens on the list")
        let before = nav.checklistScrollRequest
        nav.scrollChecklistToCurrentItem()
        XCTAssertEqual(nav.checklistScrollRequest, before + 1)
        // A leg tapped on ROUTE: MAP shows it until Back to aircraft (6.2).
        nav.showLeg(2)
        XCTAssertEqual(nav.framedLeg, 2)
        nav.endLegFraming()
        XCTAssertNil(nav.framedLeg)
    }

    // MARK: - Helpers

    private func activePlan() -> FlightPlanManager {
        let manager = makeTestPlanManager()
        let plan = FlightPlan(name: "Act band", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.392, longitude: 7.030)),
            FlightPlanWaypoint(name: "LSGC", coordinate: .init(latitude: 47.083, longitude: 6.793)),
            FlightPlanWaypoint(name: "LSGN", coordinate: .init(latitude: 46.958, longitude: 6.864)),
        ])
        manager.add(plan)
        manager.activateFlightPlan(plan)
        addTeardownBlock { @MainActor in manager.stopChronometer() }
        return manager
    }

    private func armRoute(_ manager: FlightPlanManager) {
        var plan = manager.createFlightPlan(name: "Act band")
        for (name, latitude, longitude) in [("LSZQ", 47.3923, 7.0296), ("LSGC", 47.0839, 6.7929), ("LSGN", 46.9575, 6.8647)] {
            plan.waypoints.append(FlightPlanWaypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        }
        plan.calculateRouteData()
        manager.updateFlightPlan(plan)
        manager.activateFlightPlan(plan)
        addTeardownBlock { @MainActor in manager.deactivateFlightPlan() }
    }

    private func roles(_ page: CockpitPane, _ services: Services) -> [ActSlotRole] {
        let app = services.appState, plans = services.flightPlanManager
        return ActBandRoles.make(page: page, phase: app.currentPhase, hasRoute: plans.activeFlightPlan != nil,
                                 routeFlown: plans.isFlightPlanCompleted, circuits: app.isCircuitMode,
                                 landingShown: app.landingCheckShown,
                                 canDefer: !app.currentCheckIsDone && !app.currentCheckAwaitsConfirmation)
    }

    /// The band drawn `width` wide, and each slot's frame as laid out.
    private func bandFrames(page: CockpitPane, layout: CockpitLayout, scale: CockpitScale, width: CGFloat,
                            services: Services) -> [CGRect] {
        final class Box { var frames: [Int: CGRect] = [:] }
        let box = Box()
        let band = CockpitActBand(page: page, layout: layout, actions: CockpitActions(), scale: scale,
                                  onPlace: { box.frames[$0] = $1 })
        render(band, services: services, size: CGSize(width: width, height: 200))
        return (0..<4).map { box.frames[$0] ?? .zero }
    }

    /// What the band reads from the environment, on test storage (as `ViewStackBudgetTests`).
    private struct Services {
        let appState: AppState
        let subscriptionManager: SubscriptionManager
        let aircraftDataService: AircraftDataService
        let flightPlanManager: FlightPlanManager
        let threadManager: FlightThreadManager
        let locationManager: LocationManager
        let airportDataService: AirportDataService
        let openAIPDataService: OpenAIPDataService
        let flightEventDetector: FlightEventDetector
        let navState: CockpitNavState
    }

    private func makeServices() -> Services {
        let datastore = makeTestDatastore()
        let subscriptionManager = makeTestSubscriptionManager(deferLoadProducts: true)
        let airportDataService = AirportDataService()
        airportDataService.isDownloading = true
        return Services(
            appState: makeTestAppState(datastore: datastore),
            subscriptionManager: subscriptionManager,
            aircraftDataService: makeTestAircraftDataService(subscriptionManager: subscriptionManager),
            flightPlanManager: makeTestPlanManager(datastore: datastore),
            threadManager: makeTestThreadManager(datastore: datastore),
            locationManager: LocationManager(),
            airportDataService: airportDataService,
            openAIPDataService: OpenAIPDataService(),
            flightEventDetector: FlightEventDetector(),
            navState: CockpitNavState()
        )
    }

    /// A flight with the bundled WT9, every item to check one by one, cancelled when the test ends.
    private func startFlight(_ appState: AppState) {
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        addTeardownBlock { @MainActor in appState.cancelFlight() }
    }

    private func render<V: View>(_ view: V, services: Services, size: CGSize) {
        let content = view
            .frame(width: size.width)
            .environment(services.appState)
            .environment(services.navState)
            .environment(\.cockpitTheme, CockpitTheme.resolve(.day))
            .environmentObject(services.locationManager)
            .environmentObject(services.flightPlanManager)
            .environmentObject(services.airportDataService)
            .environmentObject(services.aircraftDataService)
            .environmentObject(services.openAIPDataService)
            .environmentObject(services.flightEventDetector)
            .environmentObject(services.threadManager)
            .environmentObject(services.subscriptionManager)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: nil)
        _ = renderer.uiImage
    }
}
