import XCTest
@testable import BalloonHunter

/// Tests for the rule separating a retuned receiver from a stray decode.
///
/// The distinction matters because the two outcomes are opposites: a retune must
/// clear every trace of the previous sonde, while a stray packet must change
/// nothing at all. Acting on a single foreign packet is what let a bench unit
/// destroy a live hunt and write its own position into the flight track.
final class ForeignSondeTrackerTests: XCTestCase {

    private let hunted = "W4214540"
    private let bench = "R3651518"
    private let neighbour = "V4221514"

    // MARK: - Stray decodes

    func testSingleForeignPacket_isNotAChange() {
        var tracker = ForeignSondeTracker()
        XCTAssertFalse(tracker.sawForeignSonde(bench).isConfirmedChange)
    }

    func testForeignPacketsInterruptedByHuntedSonde_neverConfirm() {
        // The real failure: a bench unit slipping in between packets of the
        // hunted sonde, over and over. It must never accumulate.
        var tracker = ForeignSondeTracker()
        for _ in 0..<50 {
            XCTAssertFalse(tracker.sawForeignSonde(bench).isConfirmedChange)
            tracker.reset()   // hunted sonde heard again
        }
    }

    func testStreakResetsWhenHuntedSondeReturns() {
        var tracker = ForeignSondeTracker()
        _ = tracker.sawForeignSonde(bench)
        _ = tracker.sawForeignSonde(bench)
        tracker.reset()
        XCTAssertEqual(tracker.sawForeignSonde(bench).streak, 1)
    }

    func testTwoForeignSondesAlternating_neverConfirm() {
        // Interference from two sources is still interference. Neither serial
        // ever builds a run, because each resets the other.
        var tracker = ForeignSondeTracker()
        for _ in 0..<20 {
            XCTAssertFalse(tracker.sawForeignSonde(bench).isConfirmedChange)
            XCTAssertFalse(tracker.sawForeignSonde(neighbour).isConfirmedChange)
        }
    }

    // MARK: - A real retune

    func testFiveConsecutivePackets_confirmChange() {
        var tracker = ForeignSondeTracker()
        for i in 1...4 {
            let outcome = tracker.sawForeignSonde(bench)
            XCTAssertFalse(outcome.isConfirmedChange, "confirmed early at packet \(i)")
            XCTAssertEqual(outcome.streak, i)
        }
        let final = tracker.sawForeignSonde(bench)
        XCTAssertTrue(final.isConfirmedChange)
        XCTAssertEqual(final.streak, 5)
    }

    func testConfirmationResetsSoNextChangeStartsFresh() {
        // Without this, every packet after a confirmed change would re-confirm,
        // and the coordinator would clear all data on each one.
        var tracker = ForeignSondeTracker()
        for _ in 1...5 { _ = tracker.sawForeignSonde(bench) }

        let next = tracker.sawForeignSonde(bench)
        XCTAssertFalse(next.isConfirmedChange, "must not re-confirm on the next packet")
        XCTAssertEqual(next.streak, 1)
    }

    func testSwitchingForeignSondeRestartsTheCount() {
        var tracker = ForeignSondeTracker()
        for _ in 1...4 { _ = tracker.sawForeignSonde(bench) }

        let switched = tracker.sawForeignSonde(neighbour)
        XCTAssertEqual(switched.streak, 1, "a different serial restarts the run")
        XCTAssertFalse(switched.isConfirmedChange)
    }

    func testRetuneConfirmsAfterEarlierStrayDecodes() {
        // Strays first, then a genuine retune. The retune must still be caught.
        var tracker = ForeignSondeTracker()
        _ = tracker.sawForeignSonde(bench); tracker.reset()
        _ = tracker.sawForeignSonde(bench); tracker.reset()

        for i in 1...4 {
            XCTAssertFalse(tracker.sawForeignSonde(neighbour).isConfirmedChange, "early at \(i)")
        }
        XCTAssertTrue(tracker.sawForeignSonde(neighbour).isConfirmedChange)
    }

    // MARK: - Threshold

    func testConfirmCountIsHonoured() {
        var tracker = ForeignSondeTracker(confirmCount: 2)
        XCTAssertFalse(tracker.sawForeignSonde(bench).isConfirmedChange)
        XCTAssertTrue(tracker.sawForeignSonde(bench).isConfirmedChange)
    }

    func testDefaultConfirmCountIsFive() {
        XCTAssertEqual(ForeignSondeTracker().confirmCount, 5)
    }

    // MARK: - Regression

    func testBenchSondeCannotHijackAHunt() {
        // Reproduces the observed defect: one packet from R3651518, sitting at
        // the operator's own location, arriving mid-flight. Before the fix this
        // cleared all data and adopted it, leaving a track leg running from the
        // balloon to the operator.
        var tracker = ForeignSondeTracker()
        let outcome = tracker.sawForeignSonde(bench)

        XCTAssertFalse(outcome.isConfirmedChange,
                       "a lone packet from a bench sonde must never take over the hunt")
        XCTAssertNotEqual(bench, hunted)
    }
}
