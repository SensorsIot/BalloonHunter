import Foundation
import Combine
import CoreLocation
import OSLog

enum AppMode: String, CaseIterable {
    case explore = "Explore"
    case follow = "Follow"
    case finalApproach = "Final Approach"
}

class ModeManager: ObservableObject {
    @Published private(set) var currentMode: AppMode = .explore
    private var cancellables = Set<AnyCancellable>()
    private let serviceManager: ServiceManager

    // Hysteresis thresholds
    private let finalApproachEnterDistance: CLLocationDistance = 1000 // meters
    private let finalApproachExitDistance: CLLocationDistance = 1200 // meters
    private let finalApproachEnterVerticalSpeed: Double = -1.0 // m/s (descending)
    private let finalApproachExitVerticalSpeed: Double = -0.5 // m/s (less descending)

    init(serviceManager: ServiceManager) {
        self.serviceManager = serviceManager
        setupSubscriptions()
    }

    private func setupSubscriptions() {
        // Observe user location and telemetry to determine mode transitions
        serviceManager.userLocationPublisher
            .combineLatest(serviceManager.telemetryPublisher)
            .sink { [weak self] userEvent, telemetryEvent in
                guard let self = self else { return }
                self.evaluateMode(userLocation: userEvent.locationData, telemetry: telemetryEvent.telemetryData)
            }
            .store(in: &cancellables)
        
        // Observe UI events for explicit mode switches
        serviceManager.uiEventPublisher
            .sink { [weak self] event in
                guard let self = self else { return }
                if case .modeSwitched(_) = event {
                    // This is a simplified example. Actual mode switching from UI would be more explicit.
                    // For now, let's assume switching to car/bike implies 'follow' mode if not in final approach.
                    if self.currentMode != .finalApproach {
                        self.setMode(.follow) // Or based on a more direct UI input
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func evaluateMode(userLocation: LocationData, telemetry: TelemetryData) {
        let userCLLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let balloonCLLocation = CLLocation(latitude: telemetry.latitude, longitude: telemetry.longitude)
        let distanceToBalloon = userCLLocation.distance(from: balloonCLLocation)
        let verticalSpeed = telemetry.verticalSpeed

        switch currentMode {
        case .explore:
            // Transition to Follow if user is getting closer or actively tracking
            if distanceToBalloon < finalApproachEnterDistance * 5 { // Example threshold
                setMode(.follow)
            }
        case .follow:
            // Transition to Final Approach
            if distanceToBalloon < finalApproachEnterDistance && verticalSpeed < finalApproachEnterVerticalSpeed {
                setMode(.finalApproach)
            }
            // Transition back to Explore if balloon is far away and not actively tracking
            else if distanceToBalloon > finalApproachExitDistance * 5 && verticalSpeed > finalApproachExitVerticalSpeed {
                setMode(.explore)
            }
        case .finalApproach:
            // Transition back to Follow
            if distanceToBalloon > finalApproachExitDistance || verticalSpeed > finalApproachExitVerticalSpeed {
                setMode(.follow)
            }
        }
    }

    func setMode(_ newMode: AppMode) {
        guard currentMode != newMode else { return }
        appLog("Transitioning from \(currentMode.rawValue) to \(newMode.rawValue)", category: .policy, level: .info)
        currentMode = newMode
        // Trigger entry/exit actions here if needed
    }
}
