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
    @State private var currentZoomLevel: Double = 15.0
    @State private var currentDistance: CLLocationDistance = 1000
    @State private var renderSets: [RenderSet] = []
    @State private var overlays: [RenderOverlay] = []
    @State private var annotations: [RenderAnnotation] = []

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
                            get: { 
                                return mapState.transportMode 
                            },
                            set: { (newMode: TransportationMode) in
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
                                // If in heading mode, exit it first
                                if mapState.isHeadingMode {
                                    print("📍 TrackingMapView: Exiting heading mode for 'All' view")
                                    EventBus.shared.publishUIEvent(.headingModeToggled(false, timestamp: Date()))
                                    // Delay the show all request to let heading mode exit first
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        EventBus.shared.publishUIEvent(.showAllAnnotationsRequested(timestamp: Date()))
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            updateMapToShowAllAnnotations()
                                        }
                                    }
                                } else {
                                    EventBus.shared.publishUIEvent(.showAllAnnotationsRequested(timestamp: Date()))
                                    // Update map position after event is processed
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        updateMapToShowAllAnnotations()
                                    }
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
                            let newHeadingMode = !mapState.isHeadingMode
                            print("🧭 TrackingMapView: Heading mode button pressed - changing from \(mapState.isHeadingMode) to \(newHeadingMode)")
                            print("🧭 TrackingMapView: User location available: \(mapState.userLocation != nil)")
                            if let userLoc = mapState.userLocation {
                                print("🧭 TrackingMapView: User heading: \(userLoc.heading)°")
                            }
                            EventBus.shared.publishUIEvent(.headingModeToggled(newHeadingMode, timestamp: Date()))
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

                // Map view with RenderSet system
                Map(position: $position, interactionModes: mapState.isHeadingMode ? [] : .all) {
                    // Phase 6: Render overlays and annotations from cached RenderSets
                    
                    // Render overlays in z-order
                    ForEach(overlays, id: \.id) { overlay in
                        MapPolyline(coordinates: overlay.polyline.coordinates)
                            .stroke(overlay.style.color, 
                                   style: StrokeStyle(
                                       lineWidth: overlay.style.lineWidth(for: currentZoomLevel),
                                       lineCap: .round,
                                       lineJoin: .round
                                   ))
                    }
                    
                    // Render annotations in z-order
                    ForEach(annotations, id: \.id) { annotation in
                        Annotation("", coordinate: annotation.coordinate) {
                            annotation.createAnnotationView()
                        }
                    }
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                    MapUserLocationButton()
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll, showsTraffic: false))
                .mapControlVisibility(mapState.isHeadingMode ? .hidden : .automatic)
                .frame(height: geometry.size.height * 0.7)
                .onReceive(mapState.$region) { region in
                    if let region = region, !mapState.isHeadingMode {
                        print("📍 TrackingMapView: Updating map position to region: \(region)")
                        position = .region(region)
                    } else if mapState.isHeadingMode {
                        print("📍 TrackingMapView: Ignoring region update - in heading mode")
                    }
                }
                .onReceive(mapState.$isHeadingMode) { isHeadingMode in
                    updateMapPositionForHeadingMode(isHeadingMode)
                }
                .onReceive(mapState.$userLocation) { userLocation in
                    if mapState.isHeadingMode {
                        updateMapPositionForHeadingMode(true)
                    }
                }
                .onChange(of: mapState.isHeadingMode) { _, isHeadingMode in
                    if isHeadingMode {
                        // Force immediate update when entering heading mode
                        updateMapPositionForHeadingMode(true)
                    }
                }
                .onMapCameraChange { context in
                    // Track current distance for heading mode
                    currentDistance = context.camera.distance
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
                    domainModel.observeMapState(mapState) // Setup direct observation for ongoing changes
                    print("📊 DomainModel Status: \(domainModel.statusSummary)")
                    domainModel.compareWithMapState(mapState)
                    
                    // Phase 5: Initialize RenderSets
                    updateRenderSets()
                }
                .onReceive(domainModel.objectWillChange) { _ in
                    // Update RenderSets when DomainModel changes
                    DispatchQueue.main.async {
                        updateRenderSets()
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
                .environmentObject(balloonTracker.bleCommunicationService)
                .environmentObject(balloonTracker.persistenceService)
                .environmentObject(userSettings)
        }
    }
    
    private func updateMapToShowAllAnnotations() {
        // Don't change position if in heading mode
        if mapState.isHeadingMode {
            print("📍 TrackingMapView: Ignoring 'All' request - in heading mode")
            return
        }
        
        // Keep map in .automatic mode for natural positioning
        print("📍 TrackingMapView: Keeping map in .automatic mode for natural positioning")
        // Note: Map will automatically adjust to show annotations using .automatic position
    }
    
    private func updateMapPositionForHeadingMode(_ isHeadingMode: Bool) {
        if isHeadingMode {
            guard let userLocationData = mapState.userLocation else {
                print("📍 TrackingMapView: No user location available for heading mode")
                return
            }
            
            // Use follow-with-heading mode - centers and rotates with user
            position = .userLocation(followsHeading: true, fallback: .automatic)
            print("📍 TrackingMapView: HEADING MODE ACTIVATED - following user location with heading at \(userLocationData.heading)°")
            print("📍 TrackingMapView: Position set to .userLocation(followsHeading: true)")
        } else {
            // Return to automatic mode
            position = .automatic
            print("📍 TrackingMapView: HEADING MODE DISABLED - returning to automatic")
        }
    }
    
    private func updateRenderSets() {
        renderSets = RenderSetCoordinator.createRenderSets(from: domainModel)
        overlays = RenderSetCoordinator.getAllOverlays(from: renderSets)
        annotations = RenderSetCoordinator.getAllAnnotations(from: renderSets)
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



