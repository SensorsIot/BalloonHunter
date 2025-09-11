// Application.swift - DISABLED (DEAD CODE)
// Old ServiceManager architecture replaced by SimpleBalloonTracker
//
// NOTE: This entire file is commented out as it's replaced by SimpleBalloonTracker

/*
import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import OSLog

// MARK: - Application Logging

enum LogCategory: String {
    case event = "Event"
    case policy = "Policy"
    case service = "Service"
    case ui = "UI"
    case cache = "Cache"
    case general = "General"
    case persistence = "Persistence"
    case ble = "BLE"
    case lifecycle = "Lifecycle"
}

nonisolated func appLog(_ message: String, category: LogCategory, level: OSLogType = .default) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let timestamp = formatter.string(from: Date.now)
    let timestampedMessage = "[\(timestamp)] \(message)"
    
    let logger = Logger(subsystem: "com.yourcompany.BalloonHunter", category: category.rawValue)
    
    // Use literal string formatting to avoid decode issues with special characters
    switch level {
    case OSLogType.debug: logger.debug("\(timestampedMessage, privacy: .public)")
    case OSLogType.info: logger.info("\(timestampedMessage, privacy: .public)")
    case OSLogType.error: logger.error("\(timestampedMessage, privacy: .public)")
    case OSLogType.fault: logger.fault("\(timestampedMessage, privacy: .public)")
    default: logger.log("\(timestampedMessage, privacy: .public)")
    }
}


// MARK: - Service Manager

@MainActor
final class ServiceManager: ObservableObject {
    // Core infrastructure
    let persistenceService: PersistenceService
    let predictionCache: PredictionCache
    let routingCache: RoutingCache
    let policyScheduler: PolicyScheduler
    let mapState: MapState

    // Pure services (event producers)
    lazy var currentLocationService = CurrentLocationService()
    lazy var bleCommunicationService = BLECommunicationService(persistenceService: self.persistenceService)
    lazy var modeStateMachine = ModeStateMachine()
    
    // Position and tracking services (service layer architecture)
    lazy var balloonPositionService = BalloonPositionService(bleService: self.bleCommunicationService)
    lazy var balloonTrackService = BalloonTrackService(persistenceService: self.persistenceService, balloonPositionService: self.balloonPositionService)
    lazy var predictionService = PredictionService()
    lazy var landingPointService = LandingPointService(balloonTrackService: self.balloonTrackService, predictionService: self.predictionService, persistenceService: self.persistenceService, predictionCache: self.predictionCache)
    lazy var routeCalculationService = RouteCalculationService(landingPointService: self.landingPointService, currentLocationService: self.currentLocationService)
    
    // Policies (event consumers, decision logic) - now with proper service layer architecture
    lazy var predictionPolicy = PredictionPolicy(predictionService: self.predictionService, policyScheduler: self.policyScheduler, predictionCache: self.predictionCache, modeStateMachine: self.modeStateMachine, balloonPositionService: self.balloonPositionService)
    lazy var routingPolicy = RoutingPolicy(routeCalculationService: self.routeCalculationService, policyScheduler: self.policyScheduler, routingCache: self.routingCache, modeStateMachine: self.modeStateMachine, balloonPositionService: self.balloonPositionService)
    lazy var cameraPolicy = CameraPolicy(policyScheduler: self.policyScheduler, modeStateMachine: self.modeStateMachine, balloonPositionService: self.balloonPositionService)
    lazy var annotationPolicy = AnnotationPolicy(balloonTrackService: self.balloonTrackService, landingPointService: self.landingPointService, policyScheduler: self.policyScheduler)
    lazy var uiEventPolicy = UIEventPolicy(serviceManager: self)
    
    // Legacy components have been removed in Phase 3
    // Replaced by: ModeStateMachine, AnnotationPolicy, and simplified StartupView

    init() {
        appLog("ServiceManager: Initializing event-driven architecture", category: .general, level: .info)
        
        // 1. Initialize core infrastructure
        self.persistenceService = PersistenceService()
        self.predictionCache = PredictionCache()
        self.routingCache = RoutingCache()
        self.policyScheduler = PolicyScheduler()
        // MapState expects no arguments per its definition
        self.mapState = MapState()
        
        appLog("ServiceManager: Core infrastructure initialized", category: .general, level: .info)
    }
    
    func initializeEventDrivenFlow() {
        appLog("ServiceManager: Initializing event-driven flow", category: .general, level: .info)
        
        // Initialize services to start event production
        _ = currentLocationService
        _ = bleCommunicationService
        _ = modeStateMachine
        
        // Initialize position and tracking services (service layer architecture)
        _ = balloonPositionService
        _ = balloonTrackService
        _ = predictionService
        _ = landingPointService
        _ = routeCalculationService
        
        // Initialize policies to start event consumption
        _ = predictionPolicy
        _ = routingPolicy
        _ = cameraPolicy
        _ = annotationPolicy
        _ = uiEventPolicy
        
        appLog("ServiceManager: Event-driven architecture fully initialized", category: .general, level: .info)
    }
}

// MARK: - Application Lifecycle Management

protocol ApplicationLifecycleDelegate {
    func applicationDidBecomeActive()
    func applicationWillResignActive()
    func applicationDidEnterBackground()
    func applicationWillEnterForeground()
}

@MainActor
class ApplicationCoordinator: ObservableObject {
    @Published private(set) var isInitialized = false
    @Published private(set) var startupProgress: Double = 0.0
    @Published private(set) var startupMessage = "Starting up..."
    
    private var delegates: [ApplicationLifecycleDelegate] = []
    
    func addLifecycleDelegate(_ delegate: ApplicationLifecycleDelegate) {
        delegates.append(delegate)
    }
    
    func removeLifecycleDelegate(_ delegate: ApplicationLifecycleDelegate) {
        delegates.removeAll { $0 as AnyObject === delegate as AnyObject }
    }
    
    func completeStartup() {
        guard !isInitialized else { return }
        isInitialized = true
        NotificationCenter.default.post(name: .startupCompleted, object: nil)
        appLog("ApplicationCoordinator: Startup completed", category: .lifecycle, level: .info)
    }
    
    func updateStartupProgress(_ progress: Double, message: String) {
        startupProgress = progress
        startupMessage = message
        appLog("ApplicationCoordinator: Startup progress \(Int(progress * 100))% - \(message)", 
               category: .lifecycle, level: .debug)
    }
    
    // Lifecycle event forwarding
    func applicationDidBecomeActive() {
        delegates.forEach { $0.applicationDidBecomeActive() }
    }
    
    func applicationWillResignActive() {
        delegates.forEach { $0.applicationWillResignActive() }
    }
    
    func applicationDidEnterBackground() {
        delegates.forEach { $0.applicationDidEnterBackground() }
    }
    
    func applicationWillEnterForeground() {
        delegates.forEach { $0.applicationWillEnterForeground() }
    }
}
*/