import SwiftUI
import MapKit
import Combine
import OSLog
import UIKit

struct TrackingMapView: View {
    @EnvironmentObject var appServices: AppServices
    @EnvironmentObject var userSettings: UserSettings
    // MapState eliminated - ServiceCoordinator now holds all state
    @EnvironmentObject var serviceCoordinator: ServiceCoordinator  // Transitional
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
                            get: { 
                                return serviceCoordinator.transportMode 
                            },
                            set: { (newMode: TransportationMode) in
                                serviceCoordinator.transportMode = newMode
                            }
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

                        // Show All or Point button mutually exclusively based on landing point availability
                        if serviceCoordinator.landingPoint != nil {
                            // Landing point available - show "All" button
                            Button("All") {
                                // If in heading mode, exit it first
                                if serviceCoordinator.isHeadingMode {
                                    serviceCoordinator.isHeadingMode = false
                                    // Delay the show all request to let heading mode exit first
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        serviceCoordinator.triggerShowAllAnnotations()
                                    }
                                } else {
                                    serviceCoordinator.triggerShowAllAnnotations()
                                    // Update map position after direct call
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        updateMapToShowAllAnnotations()
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            // No landing point available - show "Point" button
                            Button("Point") {
                                // For now, just log since landing point setting needs to be implemented
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

                            // Haptic feedback
                            let generator = UINotificationFeedbackGenerator()
                            let newMuteState = !(serviceCoordinator.balloonTelemetry?.buzmute ?? false)
                            generator.notificationOccurred(newMuteState ? .warning : .success)
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

                // Map view with RenderSet system
                Map(position: $position, interactionModes: serviceCoordinator.isHeadingMode ? [] : .all) {
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
                .mapControlVisibility(serviceCoordinator.isHeadingMode ? .hidden : .automatic)
                .frame(height: geometry.size.height * 0.7)
                .onReceive(serviceCoordinator.$region) { region in
                    if let region = region, !serviceCoordinator.isHeadingMode {
                        position = .region(region)
                    } else if serviceCoordinator.isHeadingMode {
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
                .onChange(of: serviceCoordinator.isHeadingMode) { _, isHeadingMode in
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
                    
                    // Phase 1 Test: Create MapFeatures and log them
                    let features = MapFeatureCoordinator.createFeatures(from: serviceCoordinator)
                    let _ = MapFeatureCoordinator.getAllAnnotations(from: features)  // annotations
                    let _ = MapFeatureCoordinator.getAllOverlays(from: features)  // overlays
                    
                    
                    // Phase 2 Test: Sync DomainModel with ServiceCoordinator and compare
                    domainModel.syncWithServiceCoordinator(serviceCoordinator)
                    domainModel.observeServiceCoordinator(serviceCoordinator) // Setup direct observation for ongoing changes
                    domainModel.compareWithServiceCoordinator(serviceCoordinator)
                    
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
                .environmentObject(serviceCoordinator.bleCommunicationService)
                .environmentObject(serviceCoordinator.persistenceService)
                .environmentObject(userSettings)
        }
    }
    
    private func updateMapToShowAllAnnotations() {
        // Don't change position if in heading mode
        if serviceCoordinator.isHeadingMode {
            return
        }
        
        // Keep map in .automatic mode for natural positioning
        // Note: Map will automatically adjust to show annotations using .automatic position
    }
    
    private func updateMapPositionForHeadingMode(_ isHeadingMode: Bool) {
        if isHeadingMode {
            guard let _ = serviceCoordinator.userLocation else {  // userLocationData
                return
            }
            
            // Use follow-with-heading mode - centers and rotates with user
            position = .userLocation(followsHeading: true, fallback: .automatic)
        } else {
            // Return to automatic mode
            position = .automatic
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



