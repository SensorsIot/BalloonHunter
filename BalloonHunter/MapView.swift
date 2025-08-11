import SwiftUI
import CoreLocation
import MapKit

public struct MapView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var locationService: CurrentLocationService
    
    @State private var transportMode: RouteMode = .car
    @State private var isBuzzerOn: Bool = false
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showBurstMarker: Bool = true
    @State private var mapAnnotations: [MapAnnotationItem] = []
    
    private var panelTelemetry: TelemetryStruct? {
        // Direct assignment is used here to avoid recreating the struct with incorrect property names.
        // The TelemetryStruct is already created and updated in the BLEManager.
        viewModel.latestTelemetry
    }
    
    @EnvironmentObject private var predictionInfo: PredictionInfo
    
    var onBalloonTapped: () -> Void = {}
    
    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // Transport Mode Selector
                    HStack {
                        Text("Transport Mode:")
                            .font(.caption)
                        Spacer()
                        Picker("Transport Mode", selection: $transportMode) {
                            Image(systemName: "car.fill").tag(RouteMode.car)
                            Image(systemName: "bicycle").tag(RouteMode.bike)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .zIndex(1)
                    
                    // Map occupies 80% of height
                    Map(position: $cameraPosition, interactionModes: .all) {
                        // Annotations for user and balloon
                        ForEach(mapAnnotations) { annotation in
                            Annotation("", coordinate: annotation.coordinate) {
                                annotationView(for: annotation)
                            }
                            .annotationTitles(.hidden)
                        }
                        
                        // Polylines for paths
                        if !predictedPath.isEmpty {
                            MapPolyline(coordinates: predictedPath)
                                .stroke(.blue, lineWidth: 3)
                        }
                        if !balloonHistory.isEmpty {
                            MapPolyline(coordinates: balloonHistory)
                                .stroke(.red, lineWidth: 2)
                        }
                        if !hunterRoute.isEmpty {
                            MapPolyline(coordinates: hunterRoute)
                                .stroke(.purple, style: StrokeStyle(lineWidth: 3, dash: [6, 5]))
                        }
                        
                        // Marker for burst location
                        if showBurstMarker, let burstCoord = burstCoord {
                            Annotation("", coordinate: burstCoord) { MapMarkerOverlay(coordinate: burstCoord, systemImage: "sparkles", color: .yellow) }.annotationTitles(.hidden)
                        }
                    }
                    .frame(height: geo.size.height * 0.8)
                }
                // Data panel - bottom 20%
                VStack {
                    Spacer()
                    DataPanelView(
                        isBleConnected: viewModel.isConnected,
                        isBuzzerOn: $isBuzzerOn,
                        telemetry: panelTelemetry,
                        landingTime: predictionInfo.landingTime,
                        arrivalTime: predictionInfo.arrivalTime,
                        routeDistance: predictionInfo.routeDistanceMeters
                    )
                    .frame(height: geo.size.height * 0.2)
                    .padding(.bottom, geo.safeAreaInsets.bottom + 4)
                }
            }
            .edgesIgnoringSafeArea(.all)
            .onAppear(perform: setupView)
            .onChange(of: viewModel.latestTelemetry) {
                updateAnnotations()
            }
            .onChange(of: userLocationKey) {
                updateAnnotations()
            }
            .onReceive(locationService.$heading) { newHeading in
                guard let heading = newHeading else { return }
                updateCameraHeading(with: heading)
            }
        }
    }
    
    private func setupView() {
        // Start timers for periodic predictions and route updates
        PredictionService.shared.startPredictionTimer { info in
            predictionInfo.landingTime = info.landingTime
            predictionInfo.arrivalTime = info.arrivalTime
            predictionInfo.routeDistanceMeters = info.routeDistanceMeters
            predictionInfo.burstCoordinate = info.burstCoordinate
            predictionInfo.predictedPath = info.predictedPath
            predictionInfo.hunterRoute = info.hunterRoute
        }
        PredictionService.shared.startRouteTimer { info in
            predictionInfo.landingTime = info.landingTime
            predictionInfo.arrivalTime = info.arrivalTime
            predictionInfo.routeDistanceMeters = info.routeDistanceMeters
            predictionInfo.burstCoordinate = info.burstCoordinate
            predictionInfo.predictedPath = info.predictedPath
            predictionInfo.hunterRoute = info.hunterRoute
        }
        
        // Center map initially
        var centerCoordinate = MapView.defaultRegion.center
        if let balloonLoc = balloonCoordinate {
            centerCoordinate = balloonLoc
        } else if let userLoc = userCoordinate {
            centerCoordinate = userLoc
        }
        cameraPosition = .camera(MapCamera(centerCoordinate: centerCoordinate, distance: 5000, heading: 0, pitch: 0))
        
        updateAnnotations()
    }
    
    private func annotationView(for annotation: MapAnnotationItem) -> some View {
        annotation.annotationView
            .onTapGesture {
                if annotation.kind == .balloon {
                    onBalloonTapped()
                }
            }
    }
    
    private func updateAnnotations() {
        mapAnnotations = AnnotationService.calculateAnnotations(
            userCoordinate: userCoordinate,
            balloonCoordinate: balloonCoordinate,
            latestTelemetry: panelTelemetry,
            viewModel: viewModel
        )
    }
    
    private func updateCameraHeading(with newHeading: CLHeading) {
        if var currentCamera = cameraPosition.camera {
            currentCamera.heading = newHeading.trueHeading
            cameraPosition = .camera(currentCamera)
        }
    }
    
    // MARK: - Computed properties
    
    private var userCoordinate: CLLocationCoordinate2D? {
        locationService.location?.coordinate
    }
    private var userLocationKey: String {
        guard let coord = userCoordinate else { return "none" }
        return String(format: "%.6f,%.6f", coord.latitude, coord.longitude)
    }
    private var balloonCoordinate: CLLocationCoordinate2D? {
        viewModel.latestTelemetry?.coordinate
    }
    private var burstCoord: CLLocationCoordinate2D? {
        predictionInfo.burstCoordinate
    }
    private var predictedPath: [CLLocationCoordinate2D] {
        predictionInfo.predictedPath
    }
    private var balloonHistory: [CLLocationCoordinate2D] {
        viewModel.balloonHistory
    }
    private var hunterRoute: [CLLocationCoordinate2D] {
        predictionInfo.hunterRoute
    }
    
    // MARK: - Annotations
    
    // Replaced local updateAnnotations() with AnnotationService call above.
    
    // MARK: - Supporting Types
    
    enum RouteMode: Int, Hashable {
        case car
        case bike
    }
    
    private static var defaultRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.5, longitude: 8.0),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
    }
}
