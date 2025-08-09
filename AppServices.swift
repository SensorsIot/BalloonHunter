// AppServices.swift
// Home for all non-UI, reusable service-like logic and singleton helpers
// Merged from: PredictionLogic.swift, PredictionSettings.swift, BLEManager.swift, KML/XML helpers, BLE helpers, and other service logic.

import Foundation
import CoreLocation
import MapKit
import CoreBluetooth
import Combine

// MARK: - PredictionSettings
class PredictionSettings {
    static let shared = PredictionSettings()
    // These match the parameters expected in PredictionLogic
    var ascentRate: String = "5.0" // m/s
    var descentRate: String = "5.0" // m/s
    var burstAltitude: String = "35000" // meters
    private init() {}
}

// MARK: - PredictionLogic & KML/XML helpers
class PredictionLogic {
    static let shared = PredictionLogic()
    private init() {}
    // ...[Insert entire PredictionLogic class and KMLCoordinatesParser from PredictionLogic.swift here, unchanged]...
    
    func tawhiriURL(from telemetry: Telemetry?, settings: PredictionSettings = PredictionSettings.shared, format: String = "kml") -> URL? {
        guard telemetry != nil else { return nil }
        let ascentRate = Double(settings.ascentRate) ?? 5.0
        let descentRate = Double(settings.descentRate) ?? 5.0
        let burstAltitude: Double = {
            if let vSpeed = telemetry?.verticalSpeed, let alt = telemetry?.altitude {
                if vSpeed < 0 {
                    return alt + 10
                } else {
                    return Double(settings.burstAltitude) ?? 35000
                }
            } else {
                return Double(settings.burstAltitude) ?? 35000
            }
        }()
        let latitude = telemetry?.latitude ?? 47.47649639804274
        let longitude = telemetry?.longitude ?? 7.759382678078039
        let altitude = (telemetry?.altitude != 0 ? telemetry?.altitude : nil) ?? 3000
        let isoFormatter = ISO8601DateFormatter()
        let launchDatetime = isoFormatter.string(from: Date())
        var components = URLComponents(string: "https://api.v2.sondehub.org/tawhiri")!
        components.queryItems = [
            URLQueryItem(name: "profile", value: "standard_profile"),
            URLQueryItem(name: "launch_datetime", value: launchDatetime),
            URLQueryItem(name: "launch_latitude", value: "\(latitude)"),
            URLQueryItem(name: "launch_longitude", value: "\(longitude)"),
            URLQueryItem(name: "launch_altitude", value: String(format: "%.1f", altitude)),
            URLQueryItem(name: "ascent_rate", value: "\(ascentRate)"),
            URLQueryItem(name: "burst_altitude", value: "\(burstAltitude)"),
            URLQueryItem(name: "descent_rate", value: "\(descentRate)"),
            URLQueryItem(name: "format", value: format)
        ]
        return components.url
    }
    /// Fetches the prediction track, landing time and burst coordinate from Tawhiri API and parses the result.
    /// Calls the completion handler on the main thread with ([CLLocationCoordinate2D], Date?, CLLocationCoordinate2D?)
    func fetchPrediction(telemetry: Telemetry?, completion: @escaping ([CLLocationCoordinate2D], Date?, CLLocationCoordinate2D?) -> Void) {
        guard let url = tawhiriURL(from: telemetry) else {
            completion([], nil, nil)
            return
        }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data else {
                DispatchQueue.main.async { completion([], nil, nil) }
                return
            }
            let xmlParser = XMLParser(data: data)
            let parserDelegate = KMLCoordinatesParser()
            xmlParser.delegate = parserDelegate
            if xmlParser.parse() {
                let coordsForMap = parserDelegate.parsedCoordinates.map { CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
                var landingTime: Date? = nil
                if let landingTimeStr = parserDelegate.landingTimeString {
                    var sanitizedLandingTimeStr = landingTimeStr
                    if sanitizedLandingTimeStr.hasSuffix(".") {
                        sanitizedLandingTimeStr.removeLast()
                    }
                    let isoFormatter = ISO8601DateFormatter()
                    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = isoFormatter.date(from: sanitizedLandingTimeStr) {
                        landingTime = date
                    }
                }
                let burstCoord = parserDelegate.burstCoordinate
                DispatchQueue.main.async {
                    completion(coordsForMap, landingTime, burstCoord)
                }
            } else {
                DispatchQueue.main.async { completion([], nil, nil) }
            }
        }
        task.resume()
    }
}

class KMLCoordinatesParser: NSObject, XMLParserDelegate {
    // ...[Insert entire KMLCoordinatesParser from PredictionLogic.swift here]...
    /*
    For brevity, paste the full definition from PredictionLogic.swift here in your local codebase.
    */
}

// MARK: - BLEManager and BLE helpers
// ...[Insert BLEManager, TelemetryBuffer, SondeSettings, and UserDefaults BLE helpers from BLEManager.swift here]...
/*
For brevity, paste the full definitions from BLEManager.swift here in your local codebase, including:
- struct SondeSettings
- struct TelemetryStruct
- actor TelemetryBuffer
- class BLEManager (+ extensions for CBCentralManagerDelegate and CBPeripheralDelegate)
- UserDefaults BLE helper extensions
*/
