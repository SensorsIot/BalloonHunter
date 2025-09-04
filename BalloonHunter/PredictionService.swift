import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit

@MainActor
final class PredictionService: NSObject, ObservableObject {
    @Published var appInitializationFinished: Bool = false
    weak var routeCalculationService: RouteCalculationService?
    weak var currentLocationService: CurrentLocationService?
    weak var balloonTrackingService: BalloonTrackingService? // New property

    init(routeCalculationService: RouteCalculationService, currentLocationService: CurrentLocationService, balloonTrackingService: BalloonTrackingService) {
        self.routeCalculationService = routeCalculationService
        self.currentLocationService = currentLocationService
        self.balloonTrackingService = balloonTrackingService // Initialize new property
        super.init()
        print("[DEBUG][State: \(SharedAppState.shared.appState.rawValue)] PredictionService init: \(Unmanaged.passUnretained(self).toOpaque())")
    }
    
    @Published var predictionData: PredictionData? { didSet { } }
    @Published var lastAPICallURL: String? = nil
    @Published var isLoading: Bool = false

    private var path: [CLLocationCoordinate2D] = []
    private var burstPoint: CLLocationCoordinate2D? = nil
    private var landingPoint: CLLocationCoordinate2D? = nil
    private var landingTime: Date? = nil
    private var lastPredictionFetchTime: Date?
    @Published var predictionStatus: PredictionStatus = .noValidPrediction
    @Published var currentEffectiveDescentRate: Double? = nil // New property

