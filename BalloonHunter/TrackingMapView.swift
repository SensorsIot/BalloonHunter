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

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Top control panel
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Settings button
                        Button {
                            serviceCoordinator.bleCommunicationService.getParameters()
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
                            serviceCoordinator.isBuzzerMuted.toggle()
                            serviceCoordinator.bleCommunicationService.setMute(serviceCoordinator.isBuzzerMuted)
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
                        MapPolyline(coordinates: balloonTrackPath.coordinates)
                            .stroke(.red, lineWidth: 2)
                    }
                    
                    // 2. Balloon Predicted Path: Thick blue line (controlled by visibility toggle)
                    if serviceCoordinator.isPredictionPathVisible,
                       let predictionPath = serviceCoordinator.predictionPath {
                        MapPolyline(coordinates: predictionPath.coordinates)
                            .stroke(.blue, lineWidth: 4)
                    }
                    
                    // 3. Planned Route: Green path from user to landing point
                    if let userRoute = serviceCoordinator.userRoute {
                        MapPolyline(coordinates: userRoute.coordinates)
                            .stroke(.green, lineWidth: 3)
                    }
                    
                    // 4. User Position: Runner icon at user location
                    if let userLocation = serviceCoordinator.userLocation {
                        let userCoordinate = CLLocationCoordinate2D(
                            latitude: userLocation.latitude,
                            longitude: userLocation.longitude
                        )
                        Annotation("You", coordinate: userCoordinate) {
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
                        
                        Annotation("Balloon", coordinate: balloonCoordinate) {
                            VStack {
                                Image(systemName: "balloon.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(isAscending ? .green : .red)
                                Text("\(Int(balloonTelemetry.altitude))m")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                                    .background(Capsule().fill(.black.opacity(0.7)))
                                    .padding(.horizontal, 4)
                            }
                        }
                        .onTapGesture {
                            // Manual prediction trigger
                            Task {
                                await serviceCoordinator.balloonTrackPredictionService.triggerManualPrediction()
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
                        Annotation("Landing", coordinate: landingPoint) {
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
                .onReceive(serviceCoordinator.$region) { region in
                    if let region = region, !serviceCoordinator.isHeadingMode {
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
        if isHeadingMode {
            guard let _ = serviceCoordinator.userLocation else {
                return
            }
            position = .userLocation(followsHeading: true, fallback: .automatic)
        } else {
            position = .automatic
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