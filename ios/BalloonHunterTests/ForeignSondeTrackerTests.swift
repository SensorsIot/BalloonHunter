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

    // MARK: - A test sonde must not take over the hunt
    //
    // Five packets from a bench unit are enough to declare a retune, and adopting it
    // clears the hunted sonde's track, landing point and route. A serial SondeHub
    // holds no telemetry for is a test sonde. See FSD *Sonde Selection → Test sondes
    // must not take over the hunt*.

    func testTestSonde_confirmedEmptyRefusesTheRetune() {
        XCTAssertTrue(TestSonde.isTestSonde(recentFrameCount: 0),
                      "SondeHub answered and holds nothing: the sonde is not flying anywhere")
    }

    func testTestSonde_recentFramesMeanOrdinarySonde() {
        XCTAssertFalse(TestSonde.isTestSonde(recentFrameCount: 1),
                       "a single recent frame is enough to show it is a real sonde")
        XCTAssertFalse(TestSonde.isTestSonde(recentFrameCount: 10_218))
    }

    /// Off-grid hunting is normal, and an unreachable SondeHub is not evidence of
    /// anything. Only an answer that arrives and is empty declares a test sonde.
    func testTestSonde_unreachableSondeHubIsNotEvidence() {
        XCTAssertFalse(TestSonde.isTestSonde(recentFrameCount: nil),
                       "cannot ask is not the same as nothing there — assume an ordinary sonde")
    }

    /// The distinction the rule depends on: "nothing there" and "could not ask" must
    /// reach it as different values, never both as an empty result.
    func testTestSonde_emptyAndUnreachableDisagree() {
        XCTAssertNotEqual(TestSonde.isTestSonde(recentFrameCount: 0),
                          TestSonde.isTestSonde(recentFrameCount: nil),
                          "collapsing these two would refuse legitimate retunes whenever the network drops")
    }
}
