import SwiftUI
import MapKit
import Combine
import OSLog
import UIKit

struct TrackingMapView: View {
    @EnvironmentObject var userSettings: UserSettings
    @EnvironmentObject var mapState: MapState
    @EnvironmentObject var serviceManager: ServiceManager

    @State private var showSettings = false
    @State private var transportMode: TransportationMode = .car
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417),
        span: MKCoordinateSpan(latitudeDelta: 0.225, longitudeDelta: 0.225)
    )
    @State private var isHeadingMode: Bool = false
    @State private var mapView: MKMapView? = nil
    @State private var didPerformInitialZoom = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Top control panel
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
                        .onChange(of: transportMode) { _, newMode in
                            EventBus.shared.publishUIEvent(.transportModeChanged(newMode, timestamp: Date()))
                        }

                        // Prediction visibility toggle
                        Button {
                            EventBus.shared.publishUIEvent(.predictionVisibilityToggled(!mapState.isPredictionPathVisible, timestamp: Date()))
                        } label: {
                            Image(systemName: mapState.isPredictionPathVisible ? "eye.fill" : "eye.slash.fill")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Show All or Point button mutually exclusively based on landing point availability
                        if mapState.landingPoint != nil {
                            // Landing point available - show "All" button
                            Button("All") {
                                EventBus.shared.publishUIEvent(.showAllAnnotationsRequested(timestamp: Date()))
                            }
                            .buttonStyle(.bordered)
                        } else {
                            // No landing point available - show "Point" button
                            Button("Point") {
                                EventBus.shared.publishUIEvent(.landingPointSetRequested(timestamp: Date()))
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                        }

                        // Heading mode toggle
                        Button {
                            isHeadingMode.toggle()
                            EventBus.shared.publishUIEvent(.headingModeToggled(isHeadingMode, timestamp: Date()))
                        } label: {
                            Text(isHeadingMode ? "Heading" : "Free")
                                .font(.system(size: 14, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Buzzer mute toggle
                        Button {
                            let currentMuteState = mapState.balloonTelemetry?.buzmute ?? false
                            let newMuteState = !currentMuteState
                            EventBus.shared.publishUIEvent(.buzzerMuteToggled(newMuteState, timestamp: Date()))

                            // Haptic feedback
                            let generator = UINotificationFeedbackGenerator()
                            generator.notificationOccurred(newMuteState ? .warning : .success)
                        } label: {
                            Image(systemName: (mapState.balloonTelemetry?.buzmute ?? false) ? "speaker.slash.fill" : "speaker.2.fill")
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

                // Map view
                EventDrivenMapView(
                    region: $region,
                    mapView: $mapView,
                    isHeadingMode: $isHeadingMode,
                    didPerformInitialZoom: $didPerformInitialZoom
                )
                .frame(height: geometry.size.height * 0.7)

                // Data panel
                DataPanelView()
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 0))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(serviceManager.bleCommunicationService)
                .environmentObject(serviceManager.persistenceService)
                .environmentObject(userSettings)
        }
        .onReceive(mapState.$region) { newRegion in
            if let newRegion = newRegion {
                self.region = newRegion
            }
        }
        .onAppear {
            // Perform initial zoom after short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                performInitialZoom()
            }
        }
    }

    private func performInitialZoom() {
        guard !didPerformInitialZoom else { return }
        
        if let userLocation = mapState.userLocation {
            let span25km = MKCoordinateSpan(latitudeDelta: 0.225, longitudeDelta: 0.225)
            let userRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
                span: span25km
            )
            self.region = userRegion
            didPerformInitialZoom = true
        }
    }
}

// MARK: - Event-Driven Map View

