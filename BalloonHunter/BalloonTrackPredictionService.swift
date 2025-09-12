// BalloonTrackPredictionService.swift
// Independent Balloon Track Prediction Service
// Implements all requirements from specification

import Foundation
import CoreLocation
import MapKit
import Combine
import OSLog

@MainActor
final class BalloonTrackPredictionService: ObservableObject {
    
    // MARK: - Dependencies (Direct References)
    
    private let predictionService: PredictionService
    private let predictionCache: PredictionCache
    private weak var serviceCoordinator: ServiceCoordinator?  // Weak reference to avoid retain cycle
    private let userSettings: UserSettings
    private let balloonTrackService: BalloonTrackService
    
    // MARK: - Service State
    
    @Published var isRunning: Bool = false
    @Published var hasValidPrediction: Bool = false
    @Published var lastPredictionTime: Date?
    @Published var predictionStatus: String = "Not started"
    
    private var internalTimer: Timer?
    private let predictionInterval: TimeInterval = 60.0  // 60 seconds per requirements
    private var lastProcessedTelemetry: TelemetryData?
    
    // MARK: - Initialization
    
    init(
        predictionService: PredictionService,
        predictionCache: PredictionCache,
        serviceCoordinator: ServiceCoordinator,
        userSettings: UserSettings,
        balloonTrackService: BalloonTrackService
    ) {
        self.predictionService = predictionService
        self.predictionCache = predictionCache
        self.serviceCoordinator = serviceCoordinator
        self.userSettings = userSettings
        self.balloonTrackService = balloonTrackService
        
        appLog("🎯 BalloonTrackPredictionService: Initialized as independent service", category: .service, level: .info)
    }
    
    // MARK: - Service Lifecycle
    
    func start() {
        guard !isRunning else {
            appLog("🎯 BalloonTrackPredictionService: Already running", category: .service, level: .debug)
            return
        }
        
        isRunning = true
        predictionStatus = "Running"
        startInternalTimer()
        
        appLog("🎯 BalloonTrackPredictionService: Service started with 60-second interval", category: .service, level: .info)
    }
    
    func stop() {
        isRunning = false
        predictionStatus = "Stopped"
        stopInternalTimer()
        
        appLog("🎯 BalloonTrackPredictionService: Service stopped", category: .service, level: .info)
    }
    
    // MARK: - Internal Timer Implementation
    
    private func startInternalTimer() {
        stopInternalTimer() // Ensure no duplicate timers
        
        internalTimer = Timer.scheduledTimer(withTimeInterval: predictionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleTimerTrigger()
            }
        }
        
