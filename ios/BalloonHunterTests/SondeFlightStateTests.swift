import XCTest
@testable import BalloonHunter

/// Tests for the rule startup uses to decide between auto-selecting a sonde and
/// showing the picker.
///
/// Startup owns no classification of its own. `LandingDetector` decides
/// flying-versus-landed, `BalloonPositionService` publishes the verdict as
/// `balloonPhase`, and startup reads it through `BalloonPhase.isAirborne`.
///
/// The regression these pin: startup used to re-decide from the raw SondeHub
/// sonde list on vertical speed alone, with no notion of how old the frame was.
/// On 21 August 2026 that auto-selected W4214520 from a frame 6.8 h old, 2.4 s
/// after the detector had already classified that same sonde as landed.
final class SondeFlightStateTests: XCTestCase {

    // MARK: - Airborne

    func testAscending_isAirborne() {
        XCTAssertTrue(BalloonPhase.ascending.isAirborne)
    }

    func testDescendingAbove10k_isAirborne() {
        XCTAssertTrue(BalloonPhase.descendingAbove10k.isAirborne)
    }

    func testDescendingBelow10k_isAirborne() {
        // Descent is flight. A balloon under parachute is the case the hunter
        // most needs to chase, so it must not read as landed.
        XCTAssertTrue(BalloonPhase.descendingBelow10k.isAirborne)
    }

    // MARK: - Not airborne

    func testLanded_isNotAirborne() {
        XCTAssertFalse(BalloonPhase.landed.isAirborne)
    }

    func testUnknown_isNotAirborne() {
        // The decisive one. `unknown` means the detector could not tell, and
        // "could not tell" must never be spent on an auto-select — that is how
        // the hunter loses the picker and ends up chasing yesterday's sonde.
        XCTAssertFalse(BalloonPhase.unknown.isAirborne)
    }

    func testEveryPhaseIsClassified() {
        // If a phase is ever added, this forces a decision about it rather than
        // letting it default to one side.
        let all: [BalloonPhase] = [.ascending, .descendingAbove10k, .descendingBelow10k, .landed, .unknown]
        XCTAssertEqual(all.filter { $0.isAirborne }.count, 3)
        XCTAssertEqual(all.filter { !$0.isAirborne }.count, 2)
    }

    // MARK: - Agreement with the detector

    /// `isAirborne` must be the exact complement of the detector's `.landed`,
    /// plus `unknown`. If these ever drift apart, startup and the state machine
    /// disagree again — which is the whole defect.
    func testAirborneIsTheComplementOfLanded() {
        for phase in [BalloonPhase.ascending, .descendingAbove10k, .descendingBelow10k] {
            XCTAssertNotEqual(phase, .landed)
            XCTAssertTrue(phase.isAirborne)
        }
        XCTAssertFalse(BalloonPhase.landed.isAirborne)
    }

    // MARK: - The 21 August 2026 case, end to end through the detector

    func testStaleAPRSFrameStillDescending_classifiesAsLanded() {
        // W4214520 left coverage at 807 m still falling at -4.9 m/s. Its last
        // frame is frozen mid-descent, so vertical speed alone says "flying"
        // forever. The detector's age rule is what settles it.
        let detector = LandingDetector()
        var position = PositionData()
        position.sondeName = "W4214520"
        position.altitude = 807
        position.verticalSpeed = -4.9
        position.telemetrySource = .aprs
        position.timestamp = Date().addingTimeInterval(-6.8 * 3600)

        let phase = detector.classifyPhase(track: [], position: position)

        XCTAssertEqual(phase, .landed, "a sonde unheard for 6.8 h is down")
        XCTAssertFalse(phase.isAirborne, "startup must therefore show the picker")
    }

    func testFreshAPRSFrameDescending_classifiesAsAirborne() {
        // The control: same sonde, same rate, frame arriving now.
        let detector = LandingDetector()
        var position = PositionData()
        position.altitude = 807
        position.verticalSpeed = -4.9
        position.telemetrySource = .aprs
        position.timestamp = Date()

        let phase = detector.classifyPhase(track: [], position: position)

        XCTAssertEqual(phase, .descendingBelow10k)
        XCTAssertTrue(phase.isAirborne, "startup must auto-select a sonde that is actually falling")
    }

