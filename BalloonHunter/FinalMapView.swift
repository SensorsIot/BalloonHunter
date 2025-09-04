import SwiftUI
import MapKit
import CoreLocation // For CLLocationCoordinate2D

struct FinalMapView: View {
    @EnvironmentObject var annotationService: AnnotationService
    @EnvironmentObject var locationService: CurrentLocationService
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var balloonTrackingService: BalloonTrackingService

    @State private var showSettings = false
    @State private var landedBalloonPosition: CLLocationCoordinate2D? = nil
    @State private var userHeading: CLLocationDirection = 0.0
    @State private var distanceToBalloon: CLLocationDistance = 0.0
    
    // Track the timestamp when finalApproach started
    @State private var finalApproachStartTime: Date? = nil

    private var finalApproachAnnotations: [MapAnnotationItem] {
        var annotations: [MapAnnotationItem] = []

        if let userLocation = locationService.locationData {
            let userCoordinate = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
            annotations.append(MapAnnotationItem(coordinate: userCoordinate, kind: .user))
        }

        if let landedPos = landedBalloonPosition {
            annotations.append(MapAnnotationItem(coordinate: landedPos, kind: .landed))
        }

        return annotations
    }
    
    // Computed property to get filtered balloon track points from finalApproachStartTime
    private var finalApproachTrackCoordinates: [CLLocationCoordinate2D] {
        balloonTrackingService.currentBalloonTrack.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        ZStack {
            FinalApproachMapView(
                annotations: finalApproachAnnotations,
                userTrackingMode: .followWithHeading,
                landedBalloonPosition: landedBalloonPosition,
                trackCoordinates: finalApproachTrackCoordinates
            )
            .edgesIgnoringSafeArea(.all)
            .gesture(DragGesture().onEnded { value in
                if value.translation.height < -50 { // Upward swipe
                    showSettings = true
                }
            })

            VStack {
                // Top area for heading and distance
                HStack {
                    Spacer()
                    VStack {
                        Text(String(format: "Heading: %.0f°", userHeading))
                            .font(.headline)
                        Text(String(format: "Distance: %.0f m", distanceToBalloon))
                            .font(.headline)
                    }
                    Spacer()
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(10)
                .padding(.top, 50) // Adjust as needed to be in the top area

                Spacer()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onReceive(locationService.$locationData) { locationData in
            if let locationData = locationData {
                userHeading = locationData.heading
                updateMapAndUI(userLocation: locationData)
            }
        }
        .onReceive(balloonTrackingService.$currentBalloonTrack) { track in
            updateLandedBalloonPosition(track: track)
            if let userLocationData = locationService.locationData {
                updateMapAndUI(userLocation: userLocationData)
            }
        }
        .onChange(of: annotationService.appState) { newState in
            if newState == .finalApproach {
                // Record the start time when final approach begins
                finalApproachStartTime = Date()
            } else {
                // Clear the start time when leaving finalApproach mode
                finalApproachStartTime = nil
            }
        }
    }

    private func updateLandedBalloonPosition(track: [BalloonTrackPoint]) {
        guard track.count >= 100 else {
            landedBalloonPosition = nil
            return
        }
        let last100Points = track.suffix(100)
        let sumLat = last100Points.reduce(0.0) { $0 + $1.latitude }
        let sumLon = last100Points.reduce(0.0) { $0 + $1.longitude }
        landedBalloonPosition = CLLocationCoordinate2D(
            latitude: sumLat / Double(last100Points.count),
            longitude: sumLon / Double(last100Points.count)
        )
        // Do not update region when in final approach mode
        if annotationService.appState == .finalApproach {
            return
        }
        // Commented out auto-centering on landed balloon position to keep manual control in final approach
        /*
        if let landedPos = landedBalloonPosition {
            region.center = landedPos
        }
        */
    }

    private func updateMapAndUI(userLocation: LocationData) {
        guard let landedPos = landedBalloonPosition else { return }

        // Do not update region or annotations if in final approach mode
        if annotationService.appState == .finalApproach {
            // Still update distance only
            let userCLLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
            let balloonCLLocation = CLLocation(latitude: landedPos.latitude, longitude: landedPos.longitude)

            distanceToBalloon = userCLLocation.distance(from: balloonCLLocation)

            return
        }

        let userCLLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let balloonCLLocation = CLLocation(latitude: landedPos.latitude, longitude: landedPos.longitude)

        distanceToBalloon = userCLLocation.distance(from: balloonCLLocation)

        // Update annotations for AnnotationService only if not in final approach
        var newAnnotations: [MapAnnotationItem] = []
        newAnnotations.append(MapAnnotationItem(coordinate: userCLLocation.coordinate, kind: .user))
        newAnnotations.append(MapAnnotationItem(coordinate: landedPos, kind: .landed))
        annotationService.annotations = newAnnotations

        // Do NOT update region (zoom or pan) in final approach mode to preserve manual control
        // Previously region update code below is removed/commented out:

        /*
        // Calculate bounding rect for both user and balloon
        let points = [userCLLocation.coordinate, landedPos]
        let mapPoints = points.map { MKMapPoint($0) }
        let minX = mapPoints.map { $0.x }.min() ?? 0.0
        let maxX = mapPoints.map { $0.x }.max() ?? 0.0
        let minY = mapPoints.map { $0.y }.min() ?? 0.0
        let maxY = mapPoints.map { $0.y }.max() ?? 0.0
        let boundingRect = MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Add some padding (10%) around the points
        let paddingFactor = 0.1
        let paddedRect = boundingRect.insetBy(dx: -boundingRect.size.width * paddingFactor, dy: -boundingRect.size.height * paddingFactor)
        region = MKCoordinateRegion(paddedRect)
        */
    }
}

// MARK: - FinalApproachMapView UIViewRepresentable

private struct FinalApproachMapView: UIViewRepresentable {
    let annotations: [MapAnnotationItem]
    let userTrackingMode: MKUserTrackingMode
    let landedBalloonPosition: CLLocationCoordinate2D?
    let trackCoordinates: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard // Roads only
        mapView.showsUserLocation = true
        mapView.userTrackingMode = userTrackingMode
        mapView.register(CustomAnnotationView.self, forAnnotationViewWithReuseIdentifier: "custom")
        mapView.isRotateEnabled = true // Enable map rotation
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = false
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Update Annotations
        let existingMapAnnotations = uiView.annotations.compactMap { $0 as? CustomMapAnnotation }
        var existingMapAnnotationMap = [String: CustomMapAnnotation]()
        for annotation in existingMapAnnotations {
            if let id = annotation.item?.id {
                existingMapAnnotationMap[id] = annotation
            }
        }

        var annotationsToAdd = [CustomMapAnnotation]()
        var annotationsToRemove = [MKAnnotation]()

        let newAnnotationItemsMap = Dictionary(uniqueKeysWithValues: annotations.map { ($0.id, $0) })

        for newItem in annotations {
            if let existingAnnotation = existingMapAnnotationMap[newItem.id] {
                existingAnnotation.coordinate = newItem.coordinate
                existingAnnotation.item = newItem
            } else {
                let annotation = CustomMapAnnotation()
                annotation.coordinate = newItem.coordinate
                annotation.item = newItem
                annotationsToAdd.append(annotation)
            }
        }

        for existingAnnotation in existingMapAnnotations {
            if let id = existingAnnotation.item?.id, newAnnotationItemsMap[id] == nil {
                annotationsToRemove.append(existingAnnotation)
            }
        }

        if !annotationsToRemove.isEmpty {
            uiView.removeAnnotations(annotationsToRemove)
        }
        if !annotationsToAdd.isEmpty {
            uiView.addAnnotations(annotationsToAdd)
        }
        
        // Remove old polyline overlays for balloon track
        let existingPolylines = uiView.overlays.filter { $0 is MKPolyline }
        uiView.removeOverlays(existingPolylines)

        // Add new polyline overlay for the balloon track
        if trackCoordinates.count > 1 {
            let polyline = MKPolyline(coordinates: trackCoordinates, count: trackCoordinates.count)
            uiView.addOverlay(polyline)
        }

        // Update region and user tracking mode
        // region is removed so we don't call setRegion here

        // Added code to set initial zoom to fit all annotations once
        if !context.coordinator.hasSetInitialRegion,
           let userAnno = annotations.first(where: { $0.kind == .user })?.coordinate,
           let balloonAnno = annotations.first(where: { $0.kind == .landed })?.coordinate {
            let userPoint = MKMapPoint(userAnno)
            let balloonPoint = MKMapPoint(balloonAnno)
            let minX = min(userPoint.x, balloonPoint.x)
            let maxX = max(userPoint.x, balloonPoint.x)
            let minY = min(userPoint.y, balloonPoint.y)
            let maxY = max(userPoint.y, balloonPoint.y)
            let deltaX = max(maxX - minX, 10) // at least 10m
            let deltaY = max(maxY - minY, 10) // at least 10m
            let marginX = max(deltaX * 0.25, 10) // 25% or ≥10m
            let marginY = max(deltaY * 0.25, 10)
            let mapRect = MKMapRect(
                x: minX - marginX,
                y: minY - marginY,
                width: deltaX + 2 * marginX,
                height: deltaY + 2 * marginY
            )
            uiView.setVisibleMapRect(mapRect, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false)
            context.coordinator.hasSetInitialRegion = true
        }

        uiView.userTrackingMode = userTrackingMode
        
        uiView.isRotateEnabled = true // Ensure rotation enabled on update

        // Removed custom camera/heading manipulation to let MapKit handle rotation and user placement natively

        /*
        // Fix user location at bottom-center
        // This is a bit tricky with MKMapView's userTrackingMode.
        // A common approach is to adjust the content inset or camera.
        // For simplicity, we'll adjust the camera's center offset.
        // This might need fine-tuning based on actual UI layout.
        if userTrackingMode == .followWithHeading {
            let userLocationPoint = uiView.convert(uiView.userLocation.coordinate, toPointTo: uiView)
            let newCenterPoint = CGPoint(x: uiView.bounds.midX, y: uiView.bounds.height * 0.75) // 75% from top (25% from bottom)
            let offset = CGPoint(x: newCenterPoint.x - userLocationPoint.x, y: newCenterPoint.y - userLocationPoint.y)
            
            var newCamera = uiView.camera
            newCamera.centerCoordinate = uiView.convert(CGPoint(x: uiView.bounds.midX - offset.x, y: uiView.bounds.midY - offset.y), toCoordinateFrom: uiView)
            uiView.setCamera(newCamera, animated: true)
        }

        // Set map camera heading using latest heading from coordinator
        if userTrackingMode == .followWithHeading,
           let userAnnotation = annotations.first(where: { $0.kind == .user }) {
            let camera = MKMapCamera()
            camera.centerCoordinate = userAnnotation.coordinate
            camera.heading = context.coordinator.latestHeading ?? 0.0
            camera.pitch = 0
            camera.altitude = 500 // adjust to your preferred zoom
            uiView.setCamera(camera, animated: true)
        }
        */
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: FinalApproachMapView
        var latestHeading: CLLocationDirection?
        var hasSetInitialRegion: Bool = false

        init(_ parent: FinalApproachMapView) {
            self.parent = parent
            self.latestHeading = nil
            super.init()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // region state is removed so no update to parent.region here
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
            }
            return view
        }
        
        // Renderer for polyline overlay
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.7)
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // Update latestHeading when user heading changes via didUpdateLocations or other delegate methods
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            if let heading = userLocation.heading?.trueHeading, heading >= 0 {
                self.latestHeading = heading
            }
        }
    }
}

// Re-using CustomMapAnnotation and CustomAnnotationView from TrackingMapView for consistency
private class CustomMapAnnotation: MKPointAnnotation {
    var item: MapAnnotationItem?
}

private struct AnnotationHostingView: View {
    @ObservedObject var item: MapAnnotationItem

    var body: some View {
        item.view
    }
}

private class CustomAnnotationView: MKAnnotationView {
    private var hostingController: UIHostingController<AnnotationHostingView>?
    private var currentItem: MapAnnotationItem?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        self.frame = CGRect(x: 0, y: 0, width: 90, height: 90)
        self.backgroundColor = .clear

        let initialItem = MapAnnotationItem(coordinate: CLLocationCoordinate2D(), kind: .user)
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
        self.hostingController?.view.removeFromSuperview()
        self.addSubview(newHostingController.view)
        newHostingController.view.frame = self.bounds
        self.hostingController = newHostingController
        self.currentItem = item
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
