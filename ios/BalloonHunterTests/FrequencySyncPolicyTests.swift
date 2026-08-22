// FrequencySyncPolicyTests.swift
// U-FREQ-SYNC. Verifies FR-F.1-F.3: the receiver is asked to follow the hunted
// sonde on each of the three triggers, and stays silent between them.

import XCTest
@testable import BalloonHunter

final class FrequencySyncPolicyTests: XCTestCase {

    private func question(hunted: Double = 404.10,
                          huntedProbe: String = "RS41",
                          receiver: Double = 403.00,
                          receiverProbe: String = "RS41",
                          generation: Int = 1) -> FrequencyQuestion? {
        FrequencySyncPolicy.question(huntedFrequency: hunted,
                                     huntedProbeType: huntedProbe,
                                     receiverFrequency: receiver,
                                     receiverProbeType: receiverProbe,
                                     connectionGeneration: generation)
    }

    // MARK: - There is a question at all

    func testMismatchedFrequencyAsks() {
        XCTAssertTrue(FrequencySyncPolicy.shouldAsk(question(), lastAnswered: nil))
    }

    func testMatchedFrequencyAndProbeAsksNothing() {
        XCTAssertNil(question(hunted: 404.10, receiver: 404.10))
    }

    func testAgreementWithinToleranceIsTheSameChannel() {
        // 5 kHz apart, under the 10 kHz tolerance: not a change the hunter can see.
        XCTAssertNil(question(hunted: 404.100, receiver: 404.105))
    }

    func testDisagreementBeyondToleranceAsks() {
        XCTAssertNotNil(question(hunted: 404.10, receiver: 404.13))
    }

    func testProbeTypeMismatchAsksEvenOnTheSameFrequency() {
        XCTAssertNotNil(question(hunted: 404.10, huntedProbe: "RS41",
                                 receiver: 404.10, receiverProbe: "DFM"))
    }

    func testUnknownHuntedFrequencyAsksNothing() {
        // Nothing has been reported yet. An unknown channel is not a mismatch.
        XCTAssertNil(question(hunted: 0))
        XCTAssertNil(question(hunted: .nan))
        XCTAssertNil(question(hunted: .infinity))
    }

    func testAbsentProbeTypeIsTreatedAsRS41() {
        // The default the app has always applied; stated here so it has one owner.
        XCTAssertNil(question(hunted: 404.10, huntedProbe: "",
                              receiver: 404.10, receiverProbe: "RS41"))
    }

    // MARK: - FR-F.3: asked once per trigger, and not again

    func testAnsweredQuestionIsNotAskedAgain() {
        let asked = question()
        XCTAssertFalse(FrequencySyncPolicy.shouldAsk(asked, lastAnswered: asked),
                       "The alert would repeat while nothing has changed")
    }

    func testReconnectingAsksAgain() {
        // FR-F.1. The receiver is a physical box: it may come back on any channel,
        // so the same mismatch on a new connection is a new question.
        let answered = question(generation: 1)
        let onReconnect = question(generation: 2)
        XCTAssertTrue(FrequencySyncPolicy.shouldAsk(onReconnect, lastAnswered: answered))
    }

    func testChangedReportedFrequencyAsksAgain() {
        // FR-F.2.
        let answered = question(hunted: 404.10)
        let afterReport = question(hunted: 405.30)
        XCTAssertTrue(FrequencySyncPolicy.shouldAsk(afterReport, lastAnswered: answered))
    }

    func testSelectingAnotherSondeAsksAgain() {
        let answered = question(hunted: 404.10)
        let newSonde = question(hunted: 402.70)
        XCTAssertTrue(FrequencySyncPolicy.shouldAsk(newSonde, lastAnswered: answered))
    }

    func testRetuningToTheAnsweredChannelEndsTheQuestion() {
        // Accepting the proposal moves the receiver, so the question dissolves
        // rather than being suppressed.
        let answered = question(hunted: 404.10, receiver: 403.00)
        XCTAssertNotNil(answered)
        XCTAssertNil(question(hunted: 404.10, receiver: 404.10))
    }

    func testNothingToAskIsNeverAsked() {
        XCTAssertFalse(FrequencySyncPolicy.shouldAsk(nil, lastAnswered: nil))
        XCTAssertFalse(FrequencySyncPolicy.shouldAsk(nil, lastAnswered: question()))
    }

    // MARK: - The quantiser itself

    func testQuantiserRejectsWhatCannotBeConverted() {
        XCTAssertNil(FrequencySyncPolicy.quantise(.nan))
        XCTAssertNil(FrequencySyncPolicy.quantise(.infinity))
        XCTAssertNil(FrequencySyncPolicy.quantise(.greatestFiniteMagnitude))
        XCTAssertNil(FrequencySyncPolicy.quantise(0))
        XCTAssertEqual(FrequencySyncPolicy.quantise(404.10), 40410)
    }
}
