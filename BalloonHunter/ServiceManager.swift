import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import OSLog

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

