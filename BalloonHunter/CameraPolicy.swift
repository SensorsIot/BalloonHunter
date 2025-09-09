import Foundation
import Combine
import CoreLocation
import MapKit
import OSLog

class CameraPolicy {
    private let serviceManager: ServiceManager
    private let policyScheduler: PolicyScheduler
    private var cancellables = Set<AnyCancellable>()
    private var lastUserLocationForCamera: CLLocationCoordinate2D? = nil
    private var isFollowMeOn: Bool = false // This would be controlled by UIEvent or ModeManager later

    // Publisher for camera region updates
    let cameraRegionPublisher = PassthroughSubject<MKCoordinateRegion, Never>()

    init(serviceManager: ServiceManager, policyScheduler: PolicyScheduler) {
        self.serviceManager = serviceManager
        self.policyScheduler = policyScheduler
        setupSubscriptions()
    }

    private func setupSubscriptions() {
        serviceManager.userLocationPublisher
            .sink { [weak self] event in
                guard let self = self else { return }
                self.handleUserLocationEvent(event.locationData)
            }
            .store(in: &cancellables)

        serviceManager.uiEventPublisher
            .sink { [weak self] event in
                guard let self = self else { return }
                self.handleUIEvent(event)
            }
            .store(in: &cancellables)
    }

    private func handleUserLocationEvent(_ location: LocationData) {
        guard isFollowMeOn else { return } // Only recenter if Follow-Me is ON

        let currentUserLocation = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)

        if let lastLocation = lastUserLocationForCamera {
            let distance = CLLocation(latitude: currentUserLocation.latitude, longitude: currentUserLocation.longitude).distance(from: CLLocation(latitude: lastLocation.latitude, longitude: lastLocation.longitude))
            if distance > 20 { // Recenter if user moved >20 m
                Task { await self.triggerCameraRecenter(to: currentUserLocation) }
                self.lastUserLocationForCamera = currentUserLocation
            }
        } else {
            // First location, recenter
            Task { await self.triggerCameraRecenter(to: currentUserLocation) }
            self.lastUserLocationForCamera = currentUserLocation
        }
    }

    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .modeSwitched(let mode): // Assuming mode switch can control Follow-Me
            // This is a placeholder. Actual Follow-Me logic would be more complex.
            isFollowMeOn = (mode == .car) // Example: Follow-Me is on when in car mode
        default:
            break
        }
    }

    private func triggerCameraRecenter(to coordinate: CLLocationCoordinate2D) async {
        // Debounce: 250–400 ms. Using 250ms for now.
        let debounceDelay: TimeInterval = 0.25

        await policyScheduler.debounce(key: "cameraRecenter", delay: debounceDelay) {
            appLog("Triggering camera recenter to: \(coordinate.latitude), \(coordinate.longitude)", category: .policy, level: .debug)
            // Create a new region centered on the user's location
            let newRegion = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01) // Example span
            )
            self.cameraRegionPublisher.send(newRegion)
        }
    }
}
