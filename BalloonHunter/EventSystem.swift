import Foundation
import Combine
import MapKit
import OSLog

// MARK: - Event Bus

@MainActor
final class EventBus: ObservableObject {
    static let shared = EventBus()
    
    let telemetryPublisher = PassthroughSubject<TelemetryEvent, Never>()
    let userLocationPublisher = PassthroughSubject<UserLocationEvent, Never>()
    let uiEventPublisher = PassthroughSubject<UIEvent, Never>()
    let mapStateUpdatePublisher = PassthroughSubject<MapStateUpdate, Never>()
    let serviceHealthPublisher = PassthroughSubject<ServiceHealthEvent, Never>()
    let balloonLandingPublisher = PassthroughSubject<BalloonLandingEvent, Never>()
    let balloonPositionPublisher = PassthroughSubject<BalloonPositionEvent, Never>()
    let telemetryAvailabilityPublisher = PassthroughSubject<TelemetryAvailabilityEvent, Never>()
    
    private init() {}
    
    func publishTelemetry(_ event: TelemetryEvent) {
        telemetryPublisher.send(event)
    }
    
    func publishUserLocation(_ event: UserLocationEvent) {
        userLocationPublisher.send(event)
    }
    
    func publishUIEvent(_ event: UIEvent) {
        uiEventPublisher.send(event)
    }
    
    func publishMapStateUpdate(_ update: MapStateUpdate) {
        mapStateUpdatePublisher.send(update)
    }
    
    func publishServiceHealth(_ event: ServiceHealthEvent) {
        serviceHealthPublisher.send(event)
    }
    
    func publishBalloonLanding(_ event: BalloonLandingEvent) {
        balloonLandingPublisher.send(event)
    }
    
    func publishBalloonPosition(_ event: BalloonPositionEvent) {
        balloonPositionPublisher.send(event)
    }
    
    func publishTelemetryAvailability(_ event: TelemetryAvailabilityEvent) {
        telemetryAvailabilityPublisher.send(event)
    }
}

// MARK: - Event Types

struct TelemetryEvent: Equatable {
    let balloonId: String
    let telemetryData: TelemetryData
    let timestamp: Date
    
    init(telemetryData: TelemetryData) {
        self.balloonId = telemetryData.sondeName.isEmpty ? "unknown" : telemetryData.sondeName
        self.telemetryData = telemetryData
        self.timestamp = Date()
    }
    
    static func == (lhs: TelemetryEvent, rhs: TelemetryEvent) -> Bool {
        return lhs.balloonId == rhs.balloonId &&
               lhs.telemetryData == rhs.telemetryData &&
               abs(lhs.timestamp.timeIntervalSince(rhs.timestamp)) < 0.01
    }
}

struct UserLocationEvent: Equatable {
    let locationData: LocationData
    let timestamp: Date
    
    init(locationData: LocationData) {
        self.locationData = locationData
        self.timestamp = Date()
    }
    
    static func == (lhs: UserLocationEvent, rhs: UserLocationEvent) -> Bool {
        return lhs.locationData == rhs.locationData &&
               abs(lhs.timestamp.timeIntervalSince(rhs.timestamp)) < 0.01
    }
}

enum UIEvent: Equatable {
    case cameraRegionChanged(MKCoordinateRegion, timestamp: Date = Date())
    case annotationSelected(MapAnnotationItem, timestamp: Date = Date())
    case modeSwitched(AppMode, timestamp: Date = Date())
    case manualPredictionTriggered(timestamp: Date = Date())
    case transportModeChanged(TransportationMode, timestamp: Date = Date())
    case predictionVisibilityToggled(Bool, timestamp: Date = Date())
    case routeVisibilityToggled(Bool, timestamp: Date = Date())
    case headingModeToggled(Bool, timestamp: Date = Date())
    case buzzerMuteToggled(Bool, timestamp: Date = Date())
    case showAllAnnotationsRequested(timestamp: Date = Date())
    case landingPointSetRequested(timestamp: Date = Date())
    