    func testNoTelemetryAtAll_isNotAirborne() {
        // Nothing arrived. The detector says unknown, and startup must ask
        // rather than pick.
        let phase = LandingDetector().classifyPhase(track: [], position: nil)
        XCTAssertEqual(phase, .unknown)
        XCTAssertFalse(phase.isAirborne)
    }

    // MARK: - The startup decision

    private func decide(_ phase: BalloonPhase, _ serial: String? = "W4214520") -> StartupSelection {
        StartupSelection.decide(phase: phase, trackedSerial: serial)
    }

    func testStartup_landedSonde_showsPicker() {
        // The 21 August 2026 case. The detector said landed; startup must ask.
        XCTAssertEqual(decide(.landed), .showPicker)
    }

    func testStartup_unknownPhase_showsPicker() {
        // Nothing arrived, or the detector could not tell. Ask, never guess.
        XCTAssertEqual(decide(.unknown), .showPicker)
    }

    func testStartup_ascendingSonde_autoSelects() {
        XCTAssertEqual(decide(.ascending), .autoSelect(serial: "W4214520"))
    }

    func testStartup_descendingSonde_autoSelects() {
        // The case the hunter most needs: it is coming down and the chase is on.
        XCTAssertEqual(decide(.descendingBelow10k), .autoSelect(serial: "W4214520"))
        XCTAssertEqual(decide(.descendingAbove10k), .autoSelect(serial: "W4214520"))
    }

    func testStartup_airborneButNothingNamesIt_showsPicker() {
        // Airborne with no serial is not a selection — there is nothing to track.
        XCTAssertEqual(decide(.descendingBelow10k, nil), .showPicker)
        XCTAssertEqual(decide(.descendingBelow10k, ""), .showPicker)
        XCTAssertEqual(decide(.descendingBelow10k, "   "), .showPicker)
    }

    func testStartup_airborneSondeNotInSondeHubList_stillAutoSelects() {
        // The serial comes from the telemetry the detector judged, not from the
        // 24-hour list, so a live decode of an unlisted sonde still selects.
        XCTAssertEqual(decide(.ascending, "V4210129"), .autoSelect(serial: "V4210129"))
    }

    func testStartup_neverAutoSelectsOnAnythingButAirborne() {
        // Sweep: only the airborne phases may skip the picker, whatever serial
        // is present. This is the rule the defect broke.
        for phase in [BalloonPhase.landed, .unknown] {
            XCTAssertEqual(decide(phase), .showPicker, "\(phase) must not auto-select")
        }
    }

    // MARK: - Startup, end to end from telemetry

    /// The full path the defect took: telemetry → detector → phase → decision.
    private func decision(forFrameAged age: TimeInterval, verticalSpeed: Double) -> StartupSelection {
        var position = PositionData()
        position.sondeName = "W4214520"
        position.altitude = 807
        position.verticalSpeed = verticalSpeed
        position.telemetrySource = .aprs
        position.timestamp = Date().addingTimeInterval(-age)

        let phase = LandingDetector().classifyPhase(track: [], position: position)
        return StartupSelection.decide(phase: phase, trackedSerial: position.sondeName)
    }

    func testStartup_staleFrameFrozenMidDescent_showsPicker() {
        // W4214520 as it actually was that morning: last heard 6.8 h earlier at
        // 807 m, still falling. Read on vertical speed alone this auto-selects.
        XCTAssertEqual(decision(forFrameAged: 6.8 * 3600, verticalSpeed: -4.9), .showPicker)
    }

    func testStartup_liveFrameDescending_autoSelects() {
        XCTAssertEqual(decision(forFrameAged: 5, verticalSpeed: -4.9),
                       .autoSelect(serial: "W4214520"))
    }

    func testStartup_justPastTheSilenceThreshold_showsPicker() {
        let silence = LandingDetector().thresholds.aprsLandingAge
        XCTAssertEqual(decision(forFrameAged: silence + 1, verticalSpeed: -4.9), .showPicker)
        XCTAssertEqual(decision(forFrameAged: silence - 1, verticalSpeed: -4.9),
                       .autoSelect(serial: "W4214520"))
    }
}
