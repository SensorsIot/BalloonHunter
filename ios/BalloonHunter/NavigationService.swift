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

    /// Decides when a changed drive is worth interrupting the hunter for.
    private let handoff = NavigationHandoff()
    private var travelTimeAtLastNotification: TimeInterval?
    private var lastNotificationAt: Date?
    var lastLandingPoint: CLLocationCoordinate2D?  // Internal access for coordinator to clear on sonde change

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

        // Route from where the hunter is now to the new landing point.
        //
        // The two-item call is deliberate. Handing Maps only a destination while a
        // route is already running makes it offer to *add a stop*, turning the
        // stale landing point into a waypoint - so the hunter would drive to where
        // the balloon was predicted to land before continuing to where it is
        // predicted now. Supplying an explicit source avoids that.
        //
        // It still cannot replace an active route: Maps prompts, and the hunter
        // must end the current navigation first. No API, Shortcuts action or Siri
        // path exists to do that for them.
        let source = MKMapItem.forCurrentLocation()
        MKMapItem.openMaps(with: [source, mapItem], launchOptions: launchOptions)
        appLog("NavigationService: Handed Apple Maps a route from current position to the landing point", category: .general, level: .info)
    }

    // MARK: - Navigation Update Notifications

    /// Decide whether the moved landing point is worth telling the hunter about.
    ///
    /// Straight-line distance is the wrong measure: during a descent the prediction
    /// moves 300 m every minute, and 300 m along the same motorway changes nothing
    /// while 300 m across a ridge can add half an hour. What matters is the drive.
    ///
    /// The cost of asking is real. Apple Maps will not replace a route it is
    /// already following, so every notification the hunter acts on means ending
    /// the current route by hand before the new one will start.
    func checkForNavigationUpdate(newLandingPoint: CLLocationCoordinate2D) {
        defer { lastLandingPoint = newLandingPoint }
        guard lastLandingPoint != nil else { return }
        guard let route = routeCalculationService.currentRoute else { return }

        let decision = handoff.decide(.init(
            currentTravelTime: route.expectedTravelTime,
            travelTimeAtLastHandover: travelTimeAtLastNotification,
            lastOfferedAt: lastNotificationAt,
            distanceToLanding: route.distance
        ))

        guard case .offer(let delta) = decision else { return }

        appLog(String(format: "NavigationService: Drive changed by %.0f min - notifying", delta / 60),
               category: .general, level: .info)
        lastNotificationAt = Date()
        travelTimeAtLastNotification = route.expectedTravelTime
        sendNavigationUpdateNotification(newDestination: newLandingPoint, travelTimeDelta: delta)
    }

    private func sendNavigationUpdateNotification(newDestination: CLLocationCoordinate2D, travelTimeDelta: TimeInterval) {
        let minutes = Int(abs(travelTimeDelta) / 60)
        let direction = travelTimeDelta > 0 ? "longer" : "shorter"

        let content = UNMutableNotificationContent()
        content.title = "Landing Prediction Updated"
        // Says what changed about the drive, and what it will cost to act on it.
        content.body = "The drive is now \(minutes) min \(direction). End the route in Maps, then tap to re-route from here."
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

    // MARK: - Sonde Change

    func clearAllData() {
        lastLandingPoint = nil
        appLog("NavigationService: All data cleared for new sonde", category: .general, level: .info)
    }
}