import Foundation
import Combine
import CoreLocation
import OSLog

@MainActor
final class ModeStateMachine: ObservableObject {
    @Published private(set) var currentMode: AppMode = .explore
    @Published private(set) var modeTransitionHistory: [(AppMode, Date)] = []
    
    private var cancellables = Set<AnyCancellable>()
    private let hysteresisThreshold: TimeInterval = 5.0 // Prevent mode flapping
    private var lastTransitionTime = Date.distantPast
    
    struct ModeThresholds {
        // Follow mode entry thresholds
        static let balloonFlightAltitudeThreshold: Double = 100.0 // meters
        static let balloonSignalStrengthThreshold: Double = -80.0 // dBm
        static let continuousTelemetryDuration: TimeInterval = 30.0 // seconds
        
        // Final approach entry thresholds
        static let lowVerticalSpeedThreshold: Double = 1.0 // m/s
        static let lowAltitudeThreshold: Double = 1000.0 // meters
        static let proximityDistanceThreshold: Double = 1000.0 // meters
        static let finalApproachDuration: TimeInterval = 60.0 // seconds
        
        // Explore mode fallback thresholds
        static let signalLossTimeout: TimeInterval = 300.0 // 5 minutes
        static let maxDistanceFromBalloon: Double = 50000.0 // 50km
    }
    
    private struct ModeContext {
        var balloonAltitude: Double?
        var balloonVerticalSpeed: Double?
        var balloonSignalStrength: Double?
        var distanceToBalloon: Double?
        var lastTelemetryTime: Date?
        var userLocation: LocationData?
        var isBalloonFlying: Bool = false
        var continuousTelemetryStart: Date?
        var lowSpeedStart: Date?
    }
    
    private var context = ModeContext()
    
    init() {
        setupEventSubscriptions()
        recordTransition(to: .explore, reason: "Initial state")
    }
    
    private func setupEventSubscriptions() {
        // Subscribe to telemetry events
        EventBus.shared.telemetryPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.updateTelemetryContext(event)
                self?.evaluateTransitions()
            }
            .store(in: &cancellables)
        
