import Foundation
import Combine
import MapKit
import CoreLocation
import OSLog

@MainActor
final class MapPresenter: ObservableObject {
    // MARK: - Published State

    @Published private(set) var trackPoints: [BalloonTrackPoint] = []
    @Published private(set) var predictionPath: MKPolyline?
    @Published private(set) var userRoute: MKPolyline?
    @Published private(set) var landingHistory: [LandingPredictionPoint] = []

    // Three-channel architecture
    @Published private(set) var balloonPosition: PositionData?
    @Published private(set) var balloonRadioChannel: RadioChannelData?
    @Published private(set) var balloonSettings: SettingsData?

    // Legacy compatibility removed - use three-channel architecture
    @Published private(set) var balloonDisplayPosition: CLLocationCoordinate2D?
    @Published private(set) var landingPoint: CLLocationCoordinate2D?
    @Published private(set) var burstPoint: CLLocationCoordinate2D?
    @Published private(set) var predictionData: PredictionData?
    @Published private(set) var annotations: [MapAnnotationItem] = []
    @Published private(set) var isHeadingMode: Bool = false
    @Published private(set) var transportMode: TransportationMode = .car
    @Published private(set) var isBuzzerMuted: Bool = false
    @Published private(set) var distanceToBalloon: CLLocationDistance?
    @Published private(set) var isWithin200mOfBalloon: Bool = false
    @Published private(set) var userLocation: LocationData?
    @Published private(set) var balloonPhase: BalloonPhase = .unknown
    @Published private(set) var region: MKCoordinateRegion?
    @Published private(set) var cameraUpdatesSuspended: Bool = false

    // APRS sonde name display (for persistent field in tracking view)
    @Published private(set) var bleSerialName: String = ""
    @Published private(set) var aprsSerialName: String = ""

    // MOVED FROM ServiceCoordinator: Additional UI state
    @Published private(set) var connectionStatus: ConnectionStatus = .disconnected
    @Published private(set) var smoothedDescentRate: Double? = nil
    @Published private(set) var isDataStale: Bool = false
    @Published private(set) var aprsDataAvailable: Bool = false
    @Published private(set) var showAllAnnotations: Bool = false
    @Published private(set) var frequencySyncProposal: FrequencySyncProposal? = nil

    // MARK: - Dependencies

    private let coordinator: ServiceCoordinator
    private let balloonTrackService: BalloonTrackService
    let balloonPositionService: BalloonPositionService  // Internal access for TrackingMapView debugging
    private let landingPointTrackingService: LandingPointTrackingService
    private let currentLocationService: CurrentLocationService
    private let aprsService: APRSDataService
    private let routeCalculationService: RouteCalculationService
    private let predictionService: PredictionService

    private var cancellables = Set<AnyCancellable>()

    init(
        coordinator: ServiceCoordinator,
        balloonTrackService: BalloonTrackService,
        balloonPositionService: BalloonPositionService,
        landingPointTrackingService: LandingPointTrackingService,
        currentLocationService: CurrentLocationService,
        aprsService: APRSDataService,
        routeCalculationService: RouteCalculationService,
        predictionService: PredictionService
    ) {
        self.coordinator = coordinator
        self.balloonTrackService = balloonTrackService
        self.balloonPositionService = balloonPositionService
        self.landingPointTrackingService = landingPointTrackingService
        self.currentLocationService = currentLocationService
        self.aprsService = aprsService
        self.routeCalculationService = routeCalculationService
        self.predictionService = predictionService

        transportMode = routeCalculationService.transportMode
        distanceToBalloon = currentLocationService.distanceToBalloon
        isWithin200mOfBalloon = currentLocationService.isWithin200mOfBalloon

        bindServices()
        refreshAnnotations()
    }

    // MARK: - Red Track Diagnostics

    /// Log the red polyline exactly as the map will draw it.
    ///
    /// Every leg is measured, so a leg going somewhere it should not announces
    /// itself as an outlier without anyone having to decide in advance where
    /// "wrong" points end up. A radiosonde track is continuous: consecutive
    /// points sit seconds and metres apart. One long leg is the defect.
    private func logRedTrack(_ points: [BalloonTrackPoint]) {
        guard points.count >= 2 else { return }

        var longest: (index: Int, metres: CLLocationDistance, seconds: TimeInterval) = (0, 0, 0)
        var legs: [(Int, CLLocationDistance, TimeInterval)] = []

        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let metres = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            let seconds = b.timestamp.timeIntervalSince(a.timestamp)
            if metres > longest.metres { longest = (i, metres, seconds) }
            // A leg over 2 km is longer than a sonde travels between samples.
            if metres > 2000 { legs.append((i, metres, seconds)) }
        }

