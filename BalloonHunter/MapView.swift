import SwiftUI
import MapKit

extension CLLocationCoordinate2D: @retroactive Equatable, @retroactive Hashable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(latitude)
        hasher.combine(longitude)
    }
}

private struct BalloonTrackOverlay: View {
    let coordinates: [CLLocationCoordinate2D]
    let region: MKCoordinateRegion

    private func point(for coordinate: CLLocationCoordinate2D, in size: CGSize) -> CGPoint {
        // Basic equirectangular projection (not perfect, but reasonable for small spans)
        let span = region.span
        let center = region.center
        let x = (coordinate.longitude - (center.longitude - span.longitudeDelta/2)) / span.longitudeDelta * size.width
        let y = (1 - (coordinate.latitude - (center.latitude - span.latitudeDelta/2)) / span.latitudeDelta) * size.height
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard coordinates.count > 1 else { return }
                path.move(to: point(for: coordinates[0], in: geo.size))
                for coord in coordinates.dropFirst() {
                    path.addLine(to: point(for: coord, in: geo.size))
                }
            }
            .stroke(Color.red, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

struct MapView: View {
    @ObservedObject var ble = BLEManager.shared
    @ObservedObject var locationManager: LocationManager

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.8, longitude: 8.3),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )
    @State private var balloonTrack: [CLLocationCoordinate2D] = []
    @State private var predictionTrack: [CLLocationCoordinate2D] = []
    @State private var apiTimer: Timer? = nil
    @State private var landingTime: Date? = nil

    @State private var drivingRoute: MKPolyline? = nil

