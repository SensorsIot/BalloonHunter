import SwiftUI
import MapKit
import Combine
import OSLog


// MARK: - Distance Overlay Component
struct DistanceOverlayView: View {
    let distanceMeters: CLLocationDistance?

    private var formattedDistance: String {
        guard let distance = distanceMeters else { return "--" }
        if distance < 1000 {
            return "\(Int(distance.rounded())) m"
        } else {
            return String(format: "%.1f km", distance / 1000)
        }
    }

    var body: some View {
        VStack {
            Spacer()
            Text(formattedDistance)
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.7))
                .cornerRadius(20)
                .padding(.bottom, 20)
        }
        .animation(.easeInOut(duration: 0.3), value: formattedDistance) // Smooth distance changes when significant movement occurs
    }
}

struct TrackingMapView: View {
    @EnvironmentObject var mapPresenter: MapPresenter
    @EnvironmentObject var userSettings: UserSettings

    @State private var showSettings = false
    @State private var position: MapCameraPosition = .automatic
    @State private var hasInitializedFromLocation = false
    @State private var savedZoomLevel: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 0.225, longitudeDelta: 0.225) // Default ~25km zoom for startup
    @State private var isInHeadingMode: Bool = false
    @State private var hasPreservedStartupZoom = false  // Track if we've preserved startup zoom on first appearance
    @State private var needsStartupZoom = true  // Track if we need to apply startup zoom

    // MARK: - Flight State Computed Properties
    private var isFlying: Bool { mapPresenter.isFlying }

    private var isLanded: Bool { mapPresenter.isLanded }

    private var shouldShowRoute: Bool { mapPresenter.shouldShowRoute }

    private var isWithin200mOfLandedBalloon: Bool { mapPresenter.isWithin200mOfBalloon }

    private func logZoomChange(_ description: String, span: MKCoordinateSpan, center: CLLocationCoordinate2D? = nil) {
        mapPresenter.logZoomChange(description, span: span, center: center)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Top control panel
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Settings button
                        Button {
                            mapPresenter.requestDeviceParameters()
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Transport mode picker
                        Picker("Mode", selection: Binding(
                            get: { mapPresenter.transportMode },
                            set: { newValue in mapPresenter.setTransportMode(newValue) }
                        )) {
                            Image(systemName: "car.fill").tag(TransportationMode.car)
                            Image(systemName: "bicycle").tag(TransportationMode.bike)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)


                        // Show All or Point button
                        if mapPresenter.landingPoint != nil {
                            Button("All") {
                                if mapPresenter.isHeadingMode { mapPresenter.toggleHeadingMode() }
                                mapPresenter.triggerShowAllAnnotations()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Point") {
                                appLog("TrackingMapView: Landing point setting requested (not yet implemented)", category: .general, level: .info)
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                        }

                        // Heading mode toggle
                        Button {
                            mapPresenter.toggleHeadingMode()
                        } label: {
                            Image(systemName: mapPresenter.isHeadingMode ? "location.north.circle.fill" : "location.circle")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Buzzer mute toggle
                        Button {
                            mapPresenter.setMuteState(!mapPresenter.isBuzzerMuted)
                        } label: {
                            Image(systemName: (mapPresenter.balloonTelemetry?.buzmute ?? false) ? "speaker.slash.fill" : "speaker.2.fill")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Apple Maps navigation button (only show when landing point available)
                        if mapPresenter.landingPoint != nil {
                            Button {
                                mapPresenter.openInAppleMaps()
                            } label: {
                                Image(systemName: "location.fill.viewfinder")
                                    .imageScale(.large)
                                    .padding(8)
                            }
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }

                // Direct ServiceCoordinator Map Rendering
                ZStack {
                    Map(position: $position, interactionModes: mapPresenter.isHeadingMode ? .zoom : .all) {
                    
                    // 1. Balloon Track: Historic track as thin red line
                    let trackPoints = mapPresenter.trackPoints
                    if trackPoints.count >= 2 {
                        let coordinates = trackPoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                        let trackPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                        MapPolyline(trackPolyline)
                            .stroke(.red, lineWidth: 2)
                    }
                    
                    // 2. Balloon Predicted Path: Thick blue line (flying mode only)
                    if isFlying,
                       let predictionPath = mapPresenter.predictionPath {
                        MapPolyline(predictionPath)
                            .stroke(.blue, lineWidth: 4)
                    }
                    
                    // 3. Planned Route: Green path from user to landing point (when needed for navigation)
                    if shouldShowRoute,
                       let userRoute = mapPresenter.userRoute {
                        MapPolyline(userRoute)
                            .stroke(.green, lineWidth: 3)
                    }

                    // 4. Landing prediction history: Purple polyline connecting Sondehub landing estimates
                    let landingHistory = mapPresenter.landingHistory
                    if landingHistory.count >= 2 {
                        let landingCoordinates = landingHistory.map { $0.coordinate }
                        let landingPolyline = MKPolyline(coordinates: landingCoordinates, count: landingCoordinates.count)
                        MapPolyline(landingPolyline)
                            .stroke(.purple, lineWidth: 2)
                    }

                    if !landingHistory.isEmpty {
                        ForEach(Array(landingHistory.enumerated()), id: \.offset) { _, point in
                            Annotation("", coordinate: point.coordinate) {
                                Circle()
                                    .fill(Color.purple)
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                            }
                        }
                    }

                    // 5. User Position: Runner icon at user location (always shown in tracking view)
                    if !mapPresenter.isHeadingMode,
                       let userLocation = mapPresenter.userLocation {
                        let userCoordinate = CLLocationCoordinate2D(
                            latitude: userLocation.latitude,
                            longitude: userLocation.longitude
                        )
                        Annotation("", coordinate: userCoordinate) {
                            Image(systemName: "figure.run")
                                .font(.title2)
                                .foregroundColor(.blue)
                                .background(Circle().fill(.white).stroke(.blue, lineWidth: 2))
                        }
                    }
                    
                    // 6. Balloon Live Position: Color based on flight phase
                    if let balloonTelemetry = mapPresenter.balloonTelemetry {
                        // Use smoothed display position when available (for landed balloons), otherwise use raw telemetry
                        let balloonCoordinate = mapPresenter.balloonDisplayPosition ?? CLLocationCoordinate2D(
                            latitude: balloonTelemetry.latitude,
                            longitude: balloonTelemetry.longitude
                        )
                        let balloonColor: Color = {
                            switch mapPresenter.balloonPhase {
                            case .ascending: return .green
                            case .descendingAbove10k: return .orange
                            case .descendingBelow10k: return .red
                            case .landed: return .purple
                            case .unknown: return .gray
                            }
                        }()
                        
                        Annotation("", coordinate: balloonCoordinate) {
                            Image(systemName: "balloon.fill")
                                .font(.system(size: 30))
                                .foregroundColor(balloonColor)
                            .onTapGesture {
                                // Manual prediction trigger
                                mapPresenter.triggerPrediction()
                            }
                        }
                    }

                    // 7. Burst Point: Only visible when balloon is ascending
                    if let burstPoint = mapPresenter.burstPoint,
                       mapPresenter.balloonPhase == .ascending {
                        Annotation("Burst", coordinate: burstPoint) {
                            Image(systemName: "burst.fill")
                                .font(.title2)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    // 8. Landing Point: Always visible if available
                    if let landingPoint = mapPresenter.landingPoint {
                        Annotation("", coordinate: landingPoint) {
                            Image(systemName: "target")
                                .font(.title2)
                                .foregroundColor(.purple)
                                .background(Circle().fill(.white).stroke(.purple, lineWidth: 2))
                        }
                    }
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                    MapUserLocationButton()
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll, showsTraffic: false))
                .mapControlVisibility(mapPresenter.isHeadingMode ? .hidden : .automatic)
                .frame(height: geometry.size.height * 0.7)
                .onMapCameraChange { context in
                    guard !showSettings else { return }

                    if needsStartupZoom {
                        needsStartupZoom = false
                        appLog("🔍 ZOOM: Map initialized, triggering startup zoom", category: .general, level: .info)
                        mapPresenter.updateCameraToShowAllAnnotations()
                        return
                    }

                    savedZoomLevel = context.region.span
                    logZoomChange("Map camera changed by user", span: context.region.span, center: context.region.center)
                }
                .onReceive(mapPresenter.$region) { region in
                    guard !showSettings else { return }
                    if let region = region, !mapPresenter.isHeadingMode {
                        position = .region(region)
                    }
                }
                .onReceive(mapPresenter.$isHeadingMode) { isHeadingMode in
                    guard !showSettings else { return }

                    if !hasPreservedStartupZoom {
                        hasPreservedStartupZoom = true
                        isInHeadingMode = isHeadingMode
                        appLog("🔍 ZOOM: TrackingMapView first appearance - preserving startup zoom", category: .general, level: .info)
                        return
                    }

                    updateMapPositionForHeadingMode(isHeadingMode)
                }
                .onReceive(mapPresenter.$userLocation) { _ in
                    guard !showSettings else { return }
                    guard hasPreservedStartupZoom else { return }
                    if mapPresenter.isHeadingMode {
                        updateMapPositionForHeadingMode(true)
                    }
                }

                    // Distance annotation overlay (landing mode only)
                    if isLanded {
                        DistanceOverlayView(
                            distanceMeters: mapPresenter.distanceToBalloon
                        )
                    }
                }

                // Sonde name mismatch field (persistent, only visible when mismatch detected)
                if mapPresenter.bleSerialName != mapPresenter.aprsSerialName &&
                   !mapPresenter.bleSerialName.isEmpty &&
                   !mapPresenter.aprsSerialName.isEmpty {
                    HStack {
                        Spacer()
                        Text("SondeHub: '\(mapPresenter.aprsSerialName)' RadioSondyGo: '\(mapPresenter.bleSerialName)'")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Spacer()
                    }
                    .padding(.bottom, 4)
                }

                // Data panel
                DataPanelView()
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 0))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(mapPresenter.bleService)
                .environmentObject(mapPresenter.persistenceService)
                .environmentObject(userSettings)
        }
        .onChange(of: showSettings) { _, isOpen in
            mapPresenter.setCameraUpdatesSuspended(isOpen)
        }
    }
    
    private func updateMapToShowAllAnnotations() {
        if mapPresenter.isHeadingMode {
            return
        }
        // Map will automatically adjust using .automatic position
    }
    
    private func updateMapPositionForHeadingMode(_ isHeadingMode: Bool) {
        self.isInHeadingMode = isHeadingMode
        
        if isHeadingMode {
            // Switching TO heading mode - set initial position with saved zoom, then enable heading
            guard let userLocation = mapPresenter.userLocation else {
                appLog("🔍 ZOOM: Cannot switch to heading mode - no user location", category: .general, level: .error)
                return
            }
            
            let userCoordinate = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
            let region = MKCoordinateRegion(center: userCoordinate, span: savedZoomLevel)
            
            logZoomChange("Switch TO heading mode - initial position", span: savedZoomLevel, center: userCoordinate)
            
            // First set the position with saved zoom
            position = .region(region)
            
            // Then enable heading tracking after a brief delay, letting map preserve current zoom
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                appLog("🔍 ZOOM: Enabling heading tracking (preserving current zoom)", category: .general, level: .info)
                // Don't provide fallback - let map preserve current view
                position = .userLocation(followsHeading: true, fallback: .automatic)
            }
            
        } else {
            // Switching TO free mode - set initial position with saved zoom
            guard let userLocation = mapPresenter.userLocation else {
                appLog("🔍 ZOOM: Switch to free mode - using .automatic (no user location)", category: .general, level: .info)
                position = .automatic
                return
            }
            
            let userCoordinate = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
            let region = MKCoordinateRegion(center: userCoordinate, span: savedZoomLevel)
            
            logZoomChange("Switch TO free mode - initial position", span: savedZoomLevel, center: userCoordinate)
            position = .region(region)
        }
    }
}

