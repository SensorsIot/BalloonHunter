import SwiftUI
import MapKit
import Combine
import OSLog
import UIKit

struct TrackingMapView: View {
    @EnvironmentObject var userSettings: UserSettings
    @EnvironmentObject var mapState: MapState
    @EnvironmentObject var balloonTracker: BalloonTracker
    @EnvironmentObject var domainModel: DomainModel

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
                            // Send device settings request before showing settings
                            balloonTracker.bleCommunicationService.getParameters()
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
                            get: { mapState.transportMode },
                            set: { newMode in
                                EventBus.shared.publishUIEvent(.transportModeChanged(newMode, timestamp: Date()))
                            }
                        )) {
                            Image(systemName: "car.fill").tag(TransportationMode.car)
                            Image(systemName: "bicycle").tag(TransportationMode.bike)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)

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
                                // Update map position after event is processed
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    updateMapToShowAllAnnotations()
                                }
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
                            EventBus.shared.publishUIEvent(.headingModeToggled(!mapState.isHeadingMode, timestamp: Date()))
                        } label: {
                            Image(systemName: mapState.isHeadingMode ? "location.north.circle.fill" : "location.circle")
                                .imageScale(.large)
                                .padding(8)
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
                Map(position: $position) {
                    // User annotation
                    if let userLocation = mapState.userLocation {
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)) {
                            Image(systemName: "figure.walk")
                                .foregroundColor(.blue)
                                .font(.system(size: 24))
                        }
                    }
                    
                    // Map annotations from MapState
                    ForEach(mapState.annotations, id: \.id) { item in
                        Annotation("", coordinate: item.coordinate) {
                            item.view
                        }
                    }
                    
                    // Balloon track overlay
                    if let trackPath = mapState.balloonTrackPath {
                        MapPolyline(coordinates: trackPath.coordinates)
                            .stroke(.red, lineWidth: 2)
                    }
                    
                    // Prediction path overlay
                    if mapState.isPredictionPathVisible, let predictionPath = mapState.predictionPath {
                        MapPolyline(coordinates: predictionPath.coordinates)
                            .stroke(.blue, lineWidth: 4)
                    }
                    
                    // Route overlay
                    if mapState.isRouteVisible, let userRoute = mapState.userRoute {
                        MapPolyline(coordinates: userRoute.coordinates)
                            .stroke(.green, lineWidth: 3)
                    }
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                    MapUserLocationButton()
                }
                .frame(height: geometry.size.height * 0.7)
                .onReceive(mapState.$region) { region in
                    if let region = region {
                        print("📍 TrackingMapView: Updating map position to region: \(region)")
                        position = .region(region)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .startupCompleted)) { _ in
                    // Leave map in .automatic mode for natural positioning
                    print("📍 TrackingMapView: Startup completed - keeping map in .automatic mode")
                    
                    // Phase 1 Test: Create MapFeatures and log them
                    let features = MapFeatureCoordinator.createFeatures(from: mapState)
                    let annotations = MapFeatureCoordinator.getAllAnnotations(from: features)
                    let overlays = MapFeatureCoordinator.getAllOverlays(from: features)
                    
                    print("🎯 MapFeatures Test - Features: \(features.count), Annotations: \(annotations.count), Overlays: \(overlays.count)")
                    
                    for feature in features where feature.isVisible {
                        print("  ✅ \(feature.id): \(feature.annotations.count) annotations, \(feature.overlays.count) overlays")
                    }
                    
                    // Phase 2 Test: Sync DomainModel with MapState and compare
                    domainModel.syncWithMapState(mapState)
                    print("📊 DomainModel Status: \(domainModel.statusSummary)")
                    domainModel.compareWithMapState(mapState)
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
                .environmentObject(balloonTracker.bleCommunicationService)
                .environmentObject(balloonTracker.persistenceService)
                .environmentObject(userSettings)
        }
    }
    
    private func updateMapToShowAllAnnotations() {
        // Keep map in .automatic mode for natural positioning
        print("📍 TrackingMapView: Keeping map in .automatic mode for natural positioning")
        // Note: Map will automatically adjust to show annotations using .automatic position
    }
}

// MARK: - Map Extensions

extension MapAnnotationItem.AnnotationKind {
    var displayName: String {
        switch self {
        case .user: return "You"
        case .balloon: return "Balloon"
        case .burst: return "Burst"
        case .landing: return "Landing"
        case .landed: return "Landed"
        }
    }
}



