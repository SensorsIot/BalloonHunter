import Foundation
import Combine
import CoreLocation
import OSLog
import MapKit

@MainActor
class PredictionPolicy {
    private let predictionService: PredictionService
    private let policyScheduler: PolicyScheduler
    private let predictionCache: PredictionCache
    private let modeStateMachine: ModeStateMachine
    private let balloonPositionService: BalloonPositionService
    private var cancellables = Set<AnyCancellable>()
    
    private var lastBalloonLocation: CLLocationCoordinate2D? = nil
    private var lastPredictionTime: Date = Date.distantPast
    private var predictionVersion: Int = 0
    private var currentTelemetry: TelemetryData? = nil
    private var currentUserLocation: LocationData? = nil
    private var lastEventTimes: [String: Date] = [:]

    init(predictionService: PredictionService, policyScheduler: PolicyScheduler, predictionCache: PredictionCache, modeStateMachine: ModeStateMachine, balloonPositionService: BalloonPositionService) {
        self.predictionService = predictionService
        self.policyScheduler = policyScheduler
        self.predictionCache = predictionCache
        self.modeStateMachine = modeStateMachine
        self.balloonPositionService = balloonPositionService
        setupSubscriptions()
        appLog("PredictionPolicy: Initialized with service layer architecture", category: .policy, level: .info)
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
    }
    
    private func handlePositionUpdate(_ positionEvent: BalloonPositionEvent) {
        let now = Date()
        let timeSinceLastTelemetry = lastEventTimes["telemetry"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["telemetry"] = now
        
        currentTelemetry = positionEvent.telemetry
        appLog("PredictionPolicy: Received position update for balloon \(positionEvent.balloonId), interval: \(String(format: "%.3f", timeSinceLastTelemetry))s", category: .policy, level: .debug)
        
        Task {
            await evaluatePredictionTrigger(telemetry: positionEvent.telemetry, reason: "position_update")
        }
    }
    
    private func handleUserLocationEvent(_ event: UserLocationEvent) {
        let now = Date()
        let timeSinceLastLocation = lastEventTimes["location"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["location"] = now
        
        currentUserLocation = event.locationData
        appLog("PredictionPolicy: Received user location update, interval: \(String(format: "%.3f", timeSinceLastLocation))s", category: .policy, level: .debug)
    }
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .manualPredictionTriggered:
            guard let telemetry = currentTelemetry else { return }
            Task {
                await evaluatePredictionTrigger(telemetry: telemetry, reason: "manual_trigger", force: true)
            }
        case .modeSwitched(let mode, _):
            // Mode changes might trigger different prediction cadences
            appLog("PredictionPolicy: Mode switched to \(mode.displayName)", category: .policy, level: .info)
        default:
            break
        }
    }

    private func evaluatePredictionTrigger(telemetry: TelemetryData, reason: String, force: Bool = false) async {
        let currentLocation = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
        
        // Get current mode configuration
        let modeConfig = modeStateMachine.getModeConfig(for: modeStateMachine.currentMode)
        
        // Check if we should trigger based on mode-specific intervals
        let timeSinceLastPrediction = Date().timeIntervalSince(lastPredictionTime)
        let shouldTriggerByTime = timeSinceLastPrediction >= modeConfig.predictionInterval
        
        // Check if balloon moved significantly
        var shouldTriggerByMovement = false
        if let lastLocation = lastBalloonLocation {
            let distance = CLLocation(latitude: currentLocation.latitude, longitude: currentLocation.longitude)
                .distance(from: CLLocation(latitude: lastLocation.latitude, longitude: lastLocation.longitude))
            shouldTriggerByMovement = distance > getMovementThreshold(for: modeStateMachine.currentMode)
        } else {
            shouldTriggerByMovement = true // First telemetry
        }
        
        let shouldTrigger = force || shouldTriggerByTime || shouldTriggerByMovement
        
        if shouldTrigger {
            appLog("PredictionPolicy: Triggering prediction - reason: \(reason), force: \(force), byTime: \(shouldTriggerByTime), byMovement: \(shouldTriggerByMovement)", 
                   category: .policy, level: .debug)
            
            await executePrediction(telemetry: telemetry, reason: reason)
        } else {
            appLog("PredictionPolicy: Skipping prediction - reason: \(reason), timeSince: \(String(format: "%.1f", timeSinceLastPrediction))s", 
                   category: .policy, level: .debug)
        }
    }
    