    static func == (lhs: UIEvent, rhs: UIEvent) -> Bool {
        switch (lhs, rhs) {
        case let (.cameraRegionChanged(lhsRegion, lhsTime), .cameraRegionChanged(rhsRegion, rhsTime)):
            return lhsRegion.center.latitude == rhsRegion.center.latitude &&
                   lhsRegion.center.longitude == rhsRegion.center.longitude &&
                   lhsRegion.span.latitudeDelta == rhsRegion.span.latitudeDelta &&
                   lhsRegion.span.longitudeDelta == rhsRegion.span.longitudeDelta &&
                   abs(lhsTime.timeIntervalSince(rhsTime)) < 0.01
        case let (.annotationSelected(lhsItem, lhsTime), .annotationSelected(rhsItem, rhsTime)):
            return lhsItem == rhsItem && abs(lhsTime.timeIntervalSince(rhsTime)) < 0.01
        case let (.modeSwitched(lhsMode, lhsTime), .modeSwitched(rhsMode, rhsTime)):
            return lhsMode == rhsMode && abs(lhsTime.timeIntervalSince(rhsTime)) < 0.01
        case let (.manualPredictionTriggered(lhsTime), .manualPredictionTriggered(rhsTime)):
            return abs(lhsTime.timeIntervalSince(rhsTime)) < 0.01
        case let (.transportModeChanged(lhsMode, lhsTime), .transportModeChanged(rhsMode, rhsTime)):
            return lhsMode == rhsMode && abs(lhsTime.timeIntervalSince(rhsTime)) < 0.01
        case let (.predictionVisibilityToggled(lhsVisible, lhsTime), .predictionVisibilityToggled(rhsVisible, rhsTime)):
            return lhsVisible == rhsVisible && abs(lhsTime.timeIntervalSince(rhsTime)) < 0.01
        case let (.routeVisibilityToggled(lhsVisible, lhsTime), .routeVisibilityToggled(rhsVisible, rhsTime)):
            return lhsVisible == rhsVisible && abs(lhsTime.timeIntervalSince(rhsTime)) < 0.01
        case let (.headingModeToggled(lhsEnabled, lhsTime), .headingModeToggled(rhsEnabled, rhsTime)):
            return lhsEnabled == rhsEnabled && abs(lhsTime.timeIntervalSince(rhsTime)) < 0.01
        case let (.buzzerMuteToggled(lhsMuted, lhsTime), .buzzerMuteToggled(rhsMuted, rhsTime)):
            return lhsMuted == rhsMuted && abs(lhsTime.timeIntervalSince(rhsTime)) < 0.01
        case let (.showAllAnnotationsRequested(lhsTime), .showAllAnnotationsRequested(rhsTime)):
            return abs(lhsTime.timeIntervalSince(rhsTime)) < 0.01
        case let (.landingPointSetRequested(lhsTime), .landingPointSetRequested(rhsTime)):
            return abs(lhsTime.timeIntervalSince(rhsTime)) < 0.01
        default:
            return false
        }
    }
}

struct MapStateUpdate: Equatable {
    let source: String
    let version: Int
    let timestamp: Date
    let annotations: [MapAnnotationItem]?
    let balloonTrack: MKPolyline?
    let predictionPath: MKPolyline?
    let userRoute: MKPolyline?
    let region: MKCoordinateRegion?
    let cameraUpdate: CameraUpdate?
    
    // Additional data for DataPanelView
    let predictionData: PredictionData?
    let routeData: RouteData?
    let balloonTrackHistory: [TelemetryData]?
    let smoothedDescentRate: Double?
    
    init(source: String, 
         version: Int = 0,
         annotations: [MapAnnotationItem]? = nil,
         balloonTrack: MKPolyline? = nil,
         predictionPath: MKPolyline? = nil,
         userRoute: MKPolyline? = nil,
         region: MKCoordinateRegion? = nil,
         cameraUpdate: CameraUpdate? = nil,
         predictionData: PredictionData? = nil,
         routeData: RouteData? = nil,
         balloonTrackHistory: [TelemetryData]? = nil,
         smoothedDescentRate: Double? = nil) {
        self.source = source
        self.version = version
        self.timestamp = Date()
        self.annotations = annotations
        self.balloonTrack = balloonTrack
        self.predictionPath = predictionPath
        self.userRoute = userRoute
        self.region = region
        self.cameraUpdate = cameraUpdate
        self.predictionData = predictionData
        self.routeData = routeData
        self.balloonTrackHistory = balloonTrackHistory
        self.smoothedDescentRate = smoothedDescentRate
    }
    
