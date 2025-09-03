import SwiftUI
import MapKit
import Combine

struct TrackingMapView: View {
    @EnvironmentObject var annotationService: AnnotationService
    @EnvironmentObject var routeService: RouteCalculationService
    @EnvironmentObject var locationService: CurrentLocationService
    @EnvironmentObject var predictionService: PredictionService
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var persistenceService: PersistenceService
    @EnvironmentObject var userSettings: UserSettings

    @State private var showSettings = false
    @State private var transportMode: TransportationMode = .car
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417),
        span: MKCoordinateSpan(latitudeDelta: 0.225, longitudeDelta: 0.225) // 25km span
    )
    @State private var initialRegionSet = false
    @State private var didPerformInitialZoom = false
    @State private var lastRouteCalculationLocation: CLLocation?
    @State private var programmaticUpdateTrigger = 0
    private let routeRecalculationTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    // State for polyline overlays
    @State private var balloonTrackPolyline: MKPolyline?
    @State private var predictionPathPolyline: MKPolyline?
    @State private var userRoutePolyline: MKPolyline?

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
                            .foregroundColor(.primary)
                            .padding(8)
                    }
                    Spacer()
                    Picker("Transport Mode", selection: $transportMode) {
                        Text("Car").tag(TransportationMode.car)
                        Text("Bike").tag(TransportationMode.bike)
                    }
                    .pickerStyle(.segmented)
                    .background(.thinMaterial)
                    .cornerRadius(8)
                    .padding(.horizontal, 18)
                    Spacer()
                    // Add an invisible spacer with same width as button to keep Picker centered
                    // This keeps the Picker visually centered between leading and trailing edges
                    Color.clear.frame(width: 44, height: 44)
                }
                // No top padding, only minimal horizontal padding from Picker

                ZStack {
                    MapView(
                        region: $region,
                        annotations: annotationService.annotations,
                        balloonTrack: balloonTrackPolyline,
                        predictionPath: predictionPathPolyline,
                        userRoute: userRoutePolyline,
                        programmaticUpdateTrigger: programmaticUpdateTrigger,
                        onAnnotationTapped: { item in
                            if item.kind == .balloon {
                                print("[DEBUG][TrackingMapView] Balloon annotation tapped.")
                                guard let telemetry = bleService.latestTelemetry,
                                      let userSettings = persistenceService.readPredictionParameters() else { return }
                                predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
                            }
                        }
                    )
                    .frame(height: geometry.size.height * 0.7)
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
                    region.center = CLLocationCoordinate2D(latitude: locationData.latitude, longitude: locationData.longitude)
                    initialRegionSet = true
                }
                updateStateAndCamera()
            }
            .onReceive(bleService.telemetryData) { _ in
                updateStateAndCamera()
            }
            .onReceive(predictionService.$predictionData) { _ in
                updateStateAndCamera()
            }
            .onReceive(routeService.$routeData) { routeData in
                if routeData != nil, let userLocationData = locationService.locationData {
                    self.lastRouteCalculationLocation = CLLocation(latitude: userLocationData.latitude, longitude: userLocationData.longitude)
                    print("[DEBUG][TrackingMapView] Route updated. Stored user location for distance check.")
                }
                updateStateAndCamera()
            }
            .onChange(of: transportMode) { newMode in
                guard let userLocation = locationService.locationData,
                      let landingPoint = predictionService.predictionData?.landingPoint else { return }
                
                print("[DEBUG][TrackingMapView] Transport mode changed. Recalculating route.")
                routeService.routeData = nil
                routeService.calculateRoute(
                    from: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
                    to: landingPoint,
                    transportType: newMode
                )
            }
            .onReceive(routeRecalculationTimer) { _ in
                guard let userLocationData = locationService.locationData,
                      let landingPoint = predictionService.predictionData?.landingPoint,
                      let lastCalcLocation = lastRouteCalculationLocation else { return }

                let currentUserLocation = CLLocation(latitude: userLocationData.latitude, longitude: userLocationData.longitude)
                
                if currentUserLocation.distance(from: lastCalcLocation) > 500 {
                    print("[DEBUG][TrackingMapView] User moved > 500m. Recalculating route.")
                    routeService.calculateRoute(
                        from: currentUserLocation.coordinate,
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
            telemetryHistory: bleService.currentSondeTrack.map { TelemetryData(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude) },
            lastTelemetryUpdateTime: bleService.lastTelemetryUpdateTime
        )

        // Update polylines
        let trackPoints = bleService.currentSondeTrack.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        print("[DEBUG][TrackingMapView] Historic track points count: \(trackPoints.count)")
        for (index, point) in trackPoints.enumerated() {
            print("[DEBUG][TrackingMapView] Historic track point \(index): lat=\(point.latitude), lon=\(point.longitude)")
        }
        if !trackPoints.isEmpty {
            let polyline = MKPolyline(coordinates: trackPoints, count: trackPoints.count)
            polyline.title = "balloonTrack"
            self.balloonTrackPolyline = polyline
            print("[DEBUG][TrackingMapView] balloonTrackPolyline created: \(self.balloonTrackPolyline != nil)")
        } else {
            self.balloonTrackPolyline = nil
            print("[DEBUG][TrackingMapView] balloonTrackPolyline set to nil (no track points).")
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
            self.userRoutePolyline = polyline
        } else {
            self.userRoutePolyline = nil
        }

        // Then, update the camera
        if annotationService.appState == .startup {
            updateCameraToFitAllPoints()
        } else if annotationService.appState == .longRangeTracking && !didPerformInitialZoom {
            updateCameraToFitAllPoints()
            // Increment trigger to notify MapView to update after overlays and annotations are updated.
            programmaticUpdateTrigger += 1
            didPerformInitialZoom = true
        }
    }

    private func updateCameraToFitAllPoints() {
        let relevantAnnotations = annotationService.annotations.filter {
            $0.kind == .user || $0.kind == .balloon || $0.kind == .landing
        }
        var points: [CLLocationCoordinate2D] = relevantAnnotations.map { $0.coordinate }

        // Add points from polylines
        if let trackPoly = balloonTrackPolyline {
            points.append(contentsOf: trackPoly.coordinates)
        }
        if let predPoly = predictionPathPolyline {
            points.append(contentsOf: predPoly.coordinates)
        }
        if let userRoutePoly = userRoutePolyline {
            points.append(contentsOf: userRoutePoly.coordinates)
        }

        guard !points.isEmpty else { return }

        // Commented out manual calculation and setting of region
        // We now rely on MapView's showAnnotations to handle zoom-to-fit with animation
        /*
        var minLat = points[0].latitude
        var maxLat = points[0].latitude
        var minLon = points[0].longitude
        var maxLon = points[0].longitude

        for point in points {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // Ensure the span is not too small, providing a buffer
        // Increased buffer multiplier to 1.7 for a wider margin
        // Set minimum deltas to 0.05 (~5 km at equator) to avoid over-zooming on close points
        // This approach approximates the effective 'showAnnotations' behavior of MKMapView
        let latitudeDelta = max((maxLat - minLat) * 1.7, 0.05)
        let longitudeDelta = max((maxLon - minLon) * 1.7, 0.05)

        let span = MKCoordinateSpan(
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
        
        self.region = MKCoordinateRegion(center: center, span: span)
        */
    }
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
    let onAnnotationTapped: (MapAnnotationItem) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.register(CustomAnnotationView.self, forAnnotationViewWithReuseIdentifier: "custom")
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Removed automatic region update to allow user to move the map freely without the view resetting the region.
        // if regionsAreDifferent(uiView.region, region) {
        //     uiView.setRegion(region, animated: true)
        // }

        // Update annotations FIRST, so they are available for showAnnotations
        uiView.removeAnnotations(uiView.annotations)
        let newAnnotations = annotations.map { item -> CustomMapAnnotation in
            let annotation = CustomMapAnnotation()
            annotation.coordinate = item.coordinate
            annotation.item = item
            return annotation
        }
        uiView.addAnnotations(newAnnotations)

        // Update overlays
        uiView.removeOverlays(uiView.overlays)
        var overlaysToAdd: [MKOverlay] = []
        if let balloonTrack = balloonTrack {
            overlaysToAdd.append(balloonTrack)
            print("[DEBUG][MapView] Adding balloonTrack to overlaysToAdd.")
        }
        if let predictionPath = predictionPath { overlaysToAdd.append(predictionPath) }
        if let userRoute = userRoute { overlaysToAdd.append(userRoute) }
        uiView.addOverlays(overlaysToAdd)

        // If the programmaticUpdateTrigger changed, call showAnnotations to zoom and center map to all annotations.
        // This ensures the map zooms to fit all annotations smoothly at specific update points.
        if context.coordinator.lastUpdateTrigger != programmaticUpdateTrigger {
            // This will animate the map to show all annotations
            uiView.showAnnotations(uiView.annotations, animated: true)
            context.coordinator.lastUpdateTrigger = programmaticUpdateTrigger
            print("[DEBUG][MapView] programmaticUpdateTrigger changed; called showAnnotations.")
        }
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
            print("[DEBUG][MapView] rendererFor overlay called.")
            if let polyline = overlay as? MKPolyline {
                print("[DEBUG][MapView] Polyline title: \(polyline.title ?? "nil")")
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
    }
}