        // Subscribe to user location events
        EventBus.shared.userLocationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.updateLocationContext(event)
                self?.evaluateTransitions()
            }
            .store(in: &cancellables)
        
        // Periodic evaluation for timeout-based transitions
        Timer.publish(every: 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.evaluateTransitions()
            }
            .store(in: &cancellables)
    }
    
    private func updateTelemetryContext(_ event: TelemetryEvent) {
        let telemetry = event.telemetryData
        
        context.balloonAltitude = telemetry.altitude
        context.balloonVerticalSpeed = telemetry.verticalSpeed
        context.balloonSignalStrength = telemetry.signalStrength
        context.lastTelemetryTime = Date()
        context.isBalloonFlying = telemetry.altitude > ModeThresholds.balloonFlightAltitudeThreshold
        
        // Track continuous telemetry
        if telemetry.signalStrength > ModeThresholds.balloonSignalStrengthThreshold {
            if context.continuousTelemetryStart == nil {
                context.continuousTelemetryStart = Date()
            }
        } else {
            context.continuousTelemetryStart = nil
        }
        
        // Track low speed duration
        if abs(telemetry.verticalSpeed) < ModeThresholds.lowVerticalSpeedThreshold {
            if context.lowSpeedStart == nil {
                context.lowSpeedStart = Date()
            }
        } else {
            context.lowSpeedStart = nil
        }
        
        // Calculate distance to balloon if user location is available
        if let userLocation = context.userLocation {
            let balloonLocation = CLLocation(latitude: telemetry.latitude, longitude: telemetry.longitude)
            let userCLLocation = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
            context.distanceToBalloon = userCLLocation.distance(from: balloonLocation)
        }
        
        appLog("ModeStateMachine: Updated telemetry context - alt: \(String(format: "%.0f", telemetry.altitude))m, vspeed: \(String(format: "%.1f", telemetry.verticalSpeed))m/s, signal: \(String(format: "%.1f", telemetry.signalStrength))dBm", 
               category: .general, level: .debug)
    }
    
    private func updateLocationContext(_ event: UserLocationEvent) {
        context.userLocation = event.locationData
        
        // Recalculate distance to balloon if telemetry is available
        if let lastTelemetry = context.lastTelemetryTime,
           Date().timeIntervalSince(lastTelemetry) < 60,
           let _ = context.balloonAltitude {
            // We have recent telemetry, recalculate distance
            // This would need the actual balloon coordinates, which we'd get from the service
        }
    }
    
    private func evaluateTransitions() {
        let now = Date()
        
        // Prevent mode flapping
        if now.timeIntervalSince(lastTransitionTime) < hysteresisThreshold {
            return
        }
        
        let newMode = determineOptimalMode()
        
        if newMode != currentMode {
            transitionTo(newMode)
        }
    }
    
    private func determineOptimalMode() -> AppMode {
        let now = Date()
        
        // Check for signal loss - fallback to explore
        if let lastTelemetry = context.lastTelemetryTime,
           now.timeIntervalSince(lastTelemetry) > ModeThresholds.signalLossTimeout {
            return .explore
        }
        
        // Check for extreme distance - fallback to explore
        if let distance = context.distanceToBalloon,
           distance > ModeThresholds.maxDistanceFromBalloon {
            return .explore
        }
        
        // Check for final approach conditions
        if canTransitionToFinalApproach() {
            return .finalApproach
        }
        
        // Check for follow mode conditions
        if canTransitionToFollow() {
            return .follow
        }
        
        // Default to explore mode
        return .explore
    }
    
    private func canTransitionToFollow() -> Bool {
        guard context.isBalloonFlying else { return false }
        
        // Good signal strength
        guard let signalStrength = context.balloonSignalStrength,
              signalStrength > ModeThresholds.balloonSignalStrengthThreshold else { return false }
        
        // Continuous telemetry
        guard let continuousStart = context.continuousTelemetryStart,
              Date().timeIntervalSince(continuousStart) >= ModeThresholds.continuousTelemetryDuration else { return false }
        
        return true
    }
    
    private func canTransitionToFinalApproach() -> Bool {
        guard context.isBalloonFlying else { return false }
        
        let hasLowVerticalSpeed: Bool = {
            guard let lowSpeedStart = context.lowSpeedStart else { return false }
            return Date().timeIntervalSince(lowSpeedStart) >= ModeThresholds.finalApproachDuration
        }()
        
        let isAtLowAltitude: Bool = {
            guard let altitude = context.balloonAltitude else { return false }
            return altitude < ModeThresholds.lowAltitudeThreshold
        }()
        
        let isInProximity: Bool = {
            guard let distance = context.distanceToBalloon else { return false }
            return distance < ModeThresholds.proximityDistanceThreshold
        }()
        
        // Need either low speed for extended period OR (low altitude AND proximity)
        return hasLowVerticalSpeed || (isAtLowAltitude && isInProximity)
    }
    
    private func transitionTo(_ newMode: AppMode) {
        let previousMode = currentMode
        currentMode = newMode
        lastTransitionTime = Date()
        
        recordTransition(to: newMode, reason: getTransitionReason(from: previousMode, to: newMode))
        
        // Publish mode change event
        EventBus.shared.publishUIEvent(.modeSwitched(newMode))
        
        appLog("ModeStateMachine: Transitioned from \(previousMode.displayName) to \(newMode.displayName)", 
               category: .general, level: .info)
        
        // Execute mode-specific entry actions
        executeEntryActions(for: newMode)
    }
    
    private func recordTransition(to mode: AppMode, reason: String) {
        modeTransitionHistory.append((mode, Date()))
        
        // Keep only last 20 transitions
        if modeTransitionHistory.count > 20 {
            modeTransitionHistory.removeFirst()
        }
        
        appLog("ModeStateMachine: Mode transition - \(mode.displayName) (\(reason))", 
               category: .general, level: .info)
    }
    
    private func getTransitionReason(from: AppMode, to: AppMode) -> String {
        switch (from, to) {
        case (_, .explore):
            if context.lastTelemetryTime == nil {
                return "No telemetry data"
            } else if let lastTelemetry = context.lastTelemetryTime,
                      Date().timeIntervalSince(lastTelemetry) > ModeThresholds.signalLossTimeout {
                return "Signal loss timeout"
            } else if let distance = context.distanceToBalloon,
                      distance > ModeThresholds.maxDistanceFromBalloon {
                return "Balloon too far away"
            } else {
                return "Balloon not flying or poor signal"
            }
            
        case (_, .follow):
            return "Good signal and balloon flying"
            
        case (_, .finalApproach):
            if let _ = context.lowSpeedStart {
                return "Low vertical speed detected"
            } else {
                return "Low altitude and close proximity"
            }
        }
    }
    
    private func executeEntryActions(for mode: AppMode) {
        switch mode {
        case .explore:
            // Light fetching mode - reduce update frequency
            break
            
        case .follow:
            // Active tracking mode - enable routing, periodic predictions
            break
            
        case .finalApproach:
            // High frequency updates, tight thresholds, landing preparation
            break
        }
    }
    
    func forceTransition(to mode: AppMode, reason: String = "Manual override") {
        transitionTo(mode)
        recordTransition(to: mode, reason: reason)
    }
    
    func getModeConfig(for mode: AppMode) -> ModeConfiguration {
        switch mode {
        case .explore:
            return ModeConfiguration(
                predictionInterval: 300.0, // 5 minutes
                routingEnabled: false,
                cameraFollowEnabled: false,
                updateFrequency: .low
            )
            
        case .follow:
            return ModeConfiguration(
                predictionInterval: 120.0, // 2 minutes
                routingEnabled: true,
                cameraFollowEnabled: true,
                updateFrequency: .normal
            )
            
        case .finalApproach:
            return ModeConfiguration(
                predictionInterval: 30.0, // 30 seconds
                routingEnabled: true,
                cameraFollowEnabled: true,
                updateFrequency: .high
            )
        }
    }
    
    func getStats() -> [String: Any] {
        let now = Date()
        return [
            "currentMode": currentMode.displayName,
            "timeInCurrentMode": lastTransitionTime.timeIntervalSince(now),
            "totalTransitions": modeTransitionHistory.count,
            "balloonFlying": context.isBalloonFlying,
            "hasRecentTelemetry": context.lastTelemetryTime?.timeIntervalSince(now) ?? -1 > -60,
            "distanceToBalloon": context.distanceToBalloon ?? -1,
            "balloonAltitude": context.balloonAltitude ?? -1,
            "balloonVerticalSpeed": context.balloonVerticalSpeed ?? 0
        ]
    }
}

struct ModeConfiguration {
    let predictionInterval: TimeInterval
    let routingEnabled: Bool
    let cameraFollowEnabled: Bool
    let updateFrequency: UpdateFrequency
    
    enum UpdateFrequency {
        case low, normal, high
        
        var intervalSeconds: TimeInterval {
            switch self {
            case .low: return 60.0
            case .normal: return 30.0  
            case .high: return 10.0
            }
        }
    }
}