    static func == (lhs: MapStateUpdate, rhs: MapStateUpdate) -> Bool {
        return lhs.source == rhs.source &&
               lhs.version == rhs.version &&
               abs(lhs.timestamp.timeIntervalSince(rhs.timestamp)) < 0.01 &&
               lhs.annotations == rhs.annotations &&
               lhs.region?.center.latitude == rhs.region?.center.latitude &&
               lhs.region?.center.longitude == rhs.region?.center.longitude &&
               lhs.region?.span.latitudeDelta == rhs.region?.span.latitudeDelta &&
               lhs.region?.span.longitudeDelta == rhs.region?.span.longitudeDelta &&
               lhs.cameraUpdate == rhs.cameraUpdate
    }
}

struct CameraUpdate: Equatable {
    let center: CLLocationCoordinate2D?
    let heading: CLLocationDirection?
    let distance: CLLocationDistance?
    let pitch: CGFloat?
    let animated: Bool
    
    init(center: CLLocationCoordinate2D? = nil,
         heading: CLLocationDirection? = nil,
         distance: CLLocationDistance? = nil,
         pitch: CGFloat? = nil,
         animated: Bool = true) {
        self.center = center
        self.heading = heading
        self.distance = distance
        self.pitch = pitch
        self.animated = animated
    }
    
    static func == (lhs: CameraUpdate, rhs: CameraUpdate) -> Bool {
        return lhs.center?.latitude == rhs.center?.latitude &&
               lhs.center?.longitude == rhs.center?.longitude &&
               lhs.heading == rhs.heading &&
               lhs.distance == rhs.distance &&
               lhs.pitch == rhs.pitch &&
               lhs.animated == rhs.animated
    }
}

struct ServiceHealthEvent: Equatable {
    let serviceName: String
    let health: ServiceHealth
    let message: String?
    let timestamp: Date
    
    init(serviceName: String, health: ServiceHealth, message: String? = nil) {
        self.serviceName = serviceName
        self.health = health
        self.message = message
        self.timestamp = Date()
    }
    
    static func == (lhs: ServiceHealthEvent, rhs: ServiceHealthEvent) -> Bool {
        return lhs.serviceName == rhs.serviceName &&
               lhs.health == rhs.health &&
               lhs.message == rhs.message &&
               abs(lhs.timestamp.timeIntervalSince(rhs.timestamp)) < 0.01
    }
}

struct BalloonLandingEvent: Equatable {
    let landingPosition: CLLocationCoordinate2D
    let landingTime: Date
    let sondeName: String
    let timestamp: Date
    
    init(landingPosition: CLLocationCoordinate2D, landingTime: Date, sondeName: String) {
        self.landingPosition = landingPosition
        self.landingTime = landingTime
        self.sondeName = sondeName
        self.timestamp = Date()
    }
    
    static func == (lhs: BalloonLandingEvent, rhs: BalloonLandingEvent) -> Bool {
        return lhs.landingPosition.latitude == rhs.landingPosition.latitude &&
               lhs.landingPosition.longitude == rhs.landingPosition.longitude &&
               lhs.sondeName == rhs.sondeName &&
               abs(lhs.landingTime.timeIntervalSince(rhs.landingTime)) < 0.01 &&
               abs(lhs.timestamp.timeIntervalSince(rhs.timestamp)) < 0.01
    }
}

struct TelemetryAvailabilityEvent: Equatable {
    let isAvailable: Bool
    let reason: String
    let timestamp: Date
    
    init(isAvailable: Bool, reason: String) {
        self.isAvailable = isAvailable
        self.reason = reason
        self.timestamp = Date()
    }
    
    static func == (lhs: TelemetryAvailabilityEvent, rhs: TelemetryAvailabilityEvent) -> Bool {
        return lhs.isAvailable == rhs.isAvailable &&
               lhs.reason == rhs.reason &&
               abs(lhs.timestamp.timeIntervalSince(rhs.timestamp)) < 0.01
    }
}

