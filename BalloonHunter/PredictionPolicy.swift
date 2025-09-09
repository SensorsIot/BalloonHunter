import Foundation
import Combine
import CoreLocation
import OSLog

class PredictionPolicy {
    private let serviceManager: ServiceManager
    private let predictionService: PredictionService
    private let policyScheduler: PolicyScheduler
    private let predictionCache: PredictionCache
    private var cancellables = Set<AnyCancellable>()
    private var lastBalloonLocation: CLLocationCoordinate2D? = nil
    private var lastBalloonBearing: CLLocationDirection? = nil // New property for bearing
    private var currentMode: AppMode = .explore
    private var predictionTimer: AnyCancellable? // New property for the timer
    private var predictionVersion: Int = 0 // New property for prediction version

    init(serviceManager: ServiceManager, predictionService: PredictionService, policyScheduler: PolicyScheduler, predictionCache: PredictionCache) {
        self.serviceManager = serviceManager
        self.predictionService = predictionService
        self.policyScheduler = policyScheduler
        self.predictionCache = predictionCache
        setupSubscriptions()
        setupPredictionTimer()
    }

    private func setupPredictionTimer() {
        predictionTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if let telemetry = self.serviceManager.bleCommunicationService.latestTelemetry {
                    appLog("Prediction timer fired. Triggering prediction.", category: .policy, level: .debug)
                    self.predictionVersion += 1
                    Task { await self.triggerPrediction(telemetry: telemetry, force: true, version: self.predictionVersion) }
                }
            }
    }

    private func setupSubscriptions() {
        serviceManager.telemetryPublisher
            .sink { [weak self] event in
                guard let self = self else { return }
                self.handleTelemetryEvent(event.telemetryData)
            }
            .store(in: &cancellables)

        serviceManager.uiEventPublisher
            .sink { [weak self] event in
                guard let self = self else { return }
                self.handleUIEvent(event)
            }
            .store(in: &cancellables)

        serviceManager.modeManager.$currentMode
            .sink { [weak self] mode in
                self?.currentMode = mode
            }
            .store(in: &cancellables)
    }

    private func handleTelemetryEvent(_ telemetry: TelemetryData) {
        let currentBalloonLocation = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)

        var shouldTriggerPrediction = false

        if let lastLocation = lastBalloonLocation {
            let distance = CLLocation(latitude: currentBalloonLocation.latitude, longitude: currentBalloonLocation.longitude).distance(from: CLLocation(latitude: lastLocation.latitude, longitude: lastLocation.longitude))
            
            // Calculate bearing change
            let currentBearing = lastLocation.bearing(to: currentBalloonLocation)
            if let lastBearing = lastBalloonBearing {
                let bearingChange = abs(currentBearing - lastBearing)
                if bearingChange > 10 { // Trigger if bearing changes >10 degrees
                    appLog("PredictionPolicy: Triggered by bearing change: \(bearingChange) degrees.", category: .policy, level: .debug)
                    shouldTriggerPrediction = true
                }
            }

            if distance > 100 { // Trigger if balloon moves >100 m
                appLog("PredictionPolicy: Triggered by distance change: \(distance) meters.", category: .policy, level: .debug)
                shouldTriggerPrediction = true
            }

            if shouldTriggerPrediction {
                self.predictionVersion += 1
                Task { await self.triggerPrediction(telemetry: telemetry, force: false, version: self.predictionVersion) }
            }
        } else {
            // First telemetry, trigger prediction
            appLog("PredictionPolicy: Triggered by first telemetry.", category: .policy, level: .debug)
            shouldTriggerPrediction = true
        }

        if shouldTriggerPrediction {
            self.lastBalloonLocation = currentBalloonLocation
            // Only update lastBalloonBearing if a significant movement occurred to avoid noise
            if let lastLocation = lastBalloonLocation, lastLocation.latitude != currentBalloonLocation.latitude || lastLocation.longitude != currentBalloonLocation.longitude {
                self.lastBalloonBearing = lastBalloonLocation?.bearing(to: currentBalloonLocation)
            }
        } else if lastBalloonLocation == nil { // Handle initial case where no trigger happened yet
            self.lastBalloonLocation = currentBalloonLocation
            self.lastBalloonBearing = currentBalloonLocation.bearing(to: currentBalloonLocation) // Initial bearing (can be arbitrary)
        }

        // If no trigger happened, but it's the first telemetry, ensure location and bearing are set
        if lastBalloonLocation == nil {
            self.lastBalloonLocation = currentBalloonLocation
            self.lastBalloonBearing = currentBalloonLocation.bearing(to: currentBalloonLocation)
        }
    }

    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .manualPredictionTriggered:
            // Manual trigger should always force a prediction if telemetry is available
            if let telemetry = serviceManager.bleCommunicationService.latestTelemetry {
                self.predictionVersion += 1
                Task { await self.triggerPrediction(telemetry: telemetry, force: true, version: self.predictionVersion) }
            }
        case .annotationSelected(let item):
            // If a balloon annotation is selected, warm-start prediction immediately
            if item.kind == .balloon, let telemetry = serviceManager.bleCommunicationService.latestTelemetry {
                self.predictionVersion += 1
                Task { await self.triggerPrediction(telemetry: telemetry, force: true, version: self.predictionVersion) }
            }
        default:
            break
        }
    }

    private func triggerPrediction(telemetry: TelemetryData, force: Bool = false, version: Int) async {
        let cooldownDuration: TimeInterval
        switch currentMode {
        case .explore, .follow:
            cooldownDuration = 3.0
        case .finalApproach:
            cooldownDuration = 1.0
        }

        // Generate cache key
        let cacheKey = PredictionCache.makeKey(
            balloonID: telemetry.sondeName,
            coordinate: CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude),
            altitude: telemetry.altitude,
            timeBucket: Date() // Use current time for bucket
        )

        // Check cache first
        if !force, let cachedPrediction = await predictionCache.get(key: cacheKey) {
            if cachedPrediction.version >= version { // Only use cached if its version is not older
                print("[PredictionPolicy] Cache hit for prediction (version \(cachedPrediction.version)). Using cached data.")
                predictionService.predictionData = cachedPrediction
                return
            } else {
                appLog("PredictionPolicy: Cached prediction (version \(cachedPrediction.version)) is older than current request (version \(version)). Discarding.", category: .policy, level: .debug)
            }
        }

        // Check service health
        guard predictionService.healthStatus == .healthy || predictionService.healthStatus == .degraded else {
            print("[PredictionPolicy] PredictionService is unhealthy. Skipping prediction.")
            return
        }

        await policyScheduler.cooldown(key: "prediction", cooldownDuration: cooldownDuration, operation: {
            guard let userSettings = self.serviceManager.persistenceService.readPredictionParameters() else { return }
            appLog("Triggering prediction...", category: .policy, level: .debug)
            await self.predictionService.fetchPrediction(telemetry: telemetry, userSettings: userSettings, version: version)
            // Store result in cache and check version
            if let newPrediction = self.predictionService.predictionData {
                if newPrediction.version == version { // Only cache and use if version matches
                    await self.predictionCache.set(key: cacheKey, value: newPrediction)
                    appLog("PredictionPolicy: New prediction (version \(newPrediction.version)) matches request version. Caching and using.", category: .policy, level: .debug)
                } else {
                    appLog("PredictionPolicy: New prediction (version \(newPrediction.version)) does NOT match request version (expected \(version)). Discarding.", category: .policy, level: .error)
                    // Optionally clear predictionService.predictionData if it was set with an old version
                    if self.predictionService.predictionData?.version != version {
                        self.predictionService.predictionData = nil
                    }
                }
            }
        })
    }
}
