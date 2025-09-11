// DomainModel.swift  
// Phase 4: Structured domain model with proper entities
// Implements the full proposal specification

import Foundation
import CoreLocation
import Combine

// MARK: - Domain Entities

struct Balloon {
    var coordinate: CLLocationCoordinate2D?
    var altitude: Double?
    var climbRate: Double?
    var isAscending: Bool {
        // If we have a climb rate, use it
        if let rate = climbRate {
            return rate > 0
        }
        
        // If no climb rate and above 10000m, assume still ascending
        // (since descent rate calculation only starts below 10000m)
        if let alt = altitude, alt >= 10000 {
            return true
        }
        
        // If below 10000m with no climb rate data, assume descending
        return false
    }
}

struct TrackPoint {
    let coordinate: CLLocationCoordinate2D
    let altitude: Double
    let timestamp: Date
}

struct Track {
    var history: [TrackPoint] = []  // From HistoryService at startup/sonde switch
    var live: [TrackPoint] = []     // Appended as telemetry arrives
}

struct PredictedPoint {
    let coordinate: CLLocationCoordinate2D
    let altitude: Double
    let timestamp: Date
}

struct LandingPoint {
    let coordinate: CLLocationCoordinate2D
    let source: String  // "prediction", "manual", etc.
    let timestamp: Date
}

struct Prediction {
    var visible: Bool = false
    var path: [PredictedPoint] = []
    var burst: CLLocationCoordinate2D?
    var landing: LandingPoint?  // Shared entity reference
}

struct Route {
    let coordinates: [CLLocationCoordinate2D]
    let estimatedTravelTime: TimeInterval?
}

struct Routing {
    var transportMode: TransportationMode = .car
    var route: Route?
}

struct DomainMapCamera {
    var center: CLLocationCoordinate2D?
    var distance: CLLocationDistance?
    var pitch: CGFloat?
    var heading: CLLocationDirection?
}

struct UICamera {
    var mapCamera: DomainMapCamera = DomainMapCamera()
    var followingUser: Bool = false  // Default false; only toggled by user
}

// MARK: - Domain Model (Phase 4)

@MainActor
final class DomainModel: ObservableObject {
    // Core domain state following proposal specification
    @Published var activeSondeID: String?
    @Published var userLocation: CLLocation?
    @Published var userHeading: CLLocationDirection?
    
    // Domain entities
    @Published var balloon: Balloon = Balloon()
    @Published var track: Track = Track()
    @Published var prediction: Prediction = Prediction()
    @Published var routing: Routing = Routing()
    @Published var uiCamera: UICamera = UICamera()
    
    // Shared landing point entity (invariant: at most one)
    @Published var landingPoint: LandingPoint?
    
    // Status for comparison with existing system
    var statusSummary: String {
        let userStatus = userLocation != nil ? "Available" : "None"
        let balloonStatus = balloon.coordinate != nil ? "Available" : "None"
        let landingStatus = landingPoint != nil ? "Available" : "None"
        return "🆕 DomainModel - User: \(userStatus), Balloon: \(balloonStatus), Landing: \(landingStatus)"
    }
    
