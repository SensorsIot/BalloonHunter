import XCTest
@testable import BalloonHunter

/// Which server answers a prediction request.
///
/// Two servers speak the same Tawhiri contract — the Swiss-Balloon-Predictor at
/// `predictor.fabia.ch` and SondeHub — so choosing between them is a base-URL
/// change and nothing else. SondeHub is the fallback whenever the chosen server
/// cannot be used, because a hunt must not lose its predictions to a server that
/// is down or not yet deployed. See FSD *Prediction Service → Which server
/// answers*.
final class PredictionEndpointTests: XCTestCase {

    private let swiss = "https://predictor.fabia.ch/tawhiri"

    // MARK: - Choosing

    func testDefaultsToTheSwissPredictor() {
        XCTAssertEqual(PredictionEndpoint.base(useSwiss: true, swissURL: swiss).absoluteString, swiss)
    }

    func testToggleOffUsesSondeHub() {
        XCTAssertEqual(PredictionEndpoint.base(useSwiss: false, swissURL: swiss),
                       PredictionEndpoint.sondeHub)
    }

    func testTheDefaultURLConstantIsTheSwissPredictor() {
        // The constant the app and the UI both read for the default.
        XCTAssertEqual(PredictionEndpoint.swissPredictorDefault, swiss)
    }

    // MARK: - Refusing a URL that cannot work

    func testEmptyURLFallsBackToSondeHub() {
        XCTAssertEqual(PredictionEndpoint.base(useSwiss: true, swissURL: ""),
                       PredictionEndpoint.sondeHub)
        XCTAssertEqual(PredictionEndpoint.base(useSwiss: true, swissURL: "   "),
                       PredictionEndpoint.sondeHub)
    }

    func testHttpURLIsRefused() {
        // App Transport Security blocks plain HTTP, so accepting one would turn
        // a typo into a silent fallback on every prediction for the whole flight.
        XCTAssertEqual(PredictionEndpoint.base(useSwiss: true, swissURL: "http://predictor.fabia.ch/tawhiri"),
                       PredictionEndpoint.sondeHub)
    }

    func testGarbageURLFallsBackRatherThanCrashing() {
        for bad in ["not a url", "://", "predictor.fabia.ch/tawhiri", "ftp://x/y"] {
            XCTAssertEqual(PredictionEndpoint.base(useSwiss: true, swissURL: bad),
                           PredictionEndpoint.sondeHub, "\(bad) must not be accepted")
        }
    }

    func testURLWithoutAHostIsRefused() {
        XCTAssertEqual(PredictionEndpoint.base(useSwiss: true, swissURL: "https:///tawhiri"),
                       PredictionEndpoint.sondeHub)
    }

    func testSurroundingWhitespaceIsTolerated() {
        // Typed on a phone keyboard; a trailing space must not cost a flight.
        XCTAssertEqual(PredictionEndpoint.base(useSwiss: true, swissURL: "  \(swiss) ").absoluteString, swiss)
    }

    // MARK: - Naming the server in the log

    func testEachServerIsNameable() {
        // FR-P.3: an A/B run is worthless if the log cannot say who answered.
        XCTAssertEqual(PredictionEndpoint.name(for: PredictionEndpoint.sondeHub), "SondeHub")
        XCTAssertEqual(PredictionEndpoint.name(for: URL(string: swiss)!), "predictor.fabia.ch")
    }

    // MARK: - Fallback

    func testFallbackIsSondeHubAndNotTheChosenServer() {
        // The fallback target is fixed. Falling back to the server that just
        // failed would be a retry loop, not a fallback.
        XCTAssertNotEqual(PredictionEndpoint.fallback, URL(string: swiss))
        XCTAssertEqual(PredictionEndpoint.fallback, PredictionEndpoint.sondeHub)
    }

    func testNoFallbackNeededWhenSondeHubWasAlreadyChosen() {
        // Nothing to fall back to; the caller must not retry the same server.
        XCTAssertFalse(PredictionEndpoint.shouldFallBack(from: PredictionEndpoint.sondeHub))
        XCTAssertTrue(PredictionEndpoint.shouldFallBack(from: URL(string: swiss)!))
    }
}
