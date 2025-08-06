import SwiftUI
import MapKit
import CoreLocation
import Combine // 1. Import Combine at the top if not already imported.

extension CLLocationCoordinate2D: @retroactive Equatable, @retroactive Hashable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(latitude)
        hasher.combine(longitude)
    }
}

extension MKCoordinateRegion: Equatable {
    public static func == (lhs: MKCoordinateRegion, rhs: MKCoordinateRegion) -> Bool {
        lhs.center.latitude == rhs.center.latitude &&
        lhs.center.longitude == rhs.center.longitude &&
        lhs.span.latitudeDelta == rhs.span.latitudeDelta &&
        lhs.span.longitudeDelta == rhs.span.longitudeDelta
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
                Image(systemName: "person.fill")
                    .font(.system(size: 30)) // Changed to person.fill and increased size for visibility
                    .foregroundColor(.blue)
                    .shadow(radius: 4)
                    .position(x: point.x, y: point.y)
            }
        }
        .allowsHitTesting(false)
    }
}

// New UserHumanOverlay displays a human marker at the user's coordinate if visible in region
private struct UserHumanOverlay: View {
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
                Image(systemName: "figure.run")
                    .font(.system(size: 30)) // Increased size as per instructions
                    .foregroundColor(.blue) // Changed to blue for visibility
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
    let burstCoordinate: CLLocationCoordinate2D?

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
                
                if let burstCoord = burstCoordinate, isCoordinate(burstCoord, in: region) {
                    let point = point(for: burstCoord, in: geo.size, region: region)
                    Image(systemName: "burst.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.yellow)
                        .shadow(radius: 4)
                        .position(x: point.x, y: point.y)
                }
            }
        }
        // Hidden only if predictionTrack.count <= 1 (no valid prediction to show)
        .opacity(predictionTrack.count > 1 ? 1 : 0)
        .allowsHitTesting(false)
    }
}

// Modified RouteOverlay to display a single route polyline with configurable color
private struct RouteOverlay: View {
    let routePolyline: MKPolyline?
    let region: MKCoordinateRegion
    let routeColor: Color

    private func point(for coordinate: CLLocationCoordinate2D, in size: CGSize, region: MKCoordinateRegion) -> CGPoint {
        let span = region.span
        let center = region.center
        let x = (coordinate.longitude - (center.longitude - span.longitudeDelta/2)) / span.longitudeDelta * size.width
        let y = (1 - (coordinate.latitude - (center.latitude - span.latitudeDelta/2)) / span.latitudeDelta) * size.height
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let polyline = routePolyline {
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
                    .stroke(routeColor, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    .opacity(0.7)
                }
            }
        }
        // Hidden only if routePolyline is nil (no route to show)
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
        // Hidden if lastPredictionPin is nil or coordinate is outside region
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
        // Hidden if avgCoord is outside region
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
        // Always shown if mainPin or avgCoord is visible in region
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

    // Reintroduced selectedTransportType for route selection (car or bike)
    enum TransportType: String, CaseIterable, Identifiable {
        case car = "Car"
        case bike = "Bike"
        var id: String { rawValue }
    }
    @State private var selectedTransportType: TransportType = .car

    // Only keep one route polyline for the selected mode
    @State private var routePolyline: MKPolyline? = nil
    
    // NEW STATE VARIABLES
    @State private var isInFinalApproachMode: Bool = false
    @State private var recentTelemetryCoordinates: [CLLocationCoordinate2D] = []
    @State private var deviceHeading: CLHeading? = nil
    @State private var lastBalloonUpdateTime: Date? = nil
    @State private var burstCoordinate: CLLocationCoordinate2D? = nil
    
    // 2. Add locationAuthorizationStatus state variable to track location permission status
    @State private var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    
    // Added timerTick to trigger periodic UI updates
    @State private var timerTick: Int = 0
    
    // ADDED routeDistance state to store route distance in meters
    @State private var routeDistance: CLLocationDistance? = nil
    
    // Added didCenterOnHunter to track if we've centered on user location at startup if no balloon telemetry
    @State private var didCenterOnHunter: Bool = false
    
