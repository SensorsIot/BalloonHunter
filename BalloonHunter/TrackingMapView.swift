import SwiftUI
import MapKit
import Combine

struct TrackingMapView: View {
    
    
    @EnvironmentObject var userSettings: UserSettings
    @EnvironmentObject var annotationService: AnnotationService
    @EnvironmentObject var routeService: RouteCalculationService
    @EnvironmentObject var locationService: CurrentLocationService
    @EnvironmentObject var predictionService: PredictionService
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var persistenceService: PersistenceService
    @EnvironmentObject var balloonTrackingService: BalloonTrackingService
    @EnvironmentObject var landingPointService: LandingPointService

    @State private var showSettings = false
    @State private var transportMode: TransportationMode = .car
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417),
        span: MKCoordinateSpan(latitudeDelta: 0.225, longitudeDelta: 0.225) // 25km span
    )
    @State private var initialRegionSet = false
    @State private var didPerformInitialZoom = false
    @State private var lastRouteCalculationTime: Date?
    @State private var programmaticUpdateTrigger = 0
    @State private var isDirectionUp = false
    @State private var hasFetchedInitialPrediction = false
    @State private var showPrediction = true

    // State for polyline overlays
    @State private var balloonTrackPolyline: MKPolyline?
    @State private var predictionPathPolyline: MKPolyline?
    @State private var userRoutePolyline: MKPolyline?
    @State private var mapView: MKMapView? = nil

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // New top HStack containing settings button to leading and Picker centered
                HStack {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .imageScale(.large)
                            .padding(8)
                    }
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)

                    Spacer()

                    Picker("Mode", selection: $transportMode) {
                        Image(systemName: "car.fill").tag(TransportationMode.car)
                        Image(systemName: "bicycle").tag(TransportationMode.bike)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)

                    Spacer()

                    Button {
                        showPrediction.toggle()
                    } label: {
                        Image(systemName: showPrediction ? "eye.fill" : "eye.slash.fill")
                            .imageScale(.large)
                            .padding(8)
                    }
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)

                    if landingPointService.validLandingPoint == nil {
                        Button("Landing Point") {
                            Task {
                                if let telemetry = bleService.latestTelemetry,
                                   let userSettings = persistenceService.readPredictionParameters() {
                                    await predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }

                    Button {
                        readLandingPointFromClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .imageScale(.large)
                            .padding(8)
                    }
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)

                    Spacer()

                    Button {
                        let newMuteState = !(bleService.latestTelemetry?.buzmute ?? false)
                        bleService.latestTelemetry?.buzmute = newMuteState
                        let command = "o{mute=\(newMuteState ? 1 : 0)}o"
                        bleService.sendCommand(command: command)
                    } label: {
                        Image(systemName: (bleService.latestTelemetry?.buzmute ?? false) ? "speaker.slash.fill" : "speaker.fill")
                            .imageScale(.large)
                            .padding(8)
                    }
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                // No top padding, only minimal horizontal padding from Picker

                ZStack {
                    MapView(
                        region: $region,
                        annotations: annotationService.annotations,
                        balloonTrack: balloonTrackPolyline,
                        predictionPath: showPrediction ? predictionPathPolyline : nil,
                        userRoute: userRoutePolyline,
                        programmaticUpdateTrigger: programmaticUpdateTrigger,
                        isDirectionUp: isDirectionUp,
                        setIsDirectionUp: { newValue in isDirectionUp = newValue },
                        onAnnotationTapped: { item in
                            if item.kind == .balloon {
                                Task {
                                    if let telemetry = bleService.latestTelemetry,
                                       let userSettings = persistenceService.readPredictionParameters() {
                                        await predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
                                    }
                                }
                            }
                        },
                        getUserLocationAndHeading: {
                            guard let location = locationService.locationData else { return nil }
                            let heading = location.heading
                            return (CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude), heading)
                        },
                        getMapView: { mapView in
                            self.mapView = mapView
                        }
                    )
                    .frame(height: geometry.size.height * 0.7)
                    .overlay(alignment: .bottomLeading) {
                        Button("Overview") {
                            // Instead of updateCameraToFitAllPoints(), showAnnotations with annotationsForZoom
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
                                if let predictionPath = predictionService.predictionData?.path {
                                    for coord in predictionPath {
                                        let ann = MKPointAnnotation()
                                        ann.coordinate = coord
                                        annotationsForZoom.append(ann)
                                    }
                                }
                                if let routePath = routeService.routeData?.path {
                                    for coord in routePath {
                                        let ann = MKPointAnnotation()
                                        ann.coordinate = coord
                                        annotationsForZoom.append(ann)
                                    }
                                }
                            }
                            if !annotationsForZoom.isEmpty, let mapView = mapView {
                                mapView.showAnnotations(annotationsForZoom, animated: true)
                            }
                        }
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding([.leading, .bottom], 8)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            withAnimation {
                                isDirectionUp.toggle()
                            }
                        } label: {
                            Text(isDirectionUp ? "Heading" : "Free")
                                .font(.headline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                        }
                        .padding([.trailing, .bottom], 8)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, alignment: .center) {
                DataPanelView()
                    .frame(maxHeight: .infinity, alignment: .top)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous)) // Changed cornerRadius to 0 for full width
                    .shadow(radius: 0) // Removed shadow for full width
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            
            .onReceive(locationService.$locationData) { locationData in
                if !initialRegionSet, let locationData = locationData {
                    region = MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.225, longitudeDelta: 0.225) // 25km span
                    )
                    initialRegionSet = true
                }
                updateStateAndCamera()

                if let userLocationData = locationData,
                   let landingPoint = landingPointService.validLandingPoint {
                    let now = Date()
                    if lastRouteCalculationTime == nil || now.timeIntervalSince(lastRouteCalculationTime ?? Date(timeIntervalSince1970: 0)) >= 60 {
                        routeService.calculateRoute(
                            from: CLLocationCoordinate2D(latitude: userLocationData.latitude, longitude: userLocationData.longitude),
                            to: landingPoint,
                            transportType: transportMode
                        )
                        lastRouteCalculationTime = now
                    }
                }
            }
            .onReceive(bleService.telemetryData) { _ in
                updateStateAndCamera()
                if !hasFetchedInitialPrediction {
                    guard let telemetry = bleService.latestTelemetry,
                          let userSettings = persistenceService.readPredictionParameters() else {
                        print("[DEBUG] BLE telemetry update: missing telemetry or userSettings, skipping prediction fetch")
                        return
                    }
                    hasFetchedInitialPrediction = true
                    print("[DEBUG] Passing descent rate \(balloonTrackingService.currentEffectiveDescentRate ?? 0.0) to PredictionService")
                    Task { await predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings, measuredDescentRate: abs(balloonTrackingService.currentEffectiveDescentRate ?? userSettings.descentRate)) }
                }
            }
            .onReceive(predictionService.$predictionData) { _ in
                updateStateAndCamera()
            }
            .onReceive(routeService.$routeData) { _ in
                updateStateAndCamera()
            }
            
            .onChange(of: transportMode) {
                routeService.routeData = nil
                if let userLocationData = locationService.locationData,
                   let landingPoint = landingPointService.validLandingPoint {
                    routeService.calculateRoute(
                        from: CLLocationCoordinate2D(latitude: userLocationData.latitude, longitude: userLocationData.longitude),
                        to: landingPoint,
                        transportType: transportMode
                    )
                }
            }
            
            
            // Removed the .onChange(of: annotationService.appState) block as requested.
        }
    }

    private func updateStateAndCamera() {
        // First, update the state
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
            self.balloonTrackPolyline = polyline
        } else {
            self.balloonTrackPolyline = nil
        }

        if let predictionPath = predictionService.predictionData?.path, !predictionPath.isEmpty {
            let polyline = MKPolyline(coordinates: predictionPath, count: predictionPath.count)
            polyline.title = "predictionPath"
            self.predictionPathPolyline = polyline
        } else {
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
                    self.userRoutePolyline = nil
                } else {
                    self.userRoutePolyline = polyline
                }
            } else {
                self.userRoutePolyline = polyline
            }
        } else {
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
            if let predictionPath = predictionService.predictionData?.path {
                for coord in predictionPath {
                    let ann = MKPointAnnotation()
                    ann.coordinate = coord
                    annotationsForZoom.append(ann)
                }
            }
            if let routePath = routeService.routeData?.path {
                for coord in routePath {
                    let ann = MKPointAnnotation()
                    ann.coordinate = coord
                    annotationsForZoom.append(ann)
                }
            }
        }
        
        // Debug output preserved from previous zoom logic:
        if let userLocation = locationService.locationData {
            print("[DEBUG][ZOOM] userLocation: \(userLocation.latitude), \(userLocation.longitude)")
        } else {
            print("[DEBUG][ZOOM] userLocation: nil")
        }
        if let landing = landingPointService.validLandingPoint {
            print("[DEBUG][ZOOM] landingPoint: \(landing.latitude), \(landing.longitude)")
        } else {
            print("[DEBUG][ZOOM] landingPoint: nil")
        }
        print("[DEBUG][ZOOM] isBalloonFlying: \(balloonTrackingService.isBalloonFlying)")
        print("[DEBUG][ZOOM] zoomCoordinates count: \(annotationsForZoom.count)")
        for (index, annotation) in annotationsForZoom.enumerated() {
            print("[DEBUG][ZOOM] zoomCoordinates[\(index)]: lat=\(annotation.coordinate.latitude), lon=\(annotation.coordinate.longitude)")
        }
        
        if !annotationsForZoom.isEmpty, let mapView = mapView {
            mapView.showAnnotations(annotationsForZoom, animated: true)
            return
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

    
}

