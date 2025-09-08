import Foundation
import Combine
import CoreLocation

@MainActor
final class LandingPointService: ObservableObject {
    @Published var validLandingPoint: CLLocationCoordinate2D? = nil

    private let balloonTrackingService: BalloonTrackingService
    private let predictionService: PredictionService
    private let persistenceService: PersistenceService

    private var cancellables = Set<AnyCancellable>()

    init(
        balloonTrackingService: BalloonTrackingService,
        predictionService: PredictionService,
        persistenceService: PersistenceService
    ) {
        self.balloonTrackingService = balloonTrackingService
        self.predictionService = predictionService
        self.persistenceService = persistenceService

        // Combine publishers to listen for changes
        balloonTrackingService.$isLanded
            .combineLatest(balloonTrackingService.$landedPosition, predictionService.$predictionData)
            .sink { [weak self] _, _, _ in
                self?.updateValidLandingPoint()
            }
            .store(in: &cancellables)
    }

    private func updateValidLandingPoint() {
        if balloonTrackingService.isLanded, let landedPosition = balloonTrackingService.landedPosition {
            validLandingPoint = landedPosition
            print("Valid landing point from Telemetry: \(landedPosition)")
        } else if let predictedLandingPoint = predictionService.predictionData?.landingPoint {
            validLandingPoint = predictedLandingPoint
            print("Valid landing point from Prediction: \(predictedLandingPoint)")
        } else if let manualLandingPoint = persistenceService.loadLandingPoint(sondeName: "manual_override") {
            validLandingPoint = manualLandingPoint
            print("Valid landing point from Clipboard: \(manualLandingPoint)")
        } else if let sondeName = balloonTrackingService.currentBalloonName, let persistedLandingPoint = persistenceService.loadLandingPoint(sondeName: sondeName) {
            validLandingPoint = persistedLandingPoint
            print("Valid landing point from Persistence: \(persistedLandingPoint)")
        } else {
            validLandingPoint = nil
            print("No valid landing point available")
        }

        if let validLandingPoint = validLandingPoint, let sondeName = balloonTrackingService.currentBalloonName {
            persistenceService.saveLandingPoint(sondeName: sondeName, coordinate: validLandingPoint)
        }
    }
}
