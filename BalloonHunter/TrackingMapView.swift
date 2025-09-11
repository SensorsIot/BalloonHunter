import SwiftUI
import MapKit
import Combine
import OSLog
import UIKit

struct TrackingMapView: View {
    @EnvironmentObject var userSettings: UserSettings
    @EnvironmentObject var mapState: MapState
    @EnvironmentObject var serviceManager: ServiceManager

    @State private var showSettings = false
    @State private var transportMode: TransportationMode = .car
    @State private var position: MapCameraPosition = .automatic
    @State private var hasInitializedFromLocation = false
    @State private var isHeadingMode: Bool = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Top control panel
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Settings button
                        Button {
                            // Send device settings request before showing settings
                            serviceManager.bleCommunicationService.getParameters()
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .imageScale(.large)
                                .padding(8)
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)

                        // Transport mode picker
                        Picker("Mode", selection: $transportMode) {
                            Image(systemName: "car.fill").tag(TransportationMode.car)
                            Image(systemName: "bicycle").tag(TransportationMode.bike)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                        .onChange(of: transportMode) { _, newMode in
                            EventBus.shared.publishUIEvent(.transportModeChanged(newMode, timestamp: Date()))
                        }

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
                            isHeadingMode.toggle()
                            EventBus.shared.publishUIEvent(.headingModeToggled(isHeadingMode, timestamp: Date()))
                        } label: {
                            Text(isHeadingMode ? "Heading" : "Free")
                                .font(.system(size: 14, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
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
                        Annotation("You", coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)) {
                            Image(systemName: "figure.walk")
                                .foregroundColor(.blue)
                                .font(.system(size: 24))
                        }
                    }
                    
                    // Map annotations from MapState
                    ForEach(mapState.annotations, id: \.id) { item in
                        Annotation(item.kind.displayName, coordinate: item.coordinate) {
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
                .onChange(of: mapState.userLocation) { _, newLocation in
                    guard let location = newLocation, !hasInitializedFromLocation else { return }
                    let region = MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25) // ~25km span
                    )
                    position = .region(region)
                    hasInitializedFromLocation = true
                    print("📍 TrackingMapView: Initialized region from user location: \(location.latitude), \(location.longitude)")
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
                .environmentObject(serviceManager.bleCommunicationService)
                .environmentObject(serviceManager.persistenceService)
                .environmentObject(userSettings)
        }
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


