import SwiftUI
import MapKit
import Combine
import OSLog
import UIKit

struct TrackingMapView: View {
    
    @State private var containerHeight: CGFloat = 0
    @State private var lastUpdateStateCall: Date? = nil

    @EnvironmentObject var userSettings: UserSettings
    @EnvironmentObject var annotationService: AnnotationService
    @EnvironmentObject var routeService: RouteCalculationService
    @EnvironmentObject var locationService: CurrentLocationService
    @EnvironmentObject var predictionService: PredictionService
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var persistenceService: PersistenceService
    @EnvironmentObject var balloonTrackingService: BalloonTrackingService
    @EnvironmentObject var landingPointService: LandingPointService
    @EnvironmentObject var serviceManager: ServiceManager

    @State private var showSettings = false
    @State private var transportMode: TransportationMode = .car
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417),
        span: MKCoordinateSpan(latitudeDelta: 0.225, longitudeDelta: 0.225) // ~25km span
    )
    @State private var didPerformInitialZoom = false
    @State private var initial25kmZoomDone = false
    @State private var lastRouteCalculationTime: Date?
    @State private var shouldUpdateMapRegion = true // New state variable to control map region updates
    @State private var isDirectionUp = false
    @State private var hasFetchedInitialPrediction = false
    @State private var startupCompleted = false

    // Added missing state for heading mode
    @State private var isHeadingMode: Bool = false

    // State for polyline overlays
    @State private var balloonTrackPolyline: MKPolyline?
    @State private var predictionPathPolyline: MKPolyline?
    @State private var userRoutePolyline: MKPolyline?
    @State private var mapView: MKMapView? = nil

    // State for alert on setting landing point from clipboard feedback
    @State private var showLandingPointSetAlert = false
    @State private var landingPointSetSuccess = false
    
    // State for prediction timer
    @State private var predictionTimer: Timer?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Settings button
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Transport mode picker
                        Picker("Mode", selection: $transportMode) {
                            Image(systemName: "car.fill").tag(TransportationMode.car)
                            Image(systemName: "bicycle").tag(TransportationMode.bike)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)

                        // Prediction toggle button
                        Button {
                            predictionService.togglePredictionPathVisibility()
                        } label: {
                            Image(systemName: predictionService.isPredictionPathVisible ? "eye.fill" : "eye.slash.fill")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Enter Landing Point button (text, only if no valid landing point)
                        if landingPointService.validLandingPoint == nil {
                            Button("Point") {
                                let success = landingPointService.setLandingPointFromClipboard()
                                landingPointSetSuccess = success
                                showLandingPointSetAlert = true
                                // Haptic feedback for user
                                let generator = UINotificationFeedbackGenerator()
                                if success {
                                    generator.notificationOccurred(.success)
                                } else {
                                    generator.notificationOccurred(.error)
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                            .alert(isPresented: $showLandingPointSetAlert) {
                                if landingPointSetSuccess {
                                    return Alert(title: Text("Landing Point Set"), message: Text("Landing point successfully set from clipboard."), dismissButton: .default(Text("OK")))
                                } else {
                                    return Alert(title: Text("Failed to Set Landing Point"), message: Text("No valid coordinates found in clipboard."), dismissButton: .default(Text("OK")))
                                }
                            }
                        }

                        // Overview button (text, only if valid landing point exists)
                        if landingPointService.validLandingPoint != nil {
                            Button("All") {
                                showAllAnnotations()
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            // Show "All" button always for debugging - can be removed later
                            Button("All") {
                                showAllAnnotations()
                            }
                            .buttonStyle(.bordered)
                            .opacity(0.5)
                        }

                        // Free/Heading mode toggle button with label and icon changes and tooltip
                        Button {
                            isHeadingMode.toggle()
                            // Preserve zoom level, update heading appropriately handled in MapView updateUIView
                        } label: {
                            Image(systemName: isHeadingMode ? "location.north.line" : "location")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .help(isHeadingMode ? "Heading Mode: Map follows your heading" : "Free Mode: Pan and zoom the map freely")

                        // Buzzer mute toggle button with icon reflecting state and haptic feedback
                        Button {
                            let currentMuteState = bleService.latestTelemetry?.buzmute ?? false
                            let newMuteState = !currentMuteState
                            bleService.latestTelemetry?.buzmute = newMuteState
                            let command = "o{mute=\(newMuteState ? 1 : 0)}o"
                            bleService.sendCommand(command: command)

                            // Haptic feedback
                            let generator = UINotificationFeedbackGenerator()
                            generator.notificationOccurred(newMuteState ? .warning : .success)
                        } label: {
                            Image(systemName: (bleService.latestTelemetry?.buzmute ?? false) ? "speaker.slash.fill" : "speaker.2.fill")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .help("Toggle buzzer mute/unmute")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }

                MapView(
                    region: $region,
                    annotations: annotationService.annotations,
                    balloonTrack: balloonTrackPolyline,
                    predictionPath: predictionService.isPredictionPathVisible ? predictionPathPolyline : nil, // Respect service visibility
                    userRoute: predictionService.isRouteVisible ? userRoutePolyline : nil, // Respect service visibility
                    mapView: $mapView, // Pass the binding here
                    shouldUpdateMapRegion: $shouldUpdateMapRegion, // Pass the new binding
                    isDirectionUp: isDirectionUp,
                    setIsDirectionUp: { newValue in isDirectionUp = newValue },
                    onAnnotationTapped: { item in
                        if item.kind == .balloon {
                            serviceManager.uiEventPublisher.send(.annotationSelected(item))
                            // Trigger prediction update when balloon marker is tapped
                            triggerPredictionUpdate()
                        }
                    },
                    getUserLocationAndHeading: {
                        guard let location = locationService.locationData else { return nil }
                        let heading = location.heading
                        return (CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude), heading)
                    },
                    serviceManager: serviceManager,
                    isHeadingMode: $isHeadingMode
                )
                .background(Color.blue.opacity(0.2)) // Temporary background for debugging
                .frame(height: geometry.size.height * 0.7) // Map takes 70% of GeometryReader height

                DataPanelView()
                    .frame(maxWidth: .infinity) // Let DataPanelView take its intrinsic height
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
                    .shadow(radius: 0)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onReceive(locationService.$locationData) { locationData in
                if !initial25kmZoomDone, let locationData = locationData {
                    let span25km = MKCoordinateSpan(latitudeDelta: 0.225, longitudeDelta: 0.225)
                    let userRegion = MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude),
                        span: span25km
                    )
                    self.region = userRegion
                    initial25kmZoomDone = true
                }
            }
    }
    
    private func throttledUpdateStateAndCamera() {
        let now = Date()
        if let last = lastUpdateStateCall, now.timeIntervalSince(last) < 1.0 { return } // Increased from 0.5s to 1.0s
        lastUpdateStateCall = now
        updateStateAndCamera()
    }

    private func updateStateAndCamera() {
        // First, update the state
        appLog("updateStateAndCamera called.", category: .ui, level: .debug)

        annotationService.updateState(
            telemetry: bleService.latestTelemetry,
            userLocation: locationService.locationData,
            prediction: predictionService.predictionData,
            route: routeService.routeData,
            telemetryHistory: balloonTrackingService.currentBalloonTrack.map { TelemetryData(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude) },
            lastTelemetryUpdateTime: bleService.lastTelemetryUpdateTime
        )

        // Update polylines
        let trackPoints = balloonTrackingService.currentBalloonTrack.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        
        if !trackPoints.isEmpty {
            let polyline = MKPolyline(coordinates: trackPoints, count: trackPoints.count)
            polyline.title = "balloonTrack"
            if balloonTrackPolyline == nil || !polylinesEqual(lhs: balloonTrackPolyline!, rhs: polyline) {
                self.balloonTrackPolyline = polyline
            }
        } else if balloonTrackPolyline != nil {
            self.balloonTrackPolyline = nil
        }

        if let predictionPath = predictionService.predictionData?.path, !predictionPath.isEmpty {
            let polyline = MKPolyline(coordinates: predictionPath, count: predictionPath.count)
            polyline.title = "predictionPath"
            if predictionPathPolyline == nil || !polylinesEqual(lhs: predictionPathPolyline!, rhs: polyline) {
                self.predictionPathPolyline = polyline
            }
        } else if predictionPathPolyline != nil {
            self.predictionPathPolyline = nil
        }

        if let routePath = routeService.routeData?.path, !routePath.isEmpty {
            let polyline = MKPolyline(coordinates: routePath, count: routePath.count)
            polyline.title = "userRoute"
            if let userLocation = locationService.locationData,
               let balloonLocation = bleService.latestTelemetry {
                let userCLLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
                let balloonCLLocation = CLLocation(latitude: balloonLocation.latitude, longitude: balloonLocation.longitude)
                if userCLLocation.distance(from: balloonCLLocation) < 100 {
                    if userRoutePolyline != nil {
                        self.userRoutePolyline = nil
                    }
                } else {
                    if userRoutePolyline == nil || !polylinesEqual(lhs: userRoutePolyline!, rhs: polyline) {
                        self.userRoutePolyline = polyline
                    }
                }
            } else {
                if userRoutePolyline == nil || !polylinesEqual(lhs: userRoutePolyline!, rhs: polyline) {
                    self.userRoutePolyline = polyline
                }
            }
        } else if userRoutePolyline != nil {
            self.userRoutePolyline = nil
        }

        // Then, update the camera
        
        var annotationsForZoom: [MKAnnotation] = []
        if let userLocation = locationService.locationData {
            let userAnnotation = MKPointAnnotation()
            userAnnotation.coordinate = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
            annotationsForZoom.append(userAnnotation)
        }
        if let landing = landingPointService.validLandingPoint {
            let landingAnnotation = MKPointAnnotation()
            landingAnnotation.coordinate = landing
            annotationsForZoom.append(landingAnnotation)
        }
        if balloonTrackingService.isBalloonFlying {
            if let predictionPath = predictionService.predictionData?.path, !predictionPath.isEmpty {
                let startCoord = predictionPath.first!
                let endCoord = predictionPath.last!
                let startAnnotation = MKPointAnnotation()
                startAnnotation.coordinate = startCoord
                let endAnnotation = MKPointAnnotation()
                endAnnotation.coordinate = endCoord
                annotationsForZoom.append(startAnnotation)
                annotationsForZoom.append(endAnnotation)
            }
            if let routePath = routeService.routeData?.path, !routePath.isEmpty {
                let startCoord = routePath.first!
                let endCoord = routePath.last!
                let startAnnotation = MKPointAnnotation()
                startAnnotation.coordinate = startCoord
                let endAnnotation = MKPointAnnotation()
                endAnnotation.coordinate = endCoord
                annotationsForZoom.append(startAnnotation)
                annotationsForZoom.append(endAnnotation)
            }
        }
        
        if let mapView = mapView {
            // Step 1: After startup completion, show all required annotations with maximum zoom
            if startupCompleted && !didPerformInitialZoom {
                // Always check for required annotations after startup
                var requiredAnnotations: [MKAnnotation] = []
                
                // Add user position annotation
                if let userLocation = locationService.locationData {
                    let userAnnotation = MKPointAnnotation()
                    userAnnotation.coordinate = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
                    userAnnotation.title = "User Position"
                    requiredAnnotations.append(userAnnotation)
                }
                
                // Add landing position annotation
                if let landingPoint = landingPointService.validLandingPoint {
                    let landingAnnotation = MKPointAnnotation()
                    landingAnnotation.coordinate = landingPoint
                    landingAnnotation.title = "Landing Position"
                    requiredAnnotations.append(landingAnnotation)
                }
                
                // Add balloon position if flying
                if balloonTrackingService.isBalloonFlying, let telemetry = bleService.latestTelemetry {
                    let balloonAnnotation = MKPointAnnotation()
                    balloonAnnotation.coordinate = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
                    balloonAnnotation.title = "Balloon Position"
                    requiredAnnotations.append(balloonAnnotation)
                }
                
                if !requiredAnnotations.isEmpty {
                    appLog("TrackingMapView: Showing \(requiredAnnotations.count) required annotations with maximum zoom after startup", category: .ui, level: .info)
                    mapView.showAnnotations(requiredAnnotations, animated: true)
                    didPerformInitialZoom = true
                    
                    // Clean up temporary annotations after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        mapView.removeAnnotations(requiredAnnotations)
                    }
                } else {
                    appLog("TrackingMapView: No required annotations available yet", category: .ui, level: .info)
                }
            }
            
            // Step 2: Handle dynamic updates during normal operation
            if startupCompleted && didPerformInitialZoom {
                let hasSignificantChanges = landingPointService.validLandingPoint != nil && 
                                          balloonTrackingService.isBalloonFlying
                // Only update zoom for major changes to avoid constant map adjustments
                if hasSignificantChanges {
                    // Let user control zoom, annotations will be updated by the map view automatically
                    appLog("TrackingMapView: Significant changes detected, letting map view handle annotation updates", category: .ui, level: .debug)
                }
            }
        }
        
//        Removed custom manual camera/region calculation and updateCameraToFitAllPoints calls.
    }

    private func showAllAnnotations() {
        guard let mapView = mapView else { return }

        var annotationsToDisplay: [MKAnnotation] = []

        // Add user location if available
        if let userLocation = locationService.locationData {
            let userAnnotation = MKPointAnnotation()
            userAnnotation.coordinate = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
            annotationsToDisplay.append(userAnnotation)
        }

        // Add landing point if available
        if let landing = landingPointService.validLandingPoint {
            let landingAnnotation = MKPointAnnotation()
            landingAnnotation.coordinate = landing
            annotationsToDisplay.append(landingAnnotation)
        }

        // Add balloon's current position if available and flying
        if let telemetry = bleService.latestTelemetry, balloonTrackingService.isBalloonFlying {
            let balloonAnnotation = MKPointAnnotation()
            balloonAnnotation.coordinate = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
            annotationsToDisplay.append(balloonAnnotation)
        }

        // Add burst point only if service-driven visibility is true
        if predictionService.isBurstMarkerVisible,
           let prediction = predictionService.predictionData,
           let burst = prediction.burstPoint {
            let burstAnnotation = MKPointAnnotation()
            burstAnnotation.coordinate = burst
            annotationsToDisplay.append(burstAnnotation)
        }

        // Add start/end points of polylines if they exist
        if let balloonTrack = balloonTrackPolyline, let first = balloonTrack.coordinates.first, let last = balloonTrack.coordinates.last {
            let startAnnotation = MKPointAnnotation()
            startAnnotation.coordinate = first
            let endAnnotation = MKPointAnnotation()
            endAnnotation.coordinate = last
            annotationsToDisplay.append(startAnnotation)
            annotationsToDisplay.append(endAnnotation)
        }

        if let predictionPath = predictionService.predictionData?.path, !predictionPath.isEmpty, let first = predictionPath.first, let last = predictionPath.last {
            let startAnnotation = MKPointAnnotation()
            startAnnotation.coordinate = first
            let endAnnotation = MKPointAnnotation()
            endAnnotation.coordinate = last
            annotationsToDisplay.append(startAnnotation)
            annotationsToDisplay.append(endAnnotation)
        }

        if let userRoute = userRoutePolyline, let first = userRoute.coordinates.first, let last = userRoute.coordinates.last {
            let startAnnotation = MKPointAnnotation()
            startAnnotation.coordinate = first
            let endAnnotation = MKPointAnnotation()
            endAnnotation.coordinate = last
            annotationsToDisplay.append(startAnnotation)
            annotationsToDisplay.append(endAnnotation)
        }

        if !annotationsToDisplay.isEmpty {
            mapView.showAnnotations(annotationsToDisplay, animated: true)
        }
    }

    // MARK: - Prediction Timer Methods
    
    private func startPredictionTimer() {
        predictionTimer?.invalidate() // Cancel any existing timer
        predictionTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            triggerPredictionUpdate()
        }
    }
    
    private func stopPredictionTimer() {
        predictionTimer?.invalidate()
        predictionTimer = nil
    }
    
    private func triggerPredictionUpdate() {
        guard let telemetry = bleService.latestTelemetry,
              let userSettings = persistenceService.readPredictionParameters() else {
            return
        }
        
        Task { 
            await predictionService.fetchPrediction(
                telemetry: telemetry, 
                userSettings: userSettings, 
                measuredDescentRate: abs(balloonTrackingService.currentEffectiveDescentRate ?? userSettings.descentRate), 
                version: 0
            ) 
        }
    }
    
    // End of TrackingMapView struct
}

 // Added closing brace to end TrackingMapView struct