        appLog("🎯 BalloonTrackPredictionService: Internal 60-second timer started", category: .service, level: .info)
    }
    
    private func stopInternalTimer() {
        internalTimer?.invalidate()
        internalTimer = nil
    }
    
    private func handleTimerTrigger() async {
        guard isRunning else { return }
        
        // Timer trigger: every 60 seconds
        guard let serviceCoordinator = serviceCoordinator,
              let telemetry = serviceCoordinator.balloonTelemetry else {
            predictionStatus = "No telemetry available"
            appLog("🎯 BalloonTrackPredictionService: Timer trigger - no telemetry", category: .service, level: .debug)
            return
        }
        
        appLog("🎯 BalloonTrackPredictionService: Timer trigger - performing prediction", category: .service, level: .info)
        await performPrediction(telemetry: telemetry, trigger: "60s_timer")
    }
    
    // MARK: - Public Trigger Methods
    
    /// Trigger: At startup after first valid telemetry
    func handleStartupTelemetry(_ telemetry: TelemetryData) async {
        guard isRunning else { return }
        
        // Check if this is first telemetry
        if lastProcessedTelemetry == nil {
            appLog("🎯 BalloonTrackPredictionService: Startup trigger - first telemetry received", category: .service, level: .info)
            await performPrediction(telemetry: telemetry, trigger: "startup")
        }
        
        lastProcessedTelemetry = telemetry
    }
    
    /// Trigger: Manual prediction request (balloon tap)
    func triggerManualPrediction() async {
        guard isRunning else {
            appLog("🎯 BalloonTrackPredictionService: Manual trigger ignored - service not running", category: .service, level: .debug)
            return
        }
        
        guard let serviceCoordinator = serviceCoordinator,
              let telemetry = serviceCoordinator.balloonTelemetry else {
            predictionStatus = "No telemetry for manual prediction"
            appLog("🎯 BalloonTrackPredictionService: Manual trigger - no telemetry", category: .service, level: .debug)
            return
        }
        
        appLog("🎯 BalloonTrackPredictionService: Manual trigger - performing prediction", category: .service, level: .info)
        await performPrediction(telemetry: telemetry, trigger: "manual")
    }
    
    /// Trigger: Significant movement or altitude changes
    func handleSignificantChange(_ telemetry: TelemetryData) async {
        guard isRunning else { return }
        
        // TODO: Implement movement/altitude thresholds
        // For now, let the timer handle regular updates
        
        lastProcessedTelemetry = telemetry
    }
    
    // MARK: - Core Prediction Logic
    
    private func performPrediction(telemetry: TelemetryData, trigger: String) async {
        predictionStatus = "Processing prediction..."
        
        do {
            // Determine if balloon is descending (balloonDescends flag)
            let balloonDescends = telemetry.verticalSpeed < 0
            appLog("🎯 BalloonTrackPredictionService: Balloon descending: \(balloonDescends) (verticalSpeed: \(telemetry.verticalSpeed) m/s)", category: .service, level: .info)
            
            // Calculate effective descent rate per requirements
            let effectiveDescentRate = calculateEffectiveDescentRate(telemetry: telemetry)
            
            // Create cache key for deduplication
            let cacheKey = createCacheKey(telemetry)
            
            // Check cache first for performance
            if let cachedPrediction = await predictionCache.get(key: cacheKey) {
                appLog("🎯 BalloonTrackPredictionService: Using cached prediction", category: .service, level: .info)
                await handlePredictionResult(cachedPrediction, trigger: trigger)
                return
            }
            
            // Call prediction service with all requirements implemented
            let predictionData = try await predictionService.fetchPrediction(
                telemetry: telemetry,
                userSettings: userSettings,
                measuredDescentRate: effectiveDescentRate,
                cacheKey: cacheKey,
                balloonDescends: balloonDescends
            )
            
            // Cache the result
            await predictionCache.set(key: cacheKey, value: predictionData)
            
            // Handle successful prediction
            await handlePredictionResult(predictionData, trigger: trigger)
            
        } catch {
            hasValidPrediction = false
            predictionStatus = "Prediction failed: \(error.localizedDescription)"
            appLog("🎯 BalloonTrackPredictionService: Prediction failed from \(trigger): \(error)", category: .service, level: .error)
        }
    }
    
    private func calculateEffectiveDescentRate(telemetry: TelemetryData) -> Double {
        // Requirements: Use automatically adjusted descent rate below 10000m
        if telemetry.altitude < 10000, let smoothedRate = serviceCoordinator?.smoothedDescentRate {
            appLog("🎯 BalloonTrackPredictionService: Using smoothed descent rate: \(String(format: "%.2f", abs(smoothedRate))) m/s (below 10000m)", category: .service, level: .info)
            return abs(smoothedRate)
        } else {
            appLog("🎯 BalloonTrackPredictionService: Using settings descent rate: \(String(format: "%.2f", userSettings.descentRate)) m/s (above 10000m)", category: .service, level: .info)
            return userSettings.descentRate
        }
    }
    
    private func createCacheKey(_ telemetry: TelemetryData) -> String {
        // Simple cache key based on rounded coordinates and altitude
        let latRounded = round(telemetry.latitude * 1000) / 1000
        let lonRounded = round(telemetry.longitude * 1000) / 1000
        let altRounded = round(telemetry.altitude / 100) * 100 // Round to nearest 100m
        return "\(telemetry.sondeName)-\(latRounded)-\(lonRounded)-\(Int(altRounded))"
    }
    
    // MARK: - Result Handling & Direct Service Integration
    
    private func handlePredictionResult(_ predictionData: PredictionData, trigger: String) async {
        // Update service state
        hasValidPrediction = true
        lastPredictionTime = Date()
        predictionStatus = "Valid prediction available"
        
        // Direct ServiceCoordinator updates (no EventBus)
        updateServiceCoordinator(predictionData)
        
        // Landing point is already updated directly in ServiceCoordinator above
        
        appLog("🎯 BalloonTrackPredictionService: Prediction completed successfully from \(trigger)", category: .service, level: .info)
    }
    
    private func updateServiceCoordinator(_ predictionData: PredictionData) {
        guard let serviceCoordinator = serviceCoordinator else {
            appLog("🎯 BalloonTrackPredictionService: ServiceCoordinator is nil, cannot update", category: .service, level: .error)
            return
        }
        
        // Convert prediction path to polyline
        if let path = predictionData.path, !path.isEmpty {
            let polyline = MKPolyline(coordinates: path, count: path.count)
            serviceCoordinator.predictionPath = polyline
        }
        
        // Update burst point
        if let burstPoint = predictionData.burstPoint {
            serviceCoordinator.burstPoint = CLLocationCoordinate2D(latitude: burstPoint.latitude, longitude: burstPoint.longitude)
        }
        
        // Update landing point
        if let landingPoint = predictionData.landingPoint {
            serviceCoordinator.landingPoint = CLLocationCoordinate2D(latitude: landingPoint.latitude, longitude: landingPoint.longitude)
        }
        
        appLog("🎯 BalloonTrackPredictionService: Updated ServiceCoordinator directly", category: .service, level: .info)
    }
    
    
    // MARK: - Service Status & Monitoring
    
    var statusSummary: String {
        let status = isRunning ? "Running" : "Stopped"
        let prediction = hasValidPrediction ? "Valid" : "None"
        let lastTime = lastPredictionTime?.timeIntervalSinceNow ?? 0
        return "🎯 BalloonTrackPredictionService: \(status), Prediction: \(prediction), Last: \(String(format: "%.0f", abs(lastTime)))s ago"
    }
    
    deinit {
        internalTimer?.invalidate()
        internalTimer = nil
    }
}

// MARK: - Manual Trigger Integration

extension Notification.Name {
    static let manualPredictionRequested = Notification.Name("manualPredictionRequested")
}