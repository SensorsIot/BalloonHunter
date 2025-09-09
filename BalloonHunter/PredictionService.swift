import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation
import MapKit
import OSLog

@MainActor
final class PredictionService: NSObject, ObservableObject {
    @Published var appInitializationFinished: Bool = false
    weak var routeCalculationService: RouteCalculationService?
    weak var currentLocationService: CurrentLocationService?
    weak var balloonTrackingService: BalloonTrackingService? // New property

    weak var persistenceService: PersistenceService?
    private var userSettings: UserSettings // Added UserSettings

    init(currentLocationService: CurrentLocationService, balloonTrackingService: BalloonTrackingService, persistenceService: PersistenceService, userSettings: UserSettings) {
        self.currentLocationService = currentLocationService
        self.balloonTrackingService = balloonTrackingService // Initialize new property
        self.persistenceService = persistenceService
        self.userSettings = userSettings // Initialize UserSettings
        super.init()
        print("[DEBUG] PredictionService init: \(Unmanaged.passUnretained(self).toOpaque()))")
    }

    @Published var predictionData: PredictionData? { didSet { } }
    @Published var lastAPICallURL: String? = nil
    @Published var isLoading: Bool = false

    private var path: [CLLocationCoordinate2D] = []
    private var burstPoint: CLLocationCoordinate2D? = nil
    private var landingPoint: CLLocationCoordinate2D? = nil
    private var landingTime: Date? = nil
    @Published var predictionStatus: PredictionStatus = .noValidPrediction
    @Published var healthStatus: ServiceHealth = .healthy
    private var failureCount: Int = 0
    private var retryDelay: TimeInterval = 1.0
    

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

    /// Call this in response to explicit prediction triggers only (timer, UI, startup).
    /// Performs the prediction fetch from the external API using telemetry and user settings.
    func fetchPrediction(telemetry: TelemetryData, userSettings: UserSettings, measuredDescentRate: Double? = nil, version: Int) async {
        print("[DEBUG] fetchPrediction entered.")
        
        predictionStatus = .fetching
        isLoading = true
        print("[Debug][PredictionService] Fetching prediction...")

        persistenceService?.clearLandingPoint(sondeName: telemetry.sondeName)

        path = []
        burstPoint = nil
        landingPoint = nil
        landingTime = nil

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let launchDatetime = dateFormatter.string(from: Date().addingTimeInterval(60))
        
        print("[DEBUG][PredictionService] altitude: \(telemetry.altitude), measuredDescentRate: \(String(describing: measuredDescentRate)), userDescentRate: \(userSettings.descentRate)")
        let useMeasured = (telemetry.altitude < 10000)
        let measured = measuredDescentRate ?? userSettings.descentRate
        let effectiveDescentRate = abs(useMeasured ? measured : userSettings.descentRate)
        print("[DEBUG][PredictionService] useMeasured: \(useMeasured), measured: \(measured), effectiveDescentRate: \(effectiveDescentRate)")
        
        var adjustedBurstAltitude = userSettings.burstAltitude
        if telemetry.verticalSpeed < 0 {
            adjustedBurstAltitude = telemetry.altitude + 10.0
        }

        let urlString = "https://api.v2.sondehub.org/tawhiri?launch_latitude=\(telemetry.latitude)&launch_longitude=\(telemetry.longitude)&launch_altitude=\(telemetry.altitude)&launch_datetime=\(launchDatetime)&ascent_rate=\(userSettings.ascentRate)&descent_rate=\(effectiveDescentRate)&burst_altitude=\(adjustedBurstAltitude)"
        self.lastAPICallURL = urlString
        print("[Debug][PredictionService] API Call: \(urlString)")
        guard let url = URL(string: urlString) else {
            isLoading = false
            self.healthStatus = .unhealthy // Invalid URL is a persistent issue
            appLog("PredictionService: Invalid URL: \(urlString)", category: .service, level: .error)
            return
        }
        do {
            appLog("PredictionService: Attempting URLSession data task.", category: .service, level: .debug)
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                appLog("PredictionService: HTTP Status Code: \(httpResponse.statusCode)", category: .service, level: .debug)
                if httpResponse.statusCode != 200 {
                    let errorString = String(data: data, encoding: .utf8) ?? "Unknown error"
                    appLog("PredictionService: API returned error status code: \(httpResponse.statusCode), response: \(errorString)", category: .service, level: .error)
                    throw URLError(.badServerResponse)
                }
            }
            appLog("PredictionService: Data received, attempting JSON decode.", category: .service, level: .debug)
            let apiResponse = try JSONDecoder().decode(APIResponse.self, from: data)
            appLog("PredictionService: JSON decode successful.", category: .service, level: .debug)
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
                                print("[Debug][PredictionService] Landing point is at (0,0) -- likely invalid")
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
                    self.persistenceService?.saveLandingPoint(sondeName: telemetry.sondeName, coordinate: landingPoint)
                    var newPredictionData = PredictionData(path: self.path, burstPoint: self.burstPoint, landingPoint: landingPoint, landingTime: self.landingTime)
                    newPredictionData.version = version
                    self.predictionData = newPredictionData
                    appLog("PredictionService: PredictionData set successfully.", category: .service, level: .debug)

                    self.predictionStatus = .success
                    self.healthStatus = .healthy // Success, reset health
                    self.failureCount = 0
                    self.retryDelay = 1.0

                    if self.appInitializationFinished == false {
                        self.appInitializationFinished = true
                    }
                } else {
                    print("[Debug][PredictionService] Prediction parsing finished, but no valid landing point found.")
                    if case .fetching = self.predictionStatus {
                        self.predictionStatus = .noValidPrediction
                    }
                    self.failureCount += 1
                    self.retryDelay = min(self.retryDelay * 2, 60.0) // Exponential backoff, max 60s
                    self.healthStatus = self.failureCount >= 3 ? .unhealthy : .degraded
                    appLog("PredictionService: No valid landing point found after parsing.", category: .service, level: .error)
                }
                self.isLoading = false
            }
        } catch {
            await MainActor.run { @MainActor in
                appLog("Network or JSON parsing failed: \(error.localizedDescription)", category: .service, level: .error)
                self.predictionStatus = .error(error.localizedDescription)
                self.isLoading = false

                self.failureCount += 1
                self.retryDelay = min(self.retryDelay * 2, 60.0) // Exponential backoff, max 60s
                self.healthStatus = self.failureCount >= 3 ? .unhealthy : .degraded
            }
            appLog("Prediction fetch failed with error: \(error.localizedDescription)", category: .service, level: .error)
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .dataCorrupted(let context):
                    appLog("Data corrupted: \(context.debugDescription)", category: .service, level: .error)
                    if let underlyingError = context.underlyingError {
                        appLog("Underlying error: \(underlyingError.localizedDescription)", category: .service, level: .error)
                    }
                case .keyNotFound(let key, let context):
                    appLog("Key '\(key)' not found: \(context.debugDescription)", category: .service, level: .error)
                case .valueNotFound(let type, let context):
                    appLog("Value of type '\(type)' not found: \(context.debugDescription)", category: .service, level: .error)
                case .typeMismatch(let type, let context):
                    appLog("Type mismatch for type '\(type)': \(context.debugDescription)", category: .service, level: .error)
                @unknown default:
                    appLog("Unknown decoding error: \(decodingError.localizedDescription)", category: .service, level: .error)
                }
            }
            appLog("Return JSON: (Raw data not captured for logging in this scope)", category: .service, level: .debug)
        }
    }
    
    
}
