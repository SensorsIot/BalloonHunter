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
    @Published private(set) var balloonTelemetry: TelemetryData?
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
    // Frequency sync proposal removed - automatic sync only

    // MARK: - Dependencies

    private let coordinator: ServiceCoordinator
    private let balloonTrackService: BalloonTrackService
    private let balloonPositionService: BalloonPositionService
    private let landingPointTrackingService: LandingPointTrackingService
    private let currentLocationService: CurrentLocationService
    private let aprsTelemetryService: APRSTelemetryService
    private let routeCalculationService: RouteCalculationService

    private var cancellables = Set<AnyCancellable>()

    init(
        coordinator: ServiceCoordinator,
        balloonTrackService: BalloonTrackService,
        balloonPositionService: BalloonPositionService,
        landingPointTrackingService: LandingPointTrackingService,
        currentLocationService: CurrentLocationService,
        aprsTelemetryService: APRSTelemetryService,
        routeCalculationService: RouteCalculationService
    ) {
        self.coordinator = coordinator
        self.balloonTrackService = balloonTrackService
        self.balloonPositionService = balloonPositionService
        self.landingPointTrackingService = landingPointTrackingService
        self.currentLocationService = currentLocationService
        self.aprsTelemetryService = aprsTelemetryService
        self.routeCalculationService = routeCalculationService

        transportMode = routeCalculationService.transportMode
        distanceToBalloon = currentLocationService.distanceToBalloon
        isWithin200mOfBalloon = currentLocationService.isWithin200mOfBalloon

        bindServices()
        refreshAnnotations()
    }

    // MARK: - Derived Flags

    var isFlying: Bool {
        balloonPhase != .landed && balloonPhase != .unknown
    }

    var isLanded: Bool {
        balloonPhase == .landed
    }

    var shouldShowRoute: Bool {
        guard isLanded else { return true }
        return !isWithin200mOfBalloon
    }

    // MARK: - Intent Handlers

    func toggleHeadingMode() {
        coordinator.isHeadingMode.toggle()
    }

    func setTransportMode(_ mode: TransportationMode) {
        appLog("MapPresenter: Transport mode changed to \(mode)", category: .general, level: .info)
        routeCalculationService.setTransportMode(mode)
    }

    func requestDeviceParameters() {
        coordinator.bleCommunicationService.getParameters()
    }

    func setMuteState(_ muted: Bool) {
        coordinator.isBuzzerMuted = muted
        isBuzzerMuted = muted
        appLog("MapPresenter: Setting mute state to \(muted)", category: .general, level: .info)
        coordinator.bleCommunicationService.setMute(muted)
    }

    func triggerShowAllAnnotations() {
        updateCameraToShowAllAnnotations()
    }

    func openInAppleMaps() {
        coordinator.openInAppleMaps()
    }

    func triggerPrediction() {
        coordinator.triggerPrediction()
    }

    func updateCameraToShowAllAnnotations() {
        performCameraFit()
    }

    func setCameraUpdatesSuspended(_ suspended: Bool) {
        coordinator.suspendCameraUpdates = suspended
        cameraUpdatesSuspended = suspended
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
        coordinator.$predictionPath
            .sink { [weak self] path in
                self?.predictionPath = path
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
            }
            .store(in: &cancellables)

        coordinator.$predictionData
            .sink { [weak self] data in
                self?.predictionData = data
            }
            .store(in: &cancellables)

        balloonPositionService.$currentTelemetry
            .sink { [weak self] telemetry in
                self?.balloonTelemetry = telemetry
                self?.refreshAnnotations()
            }
            .store(in: &cancellables)

        balloonPositionService.$balloonDisplayPosition
            .sink { [weak self] coordinate in
                self?.balloonDisplayPosition = coordinate
                self?.refreshAnnotations()
            }
            .store(in: &cancellables)

        balloonPositionService.$landingPoint
            .sink { [weak self] point in
                self?.landingPoint = point
                self?.refreshAnnotations()
            }
            .store(in: &cancellables)

        coordinator.$burstPoint
            .sink { [weak self] point in
                self?.burstPoint = point
                self?.refreshAnnotations()
            }
            .store(in: &cancellables)

        coordinator.$isHeadingMode
            .sink { [weak self] headingMode in
                self?.isHeadingMode = headingMode
            }
            .store(in: &cancellables)


        coordinator.$isBuzzerMuted
            .sink { [weak self] muted in
                self?.isBuzzerMuted = muted
            }
            .store(in: &cancellables)

        routeCalculationService.$transportMode
            .sink { [weak self] mode in
                self?.transportMode = mode
            }
            .store(in: &cancellables)

        coordinator.$userLocation
            .sink { [weak self] location in
                self?.userLocation = location
                self?.refreshAnnotations()
            }
            .store(in: &cancellables)

        coordinator.$suspendCameraUpdates
            .sink { [weak self] suspended in
                self?.cameraUpdatesSuspended = suspended
            }
            .store(in: &cancellables)

        coordinator.$showAllAnnotations
            .sink { [weak self] shouldShow in
                if shouldShow {
                    self?.triggerShowAllAnnotations()
                }
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
                self?.trackPoints = points
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

        aprsTelemetryService.$bleSerialName
            .map { $0 ?? "" }
            .assign(to: &$bleSerialName)

        aprsTelemetryService.$aprsSerialName
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

        if shouldShowUserAnnotation, let userCoordinate = userCoordinate {
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
           balloonPhase == .ascending {
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

        if let telemetry = balloonTelemetry {
            return CLLocationCoordinate2D(latitude: telemetry.latitude, longitude: telemetry.longitude)
        }

        return nil
    }

    private var userCoordinate: CLLocationCoordinate2D? {
        guard let userLocation else { return nil }
        return CLLocationCoordinate2D(latitude: userLocation.latitude, longitude: userLocation.longitude)
    }

    private var shouldShowUserAnnotation: Bool {
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
