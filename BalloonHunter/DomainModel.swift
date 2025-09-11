// DomainModel.swift  
// Phase 2: Minimal domain model running parallel to MapState
// Mirrors existing functionality without replacing it

import Foundation
import CoreLocation
import Combine

// MARK: - Domain Model (Parallel to MapState)

@MainActor
final class DomainModel: ObservableObject {
    // Mirror the essential state from MapState
    @Published var userLocation: CLLocation?
    @Published var balloonPosition: CLLocationCoordinate2D?
    @Published var balloonAltitude: Double?
    @Published var balloonClimbRate: Double?
    @Published var landingPoint: CLLocationCoordinate2D?
    @Published var activeSondeID: String?
    
    // State tracking
    @Published var hasUserLocation: Bool = false
    @Published var hasBalloonData: Bool = false
    @Published var hasLandingPoint: Bool = false
    
    // Status for comparison with existing system
    var statusSummary: String {
        let userStatus = hasUserLocation ? "Available" : "None"
        let balloonStatus = hasBalloonData ? "Available" : "None"
        let landingStatus = hasLandingPoint ? "Available" : "None"
        return "🆕 DomainModel - User: \(userStatus), Balloon: \(balloonStatus), Landing: \(landingStatus)"
    }
    
    init() {
        print("🆕 DomainModel initialized (Phase 2)")
    }
    
    // Update methods to mirror MapState changes
    func updateUserLocation(_ location: CLLocation) {
        self.userLocation = location
        self.hasUserLocation = true
    }
    
    func updateBalloonPosition(_ coordinate: CLLocationCoordinate2D, altitude: Double?, climbRate: Double?) {
        self.balloonPosition = coordinate
        self.balloonAltitude = altitude
        self.balloonClimbRate = climbRate
        self.hasBalloonData = true
    }
    
    func updateLandingPoint(_ coordinate: CLLocationCoordinate2D, source: String) {
        self.landingPoint = coordinate
        self.hasLandingPoint = true
        print("🆕 DomainModel: Landing point updated from \(source): \(coordinate)")
    }
    
    func updateActiveSonde(_ sondeID: String) {
        self.activeSondeID = sondeID
        print("🆕 DomainModel: Active sonde: \(sondeID)")
    }
    
    // Phase 2: Sync with existing MapState during startup
    func syncWithMapState(_ mapState: MapState) {
        print("🔄 DomainModel: Syncing with existing MapState...")
        
        // Sync user location
        if let userLoc = mapState.userLocation {
            let location = CLLocation(latitude: userLoc.latitude, longitude: userLoc.longitude)
            updateUserLocation(location)
        }
        
        // Sync balloon position
        if let balloonTelemetry = mapState.balloonTelemetry {
            updateBalloonPosition(
                CLLocationCoordinate2D(latitude: balloonTelemetry.latitude, longitude: balloonTelemetry.longitude),
                altitude: balloonTelemetry.altitude,
                climbRate: balloonTelemetry.verticalSpeed
            )
            updateActiveSonde(balloonTelemetry.sondeName)
        }
        
        // Sync landing point
        if let landingPt = mapState.landingPoint {
            updateLandingPoint(landingPt, source: "startup_sync")
        }
        
        print("🔄 DomainModel: Sync complete - \(statusSummary)")
    }
    
    // Compare with existing MapState
    func compareWithMapState(_ mapState: MapState) {
        let domainUserAvailable = hasUserLocation
        let mapStateUserAvailable = mapState.userLocation != nil
        
        let domainBalloonAvailable = hasBalloonData
        let mapStateBalloonAvailable = mapState.balloonTelemetry != nil
        
        let domainLandingAvailable = hasLandingPoint
        let mapStateLandingAvailable = mapState.landingPoint != nil
        
        if domainUserAvailable != mapStateUserAvailable ||
           domainBalloonAvailable != mapStateBalloonAvailable ||
           domainLandingAvailable != mapStateLandingAvailable {
            print("⚠️ State Mismatch - Domain: (\(domainUserAvailable), \(domainBalloonAvailable), \(domainLandingAvailable)) vs MapState: (\(mapStateUserAvailable), \(mapStateBalloonAvailable), \(mapStateLandingAvailable))")
        } else {
            print("✅ State Match - Both systems show identical availability")
        }
    }
}