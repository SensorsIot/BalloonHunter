import Foundation
import Combine
import CoreLocation
import MapKit
import OSLog

// MARK: - Current Location Service

@MainActor
final class CurrentLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published var locationData: LocationData? = nil
    var isLocationPermissionGranted: Bool = false
    var significantMovementLocation: LocationData? = nil // Only updates on 10m+ movement
    @Published var distanceToBalloon: CLLocationDistance? = nil // Raw distance in meters for overlay display
    @Published var isWithin200mOfBalloon: Bool = false // For navigation logic
    @Published var shouldUpdateRoute: Bool = false // Triggers route recalculation when user moves significantly

    // Dual location managers for different operational modes
    private let backgroundLocationManager = CLLocationManager() // 30-second updates, standard accuracy
    private let precisionLocationManager = CLLocationManager()  // 1-2 second updates, best accuracy

    private var lastHeading: Double? = nil
    private var lastLocationTime: Date? = nil
    private var lastLocationUpdate: Date? = nil
    private var lastSignificantMovementLocation: CLLocationCoordinate2D? = nil
    private var currentBalloonDisplayPosition: CLLocationCoordinate2D?
    private var isHeadingModeActive: Bool = false
    private var cancellables = Set<AnyCancellable>()
    private var userLocationLogCount: Int = 0

    // Movement thresholds for route updates (moved from Coordinator)
    private var lastRouteUpdateLocation: CLLocationCoordinate2D? = nil
    private var lastRouteUpdateTime = Date.distantPast
    private let routeUpdateMovementThreshold: CLLocationDistance = 100.0 // meters
    private let routeUpdateTimeThreshold: TimeInterval = 60.0 // seconds
    
    // Location service operational modes
    enum LocationMode {
        case background  // 30-second updates, standard accuracy for tracking
        case precision   // 1-2 second updates, best accuracy for heading mode
    }

    
    override init() {
        super.init()
        setupLocationManagers()
        // Background location service disabled - location fetched on-demand and on foreground resume
        appLog("CurrentLocationService: Initialized with dual-mode architecture (on-demand mode)", category: .service, level: .info)
    }

    private func setupLocationManagers() {
        // Configure background location manager
        backgroundLocationManager.delegate = self
        backgroundLocationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters // ~10m accuracy
        backgroundLocationManager.distanceFilter = 10.0 // Update on 10m movement

        // Configure precision location manager
        precisionLocationManager.delegate = self
        precisionLocationManager.desiredAccuracy = kCLLocationAccuracyBest // ~3-5m accuracy
        precisionLocationManager.distanceFilter = 2.0 // Update on 2m movement
    }
    
    // MARK: - Mode Switching

    func enableHeadingMode() {
        guard !isHeadingModeActive else { return }
        isHeadingModeActive = true

        appLog("CurrentLocationService: Enabling precision mode for heading view", category: .service, level: .info)
        precisionLocationManager.startUpdatingLocation()
    }

    func disableHeadingMode() {
        guard isHeadingModeActive else { return }
        isHeadingModeActive = false

        appLog("CurrentLocationService: Disabling precision mode", category: .service, level: .info)
        precisionLocationManager.stopUpdatingLocation()
    }

    /// Request a single location update (used for on-demand location fetching)
    func requestCurrentLocation() {
        backgroundLocationManager.requestLocation()
        appLog("CurrentLocationService: Requesting current location (on-demand)", category: .service, level: .debug)
    }

    func requestPermission() {
        backgroundLocationManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        backgroundLocationManager.startUpdatingLocation()
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse:
            isLocationPermissionGranted = true
            // On-demand location only - fetch when app is active
            publishHealthEvent(.healthy, message: "Location permission granted (when in use)")

        case .authorizedAlways:
            isLocationPermissionGranted = true
            // On-demand location only - no background updates needed
            publishHealthEvent(.healthy, message: "Location permission granted (always)")

        case .denied, .restricted:
            isLocationPermissionGranted = false
            publishHealthEvent(.unhealthy("Location permission denied"), message: "Location permission denied")
        case .notDetermined:
            // Request when-in-use only (no need for "Always" permission)
            backgroundLocationManager.requestWhenInUseAuthorization()
            publishHealthEvent(.degraded("Location permission not determined"), message: "Location permission not determined")
        @unknown default:
            publishHealthEvent(.degraded("Unknown location authorization status"), message: "Unknown location authorization status")
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }
        let heading = lastHeading ?? location.course

        DispatchQueue.main.async {
            let now = Date()
            let isFirstUpdate = self.locationData == nil

            // Determine which manager provided this update
            let isFromPrecisionManager = manager === self.precisionLocationManager
            let modeString = isFromPrecisionManager ? "PRECISION" : "BACKGROUND"

            // Rate limiting for precision mode (1-2 second intervals)
            if isFromPrecisionManager {
                if let lastUpdate = self.lastLocationUpdate {
                    let timeSinceLastUpdate = now.timeIntervalSince(lastUpdate)
                    if timeSinceLastUpdate < 1.0 && !isFirstUpdate {
                        return // Skip update - too frequent for precision mode
                    }
                }
            }

            // Calculate movement distance for logging
            var distanceDiff: Double = 0
            if let previousLocation = self.locationData {
                let prevCLLocation = CLLocation(latitude: previousLocation.latitude, longitude: previousLocation.longitude)
                distanceDiff = location.distance(from: prevCLLocation)
            }

            // Create new location data
            let newLocationData = LocationData(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.altitude,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy,
                heading: heading,
                timestamp: Date()
            )

            self.locationData = newLocationData
            self.lastLocationTime = now
            self.lastLocationUpdate = now

            // Update significant movement location (10m threshold)
            self.updateSignificantMovementLocation(newLocationData)

            // Update distance overlay and proximity status
            self.updateDistanceToBalloon()
            self.updateProximityStatus()

            // Check for route update trigger (moved from Coordinator)
            self.checkForRouteUpdate(newLocationData)

            // Throttled user location logging to avoid spam (moved from ServiceCoordinator)
            self.userLocationLogCount += 1
            if isFirstUpdate {
                appLog("Initial user location [\(modeString)]: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude)", category: .service, level: .info)
            } else if self.userLocationLogCount % 10 == 1 {
                // Log every 10th update with full details
                appLog(String(format: "User (\(self.userLocationLogCount), every 10th): lat=%.5f lon=%.5f alt=%.0f acc=%.1f/%.1f",
                               newLocationData.latitude,
                               newLocationData.longitude,
                               newLocationData.altitude,
                               newLocationData.horizontalAccuracy,
                               newLocationData.verticalAccuracy),
                       category: .general, level: .debug)
            } else if distanceDiff > 20 {
                // Log significant movement (>20m) without full details
                appLog("User location update [\(modeString)]: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude), dist=\(Int(distanceDiff))m", category: .service, level: .debug)
            }
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        lastHeading = heading
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        appLog("CurrentLocationService: Location error: \(error.localizedDescription)", category: .service, level: .error)
        publishHealthEvent(.unhealthy("Location error: \(error.localizedDescription)"), message: "Location error: \(error.localizedDescription)")
    }

    private func updateSignificantMovementLocation(_ newLocation: LocationData) {
        // Check if this is the first location or movement exceeds 10m threshold
        guard let lastSignificantLocation = lastSignificantMovementLocation else {
            // First location update - always record
            significantMovementLocation = newLocation
            lastSignificantMovementLocation = CLLocationCoordinate2D(
                latitude: newLocation.latitude,
                longitude: newLocation.longitude
            )
            return
        }

        let currentCoordinate = CLLocationCoordinate2D(
            latitude: newLocation.latitude,
            longitude: newLocation.longitude
        )

        let movementDistance = CLLocation(
            latitude: lastSignificantLocation.latitude,
            longitude: lastSignificantLocation.longitude
        ).distance(from: CLLocation(
            latitude: currentCoordinate.latitude,
            longitude: currentCoordinate.longitude
        ))

        if movementDistance >= 10.0 {
            // Update significant movement location when 10m+ movement detected
            significantMovementLocation = newLocation
            lastSignificantMovementLocation = currentCoordinate
            appLog("CurrentLocationService: Significant movement detected (\(Int(movementDistance))m) - updating significant movement location", category: .service, level: .debug)
        }
    }

    // MARK: - Route Update Logic (moved from Coordinator)

    private func checkForRouteUpdate(_ newLocation: LocationData) {
        let currentCoordinate = CLLocationCoordinate2D(
            latitude: newLocation.latitude,
            longitude: newLocation.longitude
        )
        let now = Date()

        // Check time threshold first (every minute)
        let timeSinceLastUpdate = now.timeIntervalSince(lastRouteUpdateTime)
        guard timeSinceLastUpdate >= routeUpdateTimeThreshold else {
            return
        }

        // Check movement threshold
        var shouldTriggerUpdate = false
        if let lastLocation = lastRouteUpdateLocation {
            let distance = CLLocation(latitude: lastLocation.latitude, longitude: lastLocation.longitude)
                .distance(from: CLLocation(latitude: currentCoordinate.latitude, longitude: currentCoordinate.longitude))

            if distance >= routeUpdateMovementThreshold {
                shouldTriggerUpdate = true
                appLog("CurrentLocationService: User moved \(Int(distance))m - triggering route update", category: .service, level: .info)
            }
        } else {
            // First time - always trigger
            shouldTriggerUpdate = true
        }

        if shouldTriggerUpdate {
            lastRouteUpdateLocation = currentCoordinate
            lastRouteUpdateTime = now
            shouldUpdateRoute = true

            // Reset flag after brief delay to allow subscribers to react
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.shouldUpdateRoute = false
            }
        }
    }

    // MARK: - Distance and Proximity Calculations

    private func updateDistanceToBalloon() {
        guard let userLocation = locationData,
              let balloonPosition = currentBalloonDisplayPosition else {
            distanceToBalloon = nil
            return
        }

        let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let distance = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            .distance(from: CLLocation(latitude: balloonPosition.latitude, longitude: balloonPosition.longitude))

        distanceToBalloon = distance
    }

    private func updateProximityStatus() {
        guard let userLocation = locationData,
              let balloonPosition = currentBalloonDisplayPosition else {
            isWithin200mOfBalloon = false
            return
        }

        let userCoord = CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let distance = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
            .distance(from: CLLocation(latitude: balloonPosition.latitude, longitude: balloonPosition.longitude))

        isWithin200mOfBalloon = distance < 200
    }

    func updateBalloonDisplayPosition(_ position: CLLocationCoordinate2D?) {
        currentBalloonDisplayPosition = position
        updateDistanceToBalloon()
        updateProximityStatus()
    }


    private func publishHealthEvent(_ health: ServiceHealth, message: String) {
        // Health status logging removed for log reduction
    }
}
