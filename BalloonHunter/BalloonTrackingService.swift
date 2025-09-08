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
    @Published var isLanded = false
    @Published var landedPosition: CLLocationCoordinate2D? = nil
    
    /// Exposes the latest telemetry in a safe, encapsulated way.
    var latestTelemetry: TelemetryData? {
        bleService.latestTelemetry
    }
    
    // Balloon is considered flying if recent telemetry received and smoothed vertical >=2 m/s or horizontal >=2 km/h
    var isBalloonFlying: Bool {
        guard let last = last5Telemetry.last, let lastUpdate = last.lastUpdateTime,
              Date().timeIntervalSince(Date(timeIntervalSince1970: lastUpdate)) < 3
        else { return false }
        // Use last20 values if sufficient, else fallback to last
        let vCount = last20VerticalSpeeds.count
        let hCount = last20HorizontalSpeeds.count
        let smoothedV = vCount >= 5 ? last20VerticalSpeeds.reduce(0, +) / Double(vCount) : last.verticalSpeed
        let smoothedH = hCount >= 5 ? last20HorizontalSpeeds.reduce(0, +) / Double(hCount) : last.horizontalSpeed
        return abs(smoothedV) >= 2 || abs(smoothedH) >= 2
    }
    
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
    private var last100Positions: [CLLocationCoordinate2D] = []
    private var last20VerticalSpeeds: [Double] = []
    private var last20HorizontalSpeeds: [Double] = []
    
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

        // Landing detection logic
        if let lastUpdateTime = telemetryData.lastUpdateTime, Date().timeIntervalSince(Date(timeIntervalSince1970: lastUpdateTime)) < 3 {
            last20VerticalSpeeds.append(telemetryData.verticalSpeed)
            if last20VerticalSpeeds.count > 20 {
                last20VerticalSpeeds.removeFirst()
            }
            let smoothedVerticalSpeed = last20VerticalSpeeds.reduce(0, +) / Double(last20VerticalSpeeds.count)

            last20HorizontalSpeeds.append(telemetryData.horizontalSpeed)
            if last20HorizontalSpeeds.count > 20 {
                last20HorizontalSpeeds.removeFirst()
            }
            let smoothedHorizontalSpeed = last20HorizontalSpeeds.reduce(0, +) / Double(last20HorizontalSpeeds.count)

            if smoothedVerticalSpeed < 2 && smoothedHorizontalSpeed < 2 {
                isLanded = true
                last100Positions.append(CLLocationCoordinate2D(latitude: telemetryData.latitude, longitude: telemetryData.longitude))
                if last100Positions.count > 100 {
                    last100Positions.removeFirst()
                }
                let avgLat = last100Positions.map { $0.latitude }.reduce(0, +) / Double(last100Positions.count)
                let avgLon = last100Positions.map { $0.longitude }.reduce(0, +) / Double(last100Positions.count)
                landedPosition = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            } else {
                isLanded = false
            }
        }
    }
    
    /*
     Separation of concerns:
     - updateDescentRateForLatestTelemetry is called on every telemetry update to keep descent rate current.
     - fetchPrediction is only called on the first telemetry and when explicitly triggered externally (e.g. from UI or timer)
       to avoid excessive prediction calls on every telemetry packet.
     */
}

