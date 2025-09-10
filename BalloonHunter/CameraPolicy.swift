import Foundation
import Combine
import CoreLocation
import MapKit
import OSLog

@MainActor
class CameraPolicy {
    private let policyScheduler: PolicyScheduler
    private let modeStateMachine: ModeStateMachine
    private let balloonPositionService: BalloonPositionService
    private var cancellables = Set<AnyCancellable>()
    
    private var lastUserLocationForCamera: CLLocationCoordinate2D? = nil
    private var lastCameraUpdateTime: Date = Date.distantPast
    private var cameraVersion: Int = 0
    private var currentTelemetry: TelemetryData? = nil
    private var currentUserLocation: LocationData? = nil
    private var isFollowModeEnabled: Bool = false
    private var isHeadingMode: Bool = false
    private var lastEventTimes: [String: Date] = [:]

    init(policyScheduler: PolicyScheduler, modeStateMachine: ModeStateMachine, balloonPositionService: BalloonPositionService) {
        self.policyScheduler = policyScheduler
        self.modeStateMachine = modeStateMachine
        self.balloonPositionService = balloonPositionService
        setupSubscriptions()
        appLog("CameraPolicy: Initialized with service layer architecture", category: .policy, level: .info)
    }

    private func setupSubscriptions() {
        // Subscribe to balloon position service (proper service layer architecture)
        EventBus.shared.balloonPositionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] positionEvent in
                self?.handlePositionUpdate(positionEvent)
            }
            .store(in: &cancellables)
        
        // Subscribe to user location events  
        EventBus.shared.userLocationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUserLocationEvent(event)
            }
            .store(in: &cancellables)

        // Subscribe to UI events for camera controls
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUIEvent(event)
            }
            .store(in: &cancellables)
    }
    
    private func handlePositionUpdate(_ positionEvent: BalloonPositionEvent) {
        let now = Date()
        let timeSinceLastTelemetry = lastEventTimes["telemetry"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["telemetry"] = now
        
        currentTelemetry = positionEvent.telemetry
        appLog("CameraPolicy: Received position update for balloon \(positionEvent.balloonId), interval: \(String(format: "%.3f", timeSinceLastTelemetry))s", category: .policy, level: .debug)
        
        Task {
            await evaluateCameraUpdate(reason: "position_update")
        }
    }
    
    private func handleUserLocationEvent(_ event: UserLocationEvent) {
        let now = Date()
        let timeSinceLastLocation = lastEventTimes["location"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["location"] = now
        
        currentUserLocation = event.locationData
        appLog("CameraPolicy: Received user location update, interval: \(String(format: "%.3f", timeSinceLastLocation))s", category: .policy, level: .debug)
        
        Task {
            await evaluateCameraUpdate(reason: "location_update")
        }
    }
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .cameraRegionChanged(_, _):
            // User manually moved camera - disable follow mode temporarily
            if isFollowModeEnabled {
                appLog("CameraPolicy: User moved camera, temporarily disabling follow mode", category: .policy, level: .debug)
                isFollowModeEnabled = false
                // Re-enable after a delay if still in follow mode
                Task {
                    try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                    if modeStateMachine.getModeConfig(for: modeStateMachine.currentMode).cameraFollowEnabled {
                        isFollowModeEnabled = true
                        appLog("CameraPolicy: Re-enabled follow mode", category: .policy, level: .debug)
                    }
                }
            }
        case .headingModeToggled(let enabled, _):
            isHeadingMode = enabled
            appLog("CameraPolicy: Heading mode \(enabled ? "enabled" : "disabled")", category: .policy, level: .info)
            Task {
                await evaluateCameraUpdate(reason: "heading_mode_toggle", force: true)
            }
        case .modeSwitched(let (mode, _)):
            let modeConfig = modeStateMachine.getModeConfig(for: mode)
            isFollowModeEnabled = modeConfig.cameraFollowEnabled
            appLog("CameraPolicy: Mode switched to \(mode.displayName), follow mode: \(isFollowModeEnabled)", category: .policy, level: .info)
        case .showAllAnnotationsRequested(_):
            Task {
                await showAllAnnotations()
            }
        default:
            break
        }
    }
    
    private func evaluateCameraUpdate(reason: String, force: Bool = false) async {
        let timeSinceLastUpdate = Date().timeIntervalSince(lastCameraUpdateTime)
        let minUpdateInterval: TimeInterval = 1.0 // Minimum 1 second between camera updates
        
        guard force || timeSinceLastUpdate >= minUpdateInterval else {
            appLog("CameraPolicy: Skipping camera update - too frequent (\(String(format: "%.1f", timeSinceLastUpdate))s ago)", 
                   category: .policy, level: .debug)
            return
        }
        
        // Only update camera if follow mode is enabled
        guard isFollowModeEnabled else {
            appLog("CameraPolicy: Follow mode disabled, skipping camera update", category: .policy, level: .debug)
            return
        }
        
        guard let userLocation = currentUserLocation else {
            appLog("CameraPolicy: No user location available for camera update", category: .policy, level: .debug)
            return
        }
        
        let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
        
        // Check if user moved significantly
        var shouldUpdate = force
        if let lastLocation = lastUserLocationForCamera {
            let distance = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                .distance(from: CLLocation(latitude: lastLocation.latitude, longitude: lastLocation.longitude))
            shouldUpdate = shouldUpdate || distance > getCameraMovementThreshold()
        } else {
            shouldUpdate = true // First location
        }
        
        if shouldUpdate {
            appLog("CameraPolicy: Updating camera - reason: \(reason), force: \(force)", 
                   category: .policy, level: .debug)
            await executeCameraUpdate(userLocation: userCoord, reason: reason)
        } else {
            appLog("CameraPolicy: User hasn't moved enough for camera update", 
                   category: .policy, level: .debug)
        }
    }
    
    private func getCameraMovementThreshold() -> Double {
        switch modeStateMachine.currentMode {
        case .explore: return 100.0 // 100m
        case .follow: return 50.0   // 50m
        case .finalApproach: return 20.0 // 20m
        }
    }
    
    private func executeCameraUpdate(userLocation: CLLocationCoordinate2D, reason: String) async {
        cameraVersion += 1
        
        _ = await policyScheduler.debounce(key: "camera-update", delay: 0.25) {
            await self.performCameraUpdate(userLocation: userLocation, reason: reason)
        }
        
        lastUserLocationForCamera = userLocation
        lastCameraUpdateTime = Date()
        
        appLog("CameraPolicy: Executed camera update (v\(cameraVersion)) - \(reason)", 
               category: .policy, level: .debug)
    }
    
    private func performCameraUpdate(userLocation: CLLocationCoordinate2D, reason: String) async {
        // Determine appropriate zoom level based on mode
        let span = getCameraSpan()
        
        // Create camera update
        let cameraUpdate = CameraUpdate(
            center: userLocation,
            heading: isHeadingMode ? currentUserLocation?.heading : nil,
            distance: nil, // Let MapKit calculate based on span
            pitch: isHeadingMode ? 45.0 : 0.0,
            animated: true
        )
        
        // Create region update
        let region = MKCoordinateRegion(center: userLocation, span: span)
        
        let mapStateUpdate = MapStateUpdate(
            source: "CameraPolicy",
            version: cameraVersion,
            region: region,
            cameraUpdate: cameraUpdate
        )
        
        let now = Date()
        let timeSinceLastPublish = lastEventTimes["publish"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["publish"] = now
        
        EventBus.shared.publishMapStateUpdate(mapStateUpdate)
        appLog("CameraPolicy: Published camera update (v\(cameraVersion)) - \(reason), interval: \(String(format: "%.3f", timeSinceLastPublish))s", 
               category: .policy, level: .debug)
    }
    
    private func getCameraSpan() -> MKCoordinateSpan {
        switch modeStateMachine.currentMode {
        case .explore: return MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)   // Wide view
        case .follow: return MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05) // Medium view
        case .finalApproach: return MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01) // Close view
        }
    }
    
    private func showAllAnnotations() async {
        guard let userLocation = currentUserLocation,
              let balloonPosition = balloonPositionService.getBalloonLocation() else {
            appLog("CameraPolicy: Cannot show all annotations - missing data", category: .policy, level: .debug)
            return
        }
        
        cameraVersion += 1
        
        let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let balloonCoord = balloonPosition
        
        // Calculate region that encompasses both user and balloon
        let minLat = min(userCoord.latitude, balloonCoord.latitude)
        let maxLat = max(userCoord.latitude, balloonCoord.latitude)
        let minLon = min(userCoord.longitude, balloonCoord.longitude)
        let maxLon = max(userCoord.longitude, balloonCoord.longitude)
        
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let spanLat = (maxLat - minLat) * 1.2 // Add 20% padding
        let spanLon = (maxLon - minLon) * 1.2
        
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: max(spanLat, 0.01), longitudeDelta: max(spanLon, 0.01))
        )
        
        let cameraUpdate = CameraUpdate(
            center: region.center,
            heading: nil,
            distance: nil,
            pitch: 0.0,
            animated: true
        )
        
        let mapStateUpdate = MapStateUpdate(
            source: "CameraPolicy",
            version: cameraVersion,
            region: region,
            cameraUpdate: cameraUpdate
        )
        
        EventBus.shared.publishMapStateUpdate(mapStateUpdate)
        appLog("CameraPolicy: Published show-all-annotations camera update (v\(cameraVersion))", 
               category: .policy, level: .info)
    }
}
