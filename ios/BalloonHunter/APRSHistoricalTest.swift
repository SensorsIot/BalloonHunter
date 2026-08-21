// APRSHistoricalTest.swift
// Test script to examine SondeHub historical telemetry API

import Foundation

/// Test function to fetch historical telemetry from SondeHub
/// Call this from anywhere to test the API response structure
@MainActor
func testSondeHubHistoricalAPI(serial: String, duration: String = "3h") async {
    let url = URL(string: "https://api.v2.sondehub.org/sondes/telemetry?serial=\(serial)&duration=\(duration)")!

    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
    request.setValue("BalloonHunter iOS App - Testing Historical API", forHTTPHeaderField: "User-Agent")

    print("=== Testing SondeHub Historical API ===")
    print("URL: \(url.absoluteString)")
    print("Fetching historical data for sonde: \(serial)")
    print("Duration: \(duration)")

    do {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("ERROR: Invalid response")
            return
        }

        print("\nHTTP Status: \(httpResponse.statusCode)")
        print("Content-Length: \(data.count) bytes")

        if httpResponse.statusCode != 200 {
            print("ERROR: HTTP \(httpResponse.statusCode)")
            if let errorString = String(data: data, encoding: .utf8) {
                print("Response: \(errorString)")
            }
            return
        }

        // Try to decode as JSON array
        if let jsonString = String(data: data, encoding: .utf8) {
            print("\n=== RAW JSON RESPONSE ===")
            print(String(jsonString.prefix(500))) // First 500 chars
            print("...")
            print(String(jsonString.suffix(500))) // Last 500 chars
        }

        // Attempt to decode structure
        // Try as array of telemetry points
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            print("\n=== DECODED AS ARRAY ===")
            print("Number of telemetry points: \(jsonObject.count)")

            if let first = jsonObject.first {
                print("\n=== FIRST POINT STRUCTURE ===")
                print("Keys: \(first.keys.sorted())")

                // Print sample values
                for (key, value) in first.sorted(by: { $0.key < $1.key }) {
                    print("  \(key): \(value)")
                }
            }

            if let last = jsonObject.last {
                print("\n=== LAST POINT STRUCTURE ===")
                for (key, value) in last.sorted(by: { $0.key < $1.key }) {
                    print("  \(key): \(value)")
                }
            }

            // Analyze track coverage
            if jsonObject.count > 0 {
                print("\n=== TRACK ANALYSIS ===")
                print("Total points: \(jsonObject.count)")

                // Extract timestamps
                let timestamps = jsonObject.compactMap { $0["datetime"] as? String }
                if let firstTime = timestamps.first, let lastTime = timestamps.last {
                    print("Time range: \(firstTime) → \(lastTime)")
                }

                // Extract altitudes
                let altitudes = jsonObject.compactMap { $0["alt"] as? Double }
                if !altitudes.isEmpty {
                    let minAlt = altitudes.min() ?? 0
                    let maxAlt = altitudes.max() ?? 0
                    print("Altitude range: \(Int(minAlt))m → \(Int(maxAlt))m")
                }

                // Check if complete track
                print("\nConclusion:")
                if jsonObject.count > 100 {
                    print("✅ COMPLETE TRACK with \(jsonObject.count) points")
                    print("✅ This appears to be full historical telemetry!")
                    print("✅ Can use this to fill gaps in local track")
                } else if jsonObject.count > 10 {
                    print("⚠️ PARTIAL TRACK with \(jsonObject.count) points")
                } else {
                    print("❌ MINIMAL DATA with only \(jsonObject.count) points")
                }
            }
        }

    } catch {
        print("ERROR fetching: \(error)")
    }
}

// MARK: - Data Structure for Historical Telemetry
// SondeHubHistoricalPoint struct is defined in APRSDataService.swift

// MARK: - Track Gap Filling Logic
// Production implementation moved to APRSDataService.swift
