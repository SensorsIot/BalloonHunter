/*
# AI Assistant Guidelines

Your role: act as a competent Swift programmer to complete this project according to the Functional Specification Document (FSD).

## 1. Follow the FSD
- Follow the FSD: Treat the FSD as the source of truth. Identify missing features or mismatches in the code and implement fixes directly.
- Implement unambiguous tasks immediately (new methods, data model updates, UI changes).
- Check for Next Task: After each task is completed, review the FSD to identify the next highest-priority task or feature to implement.
- Do not create new files without first asking and justifying why.

## 2. Coding Standards
- Use modern Swift idioms: async/await, SwiftData, SwiftUI property wrappers.
- Prefer Apple-native tools; ask before adding third-party dependencies. As a general rule, we prefer native solutions.
- Write maintainable code: separate views, models, and services clearly and place them in the appropriate files.
- Comments: keep minimal, but explain non-obvious logic or trade-offs, or to flag a `TODO` or `FIXME`.

## 3. Decision Making
- For low-level details: decide and implement directly.
- For high-impact design or ambiguous FSD items: Stop and ask, briefly presenting options and trade-offs. When you do, use this format:   `QUESTION: [Brief, clear question] OPTIONS: 1. [Option A and its trade-offs] 2. [Option B and its trade-offs]`
 This applies only to ambiguous FSD items or architectural forks (e.g., choosing between two different data persistence strategies).


## 4. Quality
- Include basic error handling where appropriate.
- Debugging: Add temporary debugging `print()` statements to verify the execution of new features; remove them once confirmed.
- Completion: Once all items in the FSD have been implemented, state "FSD complete. Awaiting further instructions or new requirements."
*/


import SwiftUI
import MapKit
import Combine

struct MapView: View {
    @EnvironmentObject var annotationService: AnnotationService
    @EnvironmentObject var routeService: RouteCalculationService
    @EnvironmentObject var locationService: CurrentLocationService
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var predictionService: PredictionService
    @EnvironmentObject var persistenceService: PersistenceService
    @EnvironmentObject var userSettings: UserSettings

    @State private var longRangeTrackingActive = false
    // Removed @State var balloonDescends: Bool = false
    @State private var hasInitiallyFittedCamera = false
    @State private var initialCameraFitDone = false

    @State private var cameraPosition = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    )
    @State private var transportMode: TransportationMode = .car
    @State private var predictionTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @State private var isFinalApproach = false
    @State private var showSettings = false
    @State private var showPredictionError = true

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Button(action: {
                        showSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.title)
                            .padding()
                            .background(Color.white.opacity(0.8))
                            .clipShape(Circle())
                            .shadow(radius: 5)
                    }
                    .padding(.leading)
                    Spacer()
                    Picker("Mode", selection: $transportMode) {
                        Text("Car").tag(TransportationMode.car)
                        Text("Bicycle").tag(TransportationMode.bike)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding([.top, .horizontal])
                    Spacer()
                }

                if longRangeTrackingActive {
                    if isFinalApproach {
                        Map(position: $cameraPosition) {
                            ForEach(annotationService.annotations.filter { $0.kind == .landed || $0.kind == .user || $0.kind == .burst || $0.kind == .balloon }) { annotation in
                                Annotation("", coordinate: annotation.coordinate) {
                                    switch annotation.kind {
                                    case .user:
                                        Image(systemName: "person.circle")
                                    case .balloon:
                                        Image(systemName: "balloon")
                                    case .landed:
                                        Image(systemName: "balloon.fill")
                                    case .landing:
                                        Image(systemName: "flag.checkered")
                                    case .burst:
                                        Image(systemName: "sparkles")
                                    }
                                }
                            }
                        }
                        .mapControls {
                            MapCompass()
                            MapPitchToggle()
                            MapUserLocationButton()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .top)
                    } else {
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
                                        Annotation("",coordinate: CLLocationCoordinate2D(latitude: balloonTelemetry.latitude, longitude: balloonTelemetry.longitude)) {
                                            Image(systemName: "balloon")
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
                                    if !bleService.telemetryHistory.isEmpty {
                                        MapPolyline(coordinates: bleService.telemetryHistory.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
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
                } else {
                    // Loading or empty state
                    Color(.systemBackground)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                DataPanelView()
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemBackground).opacity(0.95))
            }
            .background(Color(.systemGroupedBackground))
            .onAppear {
                longRangeTrackingActive = true
                // Removed updateCameraToFitAllPoints() and hasInitiallyFittedCamera = true here
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
        .onReceive(locationService.$locationData) { locationData in
            // Updates are now only triggered by valid BLE packets.
            recalculateRoute()
            // Removed updateCameraToFitAllPoints() here
        }
        .onReceive(bleService.telemetryData) { telemetry in
            // Assuming telemetry.latitude and telemetry.longitude are non-optional Double

            // Removed initial camera fit block here

            updateAnnotations()
            predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
            // Removed updateCameraToFitAllPoints() here
        }
        .onReceive(predictionService.$predictionData) { predictionData in
            // Updates are now only triggered by valid BLE packets.

            if !hasInitiallyFittedCamera,
               locationService.locationData != nil,
               bleService.latestTelemetry != nil,
               predictionData?.landingPoint != nil {
                // Only fit camera after receiving valid prediction with landing point
                updateCameraToFitAllPoints()
                hasInitiallyFittedCamera = true
            }

            recalculateRoute()
            // Removed updateCameraToFitAllPoints() here
        }
        .onReceive(predictionTimer) { _ in
            if let telemetry = bleService.latestTelemetry {
                print("[Debug][MapView] Periodic prediction trigger.")
                predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
            }
        }
        .onReceive(annotationService.isFinalApproach) { isFinalApproach in
            self.isFinalApproach = isFinalApproach
            if isFinalApproach {
                print("[Debug][MapView] Entering final approach state")
            }
        }
        .onReceive(predictionService.$appInitializationFinished) { finished in
            if finished, !initialCameraFitDone {
                updateCameraToFitAllPoints()
                initialCameraFitDone = true
            }
        }
        .onChange(of: transportMode) { _, _ in
            recalculateRoute()
        }
        // Removed .onChange(of: bleService.balloonDescends) { value in ... }
    }

    private func updateAnnotations() {
        annotationService.updateAnnotations(telemetry: bleService.latestTelemetry, userLocation: locationService.locationData, prediction: predictionService.predictionData)
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
        let region = MKCoordinateRegion(center: center, span: span)
        
        // Update camera position to the computed region to fit all points with padding
        cameraPosition = .region(region)
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
        
        allCoordinates.append(contentsOf: bleService.telemetryHistory.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
        
        if let predictedPath = predictionService.predictionData?.path {
            allCoordinates.append(contentsOf: predictedPath)
        }
        
        return allCoordinates
    }
}

#Preview {
    MapView()
        .environmentObject(AnnotationService())
        .environmentObject(RouteCalculationService())
        .environmentObject(CurrentLocationService())
        .environmentObject(BLECommunicationService(persistenceService: PersistenceService()))
        .environmentObject(PredictionService())
        .environmentObject(UserSettings())
        .environmentObject(PersistenceService())
}


