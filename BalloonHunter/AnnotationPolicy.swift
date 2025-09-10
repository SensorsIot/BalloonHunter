import Foundation
import Combine
import CoreLocation
import MapKit
import OSLog

@MainActor
class AnnotationPolicy {
    private let balloonTrackService: BalloonTrackService
    private let landingPointService: LandingPointService
    private let policyScheduler: PolicyScheduler
    private var cancellables = Set<AnyCancellable>()
    
    private var currentTelemetry: TelemetryData? = nil
    private var currentUserLocation: LocationData? = nil
    private var currentPrediction: PredictionData? = nil
    private var lastAnnotationUpdateTime: Date = Date.distantPast
    private var annotationVersion: Int = 0
    private var appState: AppState = .startup
    private var lastEventTimes: [String: Date] = [:]

    init(balloonTrackService: BalloonTrackService, landingPointService: LandingPointService, policyScheduler: PolicyScheduler) {
        self.balloonTrackService = balloonTrackService
        self.landingPointService = landingPointService
        self.policyScheduler = policyScheduler
        setupSubscriptions()
        appLog("AnnotationPolicy: Initialized", category: .policy, level: .info)
    }
    
    private func setupSubscriptions() {
        // Subscribe to telemetry events
        EventBus.shared.telemetryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleTelemetryEvent(event)
            }
            .store(in: &cancellables)
        
