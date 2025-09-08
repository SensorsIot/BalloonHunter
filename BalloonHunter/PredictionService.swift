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
    private var lastPeriodicPredictionTime: Date? = nil

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
    func fetchPrediction(telemetry: TelemetryData, userSettings: UserSettings, measuredDescentRate: Double? = nil) async {
        print("[DEBUG] fetchPrediction entered.")
        self.lastPeriodicPredictionTime = Date()
        
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
                    let newPredictionData = PredictionData(path: self.path, burstPoint: self.burstPoint, landingPoint: landingPoint, landingTime: self.landingTime)
                    self.predictionData = newPredictionData

                    self.predictionStatus = .success
                    if self.appInitializationFinished == false {
                        self.appInitializationFinished = true
                    }
                } else {
                    print("[Debug][PredictionService] Prediction parsing finished, but no valid landing point found.")
                    if case .fetching = self.predictionStatus {
                        self.predictionStatus = .noValidPrediction
                    }
                }
                self.isLoading = false
            }
        } catch {
            await MainActor.run { @MainActor in
                print("[Debug][PredictionService] Network or JSON parsing failed: \(error.localizedDescription)")
                self.predictionStatus = .error(error.localizedDescription)
                self.isLoading = false
            }
            print("[Debug][PredictionService] Prediction fetch failed with error: \(error.localizedDescription)")
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .dataCorrupted(let context):
                    print("[Debug][PredictionService] Data corrupted: \(context.debugDescription)")
                    if let underlyingError = context.underlyingError {
                        print("[Debug][PredictionService] Underlying error: \(underlyingError.localizedDescription)")
                    }
                case .keyNotFound(let key, let context):
                    print("[Debug][PredictionService] Key '\(key)' not found: \(context.debugDescription)")
                case .valueNotFound(let type, let context):
                    print("[Debug][PredictionService] Value of type '\(type)' not found: \(context.debugDescription)")
                case .typeMismatch(let type, let context):
                    print("[Debug][PredictionService] Type mismatch for type '\(type)': \(context.debugDescription)")
                @unknown default:
                    print("[Debug][PredictionService] Unknown decoding error: \(decodingError.localizedDescription)")
                }
            }
            print("[Debug][PredictionService] Return JSON: (Raw data not captured for logging in this scope)")
        }
    }
    
    
}
