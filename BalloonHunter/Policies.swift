// Policies.swift - DISABLED (DEAD CODE)
// Consolidated policy layer for BalloonHunter  
// Contains all policy implementations and PolicyScheduler in one organized file
//
// NOTE: This entire file is commented out as it's replaced by SimpleBalloonTracker

/*
import Foundation
import Combine
import SwiftUI
import CoreLocation
import MapKit
import OSLog

// MARK: - Policy Scheduler

protocol Cancellable {
    func cancel()
}

extension Task: Cancellable {}

@MainActor
final class PolicyScheduler: ObservableObject {
    private var schedulers: [String: SchedulerState] = [:]
    
    private struct SchedulerState {
        var lastExecution: Date?
        var pendingTask: Cancellable?
        var backoffCount: Int = 0
        var isThrottling: Bool = false
    }
    
    // Execute with debouncing - delays execution until no new calls for the specified interval
    func debounce<T>(
        key: String,
        interval: TimeInterval,
        operation: @escaping () async throws -> T
    ) async -> T? {
        // Cancel any pending task for this key
        schedulers[key]?.pendingTask?.cancel()
        
        // Create a new task that waits for the debounce interval
        let task = Task<T?, Error> {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            
            // Check if we were cancelled
            guard !Task.isCancelled else { return nil }
            
            // Execute the operation
            do {
                let result = try await operation()
                schedulers[key]?.lastExecution = Date()
                schedulers[key]?.backoffCount = 0 // Reset backoff on success
                return result
            } catch {
                // Handle backoff on failure
                schedulers[key]?.backoffCount += 1
                appLog("PolicyScheduler: Operation failed for \(key), backoff count: \(schedulers[key]?.backoffCount ?? 0)", category: .policy, level: .error)
                throw error
            }
        }
        
        // Store the task
        if schedulers[key] == nil {
            schedulers[key] = SchedulerState()
        }
        schedulers[key]?.pendingTask = task
        
        return try? await task.value
    }
    
    // Execute with throttling - limits execution frequency to specified interval
    func throttle<T>(
        key: String,
        interval: TimeInterval,
        leading: Bool = true,
        operation: @escaping () async throws -> T
    ) async throws -> T? {
        let now = Date()
        let state = schedulers[key] ?? SchedulerState()
        
        // Check if we should throttle
        if let lastExecution = state.lastExecution {
            let timeSinceLastExecution = now.timeIntervalSince(lastExecution)
            if timeSinceLastExecution < interval {
                if !leading {
                    return nil // Throttled, don't execute
                }
            }
        }
        
        // Update state
        schedulers[key] = SchedulerState(
            lastExecution: now,
            pendingTask: nil,
            backoffCount: state.backoffCount,
            isThrottling: false
        )
        
        // Execute the operation
        do {
            let result = try await operation()
            schedulers[key]?.backoffCount = 0 // Reset backoff on success
            appLog("PolicyScheduler: Successfully executed \(key), reset backoff", category: .policy, level: .debug)
            return result
        } catch {
            schedulers[key]?.backoffCount += 1
            let backoffDelay = min(pow(2.0, Double(schedulers[key]?.backoffCount ?? 1)), 300) // Max 5 minutes
            appLog("PolicyScheduler: Operation failed for \(key), next retry in \(backoffDelay)s", category: .policy, level: .error)
            throw error
        }
    }
    
    // Execute with exponential backoff on failure
    func withBackoff<T>(
        key: String,
        maxRetries: Int = 5,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let state = schedulers[key] ?? SchedulerState()
        
        guard state.backoffCount < maxRetries else {
            throw PolicyError.maxRetriesExceeded
        }
        
        // Calculate backoff delay
        let backoffDelay = min(pow(2.0, Double(state.backoffCount)), 300) // Max 5 minutes
        if state.backoffCount > 0 {
            try await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
        }
        
        do {
            let result = try await operation()
            schedulers[key]?.backoffCount = 0
            schedulers[key]?.lastExecution = Date()
            return result
        } catch {
            schedulers[key] = SchedulerState(
                lastExecution: Date(),
                pendingTask: nil,
                backoffCount: state.backoffCount + 1,
                isThrottling: false
            )
            throw error
        }
    }
    
    // Get time since last execution for a key
    func timeSinceLastExecution(for key: String) -> TimeInterval? {
        guard let lastExecution = schedulers[key]?.lastExecution else { return nil }
        return Date().timeIntervalSince(lastExecution)
    }
    
    // Cancel all pending operations
    func cancelAll() {
        for (_, state) in schedulers {
            state.pendingTask?.cancel()
        }
        schedulers.removeAll()
    }
}

// MARK: - Prediction Policy

@MainActor
final class PredictionPolicy: ObservableObject {
    private let predictionService: PredictionService
    private let policyScheduler: PolicyScheduler
    private let predictionCache: PredictionCache
    private let modeStateMachine: ModeStateMachine
    private let balloonPositionService: BalloonPositionService
    
    private var cancellables = Set<AnyCancellable>()
    private var predictionVersion = 0
    private var currentUserLocation: LocationData? = nil
    private var lastEventTimes: [String: Date] = [:]
    
    // Tracking prediction triggers
    private var lastPredictionLocation: CLLocationCoordinate2D? = nil
    private var lastPredictionTime: Date? = nil
    
    init(predictionService: PredictionService, policyScheduler: PolicyScheduler, predictionCache: PredictionCache, modeStateMachine: ModeStateMachine, balloonPositionService: BalloonPositionService) {
        self.predictionService = predictionService
        self.policyScheduler = policyScheduler
        self.predictionCache = predictionCache
        self.modeStateMachine = modeStateMachine
        self.balloonPositionService = balloonPositionService
        
        setupSubscriptions()
        appLog("PredictionPolicy: Initialized with 60-second timer triggers", category: .policy, level: .info)
    }
    
    private func setupSubscriptions() {
        // Set up 60-second timer for automatic prediction triggers per specification
        Timer.publish(every: 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.handleTimerTrigger()
                }
            }
            .store(in: &cancellables)
        
        // Subscribe to first telemetry availability event for startup trigger
        EventBus.shared.telemetryAvailabilityPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleTelemetryAvailability(event)
            }
            .store(in: &cancellables)
        
        // Subscribe to UI events (balloon marker tap)
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUIEvent(event)
            }
            .store(in: &cancellables)
    }
    
    private func handleTelemetryAvailability(_ event: TelemetryAvailabilityEvent) {
        // Only trigger prediction on first valid telemetry (startup)
        guard event.isAvailable else { return }
        
        // Check if this is our first telemetry trigger
        guard lastPredictionTime == nil else {
            appLog("PredictionPolicy: Ignoring telemetry availability - already have predictions", category: .policy, level: .debug)
            return
        }
        
        appLog("PredictionPolicy: First telemetry available - triggering startup prediction", category: .policy, level: .info)
        
        Task {
            if let balloonPosition = balloonPositionService.getBalloonLocation() {
                await evaluatePredictionTrigger(
                    balloonPosition: balloonPosition,
                    reason: "startup_first_telemetry",
                    force: true
                )
            }
        }
    }
    
    private func handleTimerTrigger() async {
        let now = Date()
        let timeSinceLastEvent = lastEventTimes["timer_trigger"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["timer_trigger"] = now
        
        appLog("PredictionPolicy: 60-second timer trigger fired, interval: \(String(format: "%.1f", timeSinceLastEvent))s", category: .policy, level: .debug)
        
        // Only trigger prediction if we have balloon telemetry
        if let balloonPosition = balloonPositionService.getBalloonLocation() {
            await evaluatePredictionTrigger(
                balloonPosition: balloonPosition,
                reason: "60_second_timer",
                force: false // Don't force - respect other conditions
            )
        } else {
            appLog("PredictionPolicy: Timer trigger skipped - no balloon position available", category: .policy, level: .debug)
        }
    }
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .manualPredictionTriggered:
            appLog("PredictionPolicy: Manual prediction triggered by user", category: .policy, level: .info)
            
            Task {
                if let balloonPosition = balloonPositionService.getBalloonLocation() {
                    await evaluatePredictionTrigger(
                        balloonPosition: balloonPosition,
                        reason: "manual_trigger",
                        force: true
                    )
                }
            }
        default:
            break
        }
    }
    
    private func evaluatePredictionTrigger(balloonPosition: CLLocationCoordinate2D, reason: String, force: Bool) async {
        // Only these reasons should trigger predictions:
        // 1. startup_first_telemetry (force=true)
        // 2. manual_trigger (force=true) 
        // 3. 60_second_timer (force=false, but allowed)
        
        let allowedReasons = ["startup_first_telemetry", "manual_trigger", "60_second_timer"]
        guard force || allowedReasons.contains(reason) else {
            appLog("PredictionPolicy: Skipping prediction - invalid reason: \(reason)", category: .policy, level: .debug)
            return
        }
        
        appLog("PredictionPolicy: Triggering prediction - reason: \(reason)", category: .policy, level: .info)
        await executePrediction(balloonPosition: balloonPosition, reason: reason)
    }
    
    private func executePrediction(balloonPosition: CLLocationCoordinate2D, reason: String) async {
        let cacheKey = generateCacheKey(for: balloonPosition)
        
        // Check cache first
        if let cachedPrediction = await predictionCache.get(key: cacheKey) {
            appLog("PredictionPolicy: Using cached prediction", category: .policy, level: .debug)
            publishPredictionUpdate(cachedPrediction, source: "cache", version: 1)
            return
        }
        
        // Execute with scheduler (debouncing and backoff)
        let schedulerKey = "prediction-\(balloonPositionService.currentBalloonName ?? "unknown")"
        
        let result = await policyScheduler.debounce(key: schedulerKey, interval: 1.0) { [weak self] in
            guard let self = self else { throw PolicyError.selfDeallocated }
            
            guard let telemetry = self.balloonPositionService.getLatestTelemetry() else {
                throw PolicyError.noTelemetryData
            }
            
            guard let userSettings = try await self.getUserSettings() else {
                throw PolicyError.noUserSettings
            }
            
            appLog("PredictionPolicy: Fetching prediction (v\(self.predictionVersion)) - \(reason)", category: .policy, level: .info)
            
            let prediction = try await self.predictionService.fetchPrediction(
                telemetry: telemetry,
                userSettings: userSettings,
                measuredDescentRate: abs(self.balloonPositionService.currentTelemetry?.verticalSpeed ?? userSettings.descentRate),
                cacheKey: cacheKey
            )
            
            // Cache the result
            await self.predictionCache.set(key: cacheKey, value: prediction, version: self.predictionVersion)
            
            return prediction
        }
        
        if let prediction = result {
            publishPredictionUpdate(prediction, source: "api", version: predictionVersion)
            lastPredictionLocation = balloonPosition
            lastPredictionTime = Date()
            appLog("PredictionPolicy: Prediction executed successfully", category: .policy, level: .info)
        }
    }
    
    private func publishPredictionUpdate(_ predictionData: PredictionData, source: String, version: Int) {
        predictionVersion += 1
        
        let predictionPolyline = createPredictionPolyline(from: predictionData)
        
        let update = MapStateUpdate(
            source: "PredictionPolicy",
            version: predictionVersion,
            predictionPath: predictionPolyline,
            predictionData: predictionData
        )
        
        EventBus.shared.publishMapStateUpdate(update)
        
        let now = Date()
        let timeSinceLastPublish = lastEventTimes["publish"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["publish"] = now
        
        appLog("PredictionPolicy: Published prediction update from \(source) (v\(predictionVersion)), interval: \(String(format: "%.3f", timeSinceLastPublish))s", category: .policy, level: .debug)
    }
    
    private func createPredictionPolyline(from predictionData: PredictionData) -> MKPolyline? {
        guard let path = predictionData.path, !path.isEmpty else {
            return nil
        }
        let polyline = MKPolyline(coordinates: path, count: path.count)
        polyline.title = "predictionPath"
        return polyline
    }
    
    
    private func generateCacheKey(for position: CLLocationCoordinate2D) -> String {
        let balloonName = balloonPositionService.currentBalloonName ?? "unknown"
        // Make coordinates less precise to improve cache hits (1 decimal = ~11km at equator)
        let lat = String(format: "%.1f", position.latitude)
        let lon = String(format: "%.1f", position.longitude) 
        // Round altitude to nearest 500m for better cache hits
        let alt = String(Int((balloonPositionService.currentAltitude ?? 0) / 500) * 500)
        // Use 10-minute buckets instead of 5-minute for better cache hits
        let timestamp = String(Int(Date().timeIntervalSince1970 / 600) * 600) // 10-minute buckets
        
        return "\(balloonName)-\(lat)-\(lon)-\(alt)-\(timestamp)"
    }
    
    private func getUserSettings() async throws -> UserSettings? {
        // Access user settings through the service manager or persistence service
        // This would need to be injected or accessed through a proper channel
        return UserSettings() // Placeholder - proper implementation would fetch real settings
    }
}

// MARK: - Routing Policy

@MainActor
final class RoutingPolicy: ObservableObject {
    private let routeCalculationService: RouteCalculationService
    private let policyScheduler: PolicyScheduler
    private let routingCache: RoutingCache
    private let modeStateMachine: ModeStateMachine
    private let balloonPositionService: BalloonPositionService
    
    private var cancellables = Set<AnyCancellable>()
    private var routingVersion = 0
    private var currentUserLocation: LocationData? = nil
    private var currentPredictionData: PredictionData? = nil
    private var currentTransportationMode: TransportationMode = .car
    private var lastEventTimes: [String: Date] = [:]
    
    // Caching for route calculation triggers
    private var lastUserLocation: CLLocationCoordinate2D? = nil
    private var lastBalloonLocation: CLLocationCoordinate2D? = nil
    private var lastLandingPoint: CLLocationCoordinate2D? = nil
    private var lastRouteTime: Date? = nil
    
    init(routeCalculationService: RouteCalculationService, policyScheduler: PolicyScheduler, routingCache: RoutingCache, modeStateMachine: ModeStateMachine, balloonPositionService: BalloonPositionService) {
        self.routeCalculationService = routeCalculationService
        self.policyScheduler = policyScheduler
        self.routingCache = routingCache
        self.modeStateMachine = modeStateMachine
        self.balloonPositionService = balloonPositionService
        
        setupSubscriptions()
        appLog("RoutingPolicy: Initialized with service layer architecture", category: .policy, level: .info)
    }
    
    private func setupSubscriptions() {
        // Subscribe to user location updates to track current location
        EventBus.shared.userLocationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.currentUserLocation = event.locationData
            }
            .store(in: &cancellables)
        
        // Subscribe to UI events for transport mode changes
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUIEvent(event)
            }
            .store(in: &cancellables)
        
        // Subscribe to map state updates for prediction changes (landing point changes)
        EventBus.shared.mapStateUpdatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                self?.handleMapStateUpdate(update)
            }
            .store(in: &cancellables)
    }
    
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .transportModeChanged(let newMode, _):
            currentTransportationMode = newMode
            appLog("RoutingPolicy: Transport mode changed to \(newMode)", category: .policy, level: .info)
            Task {
                await executeRouteCalculation(reason: "transport_mode_change")
            }
        default:
            break
        }
    }
    
    private func handleMapStateUpdate(_ update: MapStateUpdate) {
        // Check for prediction data changes
        if let predictionData = update.predictionData {
            let oldLandingPoint = currentPredictionData?.landingPoint
            currentPredictionData = predictionData
            
            // Check if landing point changed significantly
            if let oldPoint = oldLandingPoint,
               let newPoint = predictionData.landingPoint {
                let distance = CLLocation(latitude: oldPoint.latitude, longitude: oldPoint.longitude)
                    .distance(from: CLLocation(latitude: newPoint.latitude, longitude: newPoint.longitude))
                
                if distance > 500 { // 500m threshold - only recalculate route for significant changes
                    appLog("RoutingPolicy: Landing point changed by \(Int(distance))m, triggering route recalculation", category: .policy, level: .info)
                    Task {
                        await executeRouteCalculation(reason: "landing_point_change")
                    }
                }
            } else if predictionData.landingPoint != nil {
                // First landing point received
                appLog("RoutingPolicy: First landing point received, calculating initial route", category: .policy, level: .info)
                Task {
                    await executeRouteCalculation(reason: "initial_landing_point")
                }
            }
        }
    }
    
    private func executeRouteCalculation(reason: String) async {
        guard modeStateMachine.currentMode != .explore else {
            appLog("RoutingPolicy: Routing disabled for current mode \(modeStateMachine.currentMode)", category: .policy, level: .debug)
            return
        }
        
        guard let landingPoint = currentPredictionData?.landingPoint else {
            appLog("RoutingPolicy: No landing point available for routing", category: .policy, level: .debug)
            return
        }
        
        guard let userLocationData = currentUserLocation else {
            appLog("RoutingPolicy: No user location available for routing", category: .policy, level: .debug)
            return
        }
        
        routingVersion += 1
        appLog("RoutingPolicy: Calculating route (v\(routingVersion)) to landing point - \(reason)", category: .policy, level: .info)
        
        do {
            let routeData = try await self.routeCalculationService.calculateRoute(
                from: userLocationData,
                to: landingPoint,
                transportMode: self.currentTransportationMode
            )
            
            // Publish route update
            let update = MapStateUpdate(
                source: "RoutingPolicy",
                version: self.routingVersion,
                userRoute: routeData.path?.isEmpty == false ? MKPolyline(coordinates: routeData.path!, count: routeData.path!.count) : nil,
                routeData: routeData
            )
            
            EventBus.shared.publishMapStateUpdate(update)
            appLog("RoutingPolicy: Published route update (v\(self.routingVersion))", category: .policy, level: .info)
            
        } catch {
            appLog("RoutingPolicy: Route calculation failed: \(error)", category: .policy, level: .error)
        }
    }
    
}

// MARK: - Camera Policy

@MainActor  
final class CameraPolicy: ObservableObject {
    private let policyScheduler: PolicyScheduler
    private let modeStateMachine: ModeStateMachine
    private let balloonPositionService: BalloonPositionService
    
    private var cancellables = Set<AnyCancellable>()
    private var cameraVersion = 0
    private var isFollowModeEnabled: Bool = false
    
    init(policyScheduler: PolicyScheduler, modeStateMachine: ModeStateMachine, balloonPositionService: BalloonPositionService) {
        self.policyScheduler = policyScheduler
        self.modeStateMachine = modeStateMachine
        self.balloonPositionService = balloonPositionService
        
        setupSubscriptions()
        appLog("CameraPolicy: Initialized with service layer architecture", category: .policy, level: .info)
    }
    
    private func setupSubscriptions() {
        // Subscribe to UI events only for "show all annotations" requests
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUIEvent(event)
            }
            .store(in: &cancellables)
    }
    
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .headingModeToggled(let enabled, _):
            isFollowModeEnabled = enabled
            appLog("CameraPolicy: Follow mode \(enabled ? "enabled" : "disabled") - no camera updates", category: .policy, level: .info)
            
        case .showAllAnnotationsRequested(_):
            appLog("CameraPolicy: Show all annotations requested", category: .policy, level: .info)
            Task {
                await showAllAnnotations()
            }
            
        default:
            break
        }
    }
    
    
    private func showAllAnnotations() async {
        let schedulerKey = "camera-show-all"
        
        await policyScheduler.debounce(key: schedulerKey, interval: 0.5) {
            self.cameraVersion += 1
            
            let cameraUpdate = CameraUpdate(
                center: nil, // Will be calculated by the map view to fit all annotations
                animated: true
            )
            
            let update = MapStateUpdate(
                source: "CameraPolicy", 
                version: self.cameraVersion,
                cameraUpdate: cameraUpdate
            )
            
            EventBus.shared.publishMapStateUpdate(update)
            appLog("CameraPolicy: Published show-all-annotations camera update (v\(self.cameraVersion))", category: .policy, level: .info)
        }
    }
    
    private func calculateOptimalRegion(userLocation: CLLocationCoordinate2D, balloonLocation: CLLocationCoordinate2D) -> MKCoordinateRegion {
        // Calculate the center point between user and balloon
        let centerLat = (userLocation.latitude + balloonLocation.latitude) / 2
        let centerLon = (userLocation.longitude + balloonLocation.longitude) / 2
        let center = CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon)
        
        // Calculate span to include both points with some padding
        let latDelta = abs(userLocation.latitude - balloonLocation.latitude) * 1.5
        let lonDelta = abs(userLocation.longitude - balloonLocation.longitude) * 1.5
        
        // Ensure minimum and maximum zoom levels
        let minSpan = 0.01  // ~1km
        let maxSpan = 2.0   // ~200km
        
        let span = MKCoordinateSpan(
            latitudeDelta: max(minSpan, min(maxSpan, latDelta)),
            longitudeDelta: max(minSpan, min(maxSpan, lonDelta))
        )
        
        return MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - Annotation Policy

@MainActor
final class AnnotationPolicy: ObservableObject {
    private let balloonTrackService: BalloonTrackService
    private let landingPointService: LandingPointService
    private let policyScheduler: PolicyScheduler
    
    private var cancellables = Set<AnyCancellable>()
    private var annotationVersion = 0
    private var currentUserLocation: LocationData? = nil
    private var cachedBalloonTelemetry: TelemetryData? = nil
    private var cachedLandingPointCoordinate: CLLocationCoordinate2D? = nil
    private var lastEventTimes: [String: Date] = [:]
    
    init(balloonTrackService: BalloonTrackService, landingPointService: LandingPointService, policyScheduler: PolicyScheduler) {
        self.balloonTrackService = balloonTrackService
        self.landingPointService = landingPointService
        self.policyScheduler = policyScheduler
        
        setupSubscriptions()
        appLog("AnnotationPolicy: Initialized", category: .policy, level: .info)
    }
    
    private func setupSubscriptions() {
        // Subscribe to balloon position updates via EventBus
        EventBus.shared.balloonPositionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] positionEvent in
                self?.cachedBalloonTelemetry = positionEvent.telemetry
                appLog("AnnotationPolicy: Cached telemetry data for balloon \(positionEvent.balloonId)", category: .policy, level: .debug)
            }
            .store(in: &cancellables)
        
        // Subscribe to balloon track updates
        balloonTrackService.trackUpdated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleTrackUpdate()
            }
            .store(in: &cancellables)
        
        // Subscribe to landing point changes
        landingPointService.$validLandingPoint
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleLandingPointChange()
            }
            .store(in: &cancellables)
        
        // Subscribe to user location updates
        EventBus.shared.userLocationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUserLocationUpdate(event)
            }
            .store(in: &cancellables)
        
    }
    
    private func handleTrackUpdate() {
        appLog("AnnotationPolicy: Balloon track updated", category: .policy, level: .debug)
        
        Task {
            await updateAnnotations(reason: "track_update")
        }
    }
    
    private func handleLandingPointChange() {
        // Get the new landing point coordinate
        let newLandingPointCoordinate = landingPointService.validLandingPoint
        
        // Debug logging
        if let new = newLandingPointCoordinate {
            appLog("AnnotationPolicy: New landing point: \(new)", category: .policy, level: .debug)
        } else {
            appLog("AnnotationPolicy: New landing point: nil", category: .policy, level: .debug)
        }
        
        if let cached = cachedLandingPointCoordinate {
            appLog("AnnotationPolicy: Cached landing point: \(cached)", category: .policy, level: .debug)
        } else {
            appLog("AnnotationPolicy: Cached landing point: nil", category: .policy, level: .debug)
        }
        
        // Check if it actually changed
        let hasChanged: Bool
        if let current = cachedLandingPointCoordinate, let new = newLandingPointCoordinate {
            // Compare coordinates
            hasChanged = current.latitude != new.latitude || current.longitude != new.longitude
            appLog("AnnotationPolicy: Coordinate comparison - hasChanged: \(hasChanged)", category: .policy, level: .debug)
        } else if cachedLandingPointCoordinate == nil && newLandingPointCoordinate != nil {
            hasChanged = true  // First landing point
            appLog("AnnotationPolicy: First landing point - hasChanged: true", category: .policy, level: .debug)
        } else if cachedLandingPointCoordinate != nil && newLandingPointCoordinate == nil {
            hasChanged = true  // Landing point removed
            appLog("AnnotationPolicy: Landing point removed - hasChanged: true", category: .policy, level: .debug)
        } else {
            hasChanged = false // Both nil
            appLog("AnnotationPolicy: Both nil - hasChanged: false", category: .policy, level: .debug)
        }
        
        guard hasChanged else {
            appLog("AnnotationPolicy: Landing point unchanged, skipping update", category: .policy, level: .debug)
            return // Skip if landing point didn't actually change
        }
        
        cachedLandingPointCoordinate = newLandingPointCoordinate
        
        let now = Date()
        let timeSinceLastEvent = lastEventTimes["landing_point_change"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["landing_point_change"] = now
        
        appLog("AnnotationPolicy: Landing point actually changed, interval: \(String(format: "%.3f", timeSinceLastEvent))s", category: .policy, level: .debug)
        
        Task {
            await updateAnnotations(reason: "landing_point_change")
        }
    }
    
    private func handleUserLocationUpdate(_ event: UserLocationEvent) {
        currentUserLocation = event.locationData
        
        appLog("AnnotationPolicy: Received user location update", category: .policy, level: .debug)
        
        Task {
            await updateAnnotations(reason: "user_location")
        }
    }
    
    
    private func updateAnnotations(reason: String) async {
        appLog("AnnotationPolicy: Immediate annotation update - reason: \(reason)", category: .policy, level: .debug)
        
        let now = Date()
        
        self.annotationVersion += 1
        
        var annotations: [MapAnnotationItem] = []
        
        // Add user location annotation
        if let userLocation = self.currentUserLocation {
            let userAnnotation = MapAnnotationItem(
                coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
                kind: .user
            )
            annotations.append(userAnnotation)
        }
        
        // Add balloon annotation if we have telemetry
        if let telemetry = self.cachedBalloonTelemetry {
            let balloonAnnotation = MapAnnotationItem(
                coordinate: CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude),
                kind: .balloon,
                isAscending: telemetry.verticalSpeed >= 0,
                altitude: telemetry.altitude
            )
            annotations.append(balloonAnnotation)
            
            appLog("AnnotationPolicy: Added balloon annotation for \(telemetry.sondeName) at (\(telemetry.latitude), \(telemetry.longitude), \(telemetry.altitude)m)", category: .policy, level: .debug)
        }
        
        // Add landing point annotation if available
        if let landingPoint = self.landingPointService.validLandingPoint {
            let landingAnnotation = MapAnnotationItem(
                coordinate: landingPoint,
                kind: .landing
            )
            annotations.append(landingAnnotation)
        }
        
        // Create balloon track polyline
        let trackPoints = self.balloonTrackService.getAllTrackPoints()
        var balloonTrackPolyline: MKPolyline? = nil
        
        if !trackPoints.isEmpty {
            let coordinates = trackPoints.map { point in
                CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
            balloonTrackPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            balloonTrackPolyline?.title = "balloonTrack"
        }
        
        let update = MapStateUpdate(
            source: "AnnotationPolicy",
            version: self.annotationVersion,
            annotations: annotations,
            balloonTrack: balloonTrackPolyline
        )
        
        EventBus.shared.publishMapStateUpdate(update)
        
        self.lastEventTimes["publish"] = now
        let timeSinceLastPublish = self.lastEventTimes["last_publish"].map { now.timeIntervalSince($0) } ?? 0
        self.lastEventTimes["last_publish"] = now
        
        appLog("AnnotationPolicy: Published annotation update (v\(self.annotationVersion)) with \(annotations.count) annotations, interval: \(String(format: "%.3f", timeSinceLastPublish))s - \(reason)", category: .policy, level: .debug)
    }
}

// MARK: - UI Event Policy

@MainActor
final class UIEventPolicy: ObservableObject {
    private weak var serviceManager: ServiceManager?
    private var cancellables = Set<AnyCancellable>()
    
    init(serviceManager: ServiceManager) {
        self.serviceManager = serviceManager
        setupSubscriptions()
        appLog("UIEventPolicy: Initialized", category: .policy, level: .info)
    }
    
    private func setupSubscriptions() {
        // Subscribe to UI events and handle them appropriately
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUIEvent(event)
            }
            .store(in: &cancellables)
    }
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .buzzerMuteToggled(let muted, _):
            handleBuzzerMuteToggle(muted: muted)
            
        case .landingPointSetRequested(_):
            handleLandingPointSetRequest()
            
        case .showAllAnnotationsRequested(_):
            // This is handled by CameraPolicy - no action needed here
            appLog("UIEventPolicy: Show all annotations requested - delegating to CameraPolicy", category: .policy, level: .debug)
            
        case .manualPredictionTriggered(_):
            // This is handled by PredictionPolicy - no action needed here
            appLog("UIEventPolicy: Manual prediction triggered - delegating to PredictionPolicy", category: .policy, level: .debug)
            
        case .transportModeChanged(let mode, _):
            // This is handled by RoutingPolicy - no action needed here
            appLog("UIEventPolicy: Transport mode changed to \(mode) - delegating to RoutingPolicy", category: .policy, level: .debug)
            
        case .predictionVisibilityToggled(let visible, _):
            handlePredictionVisibilityToggle(visible: visible)
            
        case .headingModeToggled(let enabled, _):
            // Heading mode is tracked in CameraPolicy but doesn't trigger camera updates
            appLog("UIEventPolicy: Heading mode toggled to \(enabled) - no camera action", category: .policy, level: .debug)
            
        case .cameraRegionChanged(_, _):
            // Camera region changes are user-driven - no policy action needed
            break
            
        case .annotationSelected(_, _):
            // This could trigger prediction or camera updates - handled by other policies
            appLog("UIEventPolicy: Annotation selected - delegating to other policies", category: .policy, level: .debug)
            
        case .modeSwitched(let mode, _):
            // This is handled by ModeStateMachine - no action needed here
            appLog("UIEventPolicy: Mode switched to \(mode) - delegating to ModeStateMachine", category: .policy, level: .debug)
            
        case .routeVisibilityToggled(let visible, _):
            // This is handled by RoutingPolicy - no action needed here
            appLog("UIEventPolicy: Route visibility toggled to \(visible) - delegating to RoutingPolicy", category: .policy, level: .debug)
        }
    }
    
    private func handleBuzzerMuteToggle(muted: Bool) {
        guard let serviceManager = serviceManager else { return }
        
        let command = muted ? "o{buz=0}o" : "o{buz=1}o"
        serviceManager.bleCommunicationService.sendCommand(command: command)
        
        appLog("UIEventPolicy: Sent buzzer \(muted ? "mute" : "unmute") command to device", category: .policy, level: .info)
    }
    
    private func handleLandingPointSetRequest() {
        // Get coordinates from clipboard or user input
        // This would typically show a UI for manual coordinate entry
        // For now, we'll try to parse from clipboard
        
        if let clipboardString = UIPasteboard.general.string,
           let coordinates = parseCoordinatesFromClipboard(clipboardString) {
            
            // Update landing point service
            serviceManager?.landingPointService.validLandingPoint = coordinates
            
            appLog("UIEventPolicy: Set landing point from clipboard: \(coordinates)", category: .policy, level: .info)
        } else {
            appLog("UIEventPolicy: Could not parse coordinates from clipboard", category: .policy, level: .error)
        }
    }
    
    private func handlePredictionVisibilityToggle(visible: Bool) {
        // Update map state to show/hide prediction path
        let update = MapStateUpdate(
            source: "UIEventPolicy",
            version: 0,
            predictionPath: visible ? nil : MKPolyline() // Empty polyline to hide
        )
        
        EventBus.shared.publishMapStateUpdate(update)
        appLog("UIEventPolicy: Prediction visibility set to \(visible)", category: .policy, level: .info)
    }
    
    private func parseCoordinatesFromClipboard(_ text: String) -> CLLocationCoordinate2D? {
        // Try to parse coordinates from various formats
        // This is a simplified implementation
        let components = text.components(separatedBy: CharacterSet(charactersIn: ",; "))
        
        if components.count >= 2,
           let lat = Double(components[0]),
           let lon = Double(components[1]) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        
        return nil
    }
}

// MARK: - Supporting Types and Errors

enum PolicyError: Error, LocalizedError {
    case selfDeallocated
    case noTelemetryData
    case noUserSettings
    case maxRetriesExceeded
    case invalidData
    
    var errorDescription: String? {
        switch self {
        case .selfDeallocated:
            return "Policy object was deallocated"
        case .noTelemetryData:
            return "No telemetry data available"
        case .noUserSettings:
            return "No user settings available"
        case .maxRetriesExceeded:
            return "Maximum retry attempts exceeded"
        case .invalidData:
            return "Invalid data provided"
        }
    }
}

// Camera update data structure
*/
