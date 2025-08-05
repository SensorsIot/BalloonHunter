// PredictionLogic.swift
// Encapsulates prediction URL logic, API call, and response parsing for balloon predictions.

import Foundation
import CoreLocation
import MapKit

class PredictionLogic {
    static let shared = PredictionLogic()
    
    private init() {}
    
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
    
    /// Fetches the prediction track and landing time from Tawhiri API and parses the result.
    /// Calls the completion handler on the main thread with ([CLLocationCoordinate2D], Date?)
    func fetchPrediction(telemetry: Telemetry?, completion: @escaping ([CLLocationCoordinate2D], Date?) -> Void) {
        guard let url = tawhiriURL(from: telemetry) else {
            completion([], nil)
            return
        }
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data = data else {
                DispatchQueue.main.async { completion([], nil) }
                return
            }
            let xmlParser = XMLParser(data: data)
            let parserDelegate = KMLCoordinatesParser()
            xmlParser.delegate = parserDelegate
            if xmlParser.parse() {
                let points = parserDelegate.parsedCoordinates
                let filteredPoints = Array(Set(points)) // Remove duplicates
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
                DispatchQueue.main.async {
                    completion(filteredPoints, landingTime)
                }
            } else {
                DispatchQueue.main.async { completion([], nil) }
            }
        }
        task.resume()
    }
}

// MARK: - KMLCoordinatesParser

class KMLCoordinatesParser: NSObject, XMLParserDelegate {
    private let coordinatesTag = "coordinates"
    private var currentElement = ""
    private var foundCharacters = ""
    var parsedCoordinates: [CLLocationCoordinate2D] = []
    var landingTimeString: String? = nil
    private var accumulatingCharacters: String = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        if elementName == coordinatesTag {
            foundCharacters = ""
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == coordinatesTag {
            foundCharacters += string
        }
        accumulatingCharacters += string
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == coordinatesTag {
            let trimmed = foundCharacters.trimmingCharacters(in: .whitespacesAndNewlines)
            let coordinateStrings = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            var coords: [CLLocationCoordinate2D] = []
            for coordString in coordinateStrings {
                let parts = coordString.components(separatedBy: ",")
                if parts.count >= 2,
                   let lon = Double(parts[0]),
                   let lat = Double(parts[1]) {
                    coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                }
            }
            parsedCoordinates.append(contentsOf: coords)
            foundCharacters = ""
            currentElement = ""
        }
    }
    func parserDidEndDocument(_ parser: XMLParser) {
        let lines = accumulatingCharacters.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("Balloon landing at") {
                if let lastCommaRange = line.range(of: ",", options: .backwards) {
                    let afterComma = line[lastCommaRange.upperBound...].trimmingCharacters(in: .whitespaces)
                    if let atRange = afterComma.range(of: "at ") {
                        let timestampStart = atRange.upperBound
                        let timestampStr = afterComma[timestampStart...].trimmingCharacters(in: .whitespacesAndNewlines)
                        landingTimeString = String(timestampStr)
                        break
                    }
                }
            }
        }
    }
}
