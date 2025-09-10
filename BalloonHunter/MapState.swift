import Foundation
import MapKit
import Combine
import OSLog

@MainActor
final class MapState: ObservableObject {
    // Map visual elements
    @Published var annotations: [MapAnnotationItem] = []
    @Published var balloonTrackPath: MKPolyline? = nil
    @Published var predictionPath: MKPolyline? = nil
    @Published var userRoute: MKPolyline? = nil
    @Published var region: MKCoordinateRegion? = nil
    @Published var cameraUpdate: CameraUpdate? = nil
    
    // Data state
    @Published var balloonTelemetry: TelemetryData? = nil
    @Published var userLocation: LocationData? = nil
    @Published var landingPoint: CLLocationCoordinate2D? = nil
    
    // Additional data for DataPanelView
    @Published var predictionData: PredictionData? = nil
    @Published var routeData: RouteData? = nil
    @Published var balloonTrackHistory: [TelemetryData] = []
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var smoothedDescentRate: Double? = nil
    
    // UI state
    @Published var currentMode: AppMode = .explore
    @Published var transportMode: TransportationMode = .car
    @Published var isHeadingMode: Bool = false
    @Published var isPredictionPathVisible: Bool = true
    @Published var isRouteVisible: Bool = true
    @Published var isBuzzerMuted: Bool = false
    @Published var showAllAnnotations: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private var currentVersion: [String: Int] = [:]
    private let maxVersionHistory = 10
    private var lastUpdateTime: [String: Date] = [:]
    
    init() {
        setupEventSubscriptions()
    }
    
    private func setupEventSubscriptions() {
        // Subscribe to map state updates from policies
        EventBus.shared.mapStateUpdatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                self?.applyUpdate(update)
            }
            .store(in: &cancellables)
        