private struct EventDrivenMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var mapView: MKMapView?
    @Binding var isHeadingMode: Bool
    @Binding var didPerformInitialZoom: Bool
    
    @EnvironmentObject var mapState: MapState

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsUserLocation = true
        mapView.isUserInteractionEnabled = true
        mapView.register(CustomAnnotationView.self, forAnnotationViewWithReuseIdentifier: "custom")
        
        DispatchQueue.main.async {
            self.mapView = mapView
        }
        
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Update region
        if !coordinatesEqual(uiView.region.center, region.center) ||
           abs(uiView.region.span.latitudeDelta - region.span.latitudeDelta) > 0.001 {
            uiView.setRegion(region, animated: true)
        }
        
        // Apply camera update from policies
        if let cameraUpdate = mapState.cameraUpdate {
            applyCameraUpdate(uiView, cameraUpdate)
        }
        
        // Update annotations
        updateAnnotations(uiView)
        
        // Update overlays
        updateOverlays(uiView)
        
        // Handle heading mode
        updateCameraForHeadingMode(uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func applyCameraUpdate(_ mapView: MKMapView, _ update: CameraUpdate) {
        let camera = MKMapCamera(
            lookingAtCenter: update.center ?? mapView.camera.centerCoordinate,
            fromDistance: update.distance ?? mapView.camera.centerCoordinateDistance,
            pitch: update.pitch ?? mapView.camera.pitch,
            heading: update.heading ?? mapView.camera.heading
        )
        mapView.setCamera(camera, animated: update.animated)
    }
    
    private func updateAnnotations(_ mapView: MKMapView) {
        let existingAnnotations = mapView.annotations.compactMap { $0 as? CustomMapAnnotation }
        let newIds = Set(mapState.annotations.map { $0.id })
        
        // Remove old annotations
        let annotationsToRemove = existingAnnotations.filter { annotation in
            guard let item = annotation.item else { return true }
            return !newIds.contains(item.id)
        }
        if !annotationsToRemove.isEmpty {
            mapView.removeAnnotations(annotationsToRemove)
        }
        
        // Add/update annotations
        for item in mapState.annotations {
            if let existing = existingAnnotations.first(where: { $0.item?.id == item.id }) {
                // Update existing annotation
                if let existingItem = existing.item,
                   !coordinatesEqual(existingItem.coordinate, item.coordinate) ||
                   existingItem.altitude != item.altitude ||
                   existingItem.isAscending != item.isAscending {
                    existing.coordinate = item.coordinate
                    existing.item = item
                }
            } else {
                // Add new annotation
                let annotation = CustomMapAnnotation()
                annotation.coordinate = item.coordinate
                annotation.item = item
                mapView.addAnnotation(annotation)
            }
        }
    }
    
    private func updateOverlays(_ mapView: MKMapView) {
        let currentOverlays = mapView.overlays.compactMap { $0 as? MKPolyline }
        
        // Update balloon track
        updateOverlay(mapView, current: currentOverlays.first { $0.title == "balloonTrack" }, 
                     new: mapState.balloonTrackPath, title: "balloonTrack")
        
        // Update prediction path
        let predictionPath = mapState.isPredictionPathVisible ? mapState.predictionPath : nil
        updateOverlay(mapView, current: currentOverlays.first { $0.title == "predictionPath" }, 
                     new: predictionPath, title: "predictionPath")
        
        // Update user route
        let userRoute = mapState.isRouteVisible ? mapState.userRoute : nil
        updateOverlay(mapView, current: currentOverlays.first { $0.title == "userRoute" }, 
                     new: userRoute, title: "userRoute")
    }
    
    private func updateOverlay(_ mapView: MKMapView, current: MKPolyline?, new: MKPolyline?, title: String) {
        if let new = new {
            new.title = title
            if current == nil || !polylinesEqual(lhs: current!, rhs: new) {
                if let current = current {
                    mapView.removeOverlay(current)
                }
                mapView.addOverlay(new)
            }
        } else if let current = current {
            mapView.removeOverlay(current)
        }
    }
    
    private func updateCameraForHeadingMode(_ mapView: MKMapView) {
        if isHeadingMode {
            mapView.isScrollEnabled = false
            mapView.isZoomEnabled = true
            mapView.isPitchEnabled = false
            mapView.isRotateEnabled = false
            
            if let userLocation = mapState.userLocation {
                let center = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
                let camera = MKMapCamera(
                    lookingAtCenter: center,
                    fromDistance: mapView.camera.centerCoordinateDistance,
                    pitch: 45.0,
                    heading: userLocation.heading
                )
                mapView.setCamera(camera, animated: true)
            }
        } else {
            mapView.isScrollEnabled = true
            mapView.isZoomEnabled = true
            mapView.isPitchEnabled = true
            mapView.isRotateEnabled = true
            
            let camera = MKMapCamera(
                lookingAtCenter: mapView.camera.centerCoordinate,
                fromDistance: mapView.camera.centerCoordinateDistance,
                pitch: mapView.camera.pitch,
                heading: 0
            )
            mapView.setCamera(camera, animated: true)
        }
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: EventDrivenMapView

        init(_ parent: EventDrivenMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            EventBus.shared.publishUIEvent(.cameraRegionChanged(mapView.region, timestamp: Date()))
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                switch polyline.title {
                case "balloonTrack":
                    renderer.strokeColor = .red
                    renderer.lineWidth = 1
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

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let identifier = "userLocation"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                if view == nil {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
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
                
                if item.kind == .balloon {
                    view.isUserInteractionEnabled = true
                    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleAnnotationTap(_:)))
                    view.gestureRecognizers?.forEach(view.removeGestureRecognizer)
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
            
            EventBus.shared.publishUIEvent(.annotationSelected(item, timestamp: Date()))
        }
    }
}

// MARK: - Custom Annotation Classes

private class CustomMapAnnotation: MKPointAnnotation {
    var item: MapAnnotationItem?
}

private struct AnnotationHostingView: View {
    @ObservedObject var item: MapAnnotationItem

    var body: some View {
        if item.kind == .balloon {
            let isAscending = item.isAscending ?? false
            ZStack {
                Image(systemName: "balloon.fill")
                    .foregroundColor(isAscending ? Color.green : Color.red)
                    .font(.system(size: 38))
                if let altitude = item.altitude {
                    Text("\(Int(altitude))m")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.9), radius: 1.5, x: 0, y: 0)
                        .offset(y: -8)
                } else {
                    Text("?")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.9), radius: 1.5, x: 0, y: 0)
                        .offset(y: -8)
                }
            }
            .accessibilityLabel("Balloon altitude \(item.altitude.map { Int($0) } ?? 0) meters, \(isAscending ? "ascending" : "descending")")
        } else {
            item.view
        }
    }
}

