import SwiftUI
import MapKit
import Combine
import OSLog

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
        span: MKCoordinateSpan(latitudeDelta: 0.225, longitudeDelta: 0.225) // 25km span
    )
    @State private var initialRegionSet = false
    @State private var didPerformInitialZoom = false
    @State private var lastRouteCalculationTime: Date?
    @State private var shouldUpdateMapRegion = true // New state variable to control map region updates
    @State private var isDirectionUp = false
    @State private var hasFetchedInitialPrediction = false
    @State private var showPrediction = true

    // Added missing state for heading mode
    @State private var isHeadingMode: Bool = false

    // State for polyline overlays
    @State private var balloonTrackPolyline: MKPolyline?
    @State private var predictionPathPolyline: MKPolyline?
    @State private var userRoutePolyline: MKPolyline?
    @State private var mapView: MKMapView? = nil

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
                            showPrediction.toggle()
                        } label: {
                            Image(systemName: showPrediction ? "eye.fill" : "eye.slash.fill")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Enter Landing Point button (text, only if no valid landing point)
                        if landingPointService.validLandingPoint == nil {
                            Button("Point") {
                                readLandingPointFromClipboard()
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                        }

                        // Overview button (text, only if valid landing point exists)
                        if landingPointService.validLandingPoint != nil {
                            Button("All") {
                                showAllAnnotations()
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        // Free/Heading mode toggle button
                        Button {
                            isHeadingMode.toggle()
                        } label: {
                            Image(systemName: isHeadingMode ? "location.fill" : "location.slash.fill")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Buzzer mute toggle button
                        Button {
                            let newMuteState = !(bleService.latestTelemetry?.buzmute ?? false)
                            bleService.latestTelemetry?.buzmute = newMuteState
                            let command = "o{mute=\(newMuteState ? 1 : 0)}o"
                            bleService.sendCommand(command: command)
                        } label: {
                            Image(systemName: "speaker.2.fill")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }

                MapView(
                    region: $region,
                    annotations: annotationService.annotations,
                    balloonTrack: balloonTrackPolyline,
                    predictionPath: showPrediction ? predictionPathPolyline : nil,
                    userRoute: userRoutePolyline,
                    mapView: $mapView, // Pass the binding here
                    shouldUpdateMapRegion: $shouldUpdateMapRegion, // Pass the new binding
                    isDirectionUp: isDirectionUp,
                    setIsDirectionUp: { newValue in isDirectionUp = newValue },
                    onAnnotationTapped: { item in
                        if item.kind == .balloon {
                            serviceManager.uiEventPublisher.send(.annotationSelected(item))
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
                throttledUpdateStateAndCamera()

                if let userLocationData = locationData,
                   let landingPoint = landingPointService.validLandingPoint {
                    let now = Date()
                    if lastRouteCalculationTime == nil || now.timeIntervalSince(lastRouteCalculationTime ?? Date(timeIntervalSince1970: 0)) >= 60 {
                        routeService.calculateRoute(
                            from: CLLocationCoordinate2D(latitude: userLocationData.latitude, longitude: userLocationData.longitude),
                            to: landingPoint,
                            transportType: transportMode,
                            version: 0
                        )
                        lastRouteCalculationTime = now
                    }
                }
            }
            .onReceive(bleService.telemetryData) { _ in
                throttledUpdateStateAndCamera()
                if !hasFetchedInitialPrediction {
                    guard let telemetry = bleService.latestTelemetry,
                          let userSettings = persistenceService.readPredictionParameters() else {
                        print("[DEBUG] BLE telemetry update: missing telemetry or userSettings, skipping prediction fetch")
                        return
                    }
                    hasFetchedInitialPrediction = true
                    print("[DEBUG] Passing descent rate \(balloonTrackingService.currentEffectiveDescentRate ?? 0.0) to PredictionService")
                    Task { await predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings, measuredDescentRate: abs(balloonTrackingService.currentEffectiveDescentRate ?? userSettings.descentRate), version: 0) }
                }
            }
            .onReceive(predictionService.$predictionData) { _ in
                throttledUpdateStateAndCamera()
            }
            .onReceive(routeService.$routeData) { _ in
                throttledUpdateStateAndCamera()
            }
            .onReceive(serviceManager.cameraPolicy.cameraRegionPublisher) { newRegion in
                // appLog("Received new region from cameraPolicy: \(newRegion.center.latitude), \(newRegion.center.longitude)", category: .ui, level: .debug)
                // region = newRegion // Commented out to disable automatic region updates
            }
            
            .onChange(of: transportMode) {
                serviceManager.uiEventPublisher.send(.modeSwitched(transportMode))
            }
            
            // Removed the .onChange(of: annotationService.appState) block as requested.
        }
    }
    
    private func throttledUpdateStateAndCamera() {
        let now = Date()
        if let last = lastUpdateStateCall, now.timeIntervalSince(last) < 0.5 { return }
        lastUpdateStateCall = now
        updateStateAndCamera()
    }

    private func updateStateAndCamera() {
        // First, update the state
        appLog("updateStateAndCamera called.", category: .ui, level: .debug)
        appLog("User Location Data: \(String(describing: locationService.locationData))", category: .ui, level: .debug)
        appLog("Prediction Data: \(String(describing: predictionService.predictionData))", category: .ui, level: .debug)

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
                appLog("Balloon Track Polyline set.", category: .ui, level: .debug)
            }
        } else if balloonTrackPolyline != nil {
            self.balloonTrackPolyline = nil
            appLog("Balloon Track Polyline cleared.", category: .ui, level: .debug)
        }

        if let predictionPath = predictionService.predictionData?.path, !predictionPath.isEmpty {
            let polyline = MKPolyline(coordinates: predictionPath, count: predictionPath.count)
            polyline.title = "predictionPath"
            if predictionPathPolyline == nil || !polylinesEqual(lhs: predictionPathPolyline!, rhs: polyline) {
                self.predictionPathPolyline = polyline
                appLog("Prediction Path Polyline set.", category: .ui, level: .debug)
            }
        } else if predictionPathPolyline != nil {
            self.predictionPathPolyline = nil
            appLog("Prediction Path Polyline cleared.", category: .ui, level: .debug)
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
                        appLog("User Route Polyline cleared (distance < 100m).", category: .ui, level: .debug)
                    }
                } else {
                    if userRoutePolyline == nil || !polylinesEqual(lhs: userRoutePolyline!, rhs: polyline) {
                        self.userRoutePolyline = polyline
                        appLog("User Route Polyline set.", category: .ui, level: .debug)
                    }
                }
            } else {
                if userRoutePolyline == nil || !polylinesEqual(lhs: userRoutePolyline!, rhs: polyline) {
                    self.userRoutePolyline = polyline
                    appLog("User Route Polyline set (no user/balloon location).", category: .ui, level: .debug)
                }
            }
        } else if userRoutePolyline != nil {
            self.userRoutePolyline = nil
            appLog("User Route Polyline cleared.", category: .ui, level: .debug)
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
        
        if !annotationsForZoom.isEmpty, let mapView = mapView {
            if !initialRegionSet {
                mapView.showAnnotations(annotationsForZoom, animated: true)
                initialRegionSet = true
                appLog("Initial map region set with \(annotationsForZoom.count) annotations.", category: .ui, level: .debug)
                return
            }
            // If initialRegionSet is true, do not update the region to preserve user control
        }
        
//        Removed custom manual camera/region calculation and updateCameraToFitAllPoints calls.
    }

    private func readLandingPointFromClipboard() {
        if let clipboardString = UIPasteboard.general.string {
            print("Clipboard string: \(clipboardString)")
            let components = clipboardString.components(separatedBy: "route=")
            if components.count > 1 {
                let routeComponent = components[1]
                let routeParts = routeComponent.components(separatedBy: "%3B")
                if routeParts.count > 1 {
                    let destination = routeParts[1]
                    print("Destination string: \(destination)")
                    let coords = destination.components(separatedBy: "%2C")
                    print("Coords array: \(coords)")
                    if coords.count == 2,
                       let lat = Double(coords[0]),
                       let lonString = coords[1].components(separatedBy: "#").first,
                       let lon = Double(lonString) {
                        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        print("Parsed coordinate: \(coordinate)")
                        persistenceService.saveLandingPoint(sondeName: "manual_override", coordinate: coordinate)
                        // Optionally, you can also update the prediction data to reflect this change immediately
                        let newPredictionData = PredictionData(landingPoint: coordinate)
                        predictionService.predictionData = newPredictionData
                    } else {
                        print("Could not parse coordinates from clipboard")
                    }
                } else {
                    print("Could not parse route parts from clipboard")
                }
            } else {
                print("Could not find route component in clipboard string")
            }
        } else {
            print("Clipboard is empty")
        }
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

        // Add burst point if available and balloon is ascending
        if let prediction = predictionService.predictionData, let burst = prediction.burstPoint, bleService.latestTelemetry?.verticalSpeed ?? 0 >= 0 {
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
        print("[DEBUG] MapView makeUIView called")
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
        appLog("MapView updateUIView called.", category: .ui, level: .debug)
        appLog("Annotations passed to MapView: \(annotations.count)", category: .ui, level: .debug)
        appLog("Balloon Track Polyline passed: \(balloonTrack != nil)", category: .ui, level: .debug)
        appLog("Prediction Path Polyline passed: \(predictionPath != nil)", category: .ui, level: .debug)
        appLog("User Route Polyline passed: \(userRoute != nil)", category: .ui, level: .debug)

        // Control map interaction based on isHeadingMode
        if isHeadingMode {
            uiView.isScrollEnabled = false
            uiView.isZoomEnabled = true
            uiView.isPitchEnabled = false
            uiView.isRotateEnabled = false

            if let (userLocation, userHeading) = getUserLocationAndHeading() {
                let currentCamera = uiView.camera
                let newCamera = MKMapCamera(lookingAtCenter: userLocation, fromDistance: currentCamera.centerCoordinateDistance, pitch: currentCamera.pitch, heading: userHeading)
                uiView.setCamera(newCamera, animated: true)
            }
        } else {
            uiView.isScrollEnabled = true
            uiView.isZoomEnabled = true
            uiView.isPitchEnabled = true
            uiView.isRotateEnabled = true

            // Reset camera heading to 0 (North) when switching to Free mode
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
                    renderer.lineWidth = 2
                case "predictionPath":
                    renderer.strokeColor = .blue
                    renderer.lineWidth = 4
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
                return nil
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
}

private struct AnnotationHostingView: View {
    @ObservedObject var item: MapAnnotationItem

    var body: some View {
        // Directly use the item.view property here
        item.view
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

        // Initialize hostingController once
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
            self.centerOffset = CGPoint(x: 0, y: -20) // Adjust for balloon's bottom anchor
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