        let first = points[0], last = points[points.count - 1]
        appLog(String(format: "🔴 RED TRACK: %d pts | first=%.5f,%.5f t=%@ | last=%.5f,%.5f t=%@ | longest leg #%d %.0fm over %.0fs",
                      points.count,
                      first.latitude, first.longitude, "\(first.timestamp)",
                      last.latitude, last.longitude, "\(last.timestamp)",
                      longest.index, longest.metres, longest.seconds),
               category: .general, level: .info)

        // Name every implausible leg and both of its endpoints. This is what
        // identifies the stray line and where it came from.
        for (i, metres, seconds) in legs.prefix(5) {
            let a = points[i - 1], b = points[i]
            appLog(String(format: """
                🔴 RED TRACK JUMP #%d: %.0fm in %.0fs (%.0f km/h)
                   from[%d]: lat=%.6f lon=%.6f alt=%.0fm t=%@
                   to  [%d]: lat=%.6f lon=%.6f alt=%.0fm t=%@
                """,
                i, metres, seconds, seconds > 0 ? (metres / seconds) * 3.6 : -1,
                i - 1, a.latitude, a.longitude, a.altitude, "\(a.timestamp)",
                i, b.latitude, b.longitude, b.altitude, "\(b.timestamp)"),
                category: .general, level: .error)
        }

