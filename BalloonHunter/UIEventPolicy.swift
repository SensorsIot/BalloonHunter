import Foundation
import Combine
import CoreLocation
import OSLog
import UIKit

@MainActor
class UIEventPolicy {
    private let serviceManager: ServiceManager
    private var cancellables = Set<AnyCancellable>()
    
    init(serviceManager: ServiceManager) {
        self.serviceManager = serviceManager
        setupSubscriptions()
        appLog("UIEventPolicy: Initialized", category: .policy, level: .info)
    }
    
    private func setupSubscriptions() {
        EventBus.shared.uiEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleUIEvent(event)
            }
            .store(in: &cancellables)
    }
    
    private func handleUIEvent(_ event: UIEvent) {
        switch event {
        case .landingPointSetRequested(_):
            handleLandingPointFromClipboard()
            
        case .buzzerMuteToggled(let muted, _):
            handleBuzzerToggle(muted)
            
        case .manualPredictionTriggered(_):
            // This will be handled by PredictionPolicy, no action needed here
            appLog("UIEventPolicy: Manual prediction triggered", category: .policy, level: .debug)
            
        default:
            break
        }
    }
    
    private func handleLandingPointFromClipboard() {
        appLog("UIEventPolicy: Handling landing point from clipboard", category: .policy, level: .info)
        let success = serviceManager.landingPointService.setLandingPointFromClipboard()
        
        // Provide haptic feedback
        let generator = UINotificationFeedbackGenerator()
        if success {
            generator.notificationOccurred(.success)
            appLog("UIEventPolicy: Landing point successfully set from clipboard", category: .policy, level: .info)
        } else {
            generator.notificationOccurred(.error)
            appLog("UIEventPolicy: Failed to set landing point from clipboard", category: .policy, level: .error)
        }
    }
    
    private func handleBuzzerToggle(_ muted: Bool) {
        appLog("UIEventPolicy: Toggling buzzer mute to \(muted)", category: .policy, level: .info)
        
        // Update telemetry data
        serviceManager.bleCommunicationService.latestTelemetry?.buzmute = muted
        
        // Send command to device
        let command = "o{mute=\(muted ? 1 : 0)}o"
        serviceManager.bleCommunicationService.sendCommand(command: command)
    }
}