    private var burstAltitude: Double { 35000 }
    private var burstPin: MapPin? {
        // Find the first predictionTrack point with altitude >= burstAltitude
        // If not possible, use the midpoint as fallback
        guard predictionTrack.count > 1 else { return nil }
        let kmlFirstAltitudeIndex = predictionTrack.firstIndex { coord in
            // Overload latitude field for altitude for this example, or adapt to your track's data structure if coordinate stores altitude
            // For standard CLLocationCoordinate2D, altitude is not present. This will need to be adapted if altitudes are available.
            false // Placeholder; see note below
        } ?? (predictionTrack.count / 2)
        // Just pick the midpoint if you cannot get altitude
        let burstCoord = predictionTrack[min(kmlFirstAltitudeIndex, predictionTrack.count - 1)]
        return MapPin(coordinate: burstCoord, type: .burst)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ZStack {
                    Map(coordinateRegion: $region)
                        .frame(height: geometry.size.height * 0.5)
                        .edgesIgnoringSafeArea(.top)
                    balloonTrackOverlayView
                    predictionTrackOverlayView
                    lastPredictionPinOverlay
                    mainPinOverlay
                    burstPinOverlay
                    drivingRouteOverlay
                }
                .frame(height: geometry.size.height * 0.5)

                /*
                Group {
                    if let telemetry = ble.latestTelemetry {
                        // SondeDataView(telemetry: telemetry)
                    } else {
                        VStack {
                            Text("No telemetry received yet.")
                                .foregroundColor(.secondary)
                                .padding()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                */
                // No telemetry or other content displayed below the map currently.
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear {
            apiTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                callTawhiriAPI()
            }
        }
        .onDisappear {
            apiTimer?.invalidate()
            apiTimer = nil
        }
        .onChange(of: ble.latestTelemetry) { telemetry in
            let coordinate: CLLocationCoordinate2D
            if let telemetry = telemetry {
                if telemetry.latitude == 0 && telemetry.longitude == 0 {
                    if let locCoord = locationManager.location?.coordinate {
                        coordinate = locCoord
                    } else {
                        coordinate = region.center
                    }
                } else {
                    coordinate = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
                }
                region.center = coordinate
                if telemetry.latitude != 0 || telemetry.longitude != 0 {
                    let coord = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
                    if balloonTrack.isEmpty || balloonTrack.last != coord {
                        balloonTrack.append(coord)
                        if !balloonTrack.isEmpty {
                            // Removed debug prints
                        }
                    }
                }
                // Removed calculateAppleRoute call here as per instructions
                /*
                if let landing = predictionTrack.last {
                    calculateAppleRoute(from: coordinate, to: landing)
                }
                */
            }
        }
        .onChange(of: predictionTrack) { track in
            if let current = ble.latestTelemetry, (current.latitude != 0 || current.longitude != 0), let landing = track.last {
                let start = CLLocationCoordinate2D(latitude: current.latitude, longitude: current.longitude)
                calculateAppleRoute(from: start, to: landing)
            }
        }
    }
    
    private var burstPinOverlay: some View {
        GeometryReader { geo in
            if let burstPin = burstPin {
                let point = point(for: burstPin.coordinate, in: geo.size, region: region)
                Image(systemName: "burst.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.yellow)
                    .shadow(radius: 4)
                    .position(x: point.x, y: point.y)
            }
        }
        .allowsHitTesting(false)
    }

    private func calculateAppleRoute(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) {
        let startPlacemark = MKPlacemark(coordinate: start)
        let endPlacemark = MKPlacemark(coordinate: end)
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: startPlacemark)
        request.destination = MKMapItem(placemark: endPlacemark)
        request.transportType = .automobile

        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            if let route = response?.routes.first {
                DispatchQueue.main.async {
                    self.drivingRoute = route.polyline
                }
            } else {
                // Removed route error print
                DispatchQueue.main.async {
                    self.drivingRoute = nil
                }
            }
        }
    }

    private var drivingRouteOverlay: some View {
        GeometryReader { geo in
            if let polyline = drivingRoute {
                Path { path in
                    let points = polyline.points()
                    guard polyline.pointCount > 1 else { return }
                    let firstCoord = points[0].coordinate
                    path.move(to: point(for: firstCoord, in: geo.size, region: region))
                    for i in 1..<polyline.pointCount {
                        let coord = points[i].coordinate
                        path.addLine(to: point(for: coord, in: geo.size, region: region))
                    }
                }
                .stroke(Color.purple, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                .opacity(0.7)
            }
        }
        .allowsHitTesting(false)
    }

    /// Main Pin View
    private func annotationMainPin(color: Color, onTap: @escaping () -> Void) -> some View {
        Circle()
            .fill(color)
            .frame(width: 32, height: 32)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(radius: 4)
            .onTapGesture { onTap() }
    }

    private func timeDifferenceString(from landingTime: Date) -> String {
        let now = Date()
        let diff = Int(landingTime.timeIntervalSince(now) / 60)
        if diff == 0 {
            return "now"
        } else if diff > 0 {
            return "+\(diff) min"
        } else {
            return "\(diff) min"
        }
    }

    private var balloonTrackOverlayView: some View {
        BalloonTrackOverlay(coordinates: balloonTrack, region: region)
            .opacity(balloonTrack.count > 1 ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var predictionTrackOverlayView: some View {
        GeometryReader { geo in
            Path { path in
                let visiblePredictionTrack = predictionTrack.filter { isCoordinate($0, in: region) }
                if visiblePredictionTrack.count > 1 {
                    path.move(to: point(for: visiblePredictionTrack[0], in: geo.size, region: region))
                    for coord in visiblePredictionTrack.dropFirst() {
                        path.addLine(to: point(for: coord, in: geo.size, region: region))
                    }
                }
            }
            .stroke(Color.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .opacity(predictionTrack.count > 1 ? 1 : 0)
        .allowsHitTesting(false)
    }

    private var lastPredictionPinOverlay: some View {
        GeometryReader { geo in
            if let lastPredictionPin = lastPredictionPin {
                let point = point(for: lastPredictionPin.coordinate, in: geo.size, region: region)
                Circle()
                    .fill(Color.blue)
                    .frame(width: 16, height: 16)
                    .position(x: point.x, y: point.y)
                    .shadow(radius: 4)
            }
        }
        .allowsHitTesting(false)
    }

    private var mainPinOverlay: some View {
        GeometryReader { geo in
            if let mainPin = annotationItems.first(where: { $0.type == .main }) {
                let point = point(for: mainPin.coordinate, in: geo.size, region: region)
                annotationMainPin(color: ble.validSignalReceived ? .green : .red, onTap: { callTawhiriAPI() })
                    .position(x: point.x, y: point.y)
            }
        }
        .allowsHitTesting(true)
    }

    private func point(for coordinate: CLLocationCoordinate2D, in size: CGSize, region: MKCoordinateRegion) -> CGPoint {
        let span = region.span
        let center = region.center
        let x = (coordinate.longitude - (center.longitude - span.longitudeDelta/2)) / span.longitudeDelta * size.width
        let y = (1 - (coordinate.latitude - (center.latitude - span.latitudeDelta/2)) / span.latitudeDelta) * size.height
        return CGPoint(x: x, y: y)
    }
    
    private func isCoordinate(_ coordinate: CLLocationCoordinate2D, in region: MKCoordinateRegion) -> Bool {
        let latMin = region.center.latitude - region.span.latitudeDelta/2
        let latMax = region.center.latitude + region.span.latitudeDelta/2
        let lonMin = region.center.longitude - region.span.longitudeDelta/2
        let lonMax = region.center.longitude + region.span.longitudeDelta/2
        return coordinate.latitude >= latMin && coordinate.latitude <= latMax && coordinate.longitude >= lonMin && coordinate.longitude <= lonMax
    }

    private var annotationItems: [MapPin] {
        var pins: [MapPin] = []
        if let telemetry = ble.latestTelemetry {
            if telemetry.latitude == 0 && telemetry.longitude == 0 {
                if let locCoord = locationManager.location?.coordinate {
                    pins.append(MapPin(coordinate: locCoord, type: .main))
                } else {
                    // No valid telemetry or location; use region center
                    pins.append(MapPin(coordinate: region.center, type: .main))
                }
            } else {
                pins.append(MapPin(coordinate: CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude), type: .main))
            }
        } else if let locCoord = locationManager.location?.coordinate {
            pins.append(MapPin(coordinate: locCoord, type: .main))
        } else {
            // No telemetry or location; use region center
            pins.append(MapPin(coordinate: region.center, type: .main))
        }
        if let burstPin = burstPin {
            pins.append(burstPin)
        }
        return pins
    }
    
    // The blue marker is always placed at the last coordinate of the prediction track (KML file).
    private var lastPredictionPin: MapPin? {
        guard let last = predictionTrack.last else { return nil }
        return MapPin(coordinate: last, type: .main)
    }

    struct MapPin: Identifiable {
        enum PinType { case main, burst }
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
        let type: PinType
    }
    
    struct SondeDataView: View {
        let telemetry: Telemetry
        var body: some View {
            GroupBox(label: Text("Sonde Data").font(.headline)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text("Type:"); Spacer(); Text(telemetry.probeType).bold() }
                    HStack { Text("Freq:"); Spacer(); Text(String(format: "%.3f MHz", telemetry.frequency)).bold() }
                    HStack { Text("Lat/Lon:"); Spacer(); Text("\(telemetry.latitude), \(telemetry.longitude)").bold() }
                    HStack { Text("Alt:"); Spacer(); Text("\(Int(telemetry.altitude)) m").bold() }
                    HStack { Text("Batt:"); Spacer(); Text("\(telemetry.batteryPercentage)%").bold() }
                    HStack { Text("Signal:"); Spacer(); Text("\(Int(telemetry.signalStrength)) dB").bold() }
                    HStack { Text("FW:"); Spacer(); Text(telemetry.firmwareVersion).font(.caption) }
                }
            }
            .padding()
            .background(Color(.systemBackground).opacity(0.9))
            .cornerRadius(12)
            .shadow(radius: 6)
        }
    }
}

extension MapView {
    private func tawhiriURL(from telemetry: Telemetry?, format: String = "kml") -> URL? {
        guard telemetry != nil else { return nil }
        let ascentRate = 5
        let burstAltitude = 35000
        // DEBUG: Using fixed debug coordinates and altitudes
        let latitude = 47.47649639804274
        let longitude = 7.759382678078039
        let altitude = telemetry?.altitude ?? 3000
        let descentRate = 5
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

    private func callTawhiriAPI() {
        if let url = tawhiriURL(from: ble.latestTelemetry) {
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                if let error = error {
                    // Removed API call failed print
                } else {
                    // Removed API call succeeded print
                    guard let data = data else {
                        return
                    }
                    let xmlParser = XMLParser(data: data)
                    let parserDelegate = KMLCoordinatesParser()
                    xmlParser.delegate = parserDelegate
                    if xmlParser.parse() {
                        let points = parserDelegate.parsedCoordinates
                        if points.count >= 2 {
                            // Remove duplicates by latitude and longitude before assignment
                            var seen = Set<CLLocationCoordinate2D>()
                            let filteredPoints = points.filter { coord in
                                if seen.contains(coord) {
                                    return false
                                } else {
                                    seen.insert(coord)
                                    return true
                                }
                            }
                            DispatchQueue.main.async {
                                self.predictionTrack = filteredPoints
                                if !self.predictionTrack.isEmpty {
                                    // Removed debug prints
                                }
                                if let landingTimeStr = parserDelegate.landingTimeString {
                                    var sanitizedLandingTimeStr = landingTimeStr
                                    if sanitizedLandingTimeStr.hasSuffix(".") {
                                        sanitizedLandingTimeStr.removeLast()
                                    }
                                    let isoFormatter = ISO8601DateFormatter()
                                    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                    if let date = isoFormatter.date(from: sanitizedLandingTimeStr) {
                                        self.landingTime = date
                                    } else {
                                        self.landingTime = nil
                                    }
                                } else {
                                    self.landingTime = nil
                                }
                            }
                        } else {
                            // Parsed coordinates count less than 2, ignoring prediction track update.
                        }
                    } else {
                        // Failed to parse KML data.
                        if let raw = String(data: data, encoding: .utf8) {
                            // Removed raw KML print
                        } else {
                            // Raw KML data not UTF-8 decodable.
                        }
                    }
                }
            }
            task.resume()
        } else {
            // No telemetry data available to generate Tawhiri URL.
        }
    }
}

private nonisolated class KMLCoordinatesParser: NSObject, XMLParserDelegate {
    private let coordinatesTag = "coordinates"
    private var currentElement = ""
    private var foundCharacters = ""
    var parsedCoordinates: [CLLocationCoordinate2D] = []
    
    var landingTimeString: String? = nil
    
    private var kmlRawLines: [String] = []
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
        // Accumulate all characters for the entire document to find landing time later
        accumulatingCharacters += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == coordinatesTag {
            let trimmed = foundCharacters.trimmingCharacters(in: .whitespacesAndNewlines)
            let coordinateStrings = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            var coords: [CLLocationCoordinate2D] = []
            for coordString in coordinateStrings {
                // Coordinates format: longitude,latitude[,altitude]
                let parts = coordString.components(separatedBy: ",")
                if parts.count >= 2,
                   let lon = Double(parts[0]),
                   let lat = Double(parts[1]) {
                    coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                } else {
                    // Invalid coordinate format
                }
            }
            parsedCoordinates.append(contentsOf: coords)
            foundCharacters = ""
            currentElement = ""
        }
    }
    
    func parserDidEndDocument(_ parser: XMLParser) {
        // Removed debug prints
        // Search in the accumulated characters for a line containing "Balloon landing at"
        // and extract the ISO8601 timestamp after the last comma and " at "
        let lines = accumulatingCharacters.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("Balloon landing at") {
                // Example line: "... Balloon landing at <something>, <timestamp> ..."
                // We try to extract after the last comma, then after "at "
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

#Preview {
    MapView(locationManager: LocationManager())
}