    // Added firstPositionHandled to avoid duplicate fetch/prediction updates on first balloon position
    @State private var firstPositionHandled: Bool = false

    // Added didZoomToFitInitialTracks to zoom once after both tracks available
    @State private var didZoomToFitInitialTracks: Bool = false
    
    private let headingManager = CLLocationManager()
    
    var body: some View {
        GeometryReader { geometry in
            // Adjust this value if your top banner + picker are taller than 100 points
            let topControlsHeight: CGFloat = 100
            
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if isLocationPermissionDenied {
                        Text("Location permission not granted. Please enable it in Settings.")
                            .foregroundColor(.white)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .multilineTextAlignment(.center)
                    }
                    Picker("Transport Type", selection: $selectedTransportType) {
                        ForEach(TransportType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                GeometryReader { mapGeo in
                    ZStack {
                        mapComponent
                        overlaysStack
                    }
                    .frame(width: mapGeo.size.width, height: geometry.size.height - topControlsHeight)
                    .clipped()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear {
            // 3. Update locationAuthorizationStatus on appear
            locationAuthorizationStatus = CLLocationManager().authorizationStatus
            
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
            
            // Center map on hunter location at startup if no balloon telemetry is available
            if (ble.latestTelemetry == nil || (ble.latestTelemetry?.latitude == 0 && ble.latestTelemetry?.longitude == 0)),
               let userCoord = locationManager.location?.coordinate,
               !didCenterOnHunter {
                // Only set region and didCenterOnHunter if the region actually changes (avoid blocking updates)
                let newRegion = MKCoordinateRegion(center: userCoord, span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))
                if region != newRegion {
                    region = newRegion
                    didCenterOnHunter = true
                }
            }

            // Added repeating timer for timerTick
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                timerTick += 1
            }
            
            // Calculate route on appear if possible
            calculateRouteFromUserToLanding()
        }
        .onDisappear {
            apiTimer?.invalidate()
            apiTimer = nil
            headingManager.stopUpdatingHeading()
            // No explicit invalidation of timerTick timer; no strong reference kept so it won't leak
        }
        .onChange(of: ble.latestTelemetry) { telemetry in
            // IMPORTANT FIX:
            // Do NOT allow didCenterOnHunter or firstPositionHandled to block balloonTrack appending or overlays updating.
            // Always append to balloonTrack if telemetry coordinates are valid and different from last.
            if let telemetry = telemetry {
                if telemetry.latitude != 0 || telemetry.longitude != 0 {
                    let coord = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
                    if balloonTrack.isEmpty || balloonTrack.last != coord {
                        balloonTrack.append(coord)
                        
                        // Zoom to fit all overlays (balloon and prediction tracks) on first telemetry.
                        if balloonTrack.count == 1 {
                            var allCoords = balloonTrack
                            if !predictionTrack.isEmpty {
                                allCoords.append(contentsOf: predictionTrack)
                            }
                            if !allCoords.isEmpty {
                                let latitudes = allCoords.map { $0.latitude }
                                let longitudes = allCoords.map { $0.longitude }
                                if let minLat = latitudes.min(),
                                   let maxLat = latitudes.max(),
                                   let minLon = longitudes.min(),
                                   let maxLon = longitudes.max() {
                                    let latSpan = max(0.01, (maxLat - minLat) * 1.1)
                                    let lonSpan = max(0.01, (maxLon - minLon) * 1.1)
                                    let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                                                        longitude: (minLon + maxLon) / 2)
                                    region = MKCoordinateRegion(center: center,
                                                                span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan))
                                } else {
                                    region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))
                                }
                            } else {
                                region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))
                            }
                        }
                        
                        // On first received balloon position, trigger prediction and route calculation
                        // This flag prevents duplicate fetches but does NOT block the balloonTrack updating.
                        if !firstPositionHandled {
                            firstPositionHandled = true
                            fetchPredictionAndUpdate()
                            calculateRouteFromUserToLanding()
                        }
                    }
                }
                // Only update timestamp if a fresh/valid signal is received from the balloon and lat/lon are non-zero
                if ble.validSignalReceived, telemetry.latitude != 0, telemetry.longitude != 0 {
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
        // 4. Update locationAuthorizationStatus when location changes
        .onChange(of: locationManager.location) { newLocation in
            // Update authorization status but DO NOT clear or reset any overlay data or state here to avoid hiding overlays unnecessarily
            locationAuthorizationStatus = CLLocationManager().authorizationStatus
            calculateRouteFromUserToLanding()
        }
        // On change of predictionTrack, user location, or selectedTransportType, calculate route for selected transport mode
        .onChange(of: predictionTrack) { _ in
            // Only zoom once at startup, after first telemetry and prediction/route are available.
            if !didZoomToFitInitialTracks && balloonTrack.count > 0 && predictionTrack.count > 0 {
                // Ensure zoom region includes the hunter position as well as all overlays.
                var allCoords = balloonTrack + predictionTrack
                if let hunterLoc = locationManager.location?.coordinate {
                    allCoords.append(hunterLoc)
                }
                let latitudes = allCoords.map { $0.latitude }
                let longitudes = allCoords.map { $0.longitude }
                if let minLat = latitudes.min(),
                   let maxLat = latitudes.max(),
                   let minLon = longitudes.min(),
                   let maxLon = longitudes.max() {
                    let latSpan = max(0.01, (maxLat - minLat) * 1.1)
                    let lonSpan = max(0.01, (maxLon - minLon) * 1.1)
                    let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                                        longitude: (minLon + maxLon) / 2)
                    withAnimation {
                        region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan))
                    }
                    didZoomToFitInitialTracks = true
                }
            }
            calculateRouteFromUserToLanding()
        }
        .onChange(of: selectedTransportType) { _ in
            calculateRouteFromUserToLanding()
        }
    
    }
    
    // MARK: - Helper to compute region fitting coordinates with padding
    private func regionThatFitsCoordinates(_ coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }
        
        let latitudes = coordinates.map { $0.latitude }
        let longitudes = coordinates.map { $0.longitude }
        
        guard let minLat = latitudes.min(),
              let maxLat = latitudes.max(),
              let minLon = longitudes.min(),
              let maxLon = longitudes.max() else {
            return nil
        }
        
        // Add 10% padding to span
        let latSpan = max(0.01, (maxLat - minLat) * 1.1)
        let lonSpan = max(0.01, (maxLon - minLon) * 1.1)
        
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan))
    }
    
    // 6. Helper computed property to determine if location permission is denied or restricted
    private var isLocationPermissionDenied: Bool {
        locationAuthorizationStatus == .denied || locationAuthorizationStatus == .restricted
    }

    // Calculates route from user's current location to predicted landing location for selected transport type
    private func calculateRouteFromUserToLanding() {
        guard let userLocation = locationManager.location?.coordinate,
              let landingLocation = predictionTrack.last else {
            // Clear route if data missing
            routePolyline = nil
            routeDistance = nil
            predictionInfo.routeDistanceMeters = nil
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: userLocation))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: landingLocation))
        switch selectedTransportType {
        case .car:
            request.transportType = .automobile
        case .bike:
            request.transportType = .cycling
        }

        let directions = MKDirections(request: request)
        directions.calculate { response, error in
            if let route = response?.routes.first {
                DispatchQueue.main.async {
                    self.routePolyline = route.polyline
                    self.routeDistance = route.distance // Store route distance in meters
                    let adjustedTravelTime: TimeInterval
                    switch selectedTransportType {
                    case .car:
                        adjustedTravelTime = route.expectedTravelTime
                    case .bike:
                        adjustedTravelTime = route.expectedTravelTime * 0.7
                    }
                    self.predictionInfo.arrivalTime = Date().addingTimeInterval(adjustedTravelTime)
                    self.predictionInfo.routeDistanceMeters = route.distance
                }
            } else {
                DispatchQueue.main.async {
                    self.routePolyline = nil
                    self.routeDistance = nil
                    self.predictionInfo.routeDistanceMeters = nil
                }
            }
        }
    }
    
    private var mapComponent: some View {
        Map(coordinateRegion: $region)
    }
    
    private var overlaysStack: some View {
        ZStack {
            // BalloonTrackOverlay shown only if balloonTrack has more than 1 coordinate
            balloonTrackOverlayView
            // PredictionTrackOverlay shown only if predictionTrack count > 1
            predictionTrackOverlayView
            // RouteOverlay shown only if routePolyline is not nil, color depends on selected transport type
            routeOverlayView
            // LastPredictionPinOverlay shown only if lastPredictionPin exists and coordinate is inside region
            lastPredictionPinOverlayView
            // MainPinOverlay shown if mainPin is present or averageCoord in final approach mode
            mainPinOverlayView
            // AveragePinOverlay shown only in final approach mode with valid average coordinate
            averagePinOverlayView
            // UserHumanOverlay shows blue person at user coordinate if available and visible in region
            // Only human icon is shown for the user location as per instructions
            userHumanOverlayView
            // UserLocationOverlay removed or replaced with human icon, so removed here
            
            // DebugUserLocationOverlay removed as per instructions
        }
        // NOTE: All overlays are always included to ensure they update correctly,
        // their individual opacity logic controls visibility.
    }
    
    private func fetchPredictionAndUpdate() {
        guard let telemetry = ble.latestTelemetry else { return }
        PredictionLogic.shared.fetchPrediction(telemetry: Telemetry(from: telemetry)) { coordinates, landingTime, burstCoord in
            DispatchQueue.main.async {
                self.predictionTrack = coordinates
                self.landingTime = landingTime
                self.predictionInfo.landingTime = landingTime
                self.burstCoordinate = burstCoord
            }
        }
    }
    
    // BalloonTrackOverlay shown only if balloonTrack.count > 1
    private var balloonTrackOverlayView: some View {
        return BalloonTrackOverlay(coordinates: balloonTrack, region: region)
            .opacity(balloonTrack.count > 1 ? 1 : 0)
            .allowsHitTesting(false)
    }
    
    // PredictionTrackOverlay shown only if predictionTrack.count > 1, else hidden
    private var predictionTrackOverlayView: some View {
        return PredictionTrackOverlay(predictionTrack: predictionTrack, region: region, burstCoordinate: burstCoordinate)
    }
    
    // RouteOverlay shown only if routePolyline is not nil
    private var routeOverlayView: some View {
        RouteOverlay(
            routePolyline: routePolyline,
            region: region,
            routeColor: selectedTransportType == .car ? .purple : .green)
    }
    
    // LastPredictionPinOverlay shown only if lastPredictionPin is not nil and coordinate visible in region
    private var lastPredictionPinOverlayView: some View {
        LastPredictionPinOverlay(lastPredictionPin: lastPredictionPin, region: region)
    }
    
    // AveragePinOverlay shown only if in final approach mode and average coordinate available and visible in region
    private var averagePinOverlayView: some View {
        Group {
            if isInFinalApproachMode, let avgCoord = averageRecentCoordinates() {
                AveragePinOverlay(avgCoord: avgCoord, region: region)
            }
        }
    }
    
    // MainPinOverlay always shown if main pin is present or average coord in final approach mode
    private var mainPinOverlayView: some View {
        MainPinOverlay(annotationItems: annotationItems,
                       region: region,
                       mainPinColor: mainPinColor,
                       isInFinalApproachMode: isInFinalApproachMode,
                       averageCoord: averageRecentCoordinates(),
                       onTap: { fetchPredictionAndUpdate() })
    }
    
    // UserHumanOverlay shown only if user coordinate available and visible in region
    // Only human icon is shown for the user location as per instructions
    private var userHumanOverlayView: some View {
        Group {
            if let userCoord = locationManager.location?.coordinate {
                UserHumanOverlay(coordinate: userCoord, region: region)
            }
        }
    }
    
    // Removed UserLocationOverlay view as only human icon should be shown
    
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
        let _ = timerTick  // Reference timerTick to trigger UI updates on changes
        // Color now depends only on valid signal update timestamp
        if let lastUpdate = lastBalloonUpdateTime {
            let elapsed = Date().timeIntervalSince(lastUpdate)
            if elapsed < 3 {
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
    
    // Helper function to debug print user location - REMOVED print statements as per instructions
    private func debugPrintUserLocation(_ location: CLLocation?) {
        // No debug prints here now
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