        if legs.count > 5 {
            appLog("🔴 RED TRACK: \(legs.count) implausible legs total, first 5 logged", category: .general, level: .error)
        }
    }

    // MARK: - Derived Flags

    /// Flying mode: predictions active, navigate to predicted landing point
    var isFlying: Bool {
        balloonPositionService.currentState.isFlying
    }

    /// Landed mode: no predictions, navigate to actual balloon position
    var isLanded: Bool {
        balloonPositionService.currentState.isLanded
    }

    var routeVisible: Bool {
        switch balloonPositionService.currentState {
        case .startup, .noTelemetry:
            return false
        case .liveBLEFlying, .aprsFlying, .waitingForAPRS:
            return true
        case .liveBLELanded, .aprsLanded:
            return !isWithin200mOfBalloon
        }
    }

    private var predictionPathVisible: Bool {
        switch balloonPositionService.currentState {
        case .startup, .noTelemetry:
            return false
        case .liveBLEFlying, .aprsFlying:
            return true
        case .liveBLELanded, .aprsLanded:
            // Landed-by-silence (APRS quiet while descending) keeps the predicted
            // descent line for the drive; only a confirmed BLE touchdown drops it.
            // See FSD *How a Landing Is Determined*.
            return !balloonPositionService.landingConfirmedByBLE
        case .waitingForAPRS:
            return !balloonPositionService.landingConfirmedByBLE
        }
    }

    private var burstPointVisible: Bool {
        switch balloonPositionService.currentState {
        case .startup, .noTelemetry:
            return false
        case .liveBLEFlying, .aprsFlying:
            return balloonPhase == .ascending
        case .liveBLELanded, .aprsLanded:
            return false
        case .waitingForAPRS:
            return balloonPhase == .ascending
        }
    }

    // MARK: - Intent Handlers

    func toggleHeadingMode() {
        isHeadingMode.toggle()
        updateLocationServiceMode()
        appLog("MapPresenter: Heading mode toggled to \(isHeadingMode)", category: .general, level: .info)
    }

    private func updateLocationServiceMode() {
        if isHeadingMode {
            currentLocationService.enableHeadingMode()
            appLog("MapPresenter: Enabled precision location mode for heading view", category: .general, level: .info)
        } else {
            currentLocationService.disableHeadingMode()
            appLog("MapPresenter: Disabled precision location mode, using background mode", category: .general, level: .info)
        }
    }

    func setTransportMode(_ mode: TransportationMode) {
        appLog("MapPresenter: Transport mode changed to \(mode)", category: .general, level: .info)
        routeCalculationService.setTransportMode(mode)
    }

    func requestDeviceParameters() {
        bleService.getParameters()
    }

    func setMuteState(_ muted: Bool) {
        isBuzzerMuted = muted
        appLog("MapPresenter: Setting mute state to \(muted)", category: .general, level: .info)
        bleService.setMute(muted)
    }

    // MARK: - Startup Framing

    /// Open the map on everything there is to see, as the FSD requires: track,
    /// predicted path, route, balloon and hunter.
    ///
    /// It cannot be a single fit at startup, because the overlays land at
    /// different times - the track on load, the prediction about a second later,
    /// the route after that. Framing once would frame whichever pieces happened
    /// to have arrived. So refit as each one appears, until the window closes.
    private var startupFitDeadline: Date?

    /// Begin the window. Called when startup hands over to the state machine.
    func beginStartupFraming(for duration: TimeInterval = 8.0) {
        startupFitDeadline = Date().addingTimeInterval(duration)
        appLog("MapPresenter: Startup framing open for \(Int(duration))s - map will fit each overlay as it arrives", category: .general, level: .info)
        refitDuringStartup()
    }

    /// Refit while the window is open. Ignored once it closes, so the view stops
    /// moving under the hunter the moment they take control.
    private func refitDuringStartup() {
        guard let deadline = startupFitDeadline else { return }
        guard Date() < deadline else {
            startupFitDeadline = nil
            appLog("MapPresenter: Startup framing window closed", category: .general, level: .debug)
            return
        }
        performCameraFit()
    }

    func triggerShowAllAnnotations() {
        showAllAnnotations = true
        updateCameraToShowAllAnnotations()

        // Reset flag after brief delay to allow for future triggers
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showAllAnnotations = false
        }
    }

    func setCameraUpdatesSuspended(_ suspended: Bool) {
        cameraUpdatesSuspended = suspended
        appLog("MapPresenter: Camera updates suspended: \(suspended)", category: .general, level: .debug)
    }

    func openInAppleMaps() {
        coordinator.openInAppleMaps()
    }

    func triggerPrediction() {
        // Direct service call - no coordinator middleman
        guard let position = balloonPositionService.currentPositionData else {
            appLog("MapPresenter: No position data available for manual prediction", category: .general, level: .error)
            return
        }

        Task {
            await predictionService.triggerPredictionWithPosition(position, trigger: "manual")
        }
    }

    func updateCameraToShowAllAnnotations() {
        performCameraFit()
    }



    var bleService: BLECommunicationService { coordinator.bleCommunicationService }

    var persistenceService: PersistenceService { coordinator.persistenceService }

    func logZoomChange(_ description: String, span: MKCoordinateSpan, center: CLLocationCoordinate2D? = nil) {
        let zoomKm = Int(span.latitudeDelta * 111) // Approximate km conversion
        if let center = center {
            appLog("🔍 ZOOM: \(description) - \(zoomKm)km (\(String(format: "%.3f", span.latitudeDelta))°) at [\(String(format: "%.4f", center.latitude)), \(String(format: "%.4f", center.longitude))]", category: .general, level: .info)
        } else {
            appLog("🔍 ZOOM: \(description) - \(zoomKm)km (\(String(format: "%.3f", span.latitudeDelta))°)", category: .general, level: .info)
        }
    }

    // MARK: - Private Helpers

    private func bindServices() {
        // DIRECT SERVICE SUBSCRIPTIONS - no coordinator middleman

        // Subscribe to PredictionService directly for prediction data and path
        predictionService.$latestPrediction
            .sink { [weak self] prediction in
                guard let self = self else { return }
                self.predictionData = prediction
                // Update smoothed descent rate flag from prediction data

                // Update prediction path based on state machine and prediction data
                if let prediction = prediction,
                   let path = prediction.path,
                   !path.isEmpty,
                   self.predictionPathVisible {
                    self.predictionPath = MKPolyline(coordinates: path, count: path.count)
                    self.refitDuringStartup()
                } else {
                    self.predictionPath = nil
                }

                // Update landing and burst points from prediction
                self.landingPoint = prediction?.landingPoint

                // State machine drives burst point availability
                if self.burstPointVisible {
                    self.burstPoint = prediction?.burstPoint
                } else {
                    self.burstPoint = nil
                }

                self.refreshAnnotations()
            }
            .store(in: &cancellables)

        // Subscribe to route calculation service directly
        routeCalculationService.$currentRoute
            .sink { [weak self] routeData in
                if let routeData = routeData, !routeData.coordinates.isEmpty {
                    self?.userRoute = MKPolyline(coordinates: routeData.coordinates, count: routeData.coordinates.count)
                } else {
                    self?.userRoute = nil
                }
                self?.refitDuringStartup()
            }
            .store(in: &cancellables)

        balloonPositionService.$currentPositionData
            .sink { [weak self] position in
                self?.balloonPosition = position
                self?.refreshAnnotations()
            }
            .store(in: &cancellables)

        // MARK: - Three-Channel Architecture Subscriptions

        // Subscribe to position data channel
        balloonPositionService.$currentPositionData
            .sink { [weak self] position in
                self?.balloonPosition = position
                // Update display position from position data
                if let position = position {
                    self?.balloonDisplayPosition = CLLocationCoordinate2D(
                        latitude: position.latitude,
                        longitude: position.longitude
                    )
                }
                self?.refreshAnnotations()
            }
            .store(in: &cancellables)

        // Subscribe to radio channel data
        balloonPositionService.$currentRadioChannel
            .sink { [weak self] radio in
                self?.balloonRadioChannel = radio

                // Sync mute button state from device
                if let buzmute = radio?.buzmute {
                    self?.isBuzzerMuted = buzmute
                }
            }
            .store(in: &cancellables)

        // Subscribe to settings data from BLE service
        coordinator.bleCommunicationService.$latestSettings
            .sink { [weak self] settings in
                self?.balloonSettings = settings
            }
            .store(in: &cancellables)

        balloonPositionService.$balloonDisplayPosition
            .sink { [weak self] coordinate in
                self?.balloonDisplayPosition = coordinate
                self?.refreshAnnotations()
            }
            .store(in: &cancellables)

        // Subscribe to LandingPointTrackingService for landing point updates (single source of truth)
        landingPointTrackingService.$currentLandingPoint
            .sink { [weak self] (point: CLLocationCoordinate2D?) in
                guard let self = self else { return }

                self.landingPoint = point
                self.refreshAnnotations()
            }
            .store(in: &cancellables)

        // coordinator.$isHeadingMode -> MapPresenter handles this directly
        // coordinator.$isBuzzerMuted -> MapPresenter handles this directly

        routeCalculationService.$transportMode
            .sink { [weak self] mode in
                self?.transportMode = mode
            }
            .store(in: &cancellables)

        // Subscribe directly to services for moved properties
        currentLocationService.$locationData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                self?.userLocation = location
                self?.refreshAnnotations()
            }
            .store(in: &cancellables)

        // Subscribe to BLE service for connection state
        bleService.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionStatus = state.isConnected ? .connected : .disconnected
            }
            .store(in: &cancellables)

        // Subscribe to balloon track service for motion metrics
        balloonTrackService.$motionMetrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.smoothedDescentRate = metrics.adjustedDescentRateMS
            }
            .store(in: &cancellables)

        // Subscribe to BLE service for staleness computation
        coordinator.bleCommunicationService.$lastMessageTimestamp
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (lastUpdate: Date?) in
                let isStale = lastUpdate.map { Date().timeIntervalSince($0) > 3.0 } ?? true
                self?.isDataStale = isStale
            }
            .store(in: &cancellables)

        balloonPositionService.$aprsDataAvailable
            .receive(on: DispatchQueue.main)
            .sink { [weak self] available in
                self?.aprsDataAvailable = available
            }
            .store(in: &cancellables)

        coordinator.$frequencySyncProposal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proposal in
                self?.frequencySyncProposal = proposal
            }
            .store(in: &cancellables)

        // Frequency sync subscription removed - automatic sync only

        currentLocationService.$distanceToBalloon
            .sink { [weak self] distance in
                self?.distanceToBalloon = distance
            }
            .store(in: &cancellables)

        currentLocationService.$isWithin200mOfBalloon
            .sink { [weak self] isWithin in
                self?.isWithin200mOfBalloon = isWithin
            }
            .store(in: &cancellables)

        balloonTrackService.$currentBalloonTrack
            .sink { [weak self] points in
                if points.isEmpty {
                    appLog("MapPresenter: Received EMPTY track update - clearing all track points", category: .general, level: .info)
                } else {
                    appLog("MapPresenter: Received track update with \(points.count) points", category: .general, level: .debug)
                }
                self?.logRedTrack(points)
                self?.trackPoints = points
                self?.refitDuringStartup()
            }
            .store(in: &cancellables)

        coordinator.balloonPositionService.$balloonPhase
            .sink { [weak self] (phase: BalloonPhase) in
                self?.balloonPhase = phase
                self?.refreshAnnotations()
            }
            .store(in: &cancellables)

        landingPointTrackingService.$landingHistory
            .sink { [weak self] history in
                self?.landingHistory = history
            }
            .store(in: &cancellables)

        aprsService.$bleSerialName
            .map { $0 ?? "" }
            .assign(to: &$bleSerialName)

        aprsService.$aprsSerialName
            .map { $0 ?? "" }
            .assign(to: &$aprsSerialName)
    }

    // Frequency sync methods removed - automatic sync only

    // MARK: - Annotation & Camera Helpers

    private func refreshAnnotations() {
        var updatedAnnotations: [MapAnnotationItem] = []

        if let balloonCoordinate = currentBalloonCoordinate {
            updatedAnnotations.append(
                MapAnnotationItem(
                    coordinate: balloonCoordinate,
                    title: "Balloon",
                    type: .balloon
                )
            )
        }

        if userAnnotationVisible, let userCoordinate = userCoordinate {
            updatedAnnotations.append(
                MapAnnotationItem(
                    coordinate: userCoordinate,
                    title: "You",
                    type: .user
                )
            )
        }

        if let landingCoordinate = landingPoint {
            updatedAnnotations.append(
                MapAnnotationItem(
                    coordinate: landingCoordinate,
                    title: "Landing",
                    type: .landing
                )
            )
        }

        if let burstCoordinate = burstPoint,
           burstPointVisible {
            updatedAnnotations.append(
                MapAnnotationItem(
                    coordinate: burstCoordinate,
                    title: "Burst",
                    type: .burst
                )
            )
        }

        annotations = updatedAnnotations
    }

    private var currentBalloonCoordinate: CLLocationCoordinate2D? {
        if let displayPosition = balloonDisplayPosition {
            return displayPosition
        }

        // Use three-channel architecture
        if let position = balloonPosition {
            return CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
        }

        return nil
    }

    private var userCoordinate: CLLocationCoordinate2D? {
        guard let userLocation else { return nil }
        return CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
    }

    private var userAnnotationVisible: Bool {
        guard let userCoordinate, let balloonCoordinate = currentBalloonCoordinate else {
            return false
        }

        if !isLanded {
            return true
        }

        let userLocation = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        let balloonLocation = CLLocation(latitude: balloonCoordinate.latitude, longitude: balloonCoordinate.longitude)
        let distance = userLocation.distance(from: balloonLocation)
        return distance >= 200
    }

    private func performCameraFit() {
        if cameraUpdatesSuspended {
            appLog("MapPresenter: Camera update suspended (settings open)", category: .general, level: .debug)
            return
        }

        if isHeadingMode {
            appLog("MapPresenter: Skipping camera fit - heading mode active", category: .general, level: .debug)
            return
        }

        let coordinates = cameraCoordinates()
        appLog("MapPresenter: Camera fit with \(coordinates.count) coordinates: annotations=\(annotations.count), user=\(userCoordinate != nil), prediction=\(predictionPath != nil), route=\(userRoute != nil)", category: .general, level: .info)

        guard !coordinates.isEmpty,
              let minLat = coordinates.map({ $0.latitude }).min(),
              let maxLat = coordinates.map({ $0.latitude }).max(),
              let minLon = coordinates.map({ $0.longitude }).min(),
              let maxLon = coordinates.map({ $0.longitude }).max() else {
            appLog("MapPresenter: No coordinates available for camera fit - need at least user location or landing point", category: .general, level: .info)
            return
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let latSpan = max((maxLat - minLat) * 1.4, 0.1)
        let lonSpan = max((maxLon - minLon) * 1.4, 0.1)
        let span = MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)

        region = MKCoordinateRegion(center: center, span: span)
        logZoomChange("MapPresenter updateCameraToShowAllAnnotations", span: span, center: center)
    }

    private func cameraCoordinates() -> [CLLocationCoordinate2D] {
        var allCoordinates = annotations.map { $0.coordinate }

        if let userCoordinate {
            allCoordinates.append(userCoordinate)
        }

        // Use predictionPath polyline if available, otherwise use predictionData path
        // Avoid duplication since both represent the same prediction data
        if let predictionPolyline = predictionPath {
            allCoordinates.append(contentsOf: coordinates(from: predictionPolyline))
        } else if let balloonPath = predictionData?.path, !balloonPath.isEmpty {
            allCoordinates.append(contentsOf: balloonPath)
        }

        if let routePolyline = userRoute {
            allCoordinates.append(contentsOf: coordinates(from: routePolyline))
        }

        if !trackPoints.isEmpty {
            allCoordinates.append(contentsOf: trackPoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
        }

        if !landingHistory.isEmpty {
            allCoordinates.append(contentsOf: landingHistory.map { $0.coordinate })
        }

        return allCoordinates
    }

    private func coordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords.filter { CLLocationCoordinate2DIsValid($0) }
    }

}
