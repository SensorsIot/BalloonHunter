import Foundation
import Combine
import OSLog

/// Validates the complete event-driven architecture flow
/// This can be used for integration testing and debugging
@MainActor
class EventFlowValidator {
    private var cancellables = Set<AnyCancellable>()
    private var eventCounts: [String: Int] = [:]
    private let startTime = Date()
    
    init() {
        setupEventMonitoring()
    }
    
    private func setupEventMonitoring() {
        // Monitor telemetry events
        EventBus.shared.telemetryPublisher
            .sink { [weak self] event in
                self?.logEvent("TelemetryEvent", details: "balloon: \(event.balloonId), alt: \(event.telemetryData.altitude)m")
            }
            .store(in: &cancellables)
        
        // Monitor user location events
        EventBus.shared.userLocationPublisher
            .sink { [weak self] event in
                self?.logEvent("UserLocationEvent", details: "lat: \(String(format: "%.4f", event.locationData.latitude)), lon: \(String(format: "%.4f", event.locationData.longitude))")
            }
            .store(in: &cancellables)
        
        // Monitor UI events
        EventBus.shared.uiEventPublisher
            .sink { [weak self] event in
                self?.logEvent("UIEvent", details: "\(event)")
            }
            .store(in: &cancellables)
        
        // Monitor map state updates
        EventBus.shared.mapStateUpdatePublisher
            .sink { [weak self] update in
                self?.logEvent("MapStateUpdate", details: "source: \(update.source), version: \(update.version)")
            }
            .store(in: &cancellables)
        
        // Monitor service health events
        EventBus.shared.serviceHealthPublisher
            .sink { [weak self] event in
                self?.logEvent("ServiceHealthEvent", details: "service: \(event.serviceName), health: \(event.health)")
            }
            .store(in: &cancellables)
    }
    
    private func logEvent(_ eventType: String, details: String) {
        eventCounts[eventType, default: 0] += 1
        let count = eventCounts[eventType]!
        let elapsed = Date().timeIntervalSince(startTime)
        
        appLog("EventFlow: [\(String(format: "%.1f", elapsed))s] \(eventType) #\(count) - \(details)", 
               category: .general, level: .debug)
    }
    
    func getEventSummary() -> [String: Any] {
        let elapsed = Date().timeIntervalSince(startTime)
        var summary: [String: Any] = [
            "elapsedTime": elapsed,
            "eventCounts": eventCounts
        ]
        
        // Calculate event rates
        var rates: [String: Double] = [:]
        for (eventType, count) in eventCounts {
            rates[eventType + "Rate"] = Double(count) / elapsed
        }
        summary["eventRates"] = rates
        
        return summary
    }
    
    func validateArchitecture() -> [String: Bool] {
        return [
            "telemetryFlowActive": eventCounts["TelemetryEvent", default: 0] > 0,
            "locationFlowActive": eventCounts["UserLocationEvent", default: 0] > 0,
            "uiFlowActive": eventCounts["UIEvent", default: 0] > 0,
            "mapStateUpdatesActive": eventCounts["MapStateUpdate", default: 0] > 0,
            "servicesHealthy": eventCounts["ServiceHealthEvent", default: 0] > 0,
            "balancedFlow": eventCounts["MapStateUpdate", default: 0] >= eventCounts["TelemetryEvent", default: 0]
        ]
    }
    
    deinit {
        cancellables.removeAll()
    }
}