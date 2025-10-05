import Foundation
import Combine
import MapKit
import UserNotifications
import OSLog

@MainActor
final class NavigationService: ObservableObject {

    // MARK: - Dependencies

    private let userSettings: UserSettings
    private let routeCalculationService: RouteCalculationService
    private var lastLandingPoint: CLLocationCoordinate2D?

    init(userSettings: UserSettings, routeCalculationService: RouteCalculationService) {
        self.userSettings = userSettings
        self.routeCalculationService = routeCalculationService
    }

    // MARK: - Apple Maps Integration

    func openInAppleMaps(landingPoint: CLLocationCoordinate2D) {
        let placemark = MKPlacemark(coordinate: landingPoint)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = "Balloon Landing Site"

        let directionsMode: String
        switch routeCalculationService.transportMode {
        case .car:
            directionsMode = MKLaunchOptionsDirectionsModeDriving
        case .bike:
            if #available(iOS 14.0, *) {
                directionsMode = MKLaunchOptionsDirectionsModeCycling
            } else {
                directionsMode = MKLaunchOptionsDirectionsModeWalking // Fallback for older iOS
                appLog("NavigationService: Cycling directions require iOS 14+. Falling back to walking mode", category: .general, level: .info)
            }
        }

        let launchOptions = [
            MKLaunchOptionsDirectionsModeKey: directionsMode
        ]

        mapItem.openInMaps(launchOptions: launchOptions)
        appLog("NavigationService: Opened Apple Maps navigation to landing point", category: .general, level: .info)
    }

    // MARK: - Navigation Update Notifications

    func checkForNavigationUpdate(newLandingPoint: CLLocationCoordinate2D) {
        // Check if we have a previous landing point to compare against
        guard let previousPoint = lastLandingPoint else {
            // First landing point - store it and no notification needed
            lastLandingPoint = newLandingPoint
            return
        }

        // Calculate distance between old and new landing points
        let oldLocation = CLLocation(latitude: previousPoint.latitude, longitude: previousPoint.longitude)
        let newLocation = CLLocation(latitude: newLandingPoint.latitude, longitude: newLandingPoint.longitude)
        let distanceChange = oldLocation.distance(from: newLocation)

        // Trigger update notification if change is significant (>300m)
        if distanceChange > 300 {
            appLog("NavigationService: Landing point changed by \(Int(distanceChange))m - sending navigation update notification", category: .general, level: .info)
            sendNavigationUpdateNotification(newDestination: newLandingPoint, distanceChange: distanceChange)
        }

        // Update stored landing point
        lastLandingPoint = newLandingPoint
    }

    private func sendNavigationUpdateNotification(newDestination: CLLocationCoordinate2D, distanceChange: Double) {
        // Simple notification for navigation update
        let content = UNMutableNotificationContent()
        content.title = "Landing Prediction Updated"
        content.body = "Balloon moved \(Int(distanceChange))m. Tap to open Apple Maps with new location."
        content.sound = .default

        // Store destination for when user taps notification
        content.userInfo = [
            "latitude": newDestination.latitude,
            "longitude": newDestination.longitude
        ]

        let request = UNNotificationRequest(
            identifier: "navigation_update_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                appLog("NavigationService: Failed to send navigation notification: \(error)", category: .general, level: .error)
            } else {
                appLog("NavigationService: Sent navigation update notification", category: .general, level: .info)
            }
        }
    }

    // MARK: - Sonde Change Handling

    func resetForNewSonde() {
        lastLandingPoint = nil
        appLog("NavigationService: Reset for new sonde", category: .general, level: .info)
    }
}