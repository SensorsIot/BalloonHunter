import SwiftUI
import MapKit
import Combine
import CoreLocation

struct MapView: View {
    @EnvironmentObject var annotationService: AnnotationService
    @EnvironmentObject var routeService: RouteCalculationService
    @EnvironmentObject var locationService: CurrentLocationService
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var predictionService: PredictionService
    @EnvironmentObject var persistenceService: PersistenceService
    @EnvironmentObject var userSettings: UserSettings

    @State private var hasInitiallyCenteredOnUser = false
    @State private var hasInitiallyFittedAllPoints = false

    @State private var cameraPosition = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    )
    @State private var transportMode: TransportationMode = .car
    @State private var predictionTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @State private var showSettings = false
    @State private var showPredictionError = true
    
    @State private var showSondeSettings = false

    // New state for device heading
    @State private var deviceHeading: CLLocationDirection = 0
    
    // New state for final approach camera position
    @State private var finalApproachCameraPosition: MapCameraPosition? = nil

    // CLLocationManager for compass heading
    private let locationManager = CLLocationManager()
    @State private var headingDelegate: HeadingDelegate? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                HStack {
                    Spacer()
                    Button(action: { showSondeSettings = true }) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title2)
                            .padding(12)
                            .background(Color(.systemBackground).opacity(0.8))
                            .clipShape(Circle())
                    }
                    .padding([.top, .trailing], 18)
                }
                
                VStack(spacing: 0) {
                    // Remove Picker when in finalApproach
                    if annotationService.appState != .finalApproach {
                        HStack {
                            Spacer()
                            Picker("Mode", selection: $transportMode) {
                                Text("Car").tag(TransportationMode.car)
                                Text("Bicycle").tag(TransportationMode.bike)
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .padding([.top, .horizontal])
                            Spacer()
                        }
                    }

                    // Map content always present
                    if annotationService.appState == .finalApproach {
                        // Final Approach Map with swipe gesture to show settings
                        // Use averagedBalloonLandedPosition() instead of bleService.balloonLandedPosition
                        let userCoord = locationService.locationData.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                        let balloonLandedCoord = averagedBalloonLandedPosition()
                        
                        Map(position: Binding(get: { finalApproachCameraPosition ?? cameraPosition }, set: { _ in })) {
                            // Show only user and averaged balloon landed position markers
                            if let userCoord = userCoord {
                                Annotation("", coordinate: userCoord) {
                                    Image(systemName: "person.circle")
                                }
                            }
                            if let balloonCoord = balloonLandedCoord {
                                Annotation("", coordinate: balloonCoord) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundColor(.purple)
                                        .font(.title)
                                        .shadow(radius: 2)
                                }
                            }
                            
                            // Draw recent telemetry track from currentSondeTrack if not empty
                            if !bleService.currentSondeTrack.isEmpty {
                                MapPolyline(coordinates: bleService.currentSondeTrack.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                                    .stroke(.red, lineWidth: 2)
                            }
                        }
                        .mapControls {
                            MapCompass()
                            MapPitchToggle()
                            MapUserLocationButton()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .top)
                        // Swipe up gesture attached to the map, triggers showSondeSettings
                        .gesture(DragGesture(minimumDistance: 3.0, coordinateSpace: .local)
                            .onEnded { value in
                                if value.translation.height < 0 && abs(value.translation.width) < abs(value.translation.height) {
                                    showSondeSettings = true
                                }
                            })
                        .onAppear { updateFinalApproachCamera(geometry: geometry) }
                        .onChange(of: deviceHeading) { _, _ in updateFinalApproachCamera(geometry: geometry) }
                        .onChange(of: locationService.locationData) { _, _ in updateFinalApproachCamera(geometry: geometry) }
                        .onChange(of: bleService.currentSondeTrack) { _, _ in updateFinalApproachCamera(geometry: geometry) }
                    } else { // .startup or .longRangeTracking
                        ZStack(alignment: .top) {
                            if case .error(let message) = predictionService.predictionStatus, showPredictionError {
                                Color(.systemBackground)
                                VStack {
                                    Text("Prediction Error: \(message)")
                                        .foregroundColor(.white)
                                        .padding(8)
                                        .background(Color.red.opacity(0.8))
                                        .cornerRadius(8)
                                        .padding(.top, 50)
                                        .onTapGesture {
                                            showPredictionError = false
                                        }
                                }
                            } else {
                                Map(position: $cameraPosition) {
                                    // User annotation if available
                                    if let userLocation = locationService.locationData {
                                        Annotation("",coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)) {
                                            Image(systemName: "person.circle")
                                        }
                                    }
                                    // Balloon annotation if available
                                    if let balloonTelemetry = bleService.latestTelemetry {
                                        let isAscending = balloonTelemetry.verticalSpeed >= 0 // Assuming this is needed for color
                                        let color: Color = {
                                            if let lastUpdate = bleService.lastTelemetryUpdateTime, Date().timeIntervalSince(lastUpdate) <= 3 {
                                                return .green
                                            } else {
                                                return .red
                                            }
                                        }()

                                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: balloonTelemetry.latitude, longitude: balloonTelemetry.longitude)) {
                                            BalloonAnnotationView(
                                                altitude: balloonTelemetry.altitude,
                                                isRecent: (bleService.lastTelemetryUpdateTime.map { Date().timeIntervalSince($0) <= 3 } ?? false)
                                            )
                                        }
                                    }
                                    // Landing annotation if available
                                    if let landingPoint = predictionService.predictionData?.landingPoint {
                                        Annotation("", coordinate: landingPoint) {
                                            Image(systemName: "flag.checkered")
                                        }
                                    }
                                    // Burst annotation if available
                                    if let burstPoint = predictionService.predictionData?.burstPoint {
                                        Annotation("", coordinate: burstPoint) {
                                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                        }
                                    }
                                    // Draw historical track (thin red line)
                                    if !bleService.currentSondeTrack.isEmpty {
                                        MapPolyline(coordinates: bleService.currentSondeTrack.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                                            .stroke(.red, lineWidth: 2)
                                    }

                                    // Draw predicted path (thick blue line)
                                    if let predictedPath = predictionService.predictionData?.path {
                                        MapPolyline(coordinates: predictedPath)
                                            .stroke(.blue, lineWidth: 4)
                                    }
                                    
                                    // Draw user’s planned route (thick green line) on top of others
                                    if let routePath = routeService.routeData?.path, routePath.count >= 2 {
                                        MapPolyline(coordinates: routePath)
                                            .stroke(.green, lineWidth: 5)
                                    }
                                }
                                .mapControls {
                                    MapCompass()
                                    MapPitchToggle()
                                    MapUserLocationButton()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .top)
                    }
                    
                    // Remove DataPanelView in finalApproach
                    if annotationService.appState != .finalApproach {
                        DataPanelView()
                            .frame(maxWidth: .infinity)
                            .background(Color(.systemBackground).opacity(0.95))
                            // Swipe up gesture attached to DataPanelView triggers showSondeSettings
                            .gesture(DragGesture(minimumDistance: 3.0, coordinateSpace: .local)
                                .onEnded { value in
                                    if value.translation.height < 0 && abs(value.translation.width) < abs(value.translation.height) {
                                        showSondeSettings = true
                                    }
                                })
                    }
                }
                Text("Heading: \(String(format: "%.0f", deviceHeading))°")
                    .padding(8)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .padding([.top, .leading], 16)
                    .font(.headline)
            }
            .background(Color(.systemGroupedBackground))
            .onAppear { // Moved here
                updateAppState()

                // Setup locationManager for heading updates only once
                let newDelegate = HeadingDelegate { newHeading in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.deviceHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
                    }
                }
                self.headingDelegate = newDelegate
                locationManager.delegate = newDelegate
                locationManager.requestWhenInUseAuthorization()
                if CLLocationManager.headingAvailable() {
                    locationManager.headingFilter = 1
                    locationManager.startUpdatingHeading()
                    print("[DEBUG][HEADING] Called startUpdatingHeading() - waiting for heading updates...")
                } else {
                    print("[DEBUG] CLLocationManager.headingAvailable() is false. Heading updates will not be received.")
                }
            }
            .onChange(of: predictionService.predictionStatus) { _, status in
                if case .error = status {
                    showPredictionError = true
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showSondeSettings) {
            SettingsView()
        }
        .onReceive(locationService.$locationData) { locationData in
            if !hasInitiallyCenteredOnUser, let userLocation = locationData {
                cameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude), span: MKCoordinateSpan(latitudeDelta: 0.225, longitudeDelta: 0.225))) // 25km span
                hasInitiallyCenteredOnUser = true
            }
            recalculateRoute()
            updateAppState()
        }
        .onReceive(bleService.telemetryData) { telemetry in
            updateAppState()
            // Prevent prediction fetch during finalApproach
            if annotationService.appState != .finalApproach {
                Task {
                    await predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
                }
            }
            
            // Append telemetry only in finalApproach; clear otherwise
            if annotationService.appState == .finalApproach {
                // No longer using finalApproachTelemetry buffer, currentSondeTrack is the source
            } else {
                // No longer using finalApproachTelemetry buffer
            }
        }
        .onReceive(predictionService.$predictionData) { _ in
            recalculateRoute()
            updateAppState()
        }
        .onReceive(routeService.$routeData) { _ in
            updateAppState()
        }
        .onReceive(predictionTimer) { _ in
            if let telemetry = bleService.latestTelemetry {
                print("[Debug][MapView][State: \(SharedAppState.shared.appState.rawValue)] Periodic prediction trigger.")
                Task {
                    await predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
                }
            }
        }
        .onChange(of: transportMode) { _, _ in
            recalculateRoute()
        }
    }

    private func updateAppState() {
        annotationService.updateState(
            telemetry: bleService.latestTelemetry,
            userLocation: locationService.locationData,
            prediction: predictionService.predictionData,
            route: routeService.routeData,
            telemetryHistory: bleService.currentSondeTrack.map { TelemetryData(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude) }
        )

        if annotationService.appState == .longRangeTracking && !hasInitiallyFittedAllPoints {
             if locationService.locationData != nil,
                bleService.latestTelemetry != nil,
                predictionService.predictionData?.landingPoint != nil,
                !bleService.currentSondeTrack.isEmpty {
                 updateCameraToFitAllPoints()
                 hasInitiallyFittedAllPoints = true
             }
        }
    }

    private func recalculateRoute() {
        guard let userLocation = locationService.locationData,
              let prediction = predictionService.predictionData,
              let landingPoint = prediction.landingPoint else { return }

        routeService.calculateRoute(
            from: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
            to: landingPoint,
            transportType: transportMode
        )
    }
    
    private func updateCameraToFitAllPoints() {
        var points: [CLLocationCoordinate2D] = []
        var labeledPoints: [(label: String, coordinate: CLLocationCoordinate2D)] = []
        
        // Only user, balloon, and landing are used for camera fit.
        
        if let userLocation = locationService.locationData {
            let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
            points.append(userCoord)
            labeledPoints.append(("User", userCoord))
        }
        
        if let balloonTelemetry = bleService.latestTelemetry {
            let balloonCoord = CLLocationCoordinate2D(latitude: balloonTelemetry.latitude, longitude: balloonTelemetry.longitude)
            points.append(balloonCoord)
            labeledPoints.append(("Balloon", balloonCoord))
        }
        
        if let landing = predictionService.predictionData?.landingPoint {
            points.append(landing)
            labeledPoints.append(("Landing", landing))
        }
        
        // Filter out invalid or zero coordinates
        let validPoints = points.filter { CLLocationCoordinate2DIsValid($0) && ($0.latitude != 0 || $0.longitude != 0) }
        
        guard validPoints.count >= 2 else {
            return
        }
        
        let latitudes = validPoints.map { $0.latitude }
        let longitudes = validPoints.map { $0.longitude }
        
        guard let minLat = latitudes.min(),
              let maxLat = latitudes.max(),
              let minLon = longitudes.min(),
              let maxLon = longitudes.max() else {
            return
        }
        
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        
        var latitudeDelta = (maxLat - minLat) * 1.3
        var longitudeDelta = (maxLon - minLon) * 1.3
        
        let minDelta = 0.05
        latitudeDelta = max(latitudeDelta, minDelta)
        longitudeDelta = max(longitudeDelta, minDelta)
        
        let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
        let span = MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        // Update camera position to the computed region to fit all points with padding
        cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }

    private func updateFinalApproachCamera(geometry: GeometryProxy) {
        let userCoord = locationService.locationData.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let balloonLandedCoord = averagedBalloonLandedPosition()
        finalApproachCameraPosition = computeFinalApproachCameraPosition(
            geometry: geometry,
            userCoord: userCoord,
            balloonLandedCoord: balloonLandedCoord,
            rotationDegrees: deviceHeading
        )
    }

    private func collectAllCoordinates() -> [CLLocationCoordinate2D] {
        var allCoordinates: [CLLocationCoordinate2D] = []
        
        if let userLocation = locationService.locationData {
            allCoordinates.append(CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude))
        }
        
        if let balloonTelemetry = bleService.latestTelemetry {
            allCoordinates.append(CLLocationCoordinate2D(latitude: balloonTelemetry.latitude, longitude: balloonTelemetry.longitude))
        }
        
        if let landingPoint = predictionService.predictionData?.landingPoint {
            allCoordinates.append(landingPoint)
        }
        
        if let burstPoint = predictionService.predictionData?.burstPoint {
            allCoordinates.append(burstPoint)
        }
        
        allCoordinates.append(contentsOf: bleService.currentSondeTrack.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
        
        if let predictedPath = predictionService.predictionData?.path {
            allCoordinates.append(contentsOf: predictedPath)
        }
        
        return allCoordinates
    }
    
    

    // Helper to compute final approach camera position with rotation and offset so user is bottom-center and balloon landed visible
    private func computeFinalApproachCameraPosition(
        geometry: GeometryProxy,
        userCoord: CLLocationCoordinate2D?,
        balloonLandedCoord: CLLocationCoordinate2D?,
        rotationDegrees: CLLocationDirection
    ) -> MapCameraPosition {
        guard let user = userCoord, let balloon = balloonLandedCoord else {
            // Fallback to current cameraPosition without rotation
            return cameraPosition
        }

        // Convert coordinates to MKMapPoint for calculation
        let userMapPoint = MKMapPoint(user)
        let balloonMapPoint = MKMapPoint(balloon)

        // Calculate the distance between user and balloon in map points (meters)
        let verticalDistance = abs(balloonMapPoint.y - userMapPoint.y)
        let horizontalDistance = abs(balloonMapPoint.x - userMapPoint.x)

        // Get the aspect ratio of the visible map (width/height)
        let aspectRatio = geometry.size.width / max(geometry.size.height, 1)

        // Padding as a small fraction of the distance (e.g., 10%)
        let paddingFraction = 0.15
        let verticalPadding = verticalDistance * paddingFraction
        let horizontalPadding = horizontalDistance * paddingFraction

        // The visible height should be enough to fit from user (at bottom) to balloon (near top)
        let visibleMapHeight = max(verticalDistance + verticalPadding, 100) // Minimum 100m
        let visibleMapWidth = max(horizontalDistance + horizontalPadding, visibleMapHeight * aspectRatio, 100)

        // Now, we want the center coordinate such that the user is at the bottom-center.
        // Compute offset in map points: move center down so user is at the bottom.
        // On the screen, half the map height is above center, half below; user should be at (-height/2) from center.
        let centerOffsetY = visibleMapHeight / 2

        // To account for rotation, rotate the offset vector by the heading (so user stays at bottom after map rotation)
        let rotationRadians = -rotationDegrees * .pi / 180
        let offsetX = 0.0 // Always center horizontally
        let offsetY = -centerOffsetY // Negative: move center toward balloon
        let rotatedOffsetX = offsetX * cos(rotationRadians) - offsetY * sin(rotationRadians)
        let rotatedOffsetY = offsetX * sin(rotationRadians) + offsetY * cos(rotationRadians)

        // Place the center: start at user's point and move up rotated by device heading
        let adjustedCenterMapPoint = MKMapPoint(
            x: userMapPoint.x + rotatedOffsetX,
            y: userMapPoint.y + rotatedOffsetY
        )
        let adjustedCenterCoord = adjustedCenterMapPoint.coordinate

        // Convert meters to degrees for span (approximate)
        let metersPerDegreeLat = 111_000.0
        let metersPerDegreeLon = metersPerDegreeLat * cos(user.latitude * .pi / 180)
        let latitudeDelta = visibleMapHeight / metersPerDegreeLat
        let longitudeDelta = visibleMapWidth / metersPerDegreeLon
        _ = MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)

        // Estimate a reasonable camera distance (for 2D map; otherwise adjust for 3D view if needed)
        let cameraDistance = max(visibleMapHeight * 2, 250) // At least 250m
        let camera = MapCamera(centerCoordinate: adjustedCenterCoord, distance: cameraDistance, heading: rotationDegrees, pitch: 0)
        return .camera(camera)
    }
    
    /// Helper method to compute the averaged balloon landed position from up to last 100 telemetry points after landing,
    /// only relevant in finalApproach state.
    private func averagedBalloonLandedPosition() -> CLLocationCoordinate2D? {
        guard annotationService.appState == .finalApproach else {
            return nil
        }
        // Use last up to 100 telemetry points in finalApproachTelemetry buffer
        let recentTelemetry = bleService.currentSondeTrack.suffix(100)
        guard !recentTelemetry.isEmpty else { return nil }
        
        let sumLat = recentTelemetry.reduce(0.0) { $0 + $1.latitude }
        let sumLon = recentTelemetry.reduce(0.0) { $0 + $1.longitude }
        
        let avgLat = sumLat / Double(recentTelemetry.count)
        let avgLon = sumLon / Double(recentTelemetry.count)
        
        let avgCoord = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
        guard CLLocationCoordinate2DIsValid(avgCoord) else { return nil }
        return avgCoord
    }
}

// Delegate class to handle heading updates
private class HeadingDelegate: NSObject, CLLocationManagerDelegate {
    private let headingUpdateHandler: (CLHeading) -> Void
    
    init(headingUpdateHandler: @escaping (CLHeading) -> Void) {
        self.headingUpdateHandler = headingUpdateHandler
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        print("[DEBUG][HEADING] Received heading: trueHeading=\(newHeading.trueHeading), magneticHeading=\(newHeading.magneticHeading)")
        print("[DEBUG] Heading update: trueHeading=\(newHeading.trueHeading), magneticHeading=\(newHeading.magneticHeading)")
        headingUpdateHandler(newHeading)
    }
    
    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}