private class CustomAnnotationView: MKAnnotationView {
    private var hostingController: UIHostingController<AnyView>?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        self.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setup(with item: MapAnnotationItem) {
        hostingController?.view.removeFromSuperview()
        hostingController = nil

        let swiftUIView = AnyView(item.view)
        let newHostingController = UIHostingController(rootView: swiftUIView)
        newHostingController.view.backgroundColor = .clear
        self.addSubview(newHostingController.view)
        newHostingController.view.frame = self.bounds
        self.hostingController = newHostingController
    }
}

// MARK: - Helper function to compare map regions

private func regionsAreDifferent(_ lhs: MKCoordinateRegion, _ rhs: MKCoordinateRegion) -> Bool {
    let latDiff = abs(lhs.center.latitude - rhs.center.latitude)
    let lonDiff = abs(lhs.center.longitude - rhs.center.longitude)
    let latDeltaDiff = abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta)
    let lonDeltaDiff = abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta)
    let tolerance = 0.0001
    return latDiff > tolerance || lonDiff > tolerance || latDeltaDiff > tolerance || lonDeltaDiff > tolerance
}

#Preview {
    TrackingMapView()
        .environmentObject(AnnotationService())
        .environmentObject(RouteCalculationService())
        .environmentObject(CurrentLocationService())
        .environmentObject(PredictionService())
        .environmentObject(BLECommunicationService(persistenceService: PersistenceService()))
        .environmentObject(PersistenceService())
        .environmentObject(UserSettings())
}
