/*
# AI Assistant Guidelines

Your role: act as a competent Swift programmer to complete this project according to the Functional Specification Document (FSD).

## 1. Follow the FSD
- Follow the FSD: Treat the FSD as the source of truth. Identify missing features or mismatches in the code and implement fixes directly.
- Implement unambiguous tasks immediately (new methods, data model updates, UI changes).
- Check for Next Task: After each task is completed, review the FSD to identify the next highest-priority task or feature to implement.
- Do not create new files without first asking and justifying why.

## 2. Coding Standards
- Use modern Swift idioms: async/await, SwiftData, SwiftUI property wrappers.
- Prefer Apple-native tools; ask before adding third-party dependencies. As a general rule, we prefer native solutions.
- Write maintainable code: separate views, models, and services clearly and place them in the appropriate files.
- Comments: keep minimal, but explain non-obvious logic or trade-offs, or to flag a `TODO` or `FIXME`.

## 3. Decision Making
- For low-level details: decide and implement directly.
- For high-impact design or ambiguous FSD items: Stop and ask, briefly presenting options and trade-offs. When you do, use this format:   `QUESTION: [Brief, clear question] OPTIONS: 1. [Option A and its trade-offs] 2. [Option B and its trade-offs]`
 This applies only to ambiguous FSD items or architectural forks (e.g., choosing between two different data persistence strategies).


## 4. Quality
- Include basic error handling where appropriate.
- Debugging: Add temporary debugging `print()` statements to verify the execution of new features; remove them once confirmed.
- Completion: Once all items in the FSD have been implemented, state "FSD complete. Awaiting further instructions or new requirements."
*/


import SwiftUI
import MapKit
import Combine

struct MapView: View {
    @EnvironmentObject var annotationService: AnnotationService
    @EnvironmentObject var routeService: RouteCalculationService
    @EnvironmentObject var locationService: CurrentLocationService
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var predictionService: PredictionService
    let persistenceService: PersistenceService
    @EnvironmentObject var userSettings: UserSettings

    // Removed @State var balloonDescends: Bool = false

