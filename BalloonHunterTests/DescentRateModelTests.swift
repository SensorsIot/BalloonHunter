import XCTest
@testable import BalloonHunter

/// Tests for correcting the descent rate against Tawhiri's own trajectory.
///
/// Getting this wrong does not merely worsen a prediction — it makes the landing
/// estimate march downwind for the entire descent, which put a real landing 50 km
/// from where it was first predicted.
final class DescentRateModelTests: XCTestCase {

    private let model = DescentRateModel()

    private func fall(actual: Double, predicted: Double, rate: Double = 5.0) -> DescentRateModel.FallComparison {
        .init(actualDrop: actual, predictedDrop: predicted, rateUsed: rate)
    }

    // MARK: - The correction

    func testFallingExactlyAsPredicted_leavesRateUnchanged() throws {
        let v = try XCTUnwrap(model.correctedRate(from: fall(actual: 10_000, predicted: 10_000)))
        XCTAssertEqual(v, 5.0, accuracy: 0.001)
    }

    func testFallingSlowerThanPredicted_lowersTheRate() throws {
        // Fell 6 km where 10 km was predicted: 60% of the assumed speed.
        let v = try XCTUnwrap(model.correctedRate(from: fall(actual: 6_000, predicted: 10_000)))
        XCTAssertEqual(v, 3.0, accuracy: 0.001)
    }

    func testFallingFasterThanPredicted_raisesTheRate() throws {
        // The partially-opened parachute, and the case that causes harm.
        let v = try XCTUnwrap(model.correctedRate(from: fall(actual: 14_000, predicted: 10_000)))
        XCTAssertEqual(v, 7.0, accuracy: 0.001)
    }

    func testCorrectionIsProportional() throws {
        // Halving the observed fall must halve the rate, whatever rate was used.
        for rate in [2.0, 4.0, 8.0] {
            let v = try XCTUnwrap(model.correctedRate(from: fall(actual: 5_000, predicted: 10_000, rate: rate)))
            XCTAssertEqual(v, rate / 2, accuracy: 0.001, "failed at rate \(rate)")
        }
    }

    // MARK: - The real flight

    func testSlowChuteIsCorrectedTowardItsTrueRate() throws {
        // W4214915 fell at roughly 2.9 m/s below 10 km against an assumed 5.0,
        // so over a 10 km predicted drop it managed about 5.8 km.
        let v = try XCTUnwrap(model.correctedRate(from: fall(actual: 5_800, predicted: 10_000)))
        XCTAssertEqual(v, 2.9, accuracy: 0.1)
    }

    func testDeviationIsReportedAsPercent() throws {
        let d = try XCTUnwrap(model.deviationPercent(from: fall(actual: 6_000, predicted: 10_000)))
        XCTAssertEqual(d, -40, accuracy: 0.01, "negative means slower than assumed")
    }

    // MARK: - Refusing to answer

    func testTooLittleFallToJudge() {
        // Early in the descent the drop is small enough that timing jitter
        // dominates, and a confident correction would be invented, not measured.
        XCTAssertNil(model.correctedRate(from: fall(actual: 400, predicted: 500)))
    }

    func testEnoughFallToJudge() {
        XCTAssertNotNil(model.correctedRate(from: fall(actual: 2_000, predicted: 2_500)))
    }

    func testRunawayRatioIsStepped() throws {
        // A ratio of 10 means the reference trajectory no longer describes this
        // flight. Step toward it rather than leaping, and never past the cap.
        let v = try XCTUnwrap(model.correctedRate(from: fall(actual: 30_000, predicted: 3_000, rate: 4.0)))
        XCTAssertEqual(v, 8.0, accuracy: 0.001, "capped at a factor of 2, not 10")
    }

    func testRunawayRatioIsSteppedDownwardToo() throws {
        let v = try XCTUnwrap(model.correctedRate(from: fall(actual: 3_000, predicted: 30_000, rate: 4.0)))
        XCTAssertEqual(v, 2.0, accuracy: 0.001)
    }

    func testImplausibleResultIsRejected() {
        // Correcting a slow rate further down would make predicted time aloft
        // diverge and the landing estimate run away.
        XCTAssertNil(model.correctedRate(from: fall(actual: 3_000, predicted: 6_000, rate: 1.5)))
    }

    func testZeroAndNegativeInputsRejected() {
        XCTAssertNil(model.correctedRate(from: fall(actual: 0, predicted: 10_000)))
        XCTAssertNil(model.correctedRate(from: fall(actual: 10_000, predicted: 0)))
        XCTAssertNil(model.correctedRate(from: fall(actual: -5_000, predicted: 10_000)))
        XCTAssertNil(model.correctedRate(from: fall(actual: 10_000, predicted: 10_000, rate: 0)))
    }

    func testNonFiniteInputsRejected() {
        XCTAssertNil(model.correctedRate(from: fall(actual: .nan, predicted: 10_000)))
        XCTAssertNil(model.correctedRate(from: fall(actual: 10_000, predicted: .infinity)))
    }

    // MARK: - Convergence

    func testRepeatedCorrectionConvergesOnTheTruth() {
        // Applied each prediction, the correction must settle rather than hunt.
        // Simulates a sonde whose true sea-level rate is 2.5 while 5.0 is assumed.
        let truth = 2.5
        var rate = 5.0
        for _ in 0..<6 {
            // Over a fixed span, drop is proportional to the true rate; the
            // reference trajectory's drop is proportional to the rate we sent.
            let predicted = rate * 2_000
            let actual = truth * 2_000
            if let next = model.correctedRate(from: fall(actual: actual, predicted: predicted, rate: rate)) {
                rate = next
            }
        }
        XCTAssertEqual(rate, truth, accuracy: 0.05, "should converge, not oscillate")
    }
}