        // Subscribe to user location events  
        EventBus.shared.userLocationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUserLocationEvent(event)
            }
            .store(in: &cancellables)

        // Subscribe to UI events
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUIEvent(event)
            }
            .store(in: &cancellables)
        
        // Subscribe to map state updates to get prediction data
        EventBus.shared.mapStateUpdatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                self?.handleMapStateUpdate(update)
            }
            .store(in: &cancellables)
        
        // Subscribe to balloon track service changes (proper service layer architecture)
        balloonTrackService.$currentBalloonTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let now = Date()
                let timeSinceLastTrack = self?.lastEventTimes["track"].map { now.timeIntervalSince($0) } ?? 0
                self?.lastEventTimes["track"] = now
                appLog("AnnotationPolicy: Balloon track updated, interval: \(String(format: "%.3f", timeSinceLastTrack))s", category: .policy, level: .debug)
                
                Task {
                    await self?.evaluateAnnotationUpdate(reason: "track_update")
                }
            }
            .store(in: &cancellables)
        
        // Subscribe to landing point changes
        landingPointService.$validLandingPoint
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let now = Date()
                let timeSinceLastLanding = self?.lastEventTimes["landing"].map { now.timeIntervalSince($0) } ?? 0
                self?.lastEventTimes["landing"] = now
                appLog("AnnotationPolicy: Landing point changed, interval: \(String(format: "%.3f", timeSinceLastLanding))s", category: .policy, level: .debug)
                
                Task {
                    await self?.evaluateAnnotationUpdate(reason: "landing_point_change")
                }
            }
            .store(in: &cancellables)
    }
    
    private func handleTelemetryEvent(_ event: TelemetryEvent) {
        // Store telemetry data for annotation creation, but don't trigger updates
        // Updates are triggered by BalloonTrackService changes (proper architecture)
        currentTelemetry = event.telemetryData
        appLog("AnnotationPolicy: Cached telemetry data for balloon \(event.balloonId)", category: .policy, level: .debug)
    }
    
    private func handleUserLocationEvent(_ event: UserLocationEvent) {
        let now = Date()
        let timeSinceLastLocation = lastEventTimes["location"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["location"] = now
        
        currentUserLocation = event.locationData
        appLog("AnnotationPolicy: Received user location update, interval: \(String(format: "%.3f", timeSinceLastLocation))s", category: .policy, level: .debug)
        
        Task {
            await evaluateAnnotationUpdate(reason: "location_update")
        }
    }
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .annotationSelected(let item, _):
            appLog("AnnotationPolicy: Annotation selected: \(item.kind)", category: .policy, level: .debug)
            // Could trigger special behaviors for selected annotations
        default:
            break
        }
    }
    
    private func handleMapStateUpdate(_ update: MapStateUpdate) {
        // Check if this update contains prediction data
        if update.source == "PredictionPolicy" && update.predictionPath != nil {
            // Extract prediction data if available (we'd need to enhance MapStateUpdate to include this)
            Task {
                await evaluateAnnotationUpdate(reason: "prediction_update")
            }
        }
    }
    
    private func evaluateAnnotationUpdate(reason: String, force: Bool = false) async {
        let timeSinceLastUpdate = Date().timeIntervalSince(lastAnnotationUpdateTime)
        let minUpdateInterval: TimeInterval = 1.0 // Minimum 1 second between annotation updates
        
        guard force || timeSinceLastUpdate >= minUpdateInterval else {
            appLog("AnnotationPolicy: Skipping annotation update - too frequent (\(String(format: "%.1f", timeSinceLastUpdate))s ago)", 
                   category: .policy, level: .debug)
            return
        }
        
        appLog("AnnotationPolicy: Evaluating annotation update - reason: \(reason)", 
               category: .policy, level: .debug)
        
        await executeAnnotationUpdate(reason: reason)
    }
    
    private func executeAnnotationUpdate(reason: String) async {
        annotationVersion += 1
        
        await policyScheduler.debounce(key: "annotation-update", delay: 0.5) {
            await self.performAnnotationUpdate(reason: reason)
        }
        
        lastAnnotationUpdateTime = Date()
        
        appLog("AnnotationPolicy: Executed annotation update (v\(annotationVersion)) - \(reason)", 
               category: .policy, level: .debug)
    }
    
    private func performAnnotationUpdate(reason: String) async {
        var annotations: [MapAnnotationItem] = []
        
        // Update app state based on available data
        updateAppState()
        
        // Always add user annotation if available
        if let userLocation = currentUserLocation {
            let userAnnotation = MapAnnotationItem(
                coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude), 
                kind: .user
            )
            annotations.append(userAnnotation)
        }
        
        // Add balloon annotations if telemetry is available (regardless of app state)
        if let telemetry = currentTelemetry {
            let balloonCoordinate = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
            
            // Balloon annotation
            let balloonAnnotation = MapAnnotationItem(coordinate: balloonCoordinate, kind: .balloon)
            balloonAnnotation.isAscending = telemetry.verticalSpeed >= 0
            balloonAnnotation.altitude = telemetry.altitude
            balloonAnnotation.lastUpdateTime = Date()
            annotations.append(balloonAnnotation)
            
            appLog("AnnotationPolicy: Added balloon annotation for \(telemetry.sondeName) at (\(telemetry.latitude), \(telemetry.longitude), \(telemetry.altitude)m)", 
                   category: .policy, level: .info)
            
            // Burst point annotation (if available and should be visible)
            if let prediction = currentPrediction,
               let burstPoint = prediction.burstPoint,
               shouldShowBurstMarker(for: telemetry) {
                let burstAnnotation = MapAnnotationItem(coordinate: burstPoint, kind: .burst)
                annotations.append(burstAnnotation)
            }
        }
        
        // Landing/Landed annotations
        if balloonTrackService.isLanded {
            // Balloon has landed - show landed annotation at actual position
            if let telemetry = currentTelemetry {
                let landedAnnotation = MapAnnotationItem(
                    coordinate: CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude),
                    kind: .landed
                )
                annotations.append(landedAnnotation)
            }
        } else if let landingPoint = landingPointService.validLandingPoint {
            // Show predicted landing point
            let landingAnnotation = MapAnnotationItem(coordinate: landingPoint, kind: .landing)
            annotations.append(landingAnnotation)
        }
        
        // Collect additional tracking data
        let trackHistory = balloonTrackService.last5Telemetry
        let smoothedDescentRate = balloonTrackService.smoothedDescentRate
        
        // Publish the annotation update with additional tracking data
        let mapStateUpdate = MapStateUpdate(
            source: "AnnotationPolicy",
            version: annotationVersion,
            annotations: annotations,
            balloonTrack: nil,
            predictionPath: nil,
            userRoute: nil,
            region: nil,
            cameraUpdate: nil,
            predictionData: nil,
            routeData: nil,
            balloonTrackHistory: trackHistory,
            smoothedDescentRate: smoothedDescentRate
        )
        
        EventBus.shared.publishMapStateUpdate(mapStateUpdate)
        appLog("AnnotationPolicy: Published annotation update (v\(annotationVersion)) with \(annotations.count) annotations - \(reason)", 
               category: .policy, level: .debug)
    }
    
    private func updateAppState() {
        let previousState = appState
        
        switch appState {
        case .startup:
            // Transition to tracking if we have telemetry, prediction with landing point, and route
            if let _ = currentTelemetry,
               let prediction = currentPrediction, prediction.landingPoint != nil {
                appState = .longRangeTracking
                appLog("AnnotationPolicy: App state transitioned from \(previousState) to \(appState)", 
                       category: .policy, level: .info)
                
                // Update shared state
                SharedAppState.shared.appState = appState
            }
        case .longRangeTracking:
            // Could add transitions to other states here
            break
        }
    }
    
    private func shouldShowBurstMarker(for telemetry: TelemetryData) -> Bool {
        // Show burst marker only when balloon is ascending (per requirements)
        return telemetry.verticalSpeed >= 0
    }
    
    func setAppState(_ newState: AppState) {
        let previousState = appState
        appState = newState
        SharedAppState.shared.appState = newState
        
        appLog("AnnotationPolicy: App state manually set from \(previousState) to \(newState)", 
               category: .policy, level: .info)
        
        // Trigger annotation update for state change
        Task {
            await evaluateAnnotationUpdate(reason: "app_state_change", force: true)
        }
    }
    
    func getAppState() -> AppState {
        return appState
    }
}
