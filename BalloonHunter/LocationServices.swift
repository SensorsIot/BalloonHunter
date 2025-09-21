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

    // Dual location managers for different operational modes
    private let backgroundLocationManager = CLLocationManager() // 30-second updates, standard accuracy
    private let precisionLocationManager = CLLocationManager()  // 1-2 second updates, best accuracy

    private var lastHeading: Double? = nil
    private var lastLocationTime: Date? = nil
    private var lastLocationUpdate: Date? = nil
    private var lastSignificantMovementLocation: CLLocationCoordinate2D? = nil
    private var currentBalloonDisplayPosition: CLLocationCoordinate2D?
    private var isHeadingModeActive: Bool = false
    private var backgroundTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // Location service operational modes
    enum LocationMode {
        case background  // 30-second updates, standard accuracy for tracking
        case precision   // 1-2 second updates, best accuracy for heading mode
    }

    
    override init() {
        super.init()
        setupLocationManagers()
        startBackgroundLocationService()
        appLog("CurrentLocationService: Initialized with dual-mode architecture (background active)", category: .service, level: .info)
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

        appLog("CurrentLocationService: Disabling precision mode, returning to background mode", category: .service, level: .info)
        precisionLocationManager.stopUpdatingLocation()
    }

    private func startBackgroundLocationService() {
        // Start 30-second timer for background location updates
        backgroundTimer?.invalidate()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestSingleBackgroundUpdate()
            }
        }

        // Get initial location immediately
        requestSingleBackgroundUpdate()
        appLog("CurrentLocationService: Background location service started (30-second intervals)", category: .service, level: .info)
    }

    private func requestSingleBackgroundUpdate() {
        backgroundLocationManager.requestLocation()
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
            backgroundLocationManager.startUpdatingLocation()

            // Request "Always" permission for better background operation
            backgroundLocationManager.requestAlwaysAuthorization()
            publishHealthEvent(.healthy, message: "Location permission granted (when in use)")

        case .authorizedAlways:
            isLocationPermissionGranted = true
            backgroundLocationManager.startUpdatingLocation()

            // Enable significant location changes for background updates
            backgroundLocationManager.startMonitoringSignificantLocationChanges()
            publishHealthEvent(.healthy, message: "Location permission granted (always)")

        case .denied, .restricted:
            isLocationPermissionGranted = false
            publishHealthEvent(.unhealthy("Location permission denied"), message: "Location permission denied")
        case .notDetermined:
            // Request when-in-use first, then upgrade to always
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

            if isFirstUpdate {
                appLog("Initial user location [\(modeString)]: lat=\(location.coordinate.latitude), lon=\(location.coordinate.longitude)", category: .service, level: .info)
            } else if distanceDiff > 20 { // Log significant movement (>20m)
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
