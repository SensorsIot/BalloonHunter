import Foundation
import Combine
import CoreLocation
import MapKit
import OSLog

@MainActor
class RoutingPolicy {
    private let routeCalculationService: RouteCalculationService
    private let policyScheduler: PolicyScheduler
    private let routingCache: RoutingCache
    private let modeStateMachine: ModeStateMachine
    private let balloonPositionService: BalloonPositionService
    private var cancellables = Set<AnyCancellable>()
    
    private var lastUserLocation: CLLocationCoordinate2D? = nil
    private var lastBalloonLocation: CLLocationCoordinate2D? = nil
    private var lastRouteTime: Date = Date.distantPast
    private var routingVersion: Int = 0
    private var currentTelemetry: TelemetryData? = nil
    private var currentUserLocation: LocationData? = nil
    private var currentTransportationMode: TransportationMode = .car
    private var currentPredictionData: PredictionData? = nil
    private var lastLandingPoint: CLLocationCoordinate2D? = nil
    private var lastEventTimes: [String: Date] = [:]

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

        // Subscribe to UI events
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUIEvent(event)
            }
            .store(in: &cancellables)
        
        // Note: RouteCalculationService doesn't publish results automatically
        // Routes are calculated on-demand when needed
        
        // Subscribe to map state updates for prediction changes
        EventBus.shared.mapStateUpdatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                self?.handleMapStateUpdate(update)
            }
            .store(in: &cancellables)
    }
    
    private func handlePositionUpdate(_ positionEvent: BalloonPositionEvent) {
        let now = Date()
        let timeSinceLastTelemetry = lastEventTimes["telemetry"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["telemetry"] = now
        
        currentTelemetry = positionEvent.telemetry
        appLog("RoutingPolicy: Received position update for balloon \(positionEvent.balloonId), interval: \(String(format: "%.3f", timeSinceLastTelemetry))s", category: .policy, level: .debug)
        
        Task {
            await evaluateRoutingTrigger(reason: "position_update")
        }
    }
    
    private func handleUserLocationEvent(_ event: UserLocationEvent) {
        let now = Date()
        let timeSinceLastLocation = lastEventTimes["location"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["location"] = now
        
        currentUserLocation = event.locationData
        appLog("RoutingPolicy: Received user location update, interval: \(String(format: "%.3f", timeSinceLastLocation))s", category: .policy, level: .debug)
        
        Task {
            await evaluateRoutingTrigger(reason: "location_update")
        }
    }
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .transportModeChanged(let mode, _):
            currentTransportationMode = mode
            appLog("RoutingPolicy: Transport mode changed to \(mode)", category: .policy, level: .info)
            Task {
                await evaluateRoutingTrigger(reason: "transport_mode_change", force: true)
            }
        case .routeVisibilityToggled(let visible, _):
            // Route visibility is handled by MapState, but we can log it
            appLog("RoutingPolicy: Route visibility toggled to \(visible)", category: .policy, level: .debug)
        case .modeSwitched(let mode, _):
            appLog("RoutingPolicy: Mode switched to \(mode.displayName)", category: .policy, level: .info)
        default:
            break
        }
    }
    
    private func handleMapStateUpdate(_ update: MapStateUpdate) {
        // Check for prediction data changes
        if let predictionData = update.predictionData {
            let oldLandingPoint = currentPredictionData?.landingPoint
            currentPredictionData = predictionData
            
            // Check if landing point changed
            if let newLandingPoint = predictionData.landingPoint {
                let landingPointChanged = oldLandingPoint == nil || 
                    abs(newLandingPoint.latitude - (oldLandingPoint?.latitude ?? 0)) > 0.001 ||
                    abs(newLandingPoint.longitude - (oldLandingPoint?.longitude ?? 0)) > 0.001
                
                if landingPointChanged {
                    appLog("RoutingPolicy: Landing point changed, triggering route recalculation", category: .policy, level: .info)
                    Task {
                        await evaluateRoutingTrigger(reason: "landing_point_change", force: true)
                    }
                }
            }
        }
    }
    
    private func evaluateRoutingTrigger(reason: String, force: Bool = false) async {
        guard let userLocation = currentUserLocation,
              let telemetry = currentTelemetry,
              let landingPoint = currentPredictionData?.landingPoint else {
            appLog("RoutingPolicy: Missing location data or landing point for routing evaluation", category: .policy, level: .debug)
            return
        }
        
        // Get mode configuration
        let modeConfig = modeStateMachine.getModeConfig(for: modeStateMachine.currentMode)
        
        // Check if routing is enabled for current mode
        guard modeConfig.routingEnabled else {
            appLog("RoutingPolicy: Routing disabled for current mode \(modeStateMachine.currentMode.displayName)", category: .policy, level: .debug)
            return
        }
        
        let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let balloonCoord = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
        
        // Check movement thresholds
        var shouldTriggerByMovement = false
        if let lastUserLoc = lastUserLocation {
            let userDistance = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                .distance(from: CLLocation(latitude: lastUserLoc.latitude, longitude: lastUserLoc.longitude))
            shouldTriggerByMovement = shouldTriggerByMovement || userDistance > getUserMovementThreshold()
        }
        
        if let lastLandingLoc = lastLandingPoint {
            let landingDistance = CLLocation(latitude: landingPoint.latitude, longitude: landingPoint.longitude)
                .distance(from: CLLocation(latitude: lastLandingLoc.latitude, longitude: lastLandingLoc.longitude))
            shouldTriggerByMovement = shouldTriggerByMovement || landingDistance > getBalloonMovementThreshold()
        }
        
        // Check time threshold
        let timeSinceLastRoute = Date().timeIntervalSince(lastRouteTime)
        let shouldTriggerByTime = timeSinceLastRoute >= getRouteUpdateInterval()
        
        let shouldTrigger = force || shouldTriggerByMovement || shouldTriggerByTime || lastUserLocation == nil
        
        if shouldTrigger {
            appLog("RoutingPolicy: Triggering route calculation - reason: \(reason), force: \(force), byTime: \(shouldTriggerByTime), byMovement: \(shouldTriggerByMovement)", 
                   category: .policy, level: .debug)
            
            await executeRouteCalculation(userLocation: userCoord, landingPoint: landingPoint, balloonLocation: balloonCoord, reason: reason)
        } else {
            appLog("RoutingPolicy: Skipping route calculation - reason: \(reason), timeSince: \(String(format: "%.1f", timeSinceLastRoute))s", 
                   category: .policy, level: .debug)
        }
    }
    
    private func getUserMovementThreshold() -> Double {
        switch modeStateMachine.currentMode {
        case .explore: return 200.0 // 200m
        case .follow: return 100.0  // 100m  
        case .finalApproach: return 50.0 // 50m
        }
    }
    
    private func getBalloonMovementThreshold() -> Double {
        switch modeStateMachine.currentMode {
        case .explore: return 500.0 // 500m
        case .follow: return 200.0  // 200m
        case .finalApproach: return 100.0 // 100m
        }
    }
    
    private func getRouteUpdateInterval() -> TimeInterval {
        switch modeStateMachine.currentMode {
        case .explore: return 300.0 // 5 minutes
        case .follow: return 120.0  // 2 minutes
        case .finalApproach: return 60.0 // 1 minute
        }
    }

    private func executeRouteCalculation(userLocation: CLLocationCoordinate2D, landingPoint: CLLocationCoordinate2D, balloonLocation: CLLocationCoordinate2D, reason: String) async {
        routingVersion += 1

        let _ = "routing-\(currentTransportationMode.identifier)"

        appLog("RoutingPolicy: Calculating route (v\(routingVersion)) to landing point - \(reason)", category: .policy, level: .info)

        guard let userLocationData = currentUserLocation else {
            appLog("RoutingPolicy: No user location available for route calculation", category: .policy, level: .error)
            return
        }
        
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
                userRoute: routeData.polyline,
                routeData: routeData
            )
            
            EventBus.shared.publishMapStateUpdate(update)
            appLog("RoutingPolicy: Published route update (v\(self.routingVersion))", category: .policy, level: .info)
            
        } catch {
            appLog("RoutingPolicy: Route calculation failed: \(error)", category: .policy, level: .error)
        }

        self.lastUserLocation = userLocation
        self.lastBalloonLocation = balloonLocation
        self.lastLandingPoint = landingPoint
        self.lastRouteTime = Date()
    }
    
    private func handleRouteCalculationResult(_ routeData: RouteData) {
        appLog("RoutingPolicy: Received route calculation result", category: .policy, level: .debug)
        
        // Check if balloon and user are too close (< 100m) - don't show route in this case
        if let userLocation = currentUserLocation,
           let telemetry = currentTelemetry {
            let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
            let balloonCoord = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
            let distance = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                .distance(from: CLLocation(latitude: balloonCoord.latitude, longitude: balloonCoord.longitude))
            
            if distance < 100.0 {
                appLog("RoutingPolicy: Balloon too close (\(String(format: "%.0f", distance))m) - not showing route", 
                       category: .policy, level: .debug)
                // Publish empty route to hide it
                let emptyUpdate = MapStateUpdate(
                    source: "RoutingPolicy",
                    version: routingVersion,
                    userRoute: nil
                )
                let now = Date()
                let timeSinceLastPublish = lastEventTimes["publish"].map { now.timeIntervalSince($0) } ?? 0
                lastEventTimes["publish"] = now
                
                EventBus.shared.publishMapStateUpdate(emptyUpdate)
                appLog("RoutingPolicy: Published empty route update, interval: \(String(format: "%.3f", timeSinceLastPublish))s", category: .policy, level: .debug)
                return
            }
        }
        
        publishRouteUpdate(routeData, source: "calculation_result")
    }
    
    private func publishRouteUpdate(_ route: RouteData, source: String) {
        var routePolyline: MKPolyline? = nil
        
        if let coordinates = route.path, !coordinates.isEmpty {
            routePolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            routePolyline?.title = "userRoute"
        }
        
        let update = MapStateUpdate(
            source: "RoutingPolicy",
            version: routingVersion,
            userRoute: routePolyline,
            routeData: route
        )
        
        let now = Date()
        let timeSinceLastPublish = lastEventTimes["publish"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["publish"] = now
        
        EventBus.shared.publishMapStateUpdate(update)
        appLog("RoutingPolicy: Published route update from \(source) (v\(routingVersion)), interval: \(String(format: "%.3f", timeSinceLastPublish))s", 
               category: .policy, level: .debug)
    }
}
