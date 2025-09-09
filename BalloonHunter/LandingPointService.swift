import UIKit
import Foundation
import Combine
import CoreLocation
import OSLog

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

    static func parseOpenStreetMapURL(_ urlString: String) -> CLLocationCoordinate2D? {
        appLog("LandingPointService: Attempting to parse clipboard URL: '\(urlString)'", category: .service, level: .debug)
        
        guard let url = URL(string: urlString) else {
            appLog("LandingPointService: Invalid URL format", category: .service, level: .debug)
            return nil
        }
        
        // Check for query parameters ?mlat=<lat>&mlon=<lon>
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            if let mlatString = queryItems.first(where: { $0.name == "mlat" })?.value,
               let mlonString = queryItems.first(where: { $0.name == "mlon" })?.value,
               let latitude = Double(mlatString),
               let longitude = Double(mlonString) {
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                appLog("LandingPointService: Successfully parsed coordinates from query params: \(coordinate)", category: .service, level: .info)
                return coordinate
            }
            
            // Check for directions URL with route parameter
            if let routeString = queryItems.first(where: { $0.name == "route" })?.value {
                appLog("LandingPointService: Found directions route parameter: '\(routeString)'", category: .service, level: .debug)
                // Format: lat1,lon1;lat2,lon2 - take the second coordinate (destination)
                let points = routeString.split(separator: ";")
                if points.count >= 2 {
                    let destinationPoint = String(points[1]) // Take the last point as destination
                    let coords = destinationPoint.split(separator: ",")
                    if coords.count >= 2,
                       let latitude = Double(coords[0]),
                       let longitude = Double(coords[1]) {
                        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                        appLog("LandingPointService: Successfully parsed destination coordinates from directions route: \(coordinate)", category: .service, level: .info)
                        return coordinate
                    }
                }
            }
        }
        
        // Check for fragment #map=<zoom>/<lat>/<lon>
        if let fragment = url.fragment {
            appLog("LandingPointService: Checking fragment: '\(fragment)'", category: .service, level: .debug)
            // Expected format: map=<zoom>/<lat>/<lon>
            let prefix = "map="
            guard fragment.hasPrefix(prefix) else {
                appLog("LandingPointService: Fragment doesn't start with 'map='", category: .service, level: .debug)
                return nil
            }
            let coordsString = fragment.dropFirst(prefix.count)
            let parts = coordsString.split(separator: "/")
            appLog("LandingPointService: Fragment parts: \(parts)", category: .service, level: .debug)
            if parts.count >= 3,
               let latitude = Double(parts[1]),
               let longitude = Double(parts[2]) {
                let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                appLog("LandingPointService: Successfully parsed coordinates from fragment: \(coordinate)", category: .service, level: .info)
                return coordinate
            }
        }
        
        appLog("LandingPointService: No valid coordinates found in URL", category: .service, level: .debug)
        return nil
    }
    
    func setLandingPointFromClipboard() -> Bool {
        appLog("LandingPointService: Manual clipboard override requested", category: .service, level: .info)
        
        // Request clipboard permission if needed
        if #available(iOS 14.0, macOS 10.15, *) {
            // For newer versions, we need to check permission asynchronously
            Task {
                await self.setLandingPointFromClipboardAsync()
            }
            // Return true to indicate we're processing the request
            return true
        } else {
            // Fallback for older versions - direct access
            return setLandingPointFromClipboardDirect()
        }
    }
    
    @available(iOS 14.0, macOS 10.15, *)
    private func setLandingPointFromClipboardAsync() async -> Bool {
        if UIPasteboard.general.hasStrings {
            guard let clipboardString = UIPasteboard.general.string else {
                appLog("LandingPointService: Clipboard access granted but no string found", category: .service, level: .info)
                return false
            }
            
            appLog("LandingPointService: Parsing clipboard content: \(clipboardString)", category: .service, level: .debug)
            if let coordinate = LandingPointService.parseOpenStreetMapURL(clipboardString) {
                await MainActor.run {
                    persistenceService.saveLandingPoint(sondeName: "manual_override", coordinate: coordinate)
                    appLog("LandingPointService: Successfully parsed and saved manual override coordinate: \(coordinate)", category: .service, level: .info)
                    updateValidLandingPoint()
                }
                return true
            }
            
            appLog("LandingPointService: Failed to parse valid coordinates from clipboard", category: .service, level: .info)
            return false
        } else {
            appLog("LandingPointService: No clipboard access or clipboard is empty", category: .service, level: .info)
            return false
        }
    }
    
    private func setLandingPointFromClipboardDirect() -> Bool {
        guard let clipboardString = UIPasteboard.general.string else {
            appLog("LandingPointService: No string found in clipboard", category: .service, level: .info)
            return false
        }
        
        appLog("LandingPointService: Parsing clipboard content: \(clipboardString)", category: .service, level: .debug)
        if let coordinate = LandingPointService.parseOpenStreetMapURL(clipboardString) {
            persistenceService.saveLandingPoint(sondeName: "manual_override", coordinate: coordinate)
            appLog("LandingPointService: Successfully parsed and saved manual override coordinate: \(coordinate)", category: .service, level: .info)
            updateValidLandingPoint()
            return true
        }
        
        appLog("LandingPointService: Failed to parse valid coordinates from clipboard", category: .service, level: .info)
        return false
    }
    
    /// Clear any manual override - useful for testing
    func clearManualOverride() {
        persistenceService.clearLandingPoint(sondeName: "manual_override")
        appLog("LandingPointService: Manual override cleared", category: .service, level: .info)
        updateValidLandingPoint()
    }

    private func updateValidLandingPoint() {
        appLog("LandingPointService: Updating valid landing point - checking priorities", category: .service, level: .debug)
        
        // Priority 1: Telemetry - If isLanded is active, use current balloon position
        if balloonTrackingService.isLanded, let landedPosition = balloonTrackingService.landedPosition {
            validLandingPoint = landedPosition
            // Always persist new valid landing point
            if let sondeName = balloonTrackingService.currentBalloonName {
                persistenceService.saveLandingPoint(sondeName: sondeName, coordinate: landedPosition)
                appLog("LandingPointService: Persisted landing point from telemetry for sonde: \(sondeName)", category: .service, level: .debug)
            }
            appLog("LandingPointService: Using Priority 1 - Telemetry landing point: \(landedPosition)", category: .service, level: .info)
            return
        }
        
        // Priority 2: Balloon Prediction - If balloon still in flight, use predicted landing position
        if let predictionData = predictionService.predictionData {
            let landingPointString = predictionData.landingPoint != nil ? "(\(predictionData.landingPoint!.latitude), \(predictionData.landingPoint!.longitude))" : "nil"
            appLog("LandingPointService: PREDICTION DATA AVAILABLE - Landing point: \(landingPointString)", category: .service, level: .info)
            if let predictedLandingPoint = predictionData.landingPoint {
                validLandingPoint = predictedLandingPoint
                // Always persist new valid landing point
                if let sondeName = balloonTrackingService.currentBalloonName {
                    persistenceService.saveLandingPoint(sondeName: sondeName, coordinate: predictedLandingPoint)
                    appLog("LandingPointService: Persisted landing point from prediction for sonde: \(sondeName)", category: .service, level: .debug)
                }
                appLog("LandingPointService: Using Priority 2 - Prediction landing point: \(predictedLandingPoint)", category: .service, level: .info)
                return
            }
        } else {
            appLog("LandingPointService: NO PREDICTION DATA AVAILABLE", category: .service, level: .info)
        }
        
        // Priority 3: Clipboard - Read and parse from clipboard if no prediction available
        appLog("LandingPointService: Checking Priority 3 - Clipboard", category: .service, level: .debug)
        
        if #available(iOS 14.0, macOS 10.15, *) {
            Task {
                appLog("LandingPointService: Requesting clipboard access (async)", category: .service, level: .debug)
                if UIPasteboard.general.hasStrings {
                    if let clipboardString = UIPasteboard.general.string {
                        let truncatedContent = clipboardString.count > 100 ? String(clipboardString.prefix(100)) + "..." : clipboardString
                        appLog("LandingPointService: Clipboard content (Priority 3): '\(truncatedContent)'", category: .service, level: .info)
                        
                        if let clipboardCoordinate = LandingPointService.parseOpenStreetMapURL(clipboardString) {
                            await MainActor.run {
                                self.validLandingPoint = clipboardCoordinate
                                // Always persist new valid landing point
                                if let sondeName = self.balloonTrackingService.currentBalloonName {
                                    self.persistenceService.saveLandingPoint(sondeName: sondeName, coordinate: clipboardCoordinate)
                                    appLog("LandingPointService: Persisted landing point from clipboard for sonde: \(sondeName)", category: .service, level: .debug)
                                }
                                appLog("LandingPointService: ✅ Using Priority 3 - Landing point from clipboard: \(clipboardCoordinate)", category: .service, level: .info)
                            }
                            return
                        } else {
                            appLog("LandingPointService: ❌ Clipboard content could not be parsed as coordinates", category: .service, level: .info)
                        }
                    } else {
                        appLog("LandingPointService: ❌ Clipboard access granted but no string content", category: .service, level: .info)
                    }
                } else {
                    appLog("LandingPointService: ❌ No clipboard access or clipboard is empty", category: .service, level: .info)
                }
                
                // Continue to Priority 4 if clipboard fails
                appLog("LandingPointService: Priority 3 failed, proceeding to Priority 4", category: .service, level: .debug)
                await MainActor.run {
                    self.checkPriority4()
                }
            }
        } else {
            // Fallback for older versions - direct clipboard access
            if let clipboardString = UIPasteboard.general.string {
                let truncatedContent = clipboardString.count > 100 ? String(clipboardString.prefix(100)) + "..." : clipboardString
                appLog("LandingPointService: Clipboard content (Priority 3): '\(truncatedContent)'", category: .service, level: .info)
                
                if let clipboardCoordinate = LandingPointService.parseOpenStreetMapURL(clipboardString) {
                    validLandingPoint = clipboardCoordinate
                    // Always persist new valid landing point
                    if let sondeName = balloonTrackingService.currentBalloonName {
                        persistenceService.saveLandingPoint(sondeName: sondeName, coordinate: clipboardCoordinate)
                        appLog("LandingPointService: Persisted landing point from clipboard for sonde: \(sondeName)", category: .service, level: .debug)
                    }
                    appLog("LandingPointService: ✅ Using Priority 3 - Landing point from clipboard: \(clipboardCoordinate)", category: .service, level: .info)
                    return
                } else {
                    appLog("LandingPointService: ❌ Clipboard content could not be parsed as coordinates", category: .service, level: .info)
                }
            } else {
                appLog("LandingPointService: ❌ No clipboard content available", category: .service, level: .info)
            }
            
            // Continue to Priority 4 if clipboard fails
            appLog("LandingPointService: Priority 3 failed, proceeding to Priority 4", category: .service, level: .debug)
            checkPriority4()
        }
    }
    
    private func checkPriority4() {
        appLog("LandingPointService: Checking Priority 4 - Persisted landing point", category: .service, level: .debug)
        
        // Priority 4: Persisted landing point - Use stored landing point if all else fails
        if let sondeName = balloonTrackingService.currentBalloonName {
            appLog("LandingPointService: Current balloon name: \(sondeName)", category: .service, level: .debug)
            if let persistedLandingPoint = persistenceService.loadLandingPoint(sondeName: sondeName) {
                validLandingPoint = persistedLandingPoint
                appLog("LandingPointService: Using Priority 4 - Persisted landing point for \(sondeName): \(persistedLandingPoint)", category: .service, level: .info)
                return
            } else {
                appLog("LandingPointService: No persisted landing point found for \(sondeName)", category: .service, level: .debug)
            }
        } else {
            appLog("LandingPointService: No current balloon name available", category: .service, level: .debug)
        }
        
        // No landing point available
        validLandingPoint = nil
        appLog("LandingPointService: No valid landing point available - all priorities failed", category: .service, level: .info)
    }
}
