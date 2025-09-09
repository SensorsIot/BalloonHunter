import Foundation
import Combine
import CoreLocation
import OSLog

class RoutingPolicy {
    private let serviceManager: ServiceManager
    private let routeCalculationService: RouteCalculationService
    private let policyScheduler: PolicyScheduler
    private let routingCache: RoutingCache
    private var cancellables = Set<AnyCancellable>()
    private var lastUserLocation: CLLocationCoordinate2D? = nil
    private var lastBalloonLocation: CLLocationCoordinate2D? = nil
    private var lastCalculatedDistanceThreshold: Double? = nil
    private var currentMode: AppMode = .explore
    private var currentTransportationMode: TransportationMode = .car // Default to car
    private var routingVersion: Int = 0 // New property for routing version
    private var routeTimer: AnyCancellable? // Periodic route timer

    init(serviceManager: ServiceManager, routeCalculationService: RouteCalculationService, policyScheduler: PolicyScheduler, routingCache: RoutingCache) {
        self.serviceManager = serviceManager
        self.routeCalculationService = routeCalculationService
        self.policyScheduler = policyScheduler
        self.routingCache = routingCache
        setupSubscriptions()
        setupRouteTimer()
    }

    private func setupSubscriptions() {
        serviceManager.userLocationPublisher
            .sink { [weak self] event in
                guard let self = self else { return }
                self.handleUserLocationEvent(event.locationData)
            }
            .store(in: &cancellables)

        serviceManager.telemetryPublisher
            .sink { [weak self] event in
                guard let self = self else { return }
                self.handleTelemetryEvent(event.telemetryData)
            }
            .store(in: &cancellables)

        serviceManager.modeManager.$currentMode
            .sink { [weak self] mode in
                self?.currentMode = mode
            }
            .store(in: &cancellables)

        serviceManager.uiEventPublisher
            .sink { [weak self] event in
                guard let self = self else { return }
                if case .modeSwitched(let mode) = event {
                    self.currentTransportationMode = mode
                    Task { await self.triggerRouteCalculation(transportMode: mode) }
                }
            }
            .store(in: &cancellables)
    }

    private func handleUserLocationEvent(_ location: LocationData) {
        let currentUserLocation = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        if let lastLocation = lastUserLocation {
            let distance = CLLocation(latitude: currentUserLocation.latitude, longitude: currentUserLocation.longitude).distance(from: CLLocation(latitude: lastLocation.latitude, longitude: lastLocation.longitude))
            if distance > 100 { // Trigger if user moves >100 m
                Task { await self.triggerRouteCalculation(transportMode: self.currentTransportationMode) }
                self.lastUserLocation = currentUserLocation
            }
        } else {
            self.lastUserLocation = currentUserLocation
        }
        Task { await self.triggerRouteCalculation(transportMode: self.currentTransportationMode) } // Always check on location update for distance thresholds
    }

    private func handleTelemetryEvent(_ telemetry: TelemetryData) {
        let currentBalloonLocation = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
        if let lastLocation = lastBalloonLocation {
            let distance = CLLocation(latitude: currentBalloonLocation.latitude, longitude: currentBalloonLocation.longitude).distance(from: CLLocation(latitude: lastLocation.latitude, longitude: lastLocation.longitude))
            if distance > 100 { // Trigger if balloon moves >100 m
                Task { await self.triggerRouteCalculation(transportMode: self.currentTransportationMode) }
                self.lastBalloonLocation = currentBalloonLocation
            }
        } else {
            self.lastBalloonLocation = currentBalloonLocation
        }
        Task { await self.triggerRouteCalculation(transportMode: self.currentTransportationMode) } // Always check on telemetry update for distance thresholds
    }

    private func triggerRouteCalculation(transportMode: TransportationMode) async {
        self.routingVersion += 1 // Increment version for new request
        guard let userLocation = serviceManager.currentLocationService.locationData,
              let landingPoint = serviceManager.landingPointService.validLandingPoint else { return }

        let distanceToLanding = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude).distance(from: CLLocation(latitude: landingPoint.latitude, longitude: landingPoint.longitude))

        var shouldRecalculate = false
        let thresholds = [5000.0, 1000.0, 500.0] // 5km, 1km, 500m

        // Check distance thresholds
        if let lastThreshold = lastCalculatedDistanceThreshold {
            for threshold in thresholds {
                if distanceToLanding < threshold && lastThreshold >= threshold {
                    shouldRecalculate = true
                    break
                }
            }
        } else {
            shouldRecalculate = true // First calculation
        }
        self.lastCalculatedDistanceThreshold = distanceToLanding

        let cooldownDuration: TimeInterval
        switch currentMode {
        case .explore, .follow:
            cooldownDuration = 1.0
        case .finalApproach:
            cooldownDuration = 0.25 // Tighter cooldown in final approach
        }

        // Generate cache key
        let cacheKey = RoutingCache.makeKey(
            userCoordinate: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
            balloonCoordinate: landingPoint,
            mode: transportMode
        )

        // Check cache first
        if let cachedRoute = await routingCache.get(key: cacheKey) {
            if cachedRoute.version >= self.routingVersion { // Only use cached if its version is not older
                print("[RoutingPolicy] Cache hit for route (version \(cachedRoute.version)). Using cached data.")
                routeCalculationService.routeData = cachedRoute
                return
            } else {
                appLog("RoutingPolicy: Cached route (version \(cachedRoute.version)) is older than current request (version \(self.routingVersion)). Discarding.", category: .policy, level: .debug)
            }
        }

        // Check service health
        guard routeCalculationService.healthStatus == .healthy || routeCalculationService.healthStatus == .degraded else {
            print("[RoutingPolicy] RouteCalculationService is unhealthy. Skipping route calculation.")
            return
        }

        if shouldRecalculate {
            await policyScheduler.cooldown(key: "routing", cooldownDuration: cooldownDuration, operation: {
                Task {
                    appLog("Triggering route calculation...", category: .policy, level: .debug)
                    self.routeCalculationService.calculateRoute(
                        from: CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude),
                        to: landingPoint,
                        transportType: transportMode,
                        version: self.routingVersion
                    )
                    // Store result in cache and check version
                    if let newRoute = self.routeCalculationService.routeData {
                        if newRoute.version == self.routingVersion { // Only cache and use if version matches
                            await self.routingCache.set(key: cacheKey, value: newRoute)
                            appLog("RoutingPolicy: New route (version \(newRoute.version)) matches request version. Caching and using.", category: .policy, level: .debug)
                        } else {
                            appLog("RoutingPolicy: New route (version \(newRoute.version)) does NOT match request version (expected \(self.routingVersion)). Discarding.", category: .policy, level: .error)
                            // Optionally clear routeCalculationService.routeData if it was set with an old version
                            if self.routeCalculationService.routeData?.version != self.routingVersion {
                                self.routeCalculationService.routeData = nil
                            }
                        }
                    }
                }
            })
        }
    }

    private func setupRouteTimer() {
        routeTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.handleTimerTrigger()
            }
    }

    private func handleTimerTrigger() {
        Task {
            await self.triggerRouteCalculation(transportMode: self.currentTransportationMode)
        }
    }
}
