import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import OSLog

// MARK: - Simplified Balloon Tracker

@MainActor
final class BalloonTracker: ObservableObject {
    // KEEP: Core services that provide real value
    let persistenceService: PersistenceService
    let predictionCache: PredictionCache  // Keep: has real performance value
    let routingCache: RoutingCache       // Keep: has real performance value
    let mapState: MapState               // Keep: single source of truth
    
    // KEEP: Core services (simplified)
    lazy var currentLocationService = CurrentLocationService()
    lazy var bleCommunicationService = BLECommunicationService(persistenceService: self.persistenceService)
    lazy var predictionService = PredictionService()
    
    // REQUIRED: Services that generate the events and manage data
    lazy var balloonPositionService = BalloonPositionService(bleService: self.bleCommunicationService)
    lazy var balloonTrackService = BalloonTrackService(persistenceService: self.persistenceService, balloonPositionService: self.balloonPositionService)
    lazy var landingPointService = LandingPointService(balloonTrackService: self.balloonTrackService, predictionService: self.predictionService, persistenceService: self.persistenceService, predictionCache: self.predictionCache, mapState: self.mapState)
    lazy var routeCalculationService = RouteCalculationService(landingPointService: self.landingPointService, currentLocationService: self.currentLocationService)
    
    // REMOVE: Policy architecture, ModeStateMachine, PolicyScheduler
    // REPLACE: With direct service communication
    
    private var cancellables = Set<AnyCancellable>()
    private var lastPredictionTime = Date.distantPast
    private var lastRouteCalculationTime = Date.distantPast
    private var lastUserLocation: CLLocationCoordinate2D?
    private var lastLandingPoint: CLLocationCoordinate2D?
    private var lastUserLocationUpdateTime = Date.distantPast
    
    // Simple timing constants (replace complex mode machine)
    private let predictionInterval: TimeInterval = 60  // Every 60 seconds per requirements
    private let routeUpdateInterval: TimeInterval = 60  // Always 60 seconds
    private let significantMovementThreshold: Double = 100  // meters
    
    // User settings reference (for external access)
    var userSettings = UserSettings()
    
    // Automatic descent rate calculation
    private var descentRateHistory: [Double] = [] // Store up to 20 values for smoothing
    
    init() {
        appLog("BalloonTracker: Initializing simplified architecture", category: .general, level: .info)
        
        // Initialize core infrastructure (keep what's valuable)
        self.persistenceService = PersistenceService()
        self.predictionCache = PredictionCache()
        self.routingCache = RoutingCache()
        self.mapState = MapState()
        
        setupDirectSubscriptions()
        
        appLog("BalloonTracker: Simplified architecture initialized", category: .general, level: .info)
    }
    
    func initialize() {
        // Start core services
        _ = currentLocationService
        _ = bleCommunicationService
        // NOTE: predictionService is lazy-initialized only when first telemetry is received
        
        // Initialize the services that create events and manage data
        _ = balloonPositionService
        _ = balloonTrackService  
        _ = landingPointService
        _ = routeCalculationService
        
        // Per FSD: Load persistence data after service initialization
        loadPersistenceData()
        
        appLog("BalloonTracker: All services initialized", category: .general, level: .info)
    }
    
    // MARK: - Direct Event Handling (No Policy Layers)
    