// MARK: - MapView UIViewRepresentable

private class CustomMapAnnotation: MKPointAnnotation {
    var item: MapAnnotationItem?
}

private struct MapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let annotations: [MapAnnotationItem]
    let balloonTrack: MKPolyline?
    let predictionPath: MKPolyline?
    let userRoute: MKPolyline?
    @Binding var mapView: MKMapView? // Changed to Binding
    @Binding var shouldUpdateMapRegion: Bool // New binding
    let isDirectionUp: Bool
    let setIsDirectionUp: (Bool) -> Void
    let onAnnotationTapped: (MapAnnotationItem) -> Void
    let getUserLocationAndHeading: (() -> (CLLocationCoordinate2D, CLLocationDirection)?)
    let serviceManager: ServiceManager // Added serviceManager
    @Binding var isHeadingMode: Bool

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard // Changed map style to standard for roads only
        mapView.showsUserLocation = true

        // Explicitly enable user interaction and all interaction types
        mapView.isUserInteractionEnabled = true

        mapView.register(CustomAnnotationView.self, forAnnotationViewWithReuseIdentifier: "custom")

        DispatchQueue.main.async { // Assign on the next run loop cycle
            self.mapView = mapView
        }
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Create stable annotation management
        updateAnnotationsStably(uiView: uiView)

        // Manage overlays more precisely to prevent duplicates
        let currentOverlays = uiView.overlays.compactMap { $0 as? MKPolyline }
        let currentBalloonTrack = currentOverlays.first { $0.title == "balloonTrack" }
        let currentPredictionPath = currentOverlays.first { $0.title == "predictionPath" }
        let currentUserRoute = currentOverlays.first { $0.title == "userRoute" }
        
        // Handle balloonTrack overlay
        if let balloonTrack = balloonTrack {
            if currentBalloonTrack == nil || !polylinesEqual(lhs: currentBalloonTrack!, rhs: balloonTrack) {
                if let current = currentBalloonTrack {
                    uiView.removeOverlay(current)
                }
                uiView.addOverlay(balloonTrack)
            }
        } else if let current = currentBalloonTrack {
            uiView.removeOverlay(current)
        }
        
        // Handle predictionPath overlay
        if let predictionPath = predictionPath {
            if currentPredictionPath == nil || !polylinesEqual(lhs: currentPredictionPath!, rhs: predictionPath) {
                if let current = currentPredictionPath {
                    uiView.removeOverlay(current)
                }
                uiView.addOverlay(predictionPath)
            }
        } else if let current = currentPredictionPath {
            uiView.removeOverlay(current)
        }
        
        // Handle userRoute overlay
        if let userRoute = userRoute {
            if currentUserRoute == nil || !polylinesEqual(lhs: currentUserRoute!, rhs: userRoute) {
                if let current = currentUserRoute {
                    uiView.removeOverlay(current)
                }
                uiView.addOverlay(userRoute)
            }
        } else if let current = currentUserRoute {
            uiView.removeOverlay(current)
        }

        // Control map interaction based on isHeadingMode
        if isHeadingMode {
            uiView.isScrollEnabled = false
            uiView.isZoomEnabled = true
            uiView.isPitchEnabled = false
            uiView.isRotateEnabled = false

            if let (userLocation, userHeading) = getUserLocationAndHeading() {
                let currentCamera = uiView.camera
                // Preserve zoom level (distance) and pitch, update heading to userHeading
                let newCamera = MKMapCamera(lookingAtCenter: userLocation, fromDistance: currentCamera.centerCoordinateDistance, pitch: currentCamera.pitch, heading: userHeading)
                uiView.setCamera(newCamera, animated: true)
            }
        } else {
            uiView.isScrollEnabled = true
            uiView.isZoomEnabled = true
            uiView.isPitchEnabled = true
            uiView.isRotateEnabled = true

            // Reset camera heading to 0 (North) when switching to Free mode but keep existing zoom and pitch
            let currentCamera = uiView.camera
            let newCamera = MKMapCamera(lookingAtCenter: currentCamera.centerCoordinate, fromDistance: currentCamera.centerCoordinateDistance, pitch: currentCamera.pitch, heading: 0)
            uiView.setCamera(newCamera, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self, serviceManager: serviceManager)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapView
        var lastUpdateTrigger: Int = 0
        var serviceManager: ServiceManager

        init(_ parent: MapView, serviceManager: ServiceManager) {
            self.parent = parent
            self.serviceManager = serviceManager
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                switch polyline.title {
                case "balloonTrack":
                    renderer.strokeColor = .red
                    renderer.lineWidth = 1 // Thin red line as specified
                case "predictionPath":
                    renderer.strokeColor = .blue
                    renderer.lineWidth = 4 // Remain thick blue line as requested
                case "userRoute":
                    renderer.strokeColor = .green
                    renderer.lineWidth = 3
                default:
                    break
                }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // serviceManager.uiEventPublisher.send(.cameraRegionChanged(mapView.region)) // Removed to break feedback loop
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                // Custom user location view with runner icon - stable sizing
                let identifier = "userLocation"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                if view == nil {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    // Create stable size and image
                    let size = CGSize(width: 30, height: 30)
                    if let baseImage = UIImage(systemName: "figure.walk") {
                        let renderer = UIGraphicsImageRenderer(size: size)
                        let image = renderer.image { _ in
                            baseImage.withTintColor(.blue, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: .zero, size: size))
                        }
                        view?.image = image
                    }
                    view?.frame = CGRect(origin: .zero, size: size)
                    view?.centerOffset = CGPoint(x: 0, y: 0)
                    view?.backgroundColor = .clear
                } else {
                    // Just update the annotation, don't recreate the view
                    view?.annotation = annotation
                }
                return view
            }
            
            guard let annotation = annotation as? CustomMapAnnotation else { return nil }

            let identifier = "custom"
            var view: CustomAnnotationView
            if let dequeuedView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? CustomAnnotationView {
                dequeuedView.annotation = annotation
                view = dequeuedView
            } else {
                view = CustomAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            }
            if let item = annotation.item {
                view.setup(with: item)
                
                // Add tap gesture for balloon
                if item.kind == .balloon {
                    view.isUserInteractionEnabled = true
                    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleAnnotationTap(_:)))
                    // Remove existing gesture recognizers to avoid duplicates
                    if let gestures = view.gestureRecognizers {
                        for gesture in gestures {
                            view.removeGestureRecognizer(gesture)
                        }
                    }
                    view.addGestureRecognizer(tapGesture)
                } else {
                    view.isUserInteractionEnabled = false
                    view.gestureRecognizers?.forEach(view.removeGestureRecognizer)
                }
            }
            return view
        }
        
        @objc func handleAnnotationTap(_ gesture: UITapGestureRecognizer) {
            guard let annotationView = gesture.view as? MKAnnotationView,
                  let annotation = annotationView.annotation as? CustomMapAnnotation,
                  let item = annotation.item else { return }
            parent.onAnnotationTapped(item)
        }

        func updateCameraHeading(isDirectionUp: Bool, mapView: MKMapView, getUserLocationAndHeading: () -> (CLLocationCoordinate2D, CLLocationDirection)?) {
            let currentCamera = mapView.camera
            let centerCoordinate = currentCamera.centerCoordinate
            let distance = currentCamera.centerCoordinateDistance
            let pitch = currentCamera.pitch
            var heading: CLLocationDirection = 0

            if isDirectionUp {
                if let (_, userHeading) = getUserLocationAndHeading() {
                    heading = userHeading
                }
            } else {
                heading = 0
            }

            if abs(currentCamera.heading - heading) > 0.1 {
                let newCamera = MKMapCamera(lookingAtCenter: centerCoordinate, fromDistance: distance, pitch: pitch, heading: heading)
                mapView.setCamera(newCamera, animated: true)
            }
        }

        // Removed handleLongPress(_:) method as per instructions
    }
    
    // MARK: - Stable Annotation Management
    
    func updateAnnotationsStably(uiView: MKMapView) {
        let existingAnnotations = uiView.annotations.compactMap { $0 as? CustomMapAnnotation }
        let newIds = Set(annotations.map { $0.id })
        
        // Remove annotations that no longer exist
        let annotationsToRemove = existingAnnotations.filter { annotation in
            guard let item = annotation.item else { return true }
            return !newIds.contains(item.id)
        }
        if !annotationsToRemove.isEmpty {
            uiView.removeAnnotations(annotationsToRemove)
        }
        
        // Add new annotations and update existing ones
        for item in annotations {
            if let existing = existingAnnotations.first(where: { $0.item?.id == item.id }) {
                // Update existing annotation only if it has changed
                if let existingItem = existing.item,
                   !coordinatesEqual(existingItem.coordinate, item.coordinate) ||
                   existingItem.altitude != item.altitude ||
                   existingItem.isAscending != item.isAscending ||
                   existingItem.status != item.status {
                    existing.coordinate = item.coordinate
                    existing.item = item
                }
            } else {
                // Add new annotation
                let annotation = CustomMapAnnotation()
                annotation.coordinate = item.coordinate
                annotation.item = item
                uiView.addAnnotation(annotation)
            }
        }
    }
}

