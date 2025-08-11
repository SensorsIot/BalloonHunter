import SwiftUI
import CoreLocation
import MapKit

private extension MapView {
    @ViewBuilder
    var predictedPathOverlay: some View {
        MapPolylineOverlay(
            coordinates: predictedPath,
            color: .blue,
            lineWidth: 3
        )
    }
    @ViewBuilder
    var balloonHistoryOverlay: some View {
        MapPolylineOverlay(
            coordinates: balloonHistory,
            color: .red,
            lineWidth: 2
        )
    }
    @ViewBuilder
    var hunterRouteOverlay: some View {
        MapPolylineOverlay(
            coordinates: hunterRoute,
            color: .purple,
            lineWidth: 3,
            dash: [6, 5]
        )
    }
    @ViewBuilder
    var burstMarkerOverlay: some View {
        Group {
            if showBurstMarker, let burstCoord = burstCoord {
                MapMarkerOverlay(coordinate: burstCoord, systemImage: "sparkles", color: .yellow)
            }
        }
    }
    
    func annotationView(for annotation: MapAnnotationItem) -> some View {
        annotation.annotationView
            .onTapGesture {
                if annotation.kind == .balloon {
                    onBalloonTapped()
                }
            }
    }
}

public struct MapView: View {
    @ObservedObject var viewModel: MainViewModel
    @ObservedObject var locationManager: LocationManager
    
    @State private var transportMode: RouteMode = .car
    @State private var isBuzzerOn: Bool = false
    @State private var mapRegion: MKCoordinateRegion = MKCoordinateRegion()
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
                    Map(
                        coordinateRegion: $mapRegion,
                        interactionModes: .all,
                        annotationItems: mapAnnotations
                    ) { annotation in
                        MapAnnotation(coordinate: annotation.coordinate) {
                            annotationView(for: annotation)
                        }
                    }
                    .overlay(predictedPathOverlay)
                    .overlay(balloonHistoryOverlay)
                    .overlay(hunterRouteOverlay)
                    .overlay(burstMarkerOverlay)
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
            .onAppear {
                // Start timers for periodic predictions and route updates using PredictionService
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
                // Center map initially and set span
                mapRegion = MapView.defaultRegion
                if let balloonLoc = balloonCoordinate {
                    mapRegion.center = balloonLoc
                } else if let userLoc = userCoordinate {
                    mapRegion.center = userLoc
                }
                // Update annotations using AnnotationService
                mapAnnotations = AnnotationService.calculateAnnotations(
                    userCoordinate: userCoordinate,
                    balloonCoordinate: balloonCoordinate,
                    latestTelemetry: panelTelemetry,
                    viewModel: viewModel
                ) as [MapAnnotationItem]
            }
            .onChange(of: viewModel.latestTelemetry) { _ in
                // Update annotations using AnnotationService
                mapAnnotations = AnnotationService.calculateAnnotations(
                    userCoordinate: userCoordinate,
                    balloonCoordinate: balloonCoordinate,
                    latestTelemetry: panelTelemetry,
                    viewModel: viewModel
                ) as [MapAnnotationItem]
            }
            .onChange(of: userLocationKey) { _ in
                // Update annotations using AnnotationService
                mapAnnotations = AnnotationService.calculateAnnotations(
                    userCoordinate: userCoordinate,
                    balloonCoordinate: balloonCoordinate,
                    latestTelemetry: panelTelemetry,
                    viewModel: viewModel
                ) as [MapAnnotationItem]
            }
        }
    }
    
    // MARK: - Computed properties
    
    private var userCoordinate: CLLocationCoordinate2D? {
        locationManager.location?.coordinate
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
    
    private static var initialMapRegion: MKCoordinateRegion {
        let center = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let span = MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
        return MKCoordinateRegion(center: center, span: span)
    }
}
