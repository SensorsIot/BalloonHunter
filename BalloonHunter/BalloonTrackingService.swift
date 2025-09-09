import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import os

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
        let smoothedV = vCount >= smoothingWindowSize ? last20VerticalSpeeds.reduce(0, +) / Double(vCount) : last.verticalSpeed
        let smoothedH = hCount >= smoothingWindowSize ? last20HorizontalSpeeds.reduce(0, +) / Double(hCount) : last.horizontalSpeed
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
    private var last20DescentRates: [Double] = []
    private let descentRateSmoothingWindow = 20
    private var last100Positions: [CLLocationCoordinate2D] = []
    private var last20VerticalSpeeds: [Double] = []
    private var last20HorizontalSpeeds: [Double] = []
    private let smoothingWindowSize = 5 // For general use
    private let landingDetectionSmoothingWindow = 20 // For landing detection smoothing
    
    var smoothedDescentRate: Double? {
        if last20DescentRates.count >= 3 {
            return last20DescentRates.reduce(0, +) / Double(last20DescentRates.count)
        }
        return nil
    }
    
    init(persistenceService: PersistenceService, bleService: BLECommunicationService) {
        self.persistenceService = persistenceService
        self.bleService = bleService
        print("[DEBUG] BalloonTrackingService init")
        setupSubscriptions()
        loadPersistedDataAtStartup()
    }
    
    /// Load any persisted balloon data at startup
    private func loadPersistedDataAtStartup() {
        // Try to load any existing track data from persistence
        // Note: We don't know the sonde name yet, so we can't load specific tracks
        // But we can prepare the service for when telemetry arrives
        appLog("BalloonTrackingService ready to load persisted data on first telemetry", category: .service, level: .info)
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
            appLog("BalloonTrackingService: New sonde detected - \(telemetryData.sondeName), switching from \(currentBalloonName ?? "none")", category: .service, level: .info)
            persistenceService.purgeAllTracks()
            let persistedTrack = persistenceService.loadTrackForCurrentSonde(sondeName: telemetryData.sondeName)
            if let track = persistedTrack {
                self.currentBalloonTrack = track
                appLog("BalloonTrackingService: Loaded persisted track for \(telemetryData.sondeName) with \(self.currentBalloonTrack.count) points", category: .service, level: .info)
            } else {
                self.currentBalloonTrack = []
                appLog("BalloonTrackingService: No persisted track found - starting fresh track for \(telemetryData.sondeName)", category: .service, level: .info)
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
                    
                    // Append to last20DescentRates for smoothing
                    last20DescentRates.append(descentRate)
                    if last20DescentRates.count > descentRateSmoothingWindow {
                        last20DescentRates.removeFirst()
                    }
                    
                    // Update currentEffectiveDescentRate with smoothed value or fall back
                    if let smooth = smoothedDescentRate {
                        currentEffectiveDescentRate = smooth
                    } else {
                        currentEffectiveDescentRate = descentRate
                    }
                }
            } else {
                
            }
        } else {
        }
        
        if telemetryPointCounter % 100 == 0 {
            persistenceService.saveCurrentBalloonTrack(sondeName: telemetryData.sondeName, track: self.currentBalloonTrack)
            print("[DEBUG] BalloonTrackingService: Saved current balloon track for \(telemetryData.sondeName) (\(self.currentBalloonTrack.count) points) due to 100-point trigger.")
        }

        // Landing detection logic with proper smoothing and thresholds
        if let lastUpdateTime = telemetryData.lastUpdateTime, Date().timeIntervalSince(Date(timeIntervalSince1970: lastUpdateTime)) < 3 {
            // Use 20-value smoothing for landing detection as specified
            last20VerticalSpeeds.append(telemetryData.verticalSpeed)
            if last20VerticalSpeeds.count > landingDetectionSmoothingWindow {
                last20VerticalSpeeds.removeFirst()
            }
            let smoothedVerticalSpeed = abs(last20VerticalSpeeds.reduce(0, +) / Double(last20VerticalSpeeds.count))

            last20HorizontalSpeeds.append(telemetryData.horizontalSpeed)
            if last20HorizontalSpeeds.count > landingDetectionSmoothingWindow {
                last20HorizontalSpeeds.removeFirst()
            }
            let smoothedHorizontalSpeedKmH = last20HorizontalSpeeds.reduce(0, +) / Double(last20HorizontalSpeeds.count)

            // Check landing conditions: vertical < 2 m/s AND horizontal < 2 km/h
            if smoothedVerticalSpeed < 2.0 && smoothedHorizontalSpeedKmH < 2.0 {
                isLanded = true
                // Update landed position with smoothed (100 positions)
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