    private func getMovementThreshold(for mode: AppMode) -> Double {
        switch mode {
        case .explore: return 500.0 // 500m
        case .follow: return 200.0  // 200m
        case .finalApproach: return 50.0  // 50m
        }
    }

    private func executePrediction(telemetry: TelemetryData, reason: String) async {
        predictionVersion += 1
        
        let cooldownKey = "prediction-\(telemetry.sondeName)"
        let _ = modeStateMachine.getModeConfig(for: modeStateMachine.currentMode)
        
        // Generate cache key
        let cacheKey = PredictionCache.makeKey(
            balloonID: telemetry.sondeName,
            coordinate: CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude),
            altitude: telemetry.altitude,
            timeBucket: Date()
        )
        
        // Check cache first
        if let cachedPrediction = await predictionCache.get(key: cacheKey) {
            appLog("PredictionPolicy: Using cached prediction (v\(cachedPrediction.version))", category: .policy, level: .debug)
            publishPredictionUpdate(cachedPrediction, source: "cache")
            return
        }
        
        do {
            let decision = try await policyScheduler.withBackoff(key: cooldownKey) {
                guard let userSettings = try await self.getUserSettings() else {
                    throw PredictionPolicyError.noUserSettings
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
                
                // Update tracking
                self.lastBalloonLocation = CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
                self.lastPredictionTime = Date()
                
                // Publish the update
                await MainActor.run {
                    self.publishPredictionUpdate(prediction, source: "api")
                }
            }
            
            switch decision {
            case .executed:
                appLog("PredictionPolicy: Prediction executed successfully", category: .policy, level: .debug)
            case .skippedCooldown(let remainingTime):
                appLog("PredictionPolicy: Skipped due to cooldown (\(String(format: "%.1f", remainingTime))s remaining)", category: .policy, level: .debug)
            case .skippedBackoff(let nextAttemptTime):
                appLog("PredictionPolicy: Skipped due to backoff (next attempt: \(nextAttemptTime))", category: .policy, level: .debug)
            default:
                break
            }
        } catch {
            appLog("PredictionPolicy: Error executing prediction - \(error)", category: .policy, level: .error)
        }
    }
    
    private func publishPredictionUpdate(_ prediction: PredictionData, source: String) {
        var predictionPath: MKPolyline? = nil
        
        if let path = prediction.path, !path.isEmpty {
            predictionPath = MKPolyline(coordinates: path, count: path.count)
            predictionPath?.title = "predictionPath"
        }
        
        let update = MapStateUpdate(
            source: "PredictionPolicy",
            version: predictionVersion,
            predictionPath: predictionPath,
            predictionData: prediction
        )
        
        let now = Date()
        let timeSinceLastPublish = lastEventTimes["publish"].map { now.timeIntervalSince($0) } ?? 0
        lastEventTimes["publish"] = now
        
        EventBus.shared.publishMapStateUpdate(update)
        appLog("PredictionPolicy: Published prediction update from \(source) (v\(predictionVersion)), interval: \(String(format: "%.3f", timeSinceLastPublish))s", 
               category: .policy, level: .debug)
    }
    
    private func getUserSettings() async throws -> UserSettings? {
        // This would typically come from persistence or dependency injection
        return UserSettings.default
    }
}

enum PredictionPolicyError: Error {
    case noUserSettings
    case predictionFailed(String)
}
