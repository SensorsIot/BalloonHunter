import SwiftUI
import MapKit
import Combine
import OSLog

struct TrackingMapView: View {
    @EnvironmentObject var appServices: AppServices
    @EnvironmentObject var userSettings: UserSettings
    @EnvironmentObject var serviceCoordinator: ServiceCoordinator

    @State private var showSettings = false
    @State private var position: MapCameraPosition = .automatic
    @State private var hasInitializedFromLocation = false
    @State private var savedZoomLevel: MKCoordinateSpan = MKCoordinateSpan(latitudeDelta: 0.225, longitudeDelta: 0.225) // Default ~25km zoom for startup
    @State private var isInHeadingMode: Bool = false
    
    private func logZoomChange(_ description: String, span: MKCoordinateSpan, center: CLLocationCoordinate2D? = nil) {
        let zoomKm = Int(span.latitudeDelta * 111) // Approximate km conversion
        if let center = center {
            appLog("🔍 ZOOM: \(description) - \(zoomKm)km (\(String(format: "%.3f", span.latitudeDelta))°) at [\(String(format: "%.4f", center.latitude)), \(String(format: "%.4f", center.longitude))]", category: .general, level: .info)
        } else {
            appLog("🔍 ZOOM: \(description) - \(zoomKm)km (\(String(format: "%.3f", span.latitudeDelta))°)", category: .general, level: .info)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Top control panel
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Settings button
                        Button {
                            serviceCoordinator.requestDeviceParameters()
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
                            get: { serviceCoordinator.transportMode },
                            set: { newValue in serviceCoordinator.transportMode = newValue }
                        )) {
                            Image(systemName: "car.fill").tag(TransportationMode.car)
                            Image(systemName: "bicycle").tag(TransportationMode.bike)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)

                        // Prediction visibility toggle
                        Button {
                            serviceCoordinator.isPredictionPathVisible.toggle()
                        } label: {
                            Image(systemName: serviceCoordinator.isPredictionPathVisible ? "eye.fill" : "eye.slash.fill")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Show All or Point button
                        if serviceCoordinator.landingPoint != nil {
                            Button("All") {
                                if serviceCoordinator.isHeadingMode {
                                    serviceCoordinator.isHeadingMode = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        serviceCoordinator.triggerShowAllAnnotations()
                                    }
                                } else {
                                    serviceCoordinator.triggerShowAllAnnotations()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        updateMapToShowAllAnnotations()
                                    }
                                }
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
                            serviceCoordinator.isHeadingMode.toggle()
                        } label: {
                            Image(systemName: serviceCoordinator.isHeadingMode ? "location.north.circle.fill" : "location.circle")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Buzzer mute toggle
                        Button {
                            serviceCoordinator.setMuteState(!serviceCoordinator.isBuzzerMuted)
                        } label: {
                            Image(systemName: (serviceCoordinator.balloonTelemetry?.buzmute ?? false) ? "speaker.slash.fill" : "speaker.2.fill")
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

                // Direct ServiceCoordinator Map Rendering
                Map(position: $position, interactionModes: serviceCoordinator.isHeadingMode ? [] : .all) {
                    
                    // 1. Balloon Track: Historic track as thin red line
                    if let balloonTrackPath = serviceCoordinator.balloonTrackPath {
                        MapPolyline(balloonTrackPath)
                            .stroke(.red, lineWidth: 2)
                    }
                    
                    // 2. Balloon Predicted Path: Thick blue line (controlled by visibility toggle)
                    if serviceCoordinator.isPredictionPathVisible,
                       let predictionPath = serviceCoordinator.predictionPath {
                        MapPolyline(predictionPath)
                            .stroke(.blue, lineWidth: 4)
                    }
                    
                    // 3. Planned Route: Green path from user to landing point
                    if let userRoute = serviceCoordinator.userRoute {
                        MapPolyline(userRoute)
                            .stroke(.green, lineWidth: 3)
                    }
                    
                    // 4. User Position: Runner icon at user location
                    if let userLocation = serviceCoordinator.userLocation {
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
                    
                    // 5. Balloon Live Position: Green (ascending) or Red (descending) balloon
                    if let balloonTelemetry = serviceCoordinator.balloonTelemetry {
                        let balloonCoordinate = CLLocationCoordinate2D(
                            latitude: balloonTelemetry.latitude,
                            longitude: balloonTelemetry.longitude
                        )
                        let isAscending = balloonTelemetry.verticalSpeed >= 0
                        
                        Annotation("", coordinate: balloonCoordinate) {
                            Image(systemName: "balloon.fill")
                                .font(.system(size: 30))
                                .foregroundColor(isAscending ? .green : .red)
                            .onTapGesture {
                                // Manual prediction trigger
                                serviceCoordinator.triggerPrediction()
                            }
                        }
                    }
                    
                    // 6. Burst Point: Only visible when balloon is ascending
                    if let burstPoint = serviceCoordinator.burstPoint,
                       let balloonTelemetry = serviceCoordinator.balloonTelemetry,
                       balloonTelemetry.verticalSpeed >= 0 {
                        Annotation("Burst", coordinate: burstPoint) {
                            Image(systemName: "burst.fill")
                                .font(.title2)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    // 7. Landing Point: Always visible if available
                    if let landingPoint = serviceCoordinator.landingPoint {
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
                .mapControlVisibility(serviceCoordinator.isHeadingMode ? .hidden : .automatic)
                .frame(height: geometry.size.height * 0.7)
                .onMapCameraChange { context in
                    // Update saved zoom level when user changes map view
                    savedZoomLevel = context.region.span
                    logZoomChange("Map camera changed by user", span: context.region.span, center: context.region.center)
                }
                .onReceive(serviceCoordinator.$region) { region in
                    if let region = region, !serviceCoordinator.isHeadingMode {
                        logZoomChange("ServiceCoordinator region update (free mode)", span: region.span, center: region.center)
                        position = .region(region)
                    }
                }
                .onReceive(serviceCoordinator.$isHeadingMode) { isHeadingMode in
                    updateMapPositionForHeadingMode(isHeadingMode)
                }
                .onReceive(serviceCoordinator.$userLocation) { userLocation in
                    if serviceCoordinator.isHeadingMode {
                        updateMapPositionForHeadingMode(true)
                    }
                }
                .onReceive(serviceCoordinator.$showAllAnnotations) { shouldShowAll in
                    if shouldShowAll {
                        // Use saved zoom level instead of .automatic to preserve 25km startup zoom
                        if let userLocation = serviceCoordinator.userLocation {
                            let userCoordinate = CLLocationCoordinate2D(
                                latitude: userLocation.latitude,
                                longitude: userLocation.longitude
                            )
                            let region = MKCoordinateRegion(
                                center: userCoordinate,
                                span: savedZoomLevel
                            )
                            logZoomChange("Show all annotations with saved zoom", span: savedZoomLevel, center: userCoordinate)
                            position = .region(region)
                        } else {
                            appLog("🔍 ZOOM: Show all annotations - using .automatic (no user location)", category: .general, level: .info)
                            position = .automatic
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            serviceCoordinator.showAllAnnotations = false // Reset the trigger
                        }
                    }
                }
                .onReceive(serviceCoordinator.$transportMode) { _ in
                    // Transport mode changed - trigger route recalculation
                    Task {
                        await serviceCoordinator.updateRoute()
                    }
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
                .environmentObject(serviceCoordinator.bleCommunicationService)
                .environmentObject(serviceCoordinator.persistenceService)
                .environmentObject(userSettings)
        }
    }
    
    private func updateMapToShowAllAnnotations() {
        if serviceCoordinator.isHeadingMode {
            return
        }
        // Map will automatically adjust using .automatic position
    }
    
    private func updateMapPositionForHeadingMode(_ isHeadingMode: Bool) {
        self.isInHeadingMode = isHeadingMode
        
        if isHeadingMode {
            // Switching TO heading mode - set initial position with saved zoom, then enable heading
            guard let userLocation = serviceCoordinator.userLocation else {
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
            guard let userLocation = serviceCoordinator.userLocation else {
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
        balloonTrackService: mockAppServices.balloonTrackService
    )
    
    TrackingMapView()
        .environmentObject(mockAppServices)
        .environmentObject(mockAppServices.userSettings)
        .environmentObject(mockServiceCoordinator)
}