    @State private var cameraPosition = MapCameraPosition.region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.3769, longitude: 8.5417),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    )
    @State private var transportMode: TransportationMode = .car
    @State private var predictionTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @State private var isFinalApproach = false
    @State private var showSettings = false
    @State private var showPredictionError = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    if isFinalApproach {
                        Map(position: $cameraPosition) {
                            ForEach(annotationService.annotations.filter { $0.kind == .landed || $0.kind == .user }) { annotation in
                                Annotation(String(describing: annotation.kind), coordinate: annotation.coordinate) {
                                    annotation.view
                                }
                            }
                        }
                        .mapControls {
                            MapCompass()
                            MapPitchToggle()
                            MapUserLocationButton()
                        }
                        .ignoresSafeArea(.container, edges: .top)
                        .onAppear {
                            // Zoom to show all relevant annotations
                            var allCoordinates: [CLLocationCoordinate2D] = []
                            if let userCoord = locationService.locationData {
                                allCoordinates.append(CLLocationCoordinate2D(latitude: userCoord.latitude, longitude: userCoord.longitude))
                            }
                            if let balloonCoord = bleService.latestTelemetry {
                                allCoordinates.append(CLLocationCoordinate2D(latitude: balloonCoord.latitude, longitude: balloonCoord.longitude))
                            }
                            if let landingCoord = predictionService.predictionData?.landingPoint {
                                allCoordinates.append(landingCoord)
                            }
                            if let burstCoord = predictionService.predictionData?.burstPoint {
                                allCoordinates.append(burstCoord)
                            }

                            if !allCoordinates.isEmpty {
                                let minLat = allCoordinates.map { $0.latitude }.min() ?? 0
                                let maxLat = allCoordinates.map { $0.latitude }.max() ?? 0
                                let minLon = allCoordinates.map { $0.longitude }.min() ?? 0
                                let maxLon = allCoordinates.map { $0.longitude }.max() ?? 0

                                let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
                                let span = MKCoordinateSpan(latitudeDelta: (maxLat - minLat) * 1.5, longitudeDelta: (maxLon - minLon) * 1.5)
                                cameraPosition = .region(MKCoordinateRegion(center: center, span: span))
                            }
                        }
                    } else {
                        ZStack(alignment: .top) {
                            if case .error(let message) = predictionService.predictionStatus, showPredictionError {
                                Color(.systemBackground)
                                    .ignoresSafeArea()
                                VStack {
                                    Text("Prediction Error: \(message)")
                                        .foregroundColor(.white)
                                        .padding(8)
                                        .background(Color.red.opacity(0.8))
                                        .cornerRadius(8)
                                        .padding(.top, 50)
                                        .onTapGesture {
                                            showPredictionError = false
                                        }
                                }
                            } else {
                                Map(position: $cameraPosition) {
                                    ForEach(annotationService.annotations) { annotation in
                                        Annotation(String(describing: annotation.kind), coordinate: annotation.coordinate) {
                                            annotation.view
                                        }
                                    }
                                }
                                .mapControls {
                                    MapCompass()
                                    MapPitchToggle()
                                    MapUserLocationButton()
                                }
                                .ignoresSafeArea(.container, edges: .top)
                            }
                        }
                    }
                }
                DataPanelView()
                    .frame(maxHeight: geometry.size.height * 0.3)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemBackground).opacity(0.95))
            }
            .onChange(of: predictionService.predictionStatus) { _, status in
                if case .error = status {
                    showPredictionError = true
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(persistenceService: persistenceService)
        }
        .onReceive(locationService.$locationData) { locationData in
            // Updates are now only triggered by valid BLE packets.
            recalculateRoute()
        }
        .onReceive(bleService.telemetryData) { telemetry in
            // Assuming telemetry.latitude and telemetry.longitude are non-optional Double
            updateAnnotations()
            predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
        }
        .onReceive(predictionService.$predictionData) { predictionData in
            // Updates are now only triggered by valid BLE packets.
            recalculateRoute()
        }
        .onReceive(predictionTimer) { _ in
            if let telemetry = bleService.latestTelemetry {
                print("[Debug][MapView] Periodic prediction trigger.")
                predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings)
            }
        }
        .onReceive(annotationService.isFinalApproach) { isFinalApproach in
            self.isFinalApproach = isFinalApproach
            if isFinalApproach {
                print("[Debug][MapView] Entering final approach state")
            }
        }
        // Removed .onChange(of: bleService.balloonDescends) { value in ... }
    }

    private func updateAnnotations() {
        if let telemetry = bleService.latestTelemetry {
            print("[Debug][MapView] Updating annotations with telemetry: lat=\(telemetry.latitude), lon=\(telemetry.longitude), sondeName=\(telemetry.sondeName)")
        } else {
            print("[Debug][MapView] Updating annotations with no telemetry")
        }
        annotationService.updateAnnotations(telemetry: bleService.latestTelemetry, userLocation: locationService.locationData, prediction: predictionService.predictionData)
        print("[Debug][MapView] Current annotations: \(annotationService.annotations.count)")
        for annotation in annotationService.annotations {
            print("[Debug][MapView] Annotation: kind=\(annotation.kind), coordinate=\(annotation.coordinate)")
        }
    }

    private func recalculateRoute() {
        guard let userLocation = locationService.locationData,
              let prediction = predictionService.predictionData,
              let landingPoint = prediction.landingPoint else { return }

        routeService.calculateRoute(
            from: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
            to: landingPoint,
            transportType: transportMode
        )
    }
}

#Preview {
    MapView(persistenceService: PersistenceService())
        .environmentObject(AnnotationService())
        .environmentObject(RouteCalculationService())
        .environmentObject(CurrentLocationService())
        .environmentObject(BLECommunicationService())
        .environmentObject(PredictionService())
        .environmentObject(UserSettings())
}
