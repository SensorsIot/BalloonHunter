import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

@MainActor
final class BalloonTrackingService: ObservableObject {
    @Published var currentBalloonTrack: [BalloonTrackPoint] = []
    @Published var currentEffectiveDescentRate: Double? = nil
    
    var hasReceivedFirstTelemetry: Bool = false
    var currentBalloonName: String?
    var telemetryPointCounter: Int = 0
    private(set) var last5Telemetry: [TelemetryData] = []
    
    private var persistenceService: PersistenceService
    private var bleService: BLECommunicationService
    
    weak var predictionService: PredictionService?
    
    private var cancellables = Set<AnyCancellable>()
    
    private var recentDescentRates: [Double] = []
    private let descentRateSmoothingWindow = 20
    
    init(persistenceService: PersistenceService, bleService: BLECommunicationService) {
        self.persistenceService = persistenceService
        self.bleService = bleService
        print("[DEBUG] BalloonTrackingService init")
        setupSubscriptions()
    }
    
    private func setupSubscriptions() {
        // Only update descent rate on every telemetry.
        // Prediction (fetchPrediction) will be triggered explicitly after the first telemetry or externally.
        bleService.$latestTelemetry
            .compactMap { $0 }
            .sink { [weak self] telemetry in
                self?.processTelemetryData(telemetry)
            }
            .store(in: &cancellables)
    }
    
    /// Public method to allow external triggers (UI, timer) to fetch predictions explicitly.
    func triggerPrediction() {
        // Empty implementation as per instructions
    }
    
    func processTelemetryData(_ telemetryData: TelemetryData) {
        if currentBalloonName == nil || telemetryData.sondeName != currentBalloonName {
            persistenceService.purgeAllTracks()
            let persistedTrack = persistenceService.loadTrackForCurrentSonde(sondeName: telemetryData.sondeName)
            if let track = persistedTrack {
                self.currentBalloonTrack = track
                print("[DEBUG] BalloonTrackingService: Loaded persisted track for \(telemetryData.sondeName) with \(self.currentBalloonTrack.count) points.")
            } else {
                self.currentBalloonTrack = []
                print("[DEBUG] BalloonTrackingService: Purged old tracks and reset track for new sonde: \(telemetryData.sondeName).")
            }
            telemetryPointCounter = 0
        }
        
        self.currentBalloonName = telemetryData.sondeName
        
        let newBalloonTrackPoint = BalloonTrackPoint(telemetryData: telemetryData)
        self.currentBalloonTrack.append(newBalloonTrackPoint)
        self.last5Telemetry.append(telemetryData)
        if self.last5Telemetry.count > 5 {
            self.last5Telemetry.removeFirst()
        }
        self.telemetryPointCounter += 1
        
        // Descent rate calculation logic internal to BalloonTrackingService
        if telemetryData.verticalSpeed < 0 {
            let currentTimestamp = telemetryData.lastUpdateTime.map { Date(timeIntervalSince1970: $0) } ?? Date()
            let oneMinuteAgo = currentTimestamp.addingTimeInterval(-60)
            
            // Find historical track point from approx. 1 minute ago
            if let historicalPoint = currentBalloonTrack.last(where: { $0.timestamp <= oneMinuteAgo }) {
                let deltaHeight = telemetryData.altitude - historicalPoint.altitude
                let deltaTime = currentTimestamp.timeIntervalSince(historicalPoint.timestamp)
                
                if deltaTime > 0 {
                    let descentRate = deltaHeight / deltaTime
                    
                    // Append to recent descent rates and smooth
                    recentDescentRates.append(descentRate)
                    if recentDescentRates.count > descentRateSmoothingWindow {
                        recentDescentRates.removeFirst()
                    }
                    let smoothedDescentRate = recentDescentRates.reduce(0, +) / Double(recentDescentRates.count)
                    currentEffectiveDescentRate = smoothedDescentRate
                    
                    
                
                }
            } else {
                
            }
        } else {
        }
        
        if telemetryPointCounter % 100 == 0 {
            persistenceService.saveCurrentBalloonTrack(sondeName: telemetryData.sondeName, track: self.currentBalloonTrack)
            print("[DEBUG] BalloonTrackingService: Saved current balloon track for \(telemetryData.sondeName) (\(self.currentBalloonTrack.count) points) due to 100-point trigger.")
        }
    }
    
    /*
     Separation of concerns:
     - updateDescentRateForLatestTelemetry is called on every telemetry update to keep descent rate current.
     - fetchPrediction is only called on the first telemetry and when explicitly triggered externally (e.g. from UI or timer)
       to avoid excessive prediction calls on every telemetry packet.
     */
}

