import Foundation
import Combine
import MapKit

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
    @Published private(set) var isHeadingMode: Bool = false
    @Published private(set) var transportMode: TransportationMode = .car
    @Published private(set) var isRouteVisible: Bool = true
    @Published private(set) var isBuzzerMuted: Bool = false
    @Published private(set) var distanceToBalloon: CLLocationDistance?
    @Published private(set) var isWithin200mOfBalloon: Bool = false
    @Published private(set) var userLocation: LocationData?
    @Published private(set) var balloonPhase: BalloonPhase = .unknown
    @Published private(set) var region: MKCoordinateRegion?

    // APRS sonde name display (for persistent field in tracking view)
    @Published private(set) var bleSerialName: String = ""
    @Published private(set) var aprsSerialName: String = ""

    // MARK: - Dependencies

    private let coordinator: ServiceCoordinator
    private let balloonTrackService: BalloonTrackService
    private let landingPointTrackingService: LandingPointTrackingService
    private let currentLocationService: CurrentLocationService

    init(
        coordinator: ServiceCoordinator,
        balloonTrackService: BalloonTrackService,
        landingPointTrackingService: LandingPointTrackingService,
        currentLocationService: CurrentLocationService
    ) {
        self.coordinator = coordinator
        self.balloonTrackService = balloonTrackService
        self.landingPointTrackingService = landingPointTrackingService
        self.currentLocationService = currentLocationService

        transportMode = coordinator.transportMode
        distanceToBalloon = currentLocationService.distanceToBalloon
        isWithin200mOfBalloon = currentLocationService.isWithin200mOfBalloon

        bindServices()
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
        coordinator.transportMode = mode
    }

    func requestDeviceParameters() {
        coordinator.requestDeviceParameters()
    }

    func setMuteState(_ muted: Bool) {
        coordinator.setMuteState(muted)
    }

    func triggerShowAllAnnotations() {
        coordinator.triggerShowAllAnnotations()
    }

    func openInAppleMaps() {
        coordinator.openInAppleMaps()
    }

    func triggerPrediction() {
        coordinator.triggerPrediction()
    }

    func updateCameraToShowAllAnnotations() {
        coordinator.updateCameraToShowAllAnnotations()
    }

    func setCameraUpdatesSuspended(_ suspended: Bool) {
        coordinator.suspendCameraUpdates = suspended
    }

    var bleService: BLECommunicationService { coordinator.bleCommunicationService }

    var persistenceService: PersistenceService { coordinator.persistenceService }

    func logZoomChange(_ description: String, span: MKCoordinateSpan, center: CLLocationCoordinate2D? = nil) {
        coordinator.logZoomChange(description, span: span, center: center)
    }

    // MARK: - Private Helpers

    private func bindServices() {
        coordinator.$predictionPath
            .assign(to: &$predictionPath)

        coordinator.$userRoute
            .assign(to: &$userRoute)

        coordinator.$balloonTelemetry
            .assign(to: &$balloonTelemetry)

        coordinator.$balloonDisplayPosition
            .assign(to: &$balloonDisplayPosition)

        coordinator.$landingPoint
            .assign(to: &$landingPoint)

        coordinator.$burstPoint
            .assign(to: &$burstPoint)

        coordinator.$isHeadingMode
            .assign(to: &$isHeadingMode)

        coordinator.$isRouteVisible
            .assign(to: &$isRouteVisible)

        coordinator.$isBuzzerMuted
            .assign(to: &$isBuzzerMuted)

        currentLocationService.$distanceToBalloon
            .assign(to: &$distanceToBalloon)

        currentLocationService.$isWithin200mOfBalloon
            .assign(to: &$isWithin200mOfBalloon)

        balloonTrackService.$currentBalloonTrack
            .assign(to: &$trackPoints)

        balloonTrackService.$balloonPhase
            .assign(to: &$balloonPhase)

        landingPointTrackingService.$landingHistory
            .assign(to: &$landingHistory)

        coordinator.$transportMode
            .assign(to: &$transportMode)

        coordinator.$userLocation
            .assign(to: &$userLocation)

        coordinator.$region
            .assign(to: &$region)

        // APRS sonde name display
        coordinator.$bleSerialName
            .assign(to: &$bleSerialName)

        coordinator.$aprsSerialName
            .assign(to: &$aprsSerialName)
    }
}