    private func setupDirectSubscriptions() {
        // Direct BLE telemetry handling
        EventBus.shared.balloonPositionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] positionEvent in
                self?.handleBalloonPosition(positionEvent)
            }
            .store(in: &cancellables)
        
        // Direct user location handling
        EventBus.shared.userLocationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locationEvent in
                self?.handleUserLocation(locationEvent)
            }
            .store(in: &cancellables)
        
        // Direct UI event handling
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uiEvent in
                self?.handleUIEvent(uiEvent)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Simplified Event Handlers
    
    private func handleBalloonPosition(_ event: BalloonPositionEvent) {
        let telemetry = event.telemetry
        
        appLog("BalloonTracker: Processing balloon position for \(event.balloonId)", category: .general, level: .debug)
        
        // 1. Update map state directly (no policy layers)
        updateMapWithBalloonPosition(telemetry)
        
        // 1a. Calculate automatic descent rate if below 10000m
        appLog("BalloonTracker: About to call calculateAutomaticDescentRate", category: .general, level: .debug)
        calculateAutomaticDescentRate(telemetry)
        
        // 2. Check if we need prediction (simple time-based + movement)
        appLog("BalloonTracker: Checking if prediction needed for \(telemetry.sondeName)", category: .general, level: .debug)
        if shouldRequestPrediction(telemetry) {
            appLog("BalloonTracker: Prediction needed, starting request", category: .general, level: .info)
            Task {
                await requestPrediction(telemetry)
            }
        } else {
            appLog("BalloonTracker: Prediction not needed yet", category: .general, level: .debug)
        }
        
        // 3. Update route if needed
        if shouldUpdateRoute() {
            Task {
                await updateRoute()
            }
        }
    }
    
    private func handleUserLocation(_ event: UserLocationEvent) {
        // Update map state directly
        mapState.userLocation = event.locationData
        
        // Check if route needs updating due to user movement
        let userCoord = CLLocationCoordinate2D(
            latitude: event.locationData.latitude, 
            longitude: event.locationData.longitude
        )
        
        let shouldUpdateForMovement = hasUserMovedSignificantly(to: userCoord)
        let shouldUpdateForTime = shouldUpdateRouteForUserMovement()
        
        if shouldUpdateForMovement && shouldUpdateForTime {
            appLog("BalloonTracker: User moved significantly after 1+ minute - triggering route update", category: .general, level: .info)
            lastUserLocationUpdateTime = Date()
            Task {
                await updateRoute()
            }
        }
        
        lastUserLocation = userCoord
    }
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .manualPredictionTriggered:
            // Force immediate prediction
            if let telemetry = bleCommunicationService.latestTelemetry {
                Task {
                    await requestPrediction(telemetry, force: true)
                }
            }
            
        case .buzzerMuteToggled(let muted, _):
            // Direct device command (no policy needed)
            bleCommunicationService.setMute(muted)
            
        case .showAllAnnotationsRequested:
            // Direct camera update (no policy needed)
            updateCameraToShowAllAnnotations()
            
        case .headingModeToggled(let enabled, _):
            // Update heading mode state
            mapState.isHeadingMode = enabled
            appLog("BalloonTracker: Heading mode \(enabled ? "enabled" : "disabled")", category: .general, level: .info)
            
        case .transportModeChanged(let mode, _):
            // Update transport mode and trigger route recalculation
            mapState.transportMode = mode
            appLog("BalloonTracker: Transport mode changed to \(mode) - triggering route update", category: .general, level: .info)
            Task {
                await updateRoute()
            }
            
        default:
            break
        }
    }
    
    // MARK: - Simplified Business Logic
    
    private func updateMapWithBalloonPosition(_ telemetry: TelemetryData) {
        // Update balloon annotation directly
        let balloonAnnotation = MapAnnotationItem(
            coordinate: CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude),
            kind: .balloon,
            isAscending: telemetry.verticalSpeed >= 0,
            altitude: telemetry.altitude
        )
        
        // Update user annotation if available
        var annotations: [MapAnnotationItem] = [balloonAnnotation]
        if let userLocation = mapState.userLocation {
            let userAnnotation = MapAnnotationItem(
                coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
                kind: .user
            )
            annotations.append(userAnnotation)
        }
        
        // Add landing point if available
        if let landingPoint = getCurrentLandingPoint() {
            let landingAnnotation = MapAnnotationItem(coordinate: landingPoint, kind: .landing)
            annotations.append(landingAnnotation)
        }
        
        // Add burst point if available AND balloon is ascending
        if let burstPoint = mapState.burstPoint,
           let telemetryData = mapState.balloonTelemetry,
           telemetryData.verticalSpeed >= 0 { // Only show when ascending
            let burstAnnotation = MapAnnotationItem(coordinate: burstPoint, kind: .burst)
            annotations.append(burstAnnotation)
        }
        
        // Update balloon track using the track service
        let trackPoints = balloonTrackService.getAllTrackPoints()
        var balloonTrackPolyline: MKPolyline? = nil
        if !trackPoints.isEmpty {
            let coordinates = trackPoints.map { point in
                CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            }
            balloonTrackPolyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            balloonTrackPolyline?.title = "balloonTrack"
        }
        
        // Direct map state update (no versioning complexity)
        mapState.annotations = annotations
        mapState.balloonTrackPath = balloonTrackPolyline
        mapState.balloonTelemetry = telemetry
        
        appLog("BalloonTracker: Updated map with \(annotations.count) annotations", category: .general, level: .debug)
    }
    
    private func shouldRequestPrediction(_ telemetry: TelemetryData, force: Bool = false) -> Bool {
        if force {
            appLog("BalloonTracker: Prediction forced", category: .general, level: .debug)
            return true
        }
        
        // Simple time-based trigger (no complex mode machine)
        let timeSinceLastPrediction = Date().timeIntervalSince(lastPredictionTime)
        let shouldTrigger = timeSinceLastPrediction > predictionInterval
        
        appLog("BalloonTracker: shouldRequestPrediction - timeSince: \(timeSinceLastPrediction)s, interval: \(predictionInterval)s, result: \(shouldTrigger)", category: .general, level: .debug)
        
        return shouldTrigger
    }
    
    private func requestPrediction(_ telemetry: TelemetryData, force: Bool = false) async {
        guard shouldRequestPrediction(telemetry, force: force) else { return }
        
        appLog("BalloonTracker: Requesting prediction for \(telemetry.sondeName)", category: .general, level: .info)
        
        // Use cache key generation (keep this valuable part)
        let cacheKey = generateCacheKey(telemetry)
        
        // TEMPORARY: Skip cache completely to test landing time fix
        appLog("BalloonTracker: TEMPORARY - Bypassing cache completely to test landing time fix", category: .general, level: .info)
        
        do {
            // Use the tracker's user settings
            let userSettings = self.userSettings
            
            // Use adjusted descent rate if available (below 10000m), otherwise use raw vertical speed
            let descentRateToUse: Double
            if let adjustedRate = mapState.smoothedDescentRate, telemetry.altitude < 10000 {
                descentRateToUse = abs(adjustedRate) // Use absolute value of smoothed rate
                appLog("BalloonTracker: Using adjusted descent rate: \(String(format: "%.2f", descentRateToUse)) m/s (altitude: \(Int(telemetry.altitude))m)", category: .general, level: .info)
            } else {
                descentRateToUse = abs(telemetry.verticalSpeed) // Fallback to raw vertical speed
                appLog("BalloonTracker: Using raw vertical speed: \(String(format: "%.2f", descentRateToUse)) m/s (altitude: \(Int(telemetry.altitude))m)", category: .general, level: .info)
            }
            
            // Call prediction service directly
            let predictionData = try await predictionService.fetchPrediction(
                telemetry: telemetry,
                userSettings: userSettings,
                measuredDescentRate: descentRateToUse,
                cacheKey: cacheKey
            )
            
            // Cache the result (keep this valuable optimization)
            await predictionCache.set(key: cacheKey, value: predictionData)
            
            // Update map directly
            updateMapWithPrediction(predictionData)
            
            lastPredictionTime = Date()
            
            appLog("BalloonTracker: Prediction completed successfully", category: .general, level: .info)
            
        } catch {
            appLog("BalloonTracker: Prediction failed: \(error)", category: .general, level: .error)
        }
    }
    
    private func updateMapWithPrediction(_ prediction: PredictionData) {
        // Update prediction data for DataPanelView (flight time, landing time)
        mapState.predictionData = prediction
        appLog("BalloonTracker: Set predictionData - landingTime: \(prediction.landingTime?.description ?? "nil")", category: .general, level: .debug)
        
        // Update prediction path
        if let path = prediction.path, !path.isEmpty {
            mapState.predictionPath = MKPolyline(coordinates: path, count: path.count)
            mapState.isPredictionPathVisible = true
        }
        
        // Check if landing point moved significantly (trigger route update)
        let shouldUpdateRouteFromLandingChange = checkLandingPointMovement(newLandingPoint: prediction.landingPoint)
        
        // Update landing and burst points
        mapState.landingPoint = prediction.landingPoint
        mapState.burstPoint = prediction.burstPoint
        
        // Update map annotations to include landing and burst points
        if let telemetry = bleCommunicationService.latestTelemetry {
            updateMapWithBalloonPosition(telemetry)
        }
        
        // Per FSD: Use maximum zoom level to show all annotations after data loading
        updateCameraToShowAllAnnotations()
        
        // Trigger route update if landing point moved significantly
        if shouldUpdateRouteFromLandingChange {
            Task {
                await updateRoute()
            }
        }
    }
    
    private func shouldUpdateRoute() -> Bool {
        let timeSinceLastRoute = Date().timeIntervalSince(lastRouteCalculationTime)
        return timeSinceLastRoute > routeUpdateInterval
    }
    
    private func checkLandingPointMovement(newLandingPoint: CLLocationCoordinate2D?) -> Bool {
        defer { lastLandingPoint = newLandingPoint }
        
        guard let newPoint = newLandingPoint else { return false }
        guard let lastPoint = lastLandingPoint else { return true } // First time
        
        let distance = CLLocation(latitude: lastPoint.latitude, longitude: lastPoint.longitude)
            .distance(from: CLLocation(latitude: newPoint.latitude, longitude: newPoint.longitude))
        
        let landingPointMovementThreshold: Double = 100 // meters
        let moved = distance > landingPointMovementThreshold
        
        if moved {
            appLog("BalloonTracker: Landing point moved \(Int(distance))m - triggering route update", category: .general, level: .info)
        }
        
        return moved
    }
    
    private func hasUserMovedSignificantly(to newLocation: CLLocationCoordinate2D) -> Bool {
        guard let lastLocation = lastUserLocation else { return true }
        
        let distance = CLLocation(latitude: lastLocation.latitude, longitude: lastLocation.longitude)
            .distance(from: CLLocation(latitude: newLocation.latitude, longitude: newLocation.longitude))
        
        return distance > significantMovementThreshold
    }
    
    private func shouldUpdateRouteForUserMovement() -> Bool {
        let now = Date()
        let timeSinceLastUserUpdate = now.timeIntervalSince(lastUserLocationUpdateTime)
        
        // Check every minute for user movement
        return timeSinceLastUserUpdate > 60.0
    }
    
    private func updateRoute() async {
        guard let userLocation = mapState.userLocation,
              let landingPoint = mapState.landingPoint else {
            appLog("BalloonTracker: Cannot calculate route - missing user location or landing point", category: .general, level: .debug)
            return
        }
        
        // Check distance gating (don't show route if balloon is too close to iPhone)
        let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
        
        // Use balloon position if available, otherwise fall back to landing point
        let referencePoint: CLLocationCoordinate2D
        if let balloonTelemetry = mapState.balloonTelemetry {
            referencePoint = CLLocationCoordinate2D(latitude: balloonTelemetry.latitude, longitude: balloonTelemetry.longitude)
        } else {
            referencePoint = landingPoint
        }
        
        let distance = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            .distance(from: CLLocation(latitude: referencePoint.latitude, longitude: referencePoint.longitude))
        
        if distance < 100 { // 100m rule - too close to balloon/landing point
            mapState.userRoute = nil
            mapState.isRouteVisible = false
            let referenceType = mapState.balloonTelemetry != nil ? "balloon" : "landing point"
            appLog("BalloonTracker: Route hidden - too close to \(referenceType) (\(Int(distance))m < 100m)", category: .general, level: .debug)
            return
        }
        
        // Generate cache key including transport mode (keep this valuable optimization)
        let routeKey = generateRouteCacheKey(userCoord, landingPoint, mapState.transportMode)
        
        // Check cache first
        if let cachedRoute = await routingCache.get(key: routeKey) {
            appLog("BalloonTracker: Using cached route", category: .general, level: .debug)
            if let routePath = cachedRoute.path, !routePath.isEmpty {
                mapState.userRoute = MKPolyline(coordinates: routePath, count: routePath.count)
                mapState.isRouteVisible = true
                mapState.routeData = cachedRoute  // Fix: Set route data for arrival time
            } else {
                mapState.userRoute = nil
                mapState.isRouteVisible = false
                mapState.routeData = nil
            }
            return
        }
        
        appLog("BalloonTracker: Calculating new route", category: .general, level: .info)
        
        // Calculate route using Apple Maps
        do {
            let routeData = try await routeCalculationService.calculateRoute(
                from: userLocation,
                to: landingPoint,
                transportMode: mapState.transportMode
            )
            
            // Update map state with route
            if let routePath = routeData.path, !routePath.isEmpty {
                mapState.userRoute = MKPolyline(coordinates: routePath, count: routePath.count)
                mapState.isRouteVisible = true
                mapState.routeData = routeData
                
                // Cache the route
                await routingCache.set(key: routeKey, value: routeData)
                
                appLog("BalloonTracker: Route calculated successfully - \(String(format: "%.1f", routeData.distance/1000))km, \(Int(routeData.expectedTravelTime/60))min", category: .general, level: .info)
            } else {
                mapState.userRoute = nil
                mapState.isRouteVisible = false
                appLog("BalloonTracker: Route calculation returned empty path", category: .general, level: .error)
            }
            
        } catch {
            appLog("BalloonTracker: Route calculation failed: \(error)", category: .general, level: .error)
            mapState.userRoute = nil
            mapState.isRouteVisible = false
        }
        
        lastRouteCalculationTime = Date()
    }
    
    private func updateCameraToShowAllAnnotations() {
        // Camera update to show all annotations with appropriate zoom level
        let allCoordinates = mapState.annotations.map { $0.coordinate }
        guard !allCoordinates.isEmpty else { 
            appLog("BalloonTracker: No annotations to show on map", category: .general, level: .debug)
            return 
        }
        
        // Include user location in calculations if available
        var coordinates = allCoordinates
        if let userLocation = mapState.userLocation {
            coordinates.append(CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude))
        }
        
        // Calculate bounding region
        let minLat = coordinates.map { $0.latitude }.min()!
        let maxLat = coordinates.map { $0.latitude }.max()!
        let minLon = coordinates.map { $0.longitude }.min()!
        let maxLon = coordinates.map { $0.longitude }.max()!
        
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        
        // Calculate span with padding and minimum zoom constraints
        let latSpan = max((maxLat - minLat) * 1.4, 0.01) // Add 40% padding, minimum 0.01 degrees
        let lonSpan = max((maxLon - minLon) * 1.4, 0.01) // Add 40% padding, minimum 0.01 degrees
        
        let span = MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
        
        mapState.region = MKCoordinateRegion(center: center, span: span)
        
        appLog("BalloonTracker: Updated camera to show \(coordinates.count) points - center: \(center), span: \(span)", category: .general, level: .info)
    }
    
    // MARK: - Persistence Data Loading (Per FSD)
    
    private func loadPersistenceData() {
        appLog("BalloonTracker: Loading persistence data per FSD requirements", category: .general, level: .info)
        
        // 1. Prediction parameters - already loaded in UserSettings ✅
        
        // 2. Historic track data - load and add to current track if sonde matches
        // Note: This will be handled by BalloonTrackService when first telemetry arrives
        
        // 3. Landing point (if available) - load for current sonde if available
        if let savedLandingPoint = persistenceService.loadLandingPoint(sondeName: "current") {
            mapState.landingPoint = savedLandingPoint
            appLog("BalloonTracker: Loaded saved landing point: \(savedLandingPoint)", category: .general, level: .debug)
        }
        
        // 4. Sync landing point from LandingPointService (may have clipboard data)
        if let serviceLandingPoint = landingPointService.validLandingPoint {
            mapState.landingPoint = serviceLandingPoint
            appLog("BalloonTracker: Synced landing point from service: \(serviceLandingPoint)", category: .general, level: .info)
        }
        
        appLog("BalloonTracker: Persistence data loading complete", category: .general, level: .info)
        
        // Update annotations with current data (user location + landing point, even without telemetry)
        updateAnnotationsWithoutTelemetry()
    }
    
    private func updateAnnotationsWithoutTelemetry() {
        var annotations: [MapAnnotationItem] = []
        
        // Add user annotation if available
        if let userLocation = mapState.userLocation {
            let userAnnotation = MapAnnotationItem(
                coordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
                kind: .user
            )
            annotations.append(userAnnotation)
        }
        
        // Add landing point if available
        if let landingPoint = getCurrentLandingPoint() {
            let landingAnnotation = MapAnnotationItem(coordinate: landingPoint, kind: .landing)
            annotations.append(landingAnnotation)
        }
        
        mapState.annotations = annotations
        appLog("BalloonTracker: Updated annotations without telemetry - \(annotations.count) annotations", category: .general, level: .info)
    }
    
    // MARK: - Helper Methods
    
    private func generateCacheKey(_ telemetry: TelemetryData) -> String {
        // Keep the valuable cache key generation logic
        let lat = round(telemetry.latitude * 10) / 10  // 0.1 degree precision
        let lon = round(telemetry.longitude * 10) / 10
        let alt = round(telemetry.altitude / 500) * 500  // 500m altitude buckets
        let timeSlot = Int(Date().timeIntervalSince1970 / 600) * 600  // 10-minute slots
        
        return "\(telemetry.sondeName)-\(lat)-\(lon)-\(Int(alt))-\(timeSlot)"
    }
    
    private func generateRouteCacheKey(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D, _ transportMode: TransportationMode) -> String {
        // Keep the valuable route cache key generation
        let fromLat = round(from.latitude * 100) / 100  // 0.01 degree precision
        let fromLon = round(from.longitude * 100) / 100
        let toLat = round(to.latitude * 100) / 100
        let toLon = round(to.longitude * 100) / 100
        let mode = transportMode == .car ? "car" : "bike"
        
        return "route-\(fromLat)-\(fromLon)-\(toLat)-\(toLon)-\(mode)"
    }
    
    private func getCurrentLandingPoint() -> CLLocationCoordinate2D? {
        // Try to get from landing point service first, fall back to map state
        return landingPointService.validLandingPoint ?? mapState.landingPoint
    }
    
    func getAllBalloonTrackPoints() -> [BalloonTrackPoint] {
        // Get from balloon track service
        return balloonTrackService.getAllTrackPoints()
    }
    
    // MARK: - Automatic Descent Rate Calculation
    
    private func calculateAutomaticDescentRate(_ telemetry: TelemetryData) {
        appLog("BalloonTracker: calculateAutomaticDescentRate called - altitude: \(Int(telemetry.altitude))m", category: .general, level: .debug)
        
        // Only calculate if below 10000m altitude
        guard telemetry.altitude < 10000 else {
            appLog("BalloonTracker: Altitude \(Int(telemetry.altitude))m above 10000m - will start calculating descent rate when below 10000m", category: .general, level: .debug)
            return
        }
        
        // Get current balloon track from the track service
        let trackPoints = balloonTrackService.getAllTrackPoints()
        
        // Find historical reference point (60 seconds ago)
        let currentTime = Date() // Use current time since telemetry doesn't have timestamp
        let targetHistoricalTime = currentTime.addingTimeInterval(-60.0) // 60 seconds ago
        
        // Find the first point that is older than 60 seconds
        var historicalPoint: BalloonTrackPoint? = nil
        for point in trackPoints.reversed() { // Start from most recent
            if point.timestamp < targetHistoricalTime {
                historicalPoint = point
                break
            }
        }
        
        guard let historical = historicalPoint else {
            appLog("BalloonTracker: No historical point found from 60 seconds ago - need more track history", category: .general, level: .debug)
            return
        }
        
        // Calculate descent rate: (current_altitude - historical_altitude) / time_difference
        let altitudeDiff = telemetry.altitude - historical.altitude
        let timeDiff = currentTime.timeIntervalSince(historical.timestamp)
        
        guard timeDiff > 0 else {
            appLog("BalloonTracker: Invalid time difference for descent rate calculation", category: .general, level: .error)
            return
        }
        
        let instantDescentRate = altitudeDiff / timeDiff // m/s (negative when descending)
        
        appLog("BalloonTracker: Calculated instant descent rate: \(String(format: "%.2f", instantDescentRate)) m/s (alt: \(Int(telemetry.altitude))m -> \(Int(historical.altitude))m over \(String(format: "%.1f", timeDiff))s)", category: .general, level: .debug)
        
        // Add to history for smoothing (keep up to 20 values)
        descentRateHistory.append(instantDescentRate)
        if descentRateHistory.count > 20 {
            descentRateHistory.removeFirst()
        }
        
        // Calculate smoothed descent rate (average of up to 20 values)
        let smoothedRate = descentRateHistory.reduce(0.0, +) / Double(descentRateHistory.count)
        
        appLog("BalloonTracker: Smoothed descent rate: \(String(format: "%.2f", smoothedRate)) m/s (based on \(descentRateHistory.count) values)", category: .general, level: .info)
        
        // Update map state with smoothed descent rate
        mapState.smoothedDescentRate = smoothedRate
    }
}
