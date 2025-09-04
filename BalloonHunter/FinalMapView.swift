import SwiftUI
import MapKit
import CoreLocation // For CLLocationCoordinate2D

struct FinalMapView: View {
    @EnvironmentObject var annotationService: AnnotationService
    @EnvironmentObject var locationService: CurrentLocationService
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var balloonTrackingService: BalloonTrackingService

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01) // Very zoomed in
    )
    @State private var showSettings = false
    @State private var landedBalloonPosition: CLLocationCoordinate2D? = nil
    @State private var userHeading: CLLocationDirection = 0.0
    @State private var distanceToBalloon: CLLocationDistance = 0.0

    var body: some View {
        ZStack {
            FinalApproachMapView(
                region: $region,
                annotations: annotationService.annotations,
                userTrackingMode: .followWithHeading,
                landedBalloonPosition: landedBalloonPosition
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
    }

    private func updateMapAndUI(userLocation: LocationData) {
        guard let landedPos = landedBalloonPosition else { return }

        let userCLLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let balloonCLLocation = CLLocation(latitude: landedPos.latitude, longitude: landedPos.longitude)

        distanceToBalloon = userCLLocation.distance(from: balloonCLLocation)

        // Update annotations for AnnotationService
        var newAnnotations: [MapAnnotationItem] = []
        newAnnotations.append(MapAnnotationItem(coordinate: userCLLocation.coordinate, kind: .user))
        newAnnotations.append(MapAnnotationItem(coordinate: landedPos, kind: .landed)) // Using .landed for stable position
        annotationService.annotations = newAnnotations

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
    }
}

// MARK: - FinalApproachMapView UIViewRepresentable

private struct FinalApproachMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let annotations: [MapAnnotationItem]
    let userTrackingMode: MKUserTrackingMode
    let landedBalloonPosition: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard // Roads only
        mapView.showsUserLocation = true
        mapView.userTrackingMode = userTrackingMode
        mapView.register(CustomAnnotationView.self, forAnnotationViewWithReuseIdentifier: "custom")
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

        // Update region and user tracking mode
        uiView.setRegion(region, animated: true)
        uiView.userTrackingMode = userTrackingMode

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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: FinalApproachMapView

        init(_ parent: FinalApproachMapView) {
            self.parent = parent
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
            }
            return view
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
