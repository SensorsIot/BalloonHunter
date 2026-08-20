import XCTest
@testable import BalloonHunter

/// Phase 1, from the hunter's chair: what the app knows when it comes up.
///
/// Each test is a morning, an afternoon, or a moment in a car park.
final class HuntStateTests: XCTestCase {

    private let state = HuntState()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func stored(_ serial: String, minutesAgo: Double) -> HuntState.StoredHunt {
        .init(serial: serial, lastDataAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    // MARK: - I come back to a hunt already running

    func testCheckingThePhoneAfterLunch_theHuntIsStillThere() {
        // Forty minutes in a pocket. Everything should be exactly as I left it.
        let d = state.decide(stored: stored("W4214540", minutesAgo: 40),
                             hunting: "W4214540", now: now)
        XCTAssertEqual(d, .resumeHunt)
    }

    func testTheAppWasKilledWhileIDrove_theHuntIsStillThere() {
        // iOS reclaimed the app in the car. From my side nothing happened, so a
        // cold start must show me the same thing a resume would.
        let d = state.decide(stored: stored("W4214540", minutesAgo: 90),
                             hunting: "W4214540", now: now)
        XCTAssertEqual(d, .resumeHunt, "how the app died is not something I should be able to notice")
    }

    func testFiveHoursIntoARecovery_stillMyHunt() {
        // Climb, fall, drive, and a long walk. A real recovery takes this long.
        let d = state.decide(stored: stored("W4214540", minutesAgo: 5 * 60),
                             hunting: "W4214540", now: now)
        XCTAssertEqual(d, .resumeHunt)
    }

    // MARK: - I open the app the next morning

    func testNextMorning_yesterdaysFlightIsNotDrawn() {
        // Yesterday's landing point is a real field I could drive to by mistake.
        let d = state.decide(stored: stored("W4214540", minutesAgo: 20 * 60),
                             hunting: "W4214540", now: now)
        XCTAssertEqual(d, .tooOldToShow)
        XCTAssertFalse(state.mayDisplay(stored: stored("W4214540", minutesAgo: 20 * 60),
                                        hunting: "W4214540", now: now))
    }

    func testTooOldToShowStillDoesNotThrowMyTrackAway() {
        // Nothing is drawn, but nothing is deleted either. If the sonde starts
        // transmitting again it is still the same flight.
        let old = stored("W4214540", minutesAgo: 20 * 60)
        XCTAssertFalse(state.mustClear(stored: old, hunting: "W4214540"))
    }

    func testJustUnderSixHours_shown() {
        let d = state.decide(stored: stored("W4214540", minutesAgo: 6 * 60 - 1),
                             hunting: "W4214540", now: now)
        XCTAssertEqual(d, .resumeHunt)
    }

    func testJustOverSixHours_notShown() {
        let d = state.decide(stored: stored("W4214540", minutesAgo: 6 * 60 + 1),
                             hunting: "W4214540", now: now)
        XCTAssertEqual(d, .tooOldToShow)
    }

    // MARK: - I pick a different sonde

    func testChoosingAnotherSonde_theOldHuntGoesEntirely() {
        // A different balloon has nothing to do with the last one.
        let d = state.decide(stored: stored("W4214540", minutesAgo: 10),
                             hunting: "T4230704", now: now)
        XCTAssertEqual(d, .startNewHunt)
        XCTAssertTrue(state.mustClear(stored: stored("W4214540", minutesAgo: 10), hunting: "T4230704"))
    }

    func testANewSondeClearsEvenWhenTheOldOneWasSecondsAgo() {
        // Freshness is not the point. Identity is.
        let d = state.decide(stored: stored("W4214540", minutesAgo: 0.1),
                             hunting: "T4230704", now: now)
        XCTAssertEqual(d, .startNewHunt)
    }

    func testHuntingTheSameSondeAgainKeepsWhatIAlreadyGathered() {
        // Re-fetching this serial would return the same flight, so throwing away
        // the receiver's own detail buys nothing.
        XCTAssertFalse(state.mustClear(stored: stored("W4214540", minutesAgo: 300),
                                       hunting: "W4214540"))
    }

    // MARK: - First run, and nothing chosen yet

    func testFirstEverLaunch_nothingToShow() {
        XCTAssertEqual(state.decide(stored: nil, hunting: nil, now: now), .nothingStored)
        XCTAssertFalse(state.mayDisplay(stored: nil, hunting: nil, now: now))
    }

    func testNoSondeChosenYet_recentStoredHuntIsStillMine() {
        // Startup has not resolved a sonde yet. What is stored is all there is,
        // and it is recent, so show it while waiting.
        let d = state.decide(stored: stored("W4214540", minutesAgo: 15), hunting: nil, now: now)
        XCTAssertEqual(d, .resumeHunt)
    }

    // MARK: - The rule that must not creep back

    func testAgeNeverDecidesIdentity() {
        // The bug this prevents: a stale track kept because the *name* matched,
        // or a live hunt thrown away because the clock said so.
        for minutes: Double in [1, 60, 300, 1440, 14400] {
            XCTAssertFalse(state.mustClear(stored: stored("W4214540", minutesAgo: minutes),
                                           hunting: "W4214540"),
                           "same serial must never be cleared, and \(Int(minutes)) min did")
            XCTAssertTrue(state.mustClear(stored: stored("W4214540", minutesAgo: minutes),
                                          hunting: "V4221513"),
                          "a different serial must always clear, and \(Int(minutes)) min did not")
        }
    }
}
