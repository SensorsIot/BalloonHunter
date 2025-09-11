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
        guard let rate = climbRate else { return false }
        return rate > 0
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
    
    init() {
        print("🆕 DomainModel initialized (Phase 4 - Structured Entities)")
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
        routing.route = route
        print("🆕 DomainModel: Route updated - \(route?.coordinates.count ?? 0) points")
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