struct BalloonPositionEvent: Equatable {
    let balloonId: String
    let position: CLLocationCoordinate2D
    let telemetry: TelemetryData
    let timestamp: Date
    
    init(balloonId: String, position: CLLocationCoordinate2D, telemetry: TelemetryData) {
        self.balloonId = balloonId
        self.position = position
        self.telemetry = telemetry
        self.timestamp = Date()
    }
    
    static func == (lhs: BalloonPositionEvent, rhs: BalloonPositionEvent) -> Bool {
        return lhs.balloonId == rhs.balloonId &&
               lhs.position.latitude == rhs.position.latitude &&
               lhs.position.longitude == rhs.position.longitude &&
               lhs.telemetry == rhs.telemetry &&
               abs(lhs.timestamp.timeIntervalSince(rhs.timestamp)) < 0.01
    }
}

// MARK: - Event Flow Validator

/// Validates the complete event-driven architecture flow
/// This can be used for integration testing and debugging
@MainActor
class EventFlowValidator {
    private var cancellables = Set<AnyCancellable>()
    private var eventCounts: [String: Int] = [:]
    private let startTime = Date()
    
    init() {
        setupEventMonitoring()
    }
    
    private func setupEventMonitoring() {
        // Monitor telemetry events
        EventBus.shared.telemetryPublisher
            .sink { [weak self] event in
                self?.logEvent("TelemetryEvent", details: "balloon: \(event.balloonId), alt: \(event.telemetryData.altitude)m")
            }
            .store(in: &cancellables)
        
        // Monitor user location events
        EventBus.shared.userLocationPublisher
            .sink { [weak self] event in
                self?.logEvent("UserLocationEvent", details: "lat: \(String(format: "%.4f", event.locationData.latitude)), lon: \(String(format: "%.4f", event.locationData.longitude))")
            }
            .store(in: &cancellables)
        
        // Monitor UI events
        EventBus.shared.uiEventPublisher
            .sink { [weak self] event in
                self?.logEvent("UIEvent", details: "\(event)")
            }
            .store(in: &cancellables)
        
        // Monitor map state updates
        EventBus.shared.mapStateUpdatePublisher
            .sink { [weak self] update in
                self?.logEvent("MapStateUpdate", details: "source: \(update.source), version: \(update.version)")
            }
            .store(in: &cancellables)
        
        // Monitor service health events
        EventBus.shared.serviceHealthPublisher
            .sink { [weak self] event in
                self?.logEvent("ServiceHealthEvent", details: "service: \(event.serviceName), health: \(event.health)")
            }
            .store(in: &cancellables)
    }
    
    private func logEvent(_ eventType: String, details: String) {
        eventCounts[eventType, default: 0] += 1
        let count = eventCounts[eventType]!
        let elapsed = Date().timeIntervalSince(startTime)
        
        appLog("EventFlow: [\(String(format: "%.1f", elapsed))s] \(eventType) #\(count) - \(details)", 
               category: .general, level: .debug)
    }
    
    func getEventSummary() -> [String: Any] {
        let elapsed = Date().timeIntervalSince(startTime)
        var summary: [String: Any] = [
            "elapsedTime": elapsed,
            "eventCounts": eventCounts
        ]
        
        // Calculate event rates
        var rates: [String: Double] = [:]
        for (eventType, count) in eventCounts {
            rates[eventType + "Rate"] = Double(count) / elapsed
        }
        summary["eventRates"] = rates
        
        return summary
    }
    
    func validateArchitecture() -> [String: Bool] {
        return [
            "telemetryFlowActive": eventCounts["TelemetryEvent", default: 0] > 0,
            "locationFlowActive": eventCounts["UserLocationEvent", default: 0] > 0,
            "uiFlowActive": eventCounts["UIEvent", default: 0] > 0,
            "mapStateUpdatesActive": eventCounts["MapStateUpdate", default: 0] > 0,
            "servicesHealthy": eventCounts["ServiceHealthEvent", default: 0] > 0,
            "balancedFlow": eventCounts["MapStateUpdate", default: 0] >= eventCounts["TelemetryEvent", default: 0]
        ]
    }
    
    deinit {
        cancellables.removeAll()
    }
}