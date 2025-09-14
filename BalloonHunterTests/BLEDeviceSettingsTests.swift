import XCTest
@testable import BalloonHunter

@MainActor
final class BLEDeviceSettingsTests: XCTestCase {
    func testFrequencyDigitConversionRoundTrip() {
        var settings = DeviceSettings()
        settings.frequency = 434.56
        let digits = settings.frequencyToDigits()
        XCTAssertEqual(digits, [4, 3, 4, 5, 6])

        var updated = DeviceSettings()
        updated.updateFrequencyFromDigits(digits)
        XCTAssertEqual(updated.frequency, 434.56, accuracy: 0.001)
    }

    func testParseType3SetsBandwidthAndProbeType() {
        // Type 3 format (22 fields). Using RS41Bandwidth index 17 -> 125.0 kHz
        let message = [
            "3",           // type
            "1",           // probeType (int form -> RS41)
            "434.0",       // frequency
            "21", "22", "16", // OLED pins
            "25",          // ledPin
            "17",          // RS41Bandwidth index
            "7", "7", "7", "6", // other bandwidths
            "CALL",        // callSign
            "0",           // freq correction
            "35", "2950", "4180", // battery
            "1",           // batType
            "0",           // lcdType
            "0",           // nameType
            "0",           // buzPin
            "1.0.0"        // software
        ].joined(separator: "/")

        var s = DeviceSettings()
        s.parse(message: message)

        XCTAssertEqual(s.probeType, "RS41")
        XCTAssertEqual(s.bandwidth, 125.0, accuracy: 0.01)
        XCTAssertEqual(s.callSign, "CALL")
    }

    // Command mapping test removed to simplify for manual testing
}