    // Computed properties for compatibility
    var hasUserLocation: Bool { userLocation != nil }
    var hasBalloonData: Bool { balloon.coordinate != nil }
    var hasLandingPoint: Bool { landingPoint != nil }
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        print("🆕 DomainModel initialized (Phase 4 - Structured Entities)")
        setupEventSubscriptions()
    }
    
    private func setupEventSubscriptions() {
        print("🔄 DomainModel: Setting up EventBus subscriptions and MapState observation")
        
        // Subscribe to MapStateUpdate events to keep DomainModel in sync
        EventBus.shared.mapStateUpdatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                print("🔄 DomainModel: EventBus subscription received update")
                self?.handleMapStateUpdate(update)
            }
            .store(in: &cancellables)
        
        print("🔄 DomainModel: EventBus subscription setup complete")
    }
    
    /// Setup direct MapState observation for systems that bypass EventBus
    func observeMapState(_ mapState: MapState) {
        print("🔄 DomainModel: Setting up direct MapState observation")
        
        // Observe userRoute changes directly
        mapState.$userRoute
            .receive(on: DispatchQueue.main)
            .sink { [weak self] userRoute in
                print("🔄 DomainModel: Direct MapState - userRoute changed")
                if let userRoute = userRoute {
                    let route = Route(
                        coordinates: userRoute.coordinates,
                        estimatedTravelTime: nil
                    )
                    self?.updateRoute(route)
                    print("🔄 DomainModel: Route updated via direct MapState observation - \(userRoute.coordinates.count) coordinates")
                } else {
                    self?.updateRoute(nil)
                    print("🔄 DomainModel: Route cleared via direct MapState observation")
                }
            }
            .store(in: &cancellables)
        
        // Observe transport mode changes
        mapState.$transportMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transportMode in
                print("🔄 DomainModel: Direct MapState - transportMode changed to \(transportMode)")
                self?.updateTransportMode(transportMode == .car ? .car : .bike)
            }
            .store(in: &cancellables)
    }
    
    private func handleMapStateUpdate(_ update: MapStateUpdate) {
        print("🔄 DomainModel: Received MapStateUpdate from \(update.source)")
        
        // Sync route changes
        if let userRoute = update.userRoute {
            let route = Route(
                coordinates: userRoute.coordinates,
                estimatedTravelTime: nil
            )
            updateRoute(route)
            print("🔄 DomainModel: Route updated from MapStateUpdate - \(userRoute.coordinates.count) coordinates")
        } else if update.userRoute == nil && routing.route != nil {
            // Route was cleared
            updateRoute(nil)
            print("🔄 DomainModel: Route cleared from MapStateUpdate")
        }
        
        // Sync prediction path changes
        if let predictionPath = update.predictionPath {
            let predictionPoints = predictionPath.coordinates.map { coordinate in
                PredictedPoint(coordinate: coordinate, altitude: 0, timestamp: Date())
            }
            updatePrediction(path: predictionPoints)
            print("🔄 DomainModel: Prediction path updated from MapStateUpdate - \(predictionPoints.count) points")
        }
    }
    
    // MARK: - Update Methods (Phase 4)
    
    func updateUserLocation(_ location: CLLocation, heading: CLLocationDirection? = nil) {
        self.userLocation = location
        if let heading = heading {
            self.userHeading = heading
        }
        print("🆕 DomainModel: User location updated: \(location.coordinate)")
    }
    
    func updateBalloonPosition(_ coordinate: CLLocationCoordinate2D, altitude: Double?, climbRate: Double?) {
        balloon.coordinate = coordinate
        balloon.altitude = altitude
        balloon.climbRate = climbRate
        
        // Add to live track
        let trackPoint = TrackPoint(coordinate: coordinate, altitude: altitude ?? 0, timestamp: Date())
        track.live.append(trackPoint)
        
        print("🆕 DomainModel: Balloon updated - pos: \(coordinate), alt: \(altitude ?? 0)m, ascending: \(balloon.isAscending)")
    }
    
    func updateLandingPoint(_ coordinate: CLLocationCoordinate2D, source: String) {
        let newLandingPoint = LandingPoint(coordinate: coordinate, source: source, timestamp: Date())
        self.landingPoint = newLandingPoint
        
        // Update prediction reference to shared landing point
        prediction.landing = newLandingPoint
        
        print("🆕 DomainModel: Landing point updated from \(source): \(coordinate)")
    }
    
    func updateActiveSonde(_ sondeID: String) {
        let previousSonde = self.activeSondeID
        self.activeSondeID = sondeID
        
        // On sonde switch: clear live data, preserve history if same sonde
        if previousSonde != sondeID {
            print("🆕 DomainModel: Sonde changed from \(previousSonde ?? "none") to \(sondeID) - clearing live data")
            track.live.removeAll()
            balloon = Balloon()
            prediction = Prediction()
            routing = Routing()
            landingPoint = nil
        }
        
        print("🆕 DomainModel: Active sonde: \(sondeID)")
    }
    
    func updatePrediction(visible: Bool? = nil, path: [PredictedPoint]? = nil, burst: CLLocationCoordinate2D? = nil) {
        if let visible = visible {
            prediction.visible = visible
        }
        if let path = path {
            prediction.path = path
        }
        if let burst = burst {
            prediction.burst = burst
        }
        print("🆕 DomainModel: Prediction updated - visible: \(prediction.visible), points: \(prediction.path.count)")
    }
    
    func updateTransportMode(_ mode: TransportationMode) {
        routing.transportMode = mode
        print("🆕 DomainModel: Transport mode updated: \(mode)")
    }
    
    func updateRoute(_ route: Route?) {
        let oldRoutePoints = routing.route?.coordinates.count ?? 0
        routing.route = route
        let newRoutePoints = route?.coordinates.count ?? 0
        print("🆕 DomainModel: Route updated - from \(oldRoutePoints) to \(newRoutePoints) points")
        if let route = route {
            print("🆕 DomainModel: New route first point: \(route.coordinates.first?.latitude ?? 0), \(route.coordinates.first?.longitude ?? 0)")
            print("🆕 DomainModel: New route last point: \(route.coordinates.last?.latitude ?? 0), \(route.coordinates.last?.longitude ?? 0)")
        }
    }
    
    // MARK: - MapState Integration (Phase 4)
    
    func syncWithMapState(_ mapState: MapState) {
        print("🔄 DomainModel: Syncing with existing MapState...")
        
        // Sync user location
        if let userLoc = mapState.userLocation {
            let location = CLLocation(latitude: userLoc.latitude, longitude: userLoc.longitude)
            updateUserLocation(location, heading: userLoc.heading)
        }
        
        // Sync balloon position and active sonde
        if let balloonTelemetry = mapState.balloonTelemetry {
            updateBalloonPosition(
                CLLocationCoordinate2D(latitude: balloonTelemetry.latitude, longitude: balloonTelemetry.longitude),
                altitude: balloonTelemetry.altitude,
                climbRate: balloonTelemetry.verticalSpeed
            )
            updateActiveSonde(balloonTelemetry.sondeName)
        }
        
        // Sync prediction state
        updatePrediction(visible: mapState.isPredictionPathVisible)
        
        // Sync prediction path from MapState
        if let predictionPath = mapState.predictionPath {
            let predictionPoints = predictionPath.coordinates.map { coordinate in
                PredictedPoint(coordinate: coordinate, altitude: 0, timestamp: Date())
            }
            updatePrediction(path: predictionPoints)
        }
        
        if let burstPoint = mapState.burstPoint {
            updatePrediction(burst: burstPoint)
        }
        
        // Sync landing point (shared entity)
        if let landingPt = mapState.landingPoint {
            updateLandingPoint(landingPt, source: "startup_sync")
        }
        
        // Sync transport mode - convert from MapState enum
        if mapState.transportMode == .car {
            updateTransportMode(.car)
        } else {
            updateTransportMode(.bike)
        }
        
        // Sync route from MapState
        if let userRoute = mapState.userRoute {
            let route = Route(
                coordinates: userRoute.coordinates,
                estimatedTravelTime: nil
            )
            updateRoute(route)
        }
        
        print("🔄 DomainModel: Sync complete - \(statusSummary)")
    }
    
    func compareWithMapState(_ mapState: MapState) {
        let domainUserAvailable = hasUserLocation
        let mapStateUserAvailable = mapState.userLocation != nil
        
        let domainBalloonAvailable = hasBalloonData  
        let mapStateBalloonAvailable = mapState.balloonTelemetry != nil
        
        let domainLandingAvailable = hasLandingPoint
        let mapStateLandingAvailable = mapState.landingPoint != nil
        
        // Additional comparisons for Phase 4 entities
        let domainPredictionVisible = prediction.visible
        let mapStatePredictionVisible = mapState.isPredictionPathVisible
        
        let domainTrackPoints = track.live.count + track.history.count
        let _ = mapState.annotations.filter { $0.kind == .balloon }.count
        
        if domainUserAvailable != mapStateUserAvailable ||
           domainBalloonAvailable != mapStateBalloonAvailable ||
           domainLandingAvailable != mapStateLandingAvailable ||
           domainPredictionVisible != mapStatePredictionVisible {
            print("⚠️ State Mismatch - Domain: (user:\(domainUserAvailable), balloon:\(domainBalloonAvailable), landing:\(domainLandingAvailable), pred:\(domainPredictionVisible)) vs MapState: (user:\(mapStateUserAvailable), balloon:\(mapStateBalloonAvailable), landing:\(mapStateLandingAvailable), pred:\(mapStatePredictionVisible))")
        } else {
            print("✅ State Match - Both systems show identical availability and settings")
        }
        
        // Entity-specific logging
        print("🔍 Domain Entities - Balloon: \(balloon.isAscending ? "ascending" : "descending"), Track: \(domainTrackPoints) points, Landing source: \(landingPoint?.source ?? "none")")
    }
    
    // MARK: - Convenience Methods (Phase 4)
    
    /// Returns all track points (history + live) for rendering
    func getAllTrackPoints() -> [TrackPoint] {
        return track.history + track.live
    }
    
    /// Returns current balloon position for map rendering
    var currentBalloonCoordinate: CLLocationCoordinate2D? {
        return balloon.coordinate
    }
    
    /// Returns shared landing point coordinate
    var currentLandingCoordinate: CLLocationCoordinate2D? {
        return landingPoint?.coordinate
    }
    
    /// Clears live data (for sonde switching)
    func clearLiveData() {
        track.live.removeAll()
        balloon = Balloon()
        prediction = Prediction()
        routing.route = nil
        landingPoint = nil
        print("🆕 DomainModel: Live data cleared")
    }
    
    /// Loads track history (simulated - will be replaced by HistoryService)
    func loadTrackHistory(_ points: [TrackPoint]) {
        track.history = points
        print("🆕 DomainModel: Loaded \(points.count) historical track points")
    }
}