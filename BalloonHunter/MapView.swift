import SwiftUI
import MapKit
import CoreLocation

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
                let visibleCoords = coordinates.filter { coord in
                    let latMin = region.center.latitude - region.span.latitudeDelta/2
                    let latMax = region.center.latitude + region.span.latitudeDelta/2
                    let lonMin = region.center.longitude - region.span.longitudeDelta/2
                    let lonMax = region.center.longitude + region.span.longitudeDelta/2
                    return coord.latitude >= latMin && coord.latitude <= latMax && coord.longitude >= lonMin && coord.longitude <= lonMax
                }
                guard visibleCoords.count > 1 else { return }
                path.move(to: point(for: visibleCoords[0], in: geo.size))
                for coord in visibleCoords.dropFirst() {
                    path.addLine(to: point(for: coord, in: geo.size))
                }
            }
            .stroke(Color.red, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

private struct UserLocationOverlay: View {
    let coordinate: CLLocationCoordinate2D
    let region: MKCoordinateRegion

    private func point(for coordinate: CLLocationCoordinate2D, in size: CGSize) -> CGPoint {
        let span = region.span
        let center = region.center
        let x = (coordinate.longitude - (center.longitude - span.longitudeDelta/2)) / span.longitudeDelta * size.width
        let y = (1 - (coordinate.latitude - (center.latitude - span.latitudeDelta/2)) / span.latitudeDelta) * size.height
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { geo in
            let latMin = region.center.latitude - region.span.latitudeDelta/2
            let latMax = region.center.latitude + region.span.latitudeDelta/2
            let lonMin = region.center.longitude - region.span.longitudeDelta/2
            let lonMax = region.center.longitude + region.span.longitudeDelta/2
            if coordinate.latitude >= latMin && coordinate.latitude <= latMax &&
                coordinate.longitude >= lonMin && coordinate.longitude <= lonMax {
                let point = point(for: coordinate, in: geo.size)
                Image(systemName: "location.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.blue)
                    .shadow(radius: 4)
                    .position(x: point.x, y: point.y)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PredictionTrackOverlay: View {
    let predictionTrack: [CLLocationCoordinate2D]
    let region: MKCoordinateRegion

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

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Path { path in
                    guard predictionTrack.count > 1 else { return }

                    // Draw path segments only where both points are inside the region
                    var didStart = false
                    for i in 0..<(predictionTrack.count - 1) {
                        let startCoord = predictionTrack[i]
                        let endCoord = predictionTrack[i + 1]
                        if isCoordinate(startCoord, in: region) && isCoordinate(endCoord, in: region) {
                            if !didStart {
                                path.move(to: point(for: startCoord, in: geo.size, region: region))
                                didStart = true
                            }
                            path.addLine(to: point(for: endCoord, in: geo.size, region: region))
                        } else {
                            didStart = false
                        }
                    }
                }
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                
                if predictionTrack.count >= 2 {
                    let fallbackIndex = predictionTrack.count / 2
                    let burstCoord = predictionTrack[min(fallbackIndex, predictionTrack.count - 1)]
                    if isCoordinate(burstCoord, in: region) {
                        let point = point(for: burstCoord, in: geo.size, region: region)
                        Image(systemName: "burst.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.yellow)
                            .shadow(radius: 4)
                            .position(x: point.x, y: point.y)
                    }
                }
            }
        }
        .opacity(predictionTrack.count > 1 ? 1 : 0)
        .allowsHitTesting(false)
    }
}

private struct DrivingRouteOverlay: View {
    let drivingRoute: MKPolyline?
    let region: MKCoordinateRegion

    private func point(for coordinate: CLLocationCoordinate2D, in size: CGSize, region: MKCoordinateRegion) -> CGPoint {
        let span = region.span
        let center = region.center
        let x = (coordinate.longitude - (center.longitude - span.longitudeDelta/2)) / span.longitudeDelta * size.width
        let y = (1 - (coordinate.latitude - (center.latitude - span.latitudeDelta/2)) / span.latitudeDelta) * size.height
        return CGPoint(x: x, y: y)
    }

    var body: some View {
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
}

private struct LastPredictionPinOverlay: View {
    let lastPredictionPin: MapView.MapPin?
    let region: MKCoordinateRegion

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

    var body: some View {
        GeometryReader { geo in
            if let lastPredictionPin = lastPredictionPin {
                if isCoordinate(lastPredictionPin.coordinate, in: region) {
                    let point = point(for: lastPredictionPin.coordinate, in: geo.size, region: region)
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 16, height: 16)
                        .position(x: point.x, y: point.y)
                        .shadow(radius: 4)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct AveragePinOverlay: View {
    let avgCoord: CLLocationCoordinate2D
    let region: MKCoordinateRegion

    private func point(for coordinate: CLLocationCoordinate2D, in size: CGSize, region: MKCoordinateRegion) -> CGPoint {
        let span = region.span
        let center = region.center
        let x = (coordinate.longitude - (center.longitude - span.longitudeDelta/2)) / span.longitudeDelta * size.width
        let y = (1 - (coordinate.latitude - (center.latitude - span.latitudeDelta/2)) / span.latitudeDelta) * size.height
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { geo in
            let latMin = region.center.latitude - region.span.latitudeDelta/2
            let latMax = region.center.latitude + region.span.latitudeDelta/2
            let lonMin = region.center.longitude - region.span.longitudeDelta/2
            let lonMax = region.center.longitude + region.span.longitudeDelta/2
            if avgCoord.latitude >= latMin && avgCoord.latitude <= latMax &&
                avgCoord.longitude >= lonMin && avgCoord.longitude <= lonMax {
                let point = point(for: avgCoord, in: geo.size, region: region)
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.orange)
                    .shadow(radius: 4)
                    .position(x: point.x, y: point.y)
                    .accessibilityLabel("Average position marker in Final Approach Mode")
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MainPinOverlay: View {
    let annotationItems: [MapView.MapPin]
    let region: MKCoordinateRegion
    let mainPinColor: Color
    let isInFinalApproachMode: Bool
    let averageCoord: CLLocationCoordinate2D?
    let onTap: () -> Void

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

    private func annotationMainPin(color: Color, onTap: @escaping () -> Void) -> some View {
        Circle()
            .fill(color)
            .frame(width: 32, height: 32)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(radius: 4)
            .onTapGesture { onTap() }
    }
    
    private func annotationAveragePin() -> some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(radius: 4)
    }

    var body: some View {
        GeometryReader { geo in
            if let mainPin = annotationItems.first(where: { $0.type == .main }) {
                if isCoordinate(mainPin.coordinate, in: region) {
                    let point = point(for: mainPin.coordinate, in: geo.size, region: region)
                    annotationMainPin(color: mainPinColor, onTap: onTap)
                        .position(x: point.x, y: point.y)
                }
            }
            if isInFinalApproachMode, let avgCoord = averageCoord {
                if isCoordinate(avgCoord, in: region) {
                    let point = point(for: avgCoord, in: geo.size, region: region)
                    annotationAveragePin()
                        .position(x: point.x, y: point.y)
                }
            }
        }
        .allowsHitTesting(true)
    }
}


struct MapView: View {
    @ObservedObject var ble = BLEManager.shared
    @ObservedObject var locationManager: LocationManager
    @EnvironmentObject var predictionInfo: PredictionInfo

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.8, longitude: 8.3),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )
    @State private var balloonTrack: [CLLocationCoordinate2D] = []
    @State private var predictionTrack: [CLLocationCoordinate2D] = []
    @State private var apiTimer: Timer? = nil
    @State private var landingTime: Date? = nil

    @State private var drivingRoute: MKPolyline? = nil
    
    // NEW STATE VARIABLES
    @State private var isInFinalApproachMode: Bool = false
    @State private var recentTelemetryCoordinates: [CLLocationCoordinate2D] = []
    @State private var deviceHeading: CLHeading? = nil
    @State private var lastBalloonUpdateTime: Date? = nil
    
    private enum TransportType: Hashable, CaseIterable {
        case car
        case bike
        
        var toMKDirectionsTransportType: MKDirectionsTransportType {
            switch self {
            case .car:
                return .automobile
            case .bike:
                return .walking // Using walking as bike alternative
            }
        }
        
        var displayName: String {
            switch self {
            case .car:
                return "Car"
            case .bike:
                return "Bike"
            }
        }
    }
    
    @State private var selectedTransportType: TransportType = .car

    private let headingManager = CLLocationManager()
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                routeTypePicker
                ZStack {
                    mapComponent
                    overlaysStack
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Removed SondeDataView rendering here as per instructions
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear {
            // Prediction logic refactored to use PredictionLogic.shared.fetchPrediction instead of callTawhiriAPI
            apiTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                fetchPredictionAndUpdate()
            }
            fetchPredictionAndUpdate()
            headingManager.delegate = HeadingDelegate { heading in
                self.deviceHeading = heading
                // Could trigger UI updates or map rotation here in future
            }
            headingManager.headingFilter = 5 // degrees
            headingManager.startUpdatingHeading()
        }
        .onDisappear {
            apiTimer?.invalidate()
            apiTimer = nil
            headingManager.stopUpdatingHeading()
        }
        .onChange(of: ble.latestTelemetry) { telemetry in
            if let telemetry = telemetry {
                if telemetry.latitude != 0 || telemetry.longitude != 0 {
                    let coord = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
                    if balloonTrack.isEmpty || balloonTrack.last != coord {
                        balloonTrack.append(coord)
                        if balloonTrack.count == 1 {
                            region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))
                        }
                    }
                    // Update lastBalloonUpdateTime when valid telemetry position update occurs
                    lastBalloonUpdateTime = Date()
                }
                // Append to recentTelemetryCoordinates (max 100)
                if telemetry.latitude != 0 || telemetry.longitude != 0 {
                    let newCoord = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
                    recentTelemetryCoordinates.append(newCoord)
                    if recentTelemetryCoordinates.count > 100 {
                        recentTelemetryCoordinates.removeFirst(recentTelemetryCoordinates.count - 100)
                    }
                }
                
                // Determine final approach mode
                if let deviceLoc = locationManager.location?.coordinate,
                   let balloonLoc = balloonTrack.last {
                    let distanceToBalloon = distanceBetween(deviceLoc, balloonLoc)
                    let verticalSpeedAbs = abs(telemetry.verticalSpeed)
                    let isBalloonStationary = isBalloonNotMoving()
                    // Conditions for final approach mode:
                    if verticalSpeedAbs < 1.0 && distanceToBalloon < 1000 && isBalloonStationary {
                        if !isInFinalApproachMode {
                            isInFinalApproachMode = true
                            adjustRegionForFinalApproach()
                        }
                    } else {
                        if isInFinalApproachMode {
                            isInFinalApproachMode = false
                            // Optionally, reset region or leave it as is
                        }
                    }
                } else {
                    if isInFinalApproachMode {
                        isInFinalApproachMode = false
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
        .onChange(of: selectedTransportType) { _ in
            if let current = ble.latestTelemetry, (current.latitude != 0 || current.longitude != 0), let landing = predictionTrack.last {
                let start = CLLocationCoordinate2D(latitude: current.latitude, longitude: current.longitude)
                calculateAppleRoute(from: start, to: landing)
            }
        }
        .onChange(of: locationManager.location) { _ in
            // No specific action needed here, userLocationOverlay reads locationManager.location live
        }
    }
    
    private var routeTypePicker: some View {
        Picker("Route type", selection: $selectedTransportType) {
            ForEach(TransportType.allCases, id: \.self) { type in
                Text(type.displayName).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }
    
    private var mapComponent: some View {
        Map(coordinateRegion: $region)
    }
    
    private var overlaysStack: some View {
        ZStack {
            balloonTrackOverlayView
            predictionTrackOverlayView
            drivingRouteOverlayView
            lastPredictionPinOverlayView
            mainPinOverlayView
            averagePinOverlayView
            userLocationOverlayView
        }
    }
    
    private func fetchPredictionAndUpdate() {
        guard let telemetry = ble.latestTelemetry else { return }
        PredictionLogic.shared.fetchPrediction(telemetry: telemetry) { coordinates, landingTime in
            DispatchQueue.main.async {
                self.predictionTrack = coordinates
                self.landingTime = landingTime
                self.predictionInfo.landingTime = landingTime
            }
        }
    }
    
    private var balloonTrackOverlayView: some View {
        BalloonTrackOverlay(coordinates: balloonTrack, region: region)
            .opacity(balloonTrack.count > 1 ? 1 : 0)
            .allowsHitTesting(false)
    }
    
    private var predictionTrackOverlayView: some View {
        PredictionTrackOverlay(predictionTrack: predictionTrack, region: region)
    }
    
    private var drivingRouteOverlayView: some View {
        DrivingRouteOverlay(drivingRoute: drivingRoute, region: region)
    }
    
    private var lastPredictionPinOverlayView: some View {
        LastPredictionPinOverlay(lastPredictionPin: lastPredictionPin, region: region)
    }
    
    private var averagePinOverlayView: some View {
        Group {
            if isInFinalApproachMode, let avgCoord = averageRecentCoordinates() {
                AveragePinOverlay(avgCoord: avgCoord, region: region)
            }
        }
    }
    
    private var mainPinOverlayView: some View {
        MainPinOverlay(annotationItems: annotationItems,
                       region: region,
                       mainPinColor: mainPinColor,
                       isInFinalApproachMode: isInFinalApproachMode,
                       averageCoord: averageRecentCoordinates(),
                       onTap: { fetchPredictionAndUpdate() })
    }
    
    private var userLocationOverlayView: some View {
        Group {
            if let userCoord = locationManager.location?.coordinate {
                UserLocationOverlay(coordinate: userCoord, region: region)
            }
        }
    }

    private func adjustRegionForFinalApproach() {
        // Adjust the map region to contain both balloonTrack.last and averageRecentCoordinates with some padding
        guard let balloonCoord = balloonTrack.last, let avgCoord = averageRecentCoordinates() else { return }
        let latitudes = [balloonCoord.latitude, avgCoord.latitude]
        let longitudes = [balloonCoord.longitude, avgCoord.longitude]
        let minLat = latitudes.min()!
        let maxLat = latitudes.max()!
        let minLon = longitudes.min()!
        let maxLon = longitudes.max()!
        
        let latSpan = max(0.01, (maxLat - minLat) * 1.4) // Add 40% padding
        let lonSpan = max(0.01, (maxLon - minLon) * 1.4)
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        
        DispatchQueue.main.async {
            withAnimation {
                self.region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan))
            }
        }
    }
    
    private func averageRecentCoordinates() -> CLLocationCoordinate2D? {
        guard !recentTelemetryCoordinates.isEmpty else { return nil }
        let sumLat = recentTelemetryCoordinates.reduce(0) { $0 + $1.latitude }
        let sumLon = recentTelemetryCoordinates.reduce(0) { $0 + $1.longitude }
        return CLLocationCoordinate2D(latitude: sumLat / Double(recentTelemetryCoordinates.count),
                                      longitude: sumLon / Double(recentTelemetryCoordinates.count))
    }
    
    private func isBalloonNotMoving() -> Bool {
        // Check if last N recentTelemetryCoordinates have approximately same lat/lon and alt (altitude is only in telemetry, so use lat/lon here)
        // We use last 5 coordinates for stability check.
        let checkCount = min(5, recentTelemetryCoordinates.count)
        guard checkCount >= 3 else { return false }
        let recentSlice = recentTelemetryCoordinates.suffix(checkCount)
        let latitudes = recentSlice.map { $0.latitude }
        let longitudes = recentSlice.map { $0.longitude }
        let maxLatDiff = (latitudes.max() ?? 0) - (latitudes.min() ?? 0)
        let maxLonDiff = (longitudes.max() ?? 0) - (longitudes.min() ?? 0)
        // Threshold for stationary: less than approx 5 meters (~0.000045 degrees)
        let threshold = 0.000045
        return maxLatDiff < threshold && maxLonDiff < threshold
    }

    private func distanceBetween(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let lat1 = a.latitude * Double.pi / 180
        let lat2 = b.latitude * Double.pi / 180
        let deltaLat = lat2 - lat1
        let deltaLon = (b.longitude - a.longitude) * Double.pi / 180
        let R = 6371000.0 // Earth radius in meters
        let haversine = sin(deltaLat/2) * sin(deltaLat/2) + cos(lat1) * cos(lat2) * sin(deltaLon/2) * sin(deltaLon/2)
        let c = 2 * atan2(sqrt(haversine), sqrt(1 - haversine))
        return R * c
    }

    private func calculateAppleRoute(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) {
        let startPlacemark = MKPlacemark(coordinate: start)
        let endPlacemark = MKPlacemark(coordinate: end)
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: startPlacemark)
        request.destination = MKMapItem(placemark: endPlacemark)
        request.transportType = selectedTransportType.toMKDirectionsTransportType

        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            if let route = response?.routes.first {
                DispatchQueue.main.async {
                    self.drivingRoute = route.polyline
                    self.predictionInfo.arrivalTime = route.expectedTravelTime
                }
            } else {
                // Removed route error print
                DispatchQueue.main.async {
                    self.drivingRoute = nil
                    self.predictionInfo.arrivalTime = nil
                }
            }
        }
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
    
    /// Average marker View (orange)
    private func annotationAveragePin() -> some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(radius: 4)
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

    private var mainPinColor: Color {
        if let lastUpdate = lastBalloonUpdateTime {
            if Date().timeIntervalSince(lastUpdate) < 3 {
                return .green
            } else {
                return .red
            }
        } else {
            return .red
        }
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
            if telemetry.latitude != 0 || telemetry.longitude != 0 {
                pins.append(MapPin(coordinate: CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude), type: .main))
            }
        }
        // Do not add main pin if telemetry is nil or coordinates are zero
        return pins
    }
    
    // The blue marker is always placed at the last coordinate of the prediction track (KML file).
    private var lastPredictionPin: MapPin? {
        guard let last = predictionTrack.last else { return nil }
        return MapPin(coordinate: last, type: .main)
    }

    struct MapPin: Identifiable {
        enum PinType { case main, burst, average }
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

private class HeadingDelegate: NSObject, CLLocationManagerDelegate {
    private let onUpdate: (CLHeading) -> Void
    
    init(onUpdate: @escaping (CLHeading) -> Void) {
        self.onUpdate = onUpdate
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        onUpdate(newHeading)
    }
}

#Preview {
    MapView(locationManager: LocationManager())
}
