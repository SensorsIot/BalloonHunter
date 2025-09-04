
import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

@MainActor
final class BalloonTrackingService: ObservableObject {
    @Published var currentBalloonTrack: [BalloonTrackPoint] = []
    var hasReceivedFirstTelemetry: Bool = false
    var currentBalloonName: String?
    var telemetryPointCounter: Int = 0

    private var persistenceService: PersistenceService
    private var bleService: BLECommunicationService

    private var cancellables = Set<AnyCancellable>()

    init(persistenceService: PersistenceService, bleService: BLECommunicationService) {
        self.persistenceService = persistenceService
        self.bleService = bleService
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BalloonTrackingService init")
        setupSubscriptions()
    }

    private func setupSubscriptions() {
        bleService.$latestTelemetry
            .compactMap { $0 }
            .sink { [weak self] telemetry in
                self?.processTelemetryData(telemetry)
            }
            .store(in: &cancellables)
    }

    func processTelemetryData(_ telemetryData: TelemetryData) {
        if !hasReceivedFirstTelemetry {
            hasReceivedFirstTelemetry = true
            let persistedTrack = persistenceService.loadTrackForCurrentSonde(sondeName: telemetryData.sondeName)
            if let track = persistedTrack {
                self.currentBalloonTrack = track
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BalloonTrackingService: Loaded persisted track for \(telemetryData.sondeName) with \(self.currentBalloonTrack.count) points.")
            } else {
                persistenceService.purgeAllTracks()
                self.currentBalloonTrack = []
                print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BalloonTrackingService: Purged old tracks for new sonde: \(telemetryData.sondeName).")
            }
        }

        let newBalloonTrackPoint = BalloonTrackPoint(telemetryData: telemetryData)
        self.currentBalloonTrack.append(newBalloonTrackPoint)
        self.currentBalloonName = telemetryData.sondeName
        self.telemetryPointCounter += 1

        if telemetryPointCounter % 100 == 0 {
            persistenceService.saveCurrentBalloonTrack(sondeName: telemetryData.sondeName, track: self.currentBalloonTrack)
            print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] BalloonTrackingService: Saved current balloon track for \(telemetryData.sondeName) (\(self.currentBalloonTrack.count) points) due to 100-point trigger.")
        }
    }
}