        // Subscribe to telemetry events to update data state
        EventBus.shared.telemetryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.balloonTelemetry = event.telemetryData
            }
            .store(in: &cancellables)
        
        // Subscribe to user location events to update data state
        EventBus.shared.userLocationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.userLocation = event.locationData
            }
            .store(in: &cancellables)
        
        // Subscribe to UI events to update UI state
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUIEvent(event)
            }
            .store(in: &cancellables)
        
        // Subscribe to service health events to track connection status
        EventBus.shared.serviceHealthPublisher
            .receive(on: DispatchQueue.main)
            .sink { event in
                // ServiceHealthEvent doesn't contain connection status data
                // Connection status updates will come through other event channels
                appLog("MapState: Received service health event from \(event.serviceName): \(event.health)", 
                       category: .general, level: .debug)
            }
            .store(in: &cancellables)
    }
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .transportModeChanged(let mode, _):
            updateTransportMode(mode)
        case .predictionVisibilityToggled(let visible, _):
            updatePredictionVisibility(visible)
        case .routeVisibilityToggled(let visible, _):
            updateRouteVisibility(visible)
        case .headingModeToggled(let enabled, _):
            updateHeadingMode(enabled)
        case .buzzerMuteToggled(let muted, _):
            updateBuzzerMute(muted)
        case .showAllAnnotationsRequested(_):
            triggerShowAllAnnotations()
        case .modeSwitched(let mode, _):
            updateMode(mode)
        default:
            break
        }
    }
    
    func applyUpdate(_ update: MapStateUpdate) {
        let currentVer = currentVersion[update.source] ?? -1
        
        if update.version < currentVer {
            appLog("MapState: Ignoring stale update from \(update.source), version \(update.version) < \(currentVer)", 
                   category: .general, level: .debug)
            return
        }
        
        currentVersion[update.source] = update.version
        
        // Track update frequency
        let now = Date.now
        let timeSinceLastUpdate = lastUpdateTime[update.source].map { now.timeIntervalSince($0) } ?? 0
        lastUpdateTime[update.source] = now
        
        appLog("MapState: Applying update from \(update.source), version \(update.version), interval: \(String(format: "%.3f", timeSinceLastUpdate))s", 
               category: .general, level: .debug)
        
        var hasChanges = false
        
        if let newAnnotations = update.annotations {
            if !annotationsEqual(annotations, newAnnotations) {
                annotations = newAnnotations
                hasChanges = true
                appLog("MapState: Updated \(newAnnotations.count) annotations from \(update.source)", 
                       category: .general, level: .debug)
            }
        }
        
        if let newBalloonTrack = update.balloonTrack {
            if !polylinesEqual(balloonTrackPath, newBalloonTrack) {
                balloonTrackPath = newBalloonTrack
                hasChanges = true
                appLog("MapState: Updated balloon track from \(update.source)", 
                       category: .general, level: .debug)
            }
        } else if balloonTrackPath != nil && update.balloonTrack == nil {
            balloonTrackPath = nil
            hasChanges = true
        }
        
        if let newPredictionPath = update.predictionPath {
            if !polylinesEqual(predictionPath, newPredictionPath) {
                predictionPath = newPredictionPath
                hasChanges = true
                appLog("MapState: Updated prediction path from \(update.source)", 
                       category: .general, level: .debug)
            }
        } else if predictionPath != nil && update.predictionPath == nil {
            predictionPath = nil
            hasChanges = true
        }
        
        if let newUserRoute = update.userRoute {
            if !polylinesEqual(userRoute, newUserRoute) {
                userRoute = newUserRoute
                hasChanges = true
                appLog("MapState: Updated user route from \(update.source)", 
                       category: .general, level: .debug)
            }
        } else if userRoute != nil && update.userRoute == nil {
            userRoute = nil
            hasChanges = true
        }
        
        if let newRegion = update.region {
            if !regionsEqual(region, newRegion) {
                region = newRegion
                hasChanges = true
                appLog("MapState: Updated region from \(update.source)", 
                       category: .general, level: .debug)
            }
        }
        
        if let newCameraUpdate = update.cameraUpdate {
            cameraUpdate = newCameraUpdate
            hasChanges = true
            appLog("MapState: Updated camera from \(update.source)", 
                   category: .general, level: .debug)
        }
        
        if let newPredictionData = update.predictionData {
            predictionData = newPredictionData
            hasChanges = true
            appLog("MapState: Updated prediction data from \(update.source)", 
                   category: .general, level: .debug)
        }
        
        if let newRouteData = update.routeData {
            routeData = newRouteData
            hasChanges = true
            appLog("MapState: Updated route data from \(update.source)", 
                   category: .general, level: .debug)
        }
        
        if let newTrackHistory = update.balloonTrackHistory {
            balloonTrackHistory = newTrackHistory
            hasChanges = true
            appLog("MapState: Updated track history from \(update.source)", 
                   category: .general, level: .debug)
        }
        
        if let newDescentRate = update.smoothedDescentRate {
            smoothedDescentRate = newDescentRate
            hasChanges = true
            appLog("MapState: Updated smoothed descent rate from \(update.source)", 
                   category: .general, level: .debug)
        }
        
        if hasChanges {
            objectWillChange.send()
        }
    }
    
    func updateMode(_ mode: AppMode) {
        if currentMode != mode {
            currentMode = mode
            appLog("MapState: Mode changed to \(mode.displayName)", 
                   category: .general, level: .info)
        }
    }
    
    func updateTransportMode(_ mode: TransportationMode) {
        if transportMode != mode {
            transportMode = mode
            appLog("MapState: Transport mode changed to \(mode)", 
                   category: .general, level: .info)
        }
    }
    
    func updateHeadingMode(_ enabled: Bool) {
        if isHeadingMode != enabled {
            isHeadingMode = enabled
            appLog("MapState: Heading mode \(enabled ? "enabled" : "disabled")", 
                   category: .general, level: .info)
        }
    }
    
    func updatePredictionVisibility(_ visible: Bool) {
        if isPredictionPathVisible != visible {
            isPredictionPathVisible = visible
            appLog("MapState: Prediction visibility \(visible ? "enabled" : "disabled")", 
                   category: .general, level: .info)
        }
    }
    
    func updateRouteVisibility(_ visible: Bool) {
        if isRouteVisible != visible {
            isRouteVisible = visible
            appLog("MapState: Route visibility \(visible ? "enabled" : "disabled")", 
                   category: .general, level: .info)
        }
    }
    
    func updateBuzzerMute(_ muted: Bool) {
        if isBuzzerMuted != muted {
            isBuzzerMuted = muted
            appLog("MapState: Buzzer \(muted ? "muted" : "unmuted")", 
                   category: .general, level: .info)
        }
    }
    
    func triggerShowAllAnnotations() {
        showAllAnnotations = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.showAllAnnotations = false
        }
    }
    
    func clearCameraUpdate() {
        cameraUpdate = nil
    }
    
    func getStats() -> [String: Any] {
        return [
            "annotationCount": annotations.count,
            "hasBalloonTrack": balloonTrackPath != nil,
            "hasPredictionPath": predictionPath != nil,
            "hasUserRoute": userRoute != nil,
            "currentMode": currentMode.displayName,
            "transportMode": transportMode,
            "isHeadingMode": isHeadingMode,
            "versionCount": currentVersion.count
        ]
    }
}

private func annotationsEqual(_ lhs: [MapAnnotationItem], _ rhs: [MapAnnotationItem]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (a, b) in zip(lhs, rhs) {
        if a != b { return false }
    }
    return true
}

private func polylinesEqual(_ lhs: MKPolyline?, _ rhs: MKPolyline?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case (let lhsPolyline?, let rhsPolyline?):
        guard lhsPolyline.pointCount == rhsPolyline.pointCount else { return false }
        let lhsCoords = lhsPolyline.coordinates
        let rhsCoords = rhsPolyline.coordinates
        for (a, b) in zip(lhsCoords, rhsCoords) {
            if a.latitude != b.latitude || a.longitude != b.longitude { return false }
        }
        return true
    default:
        return false
    }
}

private func regionsEqual(_ lhs: MKCoordinateRegion?, _ rhs: MKCoordinateRegion) -> Bool {
    guard let lhs = lhs else { return false }
    return abs(lhs.center.latitude - rhs.center.latitude) < 0.0001 &&
           abs(lhs.center.longitude - rhs.center.longitude) < 0.0001 &&
           abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < 0.0001 &&
           abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < 0.0001
}