private class CustomAnnotationView: MKAnnotationView {
    private var hostingController: UIHostingController<AnnotationHostingView>?
    private var currentItem: MapAnnotationItem?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        self.frame = CGRect(x: 0, y: 0, width: 90, height: 90)
        self.backgroundColor = .clear
        self.canShowCallout = false

        let initialItem = MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .user)
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
        if let hc = hostingController {
            hc.rootView = AnnotationHostingView(item: item)
        }
        self.currentItem = item

        switch item.kind {
        case .user:
            self.centerOffset = CGPoint(x: 0, y: 0)
        case .balloon:
            self.centerOffset = CGPoint(x: 0, y: -32)
        case .burst:
            self.centerOffset = CGPoint(x: 0, y: -15)
        case .landing:
            self.centerOffset = CGPoint(x: 0, y: -15)
        case .landed:
            self.centerOffset = CGPoint(x: 0, y: -15)
        }
    }

    override var annotation: MKAnnotation? {
        didSet {
            if let customAnnotation = annotation as? CustomMapAnnotation, let item = customAnnotation.item {
                if self.currentItem !== item {
                    setup(with: item)
                }
            }
        }
    }
}

// MARK: - Utility Functions

private func polylinesEqual(lhs: MKPolyline, rhs: MKPolyline) -> Bool {
    guard lhs.pointCount == rhs.pointCount else { return false }
    let lhsCoords = lhs.coordinates
    let rhsCoords = rhs.coordinates
    for (a, b) in zip(lhsCoords, rhsCoords) {
        if a.latitude != b.latitude || a.longitude != b.longitude { return false }
    }
    return true
}

// coordinatesEqual function removed - duplicate definition