    nonisolated private struct APIResponse: Codable {
        struct Prediction: Codable {
            struct TrajectoryPoint: Codable {
                let altitude: Double?
                let datetime: String?
                let latitude: Double?
                let longitude: Double?
            }
            let stage: String
            let trajectory: [TrajectoryPoint]
        }
        let prediction: [Prediction]
    }
    func fetchPrediction(telemetry: TelemetryData, userSettings: UserSettings) async {
        if SharedAppState.shared.appState == .finalApproach {
            return
        }
        if let lastFetchTime = lastPredictionFetchTime {
            let timeSinceLastFetch = Date().timeIntervalSince(lastFetchTime)
            if timeSinceLastFetch < 30 {
                return
            }
        }
        lastPredictionFetchTime = Date()
        predictionStatus = .fetching
        isLoading = true
        print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Fetching prediction...")
        path = []
        burstPoint = nil
        landingPoint = nil
        landingTime = nil
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let launchDatetime = dateFormatter.string(from: Date().addingTimeInterval(60))
        var adjustedBurstAltitude = userSettings.burstAltitude
        if telemetry.verticalSpeed < 0 {
            adjustedBurstAltitude = telemetry.altitude + 10.0
        }

        var effectiveDescentRate = userSettings.descentRate // Start with user's setting

        // Automatic adjustment of descending speed
        if telemetry.altitude < 15000 && telemetry.verticalSpeed < 0 {
            // telemetry.lastUpdateTime is a Date?, so this usage is correct
            let currentTelemetryTime = telemetry.lastUpdateTime.map { Date(timeIntervalSince1970: $0) } ?? Date()
            if let balloonTrackingService = balloonTrackingService,
               let historicalPoint = findHistoricalPoint(in: balloonTrackingService.currentBalloonTrack, currentTelemetryTime: currentTelemetryTime) {
                let exactTimeDifference = currentTelemetryTime.timeIntervalSince(historicalPoint.timestamp)

                if exactTimeDifference > 0.1 { // Use a small threshold to avoid near-zero division
                    let altitudeChange = historicalPoint.altitude - telemetry.altitude
                    effectiveDescentRate = abs(altitudeChange / exactTimeDifference)
                }
            }
        }
        self.currentEffectiveDescentRate = effectiveDescentRate // Update the published property

        let urlString = "https://api.v2.sondehub.org/tawhiri?launch_latitude=\(telemetry.latitude)&launch_longitude=\(telemetry.longitude)&launch_altitude=\(telemetry.altitude)&launch_datetime=\(launchDatetime)&ascent_rate=\(userSettings.ascentRate)&descent_rate=\(effectiveDescentRate)&burst_altitude=\(adjustedBurstAltitude)"
        self.lastAPICallURL = urlString
        print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] API Call: \(urlString)")
        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
            await MainActor.run { @MainActor in
                self.path = []
                var ascentPoints: [CLLocationCoordinate2D] = []
                var descentPoints: [CLLocationCoordinate2D] = []

                for p in apiResponse.prediction {
                    if p.stage == "ascent" {
                        for point in p.trajectory {
                            if let lat = point.latitude, let lon = point.longitude {
                                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                                ascentPoints.append(coord)
                            }
                        }
                        self.burstPoint = ascentPoints.last
                    } else if p.stage == "descent" {
                        var lastDescentPoint: APIResponse.Prediction.TrajectoryPoint? = nil
                        for point in p.trajectory {
                            if let lat = point.latitude, let lon = point.longitude {
                                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                                descentPoints.append(coord)
                                lastDescentPoint = point
                            }
                        }
                        if let last = lastDescentPoint, let lat = last.latitude, let lon = last.longitude {
                            self.landingPoint = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                            if lat == 0 && lon == 0 {
                                print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Landing point is at (0,0) -- likely invalid")
                            }
                            if let dt = last.datetime {
                                let formatter = ISO8601DateFormatter()
                                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                self.landingTime = formatter.date(from: dt)
                            }
                        }
                    }
                }
                self.path = ascentPoints + descentPoints

                if let landingPoint = self.landingPoint {
                    let newPredictionData = PredictionData(path: self.path, burstPoint: self.burstPoint, landingPoint: landingPoint, landingTime: self.landingTime)
                    self.predictionData = newPredictionData
                    
                    self.predictionStatus = .success
                    if self.appInitializationFinished == false {
                        self.appInitializationFinished = true
                    }
                } else {
                    print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Prediction parsing finished, but no valid landing point found.")
                    if case .fetching = self.predictionStatus {
                        self.predictionStatus = .noValidPrediction
                    }
                }
                self.isLoading = false
            }
        } catch {
            await MainActor.run { @MainActor in
                print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Network or JSON parsing failed: \(error.localizedDescription)")
                self.predictionStatus = .error(error.localizedDescription)
                self.isLoading = false
            }
            print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Prediction fetch failed with error: \(error.localizedDescription)")
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .dataCorrupted(let context):
                    print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Data corrupted: \(context.debugDescription)")
                    if let underlyingError = context.underlyingError {
                        print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Underlying error: \(underlyingError.localizedDescription)")
                    }
                case .keyNotFound(let key, let context):
                    print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Key '\(key)' not found: \(context.debugDescription)")
                case .valueNotFound(let type, let context):
                    print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Value of type '\(type)' not found: \(context.debugDescription)")
                case .typeMismatch(let type, let context):
                    print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Type mismatch for type '\(type)': \(context.debugDescription)")
                @unknown default:
                    print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Unknown decoding error: \(decodingError.localizedDescription)")
                }
            }
            print("[Debug][PredictionService][State: \(SharedAppState.shared.appState.rawValue)] Return JSON: (Raw data not captured for logging in this scope)")
        }
    }

    // Helper function for finding historical point
    private func findHistoricalPoint(in track: [BalloonTrackPoint], currentTelemetryTime: Date) -> BalloonTrackPoint? {
        guard !track.isEmpty else { return nil }

        let oneMinuteAgo = currentTelemetryTime.addingTimeInterval(-60)

        // Iterate backwards from the most recent point
        for i in (0..<track.count).reversed() {
            let point = track[i]
            if point.timestamp < oneMinuteAgo {
                return point // This is the first point older than 1 minute ago
            }
        }
        return nil // No point found that is older than 1 minute ago
    }
}

