// PredictionPolicy.swift
// Phase 3: Event-driven prediction logic
// Centralized trigger logic for prediction requests

import Foundation
import Combine
import CoreLocation
import OSLog

@MainActor
final class PredictionPolicy: ObservableObject {
    private let predictionService: PredictionService
    private let predictionCache: PredictionCache
    private let mapState: MapState
    private let domainModel: DomainModel?
    
    private var cancellables = Set<AnyCancellable>()
    private var lastPredictionTime = Date.distantPast
    
    // Simple timing constants (extracted from BalloonTracker)
    private let predictionInterval: TimeInterval = 60  // Every 60 seconds per requirements
    
    init(predictionService: PredictionService, predictionCache: PredictionCache, mapState: MapState, domainModel: DomainModel? = nil) {
        self.predictionService = predictionService
        self.predictionCache = predictionCache
        self.mapState = mapState
        self.domainModel = domainModel
        
        setupEventSubscriptions()
        appLog("🎯 PredictionPolicy: Initialized event-driven prediction policy", category: .general, level: .info)
    }
    
    private func setupEventSubscriptions() {
        // Subscribe to balloon position events for automatic prediction triggering
        EventBus.shared.balloonPositionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] positionEvent in
                self?.handleBalloonPosition(positionEvent)
            }
            .store(in: &cancellables)
        
        // Subscribe to manual prediction requests from UI
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uiEvent in
                if case .manualPredictionTriggered = uiEvent {
                    self?.handleManualPredictionRequest()
                }
            }
            .store(in: &cancellables)
        
        // Subscribe to prediction requests from other sources
        EventBus.shared.predictionRequestPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                self?.handlePredictionRequest(request)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Event Handlers
    
    private func handleBalloonPosition(_ event: BalloonPositionEvent) {
        let telemetry = event.telemetry
        appLog("🎯 PredictionPolicy: Evaluating prediction need for \(event.balloonId)", category: .general, level: .debug)
        
        if shouldRequestPrediction(telemetry) {
            appLog("🎯 PredictionPolicy: Prediction needed - creating request", category: .general, level: .info)
            
            // Create and publish prediction request
            let request = PredictionRequest(
                telemetry: telemetry,
                userSettings: getUserSettings(),
                measuredDescentRate: getMeasuredDescentRate(),
                force: false
            )
            
            EventBus.shared.publishPredictionRequest(request)
        } else {
            appLog("🎯 PredictionPolicy: Prediction not needed yet", category: .general, level: .debug)
        }
    }
    
    private func handleManualPredictionRequest() {
        appLog("🎯 PredictionPolicy: Manual prediction requested", category: .general, level: .info)
        
        // Get current telemetry for manual prediction
        guard let telemetry = mapState.balloonTelemetry else {
            appLog("🎯 PredictionPolicy: No telemetry available for manual prediction", category: .general, level: .error)
            return
        }
        
        // Create forced prediction request
        let request = PredictionRequest(
            telemetry: telemetry,
            userSettings: getUserSettings(),
            measuredDescentRate: getMeasuredDescentRate(),
            force: true
        )
        
        EventBus.shared.publishPredictionRequest(request)
    }
    
    private func handlePredictionRequest(_ request: PredictionRequest) {
        appLog("🎯 PredictionPolicy: Processing prediction request \(request.requestId)", category: .general, level: .info)
        
        Task {
            await processPredictionRequest(request)
        }
    }
    
    // MARK: - Prediction Logic
    
    private func shouldRequestPrediction(_ telemetry: TelemetryData, force: Bool = false) -> Bool {
        if force {
            appLog("🎯 PredictionPolicy: Prediction forced", category: .general, level: .debug)
            return true
        }
        
        // Simple time-based trigger (extracted from BalloonTracker)
        let timeSinceLastPrediction = Date().timeIntervalSince(lastPredictionTime)
        let shouldTrigger = timeSinceLastPrediction > predictionInterval
        
        appLog("🎯 PredictionPolicy: shouldRequestPrediction - timeSince: \(timeSinceLastPrediction)s, interval: \(predictionInterval)s, result: \(shouldTrigger)", category: .general, level: .debug)
        
        return shouldTrigger
    }
    
    private func processPredictionRequest(_ request: PredictionRequest) async {
        let telemetry = request.telemetry
        
        // Check cache first
        let cacheKey = generateCacheKey(telemetry)
        if let cachedPrediction = await predictionCache.get(key: cacheKey), !request.force {
            appLog("🎯 PredictionPolicy: Using cached prediction for \(telemetry.sondeName)", category: .general, level: .info)
            let response = PredictionResponse(cached: cachedPrediction, requestId: request.requestId)
            EventBus.shared.publishPredictionResponse(response)
            return
        }
        
        do {
            // Call prediction service
            appLog("🎯 PredictionPolicy: Calling prediction service for \(telemetry.sondeName)", category: .general, level: .info)
            
            let predictionData = try await predictionService.fetchPrediction(
                telemetry: telemetry,
                userSettings: request.userSettings,
                measuredDescentRate: request.measuredDescentRate ?? abs(telemetry.verticalSpeed),
                cacheKey: cacheKey
            )
            
            // Cache the result
            await predictionCache.set(key: cacheKey, value: predictionData)
            
            // Update last prediction time
            lastPredictionTime = Date()
            
            // Send success response
            let response = PredictionResponse(success: predictionData, requestId: request.requestId)
            EventBus.shared.publishPredictionResponse(response)
            
            appLog("🎯 PredictionPolicy: Prediction completed successfully", category: .general, level: .info)
            
        } catch {
            appLog("🎯 PredictionPolicy: Prediction failed: \(error)", category: .general, level: .error)
            
            // Send failure response
            let response = PredictionResponse(failure: error, requestId: request.requestId)
            EventBus.shared.publishPredictionResponse(response)
        }
    }
    
    // MARK: - Helper Methods
    
    private func generateCacheKey(_ telemetry: TelemetryData) -> String {
        // Use same cache key generation as BalloonTracker
        let latRounded = (telemetry.latitude * 1000).rounded() / 1000  // 3 decimal places (~111m accuracy)
        let lonRounded = (telemetry.longitude * 1000).rounded() / 1000
        let altRounded = (telemetry.altitude / 100).rounded() * 100    // 100m altitude buckets
        
        return "\(telemetry.sondeName)-\(latRounded)-\(lonRounded)-\(Int(altRounded))"
    }
    
    private func getUserSettings() -> UserSettings {
        // Get user settings from the current system
        // TODO: This should come from dependency injection in the future
        UserSettings()
    }
    
    private func getMeasuredDescentRate() -> Double? {
        // Get measured descent rate from MapState
        return mapState.smoothedDescentRate
    }
}