#Preview {
    let mockAppServices = AppServices()
    let mockServiceCoordinator = ServiceCoordinator(
        bleCommunicationService: mockAppServices.bleCommunicationService,
        currentLocationService: mockAppServices.currentLocationService,
        persistenceService: mockAppServices.persistenceService,
        predictionCache: mockAppServices.predictionCache,
        routingCache: mockAppServices.routingCache,
        balloonPositionService: mockAppServices.balloonPositionService,
        balloonTrackService: mockAppServices.balloonTrackService,
        landingPointTrackingService: mockAppServices.landingPointTrackingService
    )
    let mockPresenter = MapPresenter(
        coordinator: mockServiceCoordinator,
        balloonTrackService: mockAppServices.balloonTrackService,
        landingPointTrackingService: mockAppServices.landingPointTrackingService,
        currentLocationService: mockAppServices.currentLocationService
    )
    
    TrackingMapView()
        .environmentObject(mockPresenter)
        .environmentObject(mockAppServices.userSettings)
        .environmentObject(mockServiceCoordinator)
        .environmentObject(mockAppServices.bleCommunicationService)
        .environmentObject(mockAppServices.balloonTrackService)
        .environmentObject(mockAppServices.balloonPositionService)
        .environmentObject(mockAppServices.landingPointTrackingService)
        .environmentObject(mockServiceCoordinator.predictionService)
}
