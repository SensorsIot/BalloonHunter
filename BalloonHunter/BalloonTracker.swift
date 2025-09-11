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
    let domainModel: DomainModel?        // Phase 2: Parallel domain model for comparison
    
    // KEEP: Core services (simplified)
    lazy var currentLocationService = CurrentLocationService()
    lazy var bleCommunicationService = BLECommunicationService(persistenceService: self.persistenceService)
    lazy var predictionService = PredictionService()
    
    // Phase 3: Independent Balloon Track Prediction Service
    lazy var balloonTrackPredictionService = BalloonTrackPredictionService(
        predictionService: self.predictionService,
        predictionCache: self.predictionCache,
        mapState: self.mapState,
        userSettings: self.userSettings,
        landingPointService: self.landingPointService,
        balloonTrackService: self.balloonTrackService
    )
    
    // REQUIRED: Services that generate the events and manage data
    lazy var balloonPositionService = BalloonPositionService(bleService: self.bleCommunicationService)
    lazy var balloonTrackService = BalloonTrackService(persistenceService: self.persistenceService, balloonPositionService: self.balloonPositionService)
    lazy var landingPointService = LandingPointService(balloonTrackService: self.balloonTrackService, predictionService: self.predictionService, persistenceService: self.persistenceService, predictionCache: self.predictionCache, mapState: self.mapState)
    lazy var routeCalculationService = RouteCalculationService(landingPointService: self.landingPointService, currentLocationService: self.currentLocationService)
    
    // REMOVE: Policy architecture, ModeStateMachine, PolicyScheduler
    // REPLACE: With direct service communication
    
    private var cancellables = Set<AnyCancellable>()
    private var lastRouteCalculationTime = Date.distantPast
    private var lastUserLocation: CLLocationCoordinate2D?
    private var lastLandingPoint: CLLocationCoordinate2D?
    private var lastUserLocationUpdateTime = Date.distantPast
    
    // Simple timing constants (replace complex mode machine)
    // Phase 3: Prediction timing moved to PredictionPolicy
    private let routeUpdateInterval: TimeInterval = 60  // Always 60 seconds
    private let significantMovementThreshold: Double = 100  // meters
    
    // User settings reference (for external access)
    var userSettings = UserSettings()
    
    // Automatic descent rate calculation
    private var descentRateHistory: [Double] = [] // Store up to 20 values for smoothing
    
    // Phase 2: Telemetry counter for comparison logging
    private var telemetryCounter = 0
    
    init(domainModel: DomainModel? = nil) {
        appLog("BalloonTracker: Initializing simplified architecture", category: .general, level: .info)
        
        // Initialize core infrastructure (keep what's valuable)
        self.persistenceService = PersistenceService()
        self.predictionCache = PredictionCache()
        self.routingCache = RoutingCache()
        self.mapState = MapState()
        self.domainModel = domainModel
        
        setupDirectSubscriptions()
        
        appLog("BalloonTracker: Simplified architecture initialized \(domainModel != nil ? "(with DomainModel)" : "")", category: .general, level: .info)
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
        
        // Phase 3: Start independent prediction service
        balloonTrackPredictionService.start()
        
        // Per FSD: Load persistence data after service initialization
        loadPersistenceData()
        
        // Setup manual prediction listener
        setupManualPredictionListener()
        
        appLog("BalloonTracker: All services initialized with direct calls (no EventBus)", category: .general, level: .info)
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
        
        // Phase 3: Prediction response handling
        EventBus.shared.predictionResponsePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                self?.handlePredictionResponse(response)
            }
            .store(in: &cancellables)
    }
    
    private func setupManualPredictionListener() {
        NotificationCenter.default.addObserver(
            forName: .manualPredictionRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.balloonTrackPredictionService.triggerManualPrediction()
            }
        }
    }
    
    // MARK: - Simplified Event Handlers
    
    private func handleBalloonPosition(_ event: BalloonPositionEvent) {
        let telemetry = event.telemetry
        
        appLog("BalloonTracker: Processing balloon position for \(event.balloonId)", category: .general, level: .debug)
        
        // 1. Update map state directly (no policy layers)
        updateMapWithBalloonPosition(telemetry)
        
        // 1b. Phase 2: Mirror balloon position in DomainModel
        if let domainModel = self.domainModel {
            telemetryCounter += 1
            domainModel.updateBalloonPosition(
                CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude),
                altitude: telemetry.altitude,
                climbRate: telemetry.verticalSpeed
            )
            domainModel.updateActiveSonde(telemetry.sondeName)
            
            // Phase 2: Compare every 10th telemetry update to verify consistency  
            if telemetryCounter % 10 == 0 {
                appLog("📊 Phase 2 Comparison (telemetry #\(telemetryCounter)): \(domainModel.statusSummary)", category: .general, level: .debug)
                domainModel.compareWithMapState(mapState)
            }
        }
        
        // 1. Process altitude-based descent/climb rate calculation
        if telemetry.altitude >= 10000 {
            // Above 10000m: use raw vertical speed as climb rate
            if let domainModel = self.domainModel {
                domainModel.balloon.climbRate = telemetry.verticalSpeed
            }
            appLog("BalloonTracker: Above 10000m (\(Int(telemetry.altitude))m) - using raw vertical speed: \(String(format: "%.2f", telemetry.verticalSpeed)) m/s", category: .general, level: .debug)
        } else {
            // Below 10000m: calculate smoothed descent rate
            calculateAutomaticDescentRate(telemetry)
        }
        
        // Phase 3: Notify independent prediction service
        Task {
            await balloonTrackPredictionService.handleStartupTelemetry(telemetry)
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
        
        // Phase 2: Mirror location in DomainModel
        if let domainModel = self.domainModel {
            let location = CLLocation(
                latitude: event.locationData.latitude,
                longitude: event.locationData.longitude
            )
            domainModel.updateUserLocation(location)
        }
        
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
    
    // Phase 3: Handle prediction responses from PredictionPolicy
    private func handlePredictionResponse(_ response: PredictionResponse) {
        switch response {
        case .success(let predictionData, let requestId, _):
            appLog("🎯 BalloonTracker: Received successful prediction response \(requestId)", category: .general, level: .info)
            updateMapWithPrediction(predictionData)
            
        case .cached(let predictionData, let requestId, _):
            appLog("🎯 BalloonTracker: Received cached prediction response \(requestId)", category: .general, level: .debug)
            updateMapWithPrediction(predictionData)
            
        case .failure(let error, let requestId, _):
            appLog("🎯 BalloonTracker: Prediction failed \(requestId): \(error)", category: .general, level: .error)
        }
    }
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .manualPredictionTriggered:
            // Phase 3: Manual predictions are now handled by PredictionPolicy
            // The PredictionPolicy subscribes to UIEvent and handles manual prediction requests
            break
            
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
    
    // Phase 3: REMOVED - Prediction logic migrated to PredictionPolicy
    // - shouldRequestPrediction() -> moved to PredictionPolicy.shouldRequestPrediction()
    // - requestPrediction() -> moved to PredictionPolicy.processPredictionRequest()
    // All prediction timing, caching, and service calls are now handled by PredictionPolicy
    // This provides better separation of concerns and event-driven architecture
    
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
        
        // Phase 2: Mirror landing point in DomainModel
        if let domainModel = self.domainModel, let landingPoint = prediction.landingPoint {
            domainModel.updateLandingPoint(landingPoint, source: "prediction")
        }
        
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
                print("🛣️ BalloonTracker: CACHED route set - \(routePath.count) coordinates, transport: \(mapState.transportMode)")
            } else {
                mapState.userRoute = nil
                mapState.isRouteVisible = false
                mapState.routeData = nil
                print("🛣️ BalloonTracker: CACHED route CLEARED - empty path")
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
                
                print("🛣️ BalloonTracker: NEW route set - \(routePath.count) coordinates, transport: \(mapState.transportMode)")
                appLog("BalloonTracker: Route calculated successfully - \(String(format: "%.1f", routeData.distance/1000))km, \(Int(routeData.expectedTravelTime/60))min", category: .general, level: .info)
            } else {
                mapState.userRoute = nil
                mapState.isRouteVisible = false
                print("🛣️ BalloonTracker: NEW route CLEARED - empty path")
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
            
            // Phase 2: Mirror in DomainModel
            if let domainModel = self.domainModel {
                domainModel.updateLandingPoint(savedLandingPoint, source: "persistence")
            }
        }
        
        // 4. Sync landing point from LandingPointService (may have clipboard data)
        if let serviceLandingPoint = landingPointService.validLandingPoint {
            mapState.landingPoint = serviceLandingPoint
            appLog("BalloonTracker: Synced landing point from service: \(serviceLandingPoint)", category: .general, level: .info)
            
            // Phase 2: Mirror in DomainModel
            if let domainModel = self.domainModel {
                domainModel.updateLandingPoint(serviceLandingPoint, source: "service")
            }
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
        // Only calculate if below 10000m altitude
        guard telemetry.altitude < 10000 else {
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
        
        // Sync smoothed descent rate to DomainModel for better ascent/descent detection
        if let domainModel = self.domainModel {
            domainModel.balloon.climbRate = smoothedRate
            print("🆕 BalloonTracker: Updated DomainModel with smoothed climb rate: \(String(format: "%.2f", smoothedRate)) m/s")
        }
    }
    
    // MARK: - Prediction Logic Now Handled by Independent BalloonTrackPredictionService
    // All prediction functionality moved to BalloonTrackPredictionService for better separation of concerns
}