/// Compares two MKPolyline objects for equality by checking their coordinates.
private func polylinesEqual(lhs: MKPolyline, rhs: MKPolyline) -> Bool {
    guard lhs.pointCount == rhs.pointCount else { return false }
    let lhsCoords = lhs.coordinates
    let rhsCoords = rhs.coordinates
    for (a, b) in zip(lhsCoords, rhsCoords) {
        if a.latitude != b.latitude || a.longitude != b.longitude { return false }
    }
    return true
}

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
    let programmaticUpdateTrigger: Int
    let isDirectionUp: Bool
    let setIsDirectionUp: (Bool) -> Void
    let onAnnotationTapped: (MapAnnotationItem) -> Void
    let getUserLocationAndHeading: (() -> (CLLocationCoordinate2D, CLLocationDirection)?)
    let getMapView: (MKMapView) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard // Changed map style to standard for roads only
        mapView.register(CustomAnnotationView.self, forAnnotationViewWithReuseIdentifier: "custom")

        // Remove default double-tap (zoom) gesture recognizer
        if let recognizers = mapView.gestureRecognizers {
            for recognizer in recognizers {
                if let tap = recognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2 {
                    mapView.removeGestureRecognizer(tap)
                }
            }
        }

        // Removed longPressGestureRecognizer setup as per instructions
        getMapView(mapView)
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // --- Update Annotations ---
        // Get current annotations on the map view
        let existingMapAnnotations = uiView.annotations.compactMap { $0 as? CustomMapAnnotation }
        var existingMapAnnotationMap = [String: CustomMapAnnotation]()
        for annotation in existingMapAnnotations {
            if let id = annotation.item?.id { // Use the stable ID from MapAnnotationItem
                existingMapAnnotationMap[id] = annotation
            }
        }

        var annotationsToAdd = [CustomMapAnnotation]()
        var annotationsToRemove = [MKAnnotation]()

        // Determine which annotations to add, update, or remove
        let newAnnotationItemsMap = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, $0) })

        for newItem in annotations {
            if let existingAnnotation = existingMapAnnotationMap[newItem.id] {
                // Annotation exists, update its properties
                existingAnnotation.coordinate = newItem.coordinate
                existingAnnotation.item = newItem // Update the item reference
            } else {
                // New annotation
                let annotation = CustomMapAnnotation()
                annotation.coordinate = newItem.coordinate
                annotation.item = newItem
                annotationsToAdd.append(annotation)
            }
        }

        for existingAnnotation in existingMapAnnotations {
            if let id = existingAnnotation.item?.id, newAnnotationItemsMap[id] == nil {
                // Annotation no longer in new data, mark for removal
                annotationsToRemove.append(existingAnnotation)
            }
        }

        // Perform updates
        if !annotationsToRemove.isEmpty {
            uiView.removeAnnotations(annotationsToRemove)
        }
        if !annotationsToAdd.isEmpty {
            uiView.addAnnotations(annotationsToAdd)
        }
        // For annotationsToUpdate, their properties are already updated in place.
        // MKMapView will automatically reflect changes to coordinate if the annotation object is the same.


        // --- Update Overlays ---
        // Keep track of current overlays on the map view
        let existingMapOverlays = uiView.overlays.compactMap { $0 as? MKPolyline }
        var existingMapOverlayMap = [String: MKPolyline]()
        for overlay in existingMapOverlays {
            if let title = overlay.title {
                existingMapOverlayMap[title] = overlay
            }
        }

        var overlaysToAdd = [MKPolyline]()
        var overlaysToRemove = [MKOverlay]()

        // Process balloonTrackPolyline
        if let newBalloonTrack = balloonTrack {
            if let existing = existingMapOverlayMap["balloonTrack"], polylinesEqual(lhs: existing, rhs: newBalloonTrack) {
                // Same polyline, no change needed
            } else {
                if let existing = existingMapOverlayMap["balloonTrack"] {
                    overlaysToRemove.append(existing)
                }
                overlaysToAdd.append(newBalloonTrack)
            }
        } else {
            if let existing = existingMapOverlayMap["balloonTrack"] {
                overlaysToRemove.append(existing)
            }
        }

        // Process predictionPathPolyline
        if let newPredictionPath = predictionPath {
            if let existing = existingMapOverlayMap["predictionPath"], polylinesEqual(lhs: existing, rhs: newPredictionPath) {
                // Same polyline, no change needed
            } else {
                if let existing = existingMapOverlayMap["predictionPath"] {
                    overlaysToRemove.append(existing)
                }
                overlaysToAdd.append(newPredictionPath)
            }
        } else {
            if let existing = existingMapOverlayMap["predictionPath"] {
                overlaysToRemove.append(existing)
            }
        }

        // Process userRoutePolyline
        if let newUserRoute = userRoute {
            if let existing = existingMapOverlayMap["userRoute"], polylinesEqual(lhs: existing, rhs: newUserRoute) {
                // Same polyline, no change needed
            } else {
                if let existing = existingMapOverlayMap["userRoute"] {
                    overlaysToRemove.append(existing)
                }
                overlaysToAdd.append(newUserRoute)
            }
        } else {
            if let existing = existingMapOverlayMap["userRoute"] {
                overlaysToRemove.append(existing)
            }
        }

        // Perform updates
        if !overlaysToRemove.isEmpty {
            uiView.removeOverlays(overlaysToRemove)
        }
        if !overlaysToAdd.isEmpty {
            uiView.addOverlays(overlaysToAdd)
        }

        // If the programmaticUpdateTrigger changed, call showAnnotations to zoom and center map to all annotations.
        if context.coordinator.lastUpdateTrigger != programmaticUpdateTrigger {
            let annotationsForDebug = uiView.annotations
            print("[DEBUG] Calling showAnnotations with the following annotations:")
            for annotation in annotationsForDebug {
                if let title = annotation.title {
                    print("\tAnnotation: \(annotation), title: \(title) coordinate: \(annotation.coordinate)")
                } else {
                    print("\tAnnotation: \(annotation), coordinate: \(annotation.coordinate)")
                }
            }
            uiView.showAnnotations(annotationsForDebug, animated: true)
            context.coordinator.lastUpdateTrigger = programmaticUpdateTrigger
        }

        // Handle changes in isDirectionUp by updating camera heading accordingly
        context.coordinator.updateCameraHeading(isDirectionUp: isDirectionUp, mapView: uiView, getUserLocationAndHeading: getUserLocationAndHeading)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapView
        var lastUpdateTrigger: Int = 0

        init(_ parent: MapView) {
            self.parent = parent
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
            parent.region = mapView.region
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
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
    private var hostingController: UIHostingController<AnnotationHostingView>? // Use a specific hosting view
    private var currentItem: MapAnnotationItem?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        self.frame = CGRect(x: 0, y: 0, width: 90, height: 90)
        self.backgroundColor = .clear

        // Initialize hostingController once with a placeholder item
        let initialItem = MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .user) // Placeholder
        let newHostingController = UIHostingController(rootView: AnnotationHostingView(item: initialItem))
        newHostingController.view.backgroundColor = .clear
        self.addSubview(newHostingController.view)
        newHostingController.view.frame = self.bounds
        self.hostingController = newHostingController
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setup(with item: MapAnnotationItem) {
        let newHostingController = UIHostingController(rootView: AnnotationHostingView(item: item))
        newHostingController.view.backgroundColor = .clear
        // Remove any previous hostingController's view from superview
        self.hostingController?.view.removeFromSuperview()
        self.addSubview(newHostingController.view)
        newHostingController.view.frame = self.bounds
        self.hostingController = newHostingController
        self.currentItem = item
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