private struct AnnotationHostingView: View {
    @ObservedObject var item: MapAnnotationItem

    var body: some View {
        if item.kind == .balloon {
            let isAscending = item.isAscending ?? false
            ZStack {
                Circle()
                    .fill(isAscending ? Color.green : Color.red)
                    .frame(width: 64, height: 64)
                if let altitude = item.altitude {
                    Text("\(Int(altitude))")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 0)
                } else {
                    Text("?")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 0)
                }
            }
            .accessibilityLabel("Balloon altitude \(item.altitude.map { Int($0) } ?? 0) meters, \(isAscending ? "ascending" : "descending")")
        } else {
            // For other kinds, use the default item.view as before
            item.view
        }
    }
}

// End of AnnotationHostingView definition.

private class CustomAnnotationView: MKAnnotationView {
    private var hostingController: UIHostingController<AnnotationHostingView>?
    private var currentItem: MapAnnotationItem?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        self.frame = CGRect(x: 0, y: 0, width: 90, height: 90) // Set a fixed frame for the annotation view
        self.backgroundColor = .clear
        self.canShowCallout = false // Disable callouts for custom annotations

        // Initialize hostingController once with placeholder
        let initialItem = MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .user) // Placeholder
        hostingController = UIHostingController(rootView: AnnotationHostingView(item: initialItem))
        if let hcView = hostingController?.view {
            hcView.backgroundColor = .clear
            hcView.translatesAutoresizingMaskIntoConstraints = false
            self.addSubview(hcView)
            NSLayoutConstraint.activate([
                hcView.centerXAnchor.constraint(equalTo: self.centerXAnchor),
                hcView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                hcView.widthAnchor.constraint(equalTo: self.widthAnchor),
                hcView.heightAnchor.constraint(equalTo: self.heightAnchor)
            ])
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setup(with item: MapAnnotationItem) {
        appLog("CustomAnnotationView setup called for kind: \(item.kind)", category: .ui, level: .debug)
        // Update the rootView of the existing hostingController
        if let hc = hostingController {
            hc.rootView = AnnotationHostingView(item: item)
        }
        self.currentItem = item

        // Adjust centerOffset based on the kind of annotation for proper anchoring
        switch item.kind {
        case .user:
            self.centerOffset = CGPoint(x: 0, y: 0) // Center the icon
        case .balloon:
            self.centerOffset = CGPoint(x: 0, y: -32) // Adjust for balloon's bottom anchor (larger view, so -32)
        case .burst:
            self.centerOffset = CGPoint(x: 0, y: -15) // Adjust for burst icon
        case .landing:
            self.centerOffset = CGPoint(x: 0, y: -15) // Adjust for pin icon
        case .landed:
            self.centerOffset = CGPoint(x: 0, y: -15) // Adjust for pin icon
        }
    }

    override var annotation: MKAnnotation? {
        didSet {
            if let customAnnotation = annotation as? CustomMapAnnotation, let item = customAnnotation.item {
                // Only call setup if the item reference has actually changed
                if self.currentItem !== item {
                    setup(with: item)
                }
            }
        }
    }
}

fileprivate func polylinesEqual(lhs: MKPolyline, rhs: MKPolyline) -> Bool {
    guard lhs.pointCount == rhs.pointCount else { return false }
    let lhsCoords = lhs.coordinates
    let rhsCoords = rhs.coordinates
    for (a, b) in zip(lhsCoords, rhsCoords) {
        if a.latitude != b.latitude || a.longitude != b.longitude { return false }
    }
    return true
}

