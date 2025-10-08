// DataPanelView.swift
import SwiftUI
import OSLog
import Foundation

struct DataPanelView: View {
    // UI state now provided by MapPresenter, app flow by ServiceCoordinator
    @EnvironmentObject var serviceCoordinator: ServiceCoordinator
    @EnvironmentObject var mapPresenter: MapPresenter
    @EnvironmentObject var predictionService: PredictionService
    @EnvironmentObject var userSettings: UserSettings
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var balloonTrackService: BalloonTrackService
    @EnvironmentObject var balloonPositionService: BalloonPositionService
    @EnvironmentObject var routeCalculationService: RouteCalculationService

    // Flash animation state for BLE icon
    @State private var isFlashing = false
    @State private var lastBLETimestamp: Date? = nil

    var body: some View {
        GeometryReader { geometry in // Added GeometryReader

            VStack {
                // Table 1: 5 columns - Connected, Flight Status, Sonde Type, Sonde Name, Altitude
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    GridRow {
                        let icon = connectionIcon()
                        Image(systemName: icon.name)
                            .foregroundColor(icon.color)
                            .font(.system(size: 24))
                            .frame(width: 48, alignment: .center)
                            .scaleEffect(isFlashing ? 1.3 : 1.0)
                            .animation(.easeInOut(duration: 0.1), value: isFlashing)
                        Image(systemName: flightStatusIconName)
                            .foregroundColor(flightStatusTint)
                            .font(.system(size: 24))
                            .frame(width: 48, alignment: .center)
                            .accessibilityLabel(Text(flightStatusString))
                        Text(showingPlaceholders ? "N/A" : (balloonPositionService.currentRadioChannel?.probeType ?? "N/A"))
                            .frame(width: 70, alignment: .center)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                        Text(showingPlaceholders ? "N/A" : (balloonPositionService.currentPositionData?.sondeName ?? "N/A"))
                            .frame(width: 120, alignment: .center)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                        Text(showingPlaceholders ? "N/A" : (balloonPositionService.currentPositionData != nil ? "\(Int(balloonPositionService.currentPositionData!.altitude)) m" : "N/A"))
                            .frame(width: 80, alignment: .center)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)

                // Table 2: 3 columns - Per FSD specification
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    // Row 1: Frequency, Signal Strength, Battery %
                    GridRow {
                        Text("\(frequencyString)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(signalStrengthString) dBm")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(batteryPercentageString)%")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Row 2: Vertical speed, Horizontal speed, Distance
                    GridRow {
                        let verticalSpeed = motionMetricsZeroed ? 0.0 : balloonTrackService.motionMetrics.smoothedVerticalSpeedMS
                        let horizontalSpeed = motionMetricsZeroed ? 0.0 : balloonTrackService.motionMetrics.smoothedHorizontalSpeedMS * 3.6
                        Text("V: \(String(format: "%.1f", verticalSpeed)) m/s")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(verticalSpeed >= 0 ? .green : .red)
                        Text("H: \(String(format: "%.1f", horizontalSpeed)) km/h")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Dist: \(distanceString) km")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Row 3: Flight time, Landing time, Arrival time
                    GridRow {
                        Text("Flight: \(remainingFlightTimeString)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Landing: \(predictedLandingTimeString)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Arrival: \(arrivalTimeString)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Row 4: Adjusted descent rate (per FSD requirement) - spans all 3 columns
                    GridRow {
                        let descentRate = mapPresenter.smoothedDescentRate
                        let descentValue: String = {
                            if showingDescentRate {
                                return String(format: "%.1f", abs(descentRate ?? userSettings.descentRate))
                            } else {
                                return "0.0"
                            }
                        }()
                        let burstKillerExpiry = burstKillerExpiryString()
                        HStack(spacing: 0) {
                            Text("Descent Rate: \(descentValue) m/s")
                                .foregroundColor(mapPresenter.smoothenedPredictionActive ? .green : .primary)
                            Text("  •  Burst killer: \(burstKillerExpiry)")
                                .foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .gridCellColumns(3)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, -10) // Reduced top padding
            .font(.system(size: 18)) // Apply font size to the VStack
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Fill available space
            .background(Color(.systemGray6))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(frameStyle.color, lineWidth: frameStyle.lineWidth)
            )
            .onReceive(predictionService.$predictedLandingTimeString) { value in
                appLog("DataPanelView: predicted landing time string updated -> \(value)", category: .ui, level: .debug)
            }
            .onReceive(predictionService.$remainingFlightTimeString) { value in
                appLog("DataPanelView: remaining flight time string updated -> \(value)", category: .ui, level: .debug)
            }
            .onChange(of: bleService.lastMessageTimestamp) { _, newTimestamp in
                // Trigger flash animation when new BLE data arrives from RadioSondy
                // Only flash when telemetry data is received (dataReady state)
                if let newTimestamp = newTimestamp,
                   lastBLETimestamp != newTimestamp,
                   bleService.connectionState == .dataReady {
                    lastBLETimestamp = newTimestamp
                    triggerFlashAnimation()
                }
            }
        } // End GeometryReader
    }

    // MARK: - Computed properties for presentation only (business logic moved to services)

    private var motionMetricsZeroed: Bool {
        switch balloonPositionService.currentState {
        case .liveBLELanded, .aprsLanded, .noTelemetry:
            return true
        default:
            return false
        }
    }

    private var showingPlaceholders: Bool {
        switch balloonPositionService.currentState {
        case .startup, .noTelemetry:
            return true
        default:
            return false
        }
    }

    private var showingDescentRate: Bool {
        switch balloonPositionService.currentState {
        case .startup, .noTelemetry:
            return false
        case .liveBLEFlying, .aprsFlying, .waitingForAPRS:
            return balloonPositionService.balloonPhase != .ascending
        case .liveBLELanded, .aprsLanded:
            return false
        }
    }

    private var frameStyle: (color: Color, lineWidth: CGFloat) {
        // Simple color logic: grey = working, red = no data
        switch balloonPositionService.currentState {
        case .startup, .liveBLEFlying, .liveBLELanded, .waitingForAPRS, .aprsFlying, .aprsLanded:
            return (.gray, 6)  // Working correctly (BLE or APRS data available)
        case .noTelemetry:
            return (.red, 6)   // No data available
        }
    }
    
    private var flightStatusString: String {
        switch balloonPositionService.balloonPhase {
        case .landed: return "Landed"
        case .ascending: return "Ascending"
        case .descendingAbove10k, .descendingBelow10k: return "Descending"
        case .unknown: return "Unknown"
        }
    }

    private var flightStatusIconName: String {
        switch balloonPositionService.balloonPhase {
        case .landed: return "target"
        case .ascending: return "arrow.up.circle.fill"
        case .descendingAbove10k, .descendingBelow10k: return "arrow.down.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var flightStatusTint: Color {
        switch balloonPositionService.balloonPhase {
        case .landed: return .purple
        case .ascending: return .green
        case .descendingBelow10k: return .red  // Low altitude descent - critical
        case .descendingAbove10k: return .orange  // High altitude descent - normal
        case .unknown: return .gray
        }
    }

    private var remainingFlightTimeString: String {
        return predictionService.remainingFlightTimeString
    }
    
    private var predictedLandingTimeString: String {
        return predictionService.predictedLandingTimeString
    }
    
    private var arrivalTimeString: String {
        if showingPlaceholders {
            return "--:--"
        }
        if let routeData = routeCalculationService.currentRoute {
            let arrivalTime = Date().addingTimeInterval(routeData.expectedTravelTime)
            return Self.timeFormatter.string(from: arrivalTime)
        }
        return "--:--"
    }
    
    private var distanceString: String {
        if showingPlaceholders {
            return "--"
        }
        guard let distanceMeters = routeCalculationService.currentRoute?.distance else { return "--" }
        let distanceKm = distanceMeters / 1000.0
        return String(format: "%.1f", distanceKm)
    }

    private static var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static var lastLoggedBurstKillerTime: Int? = nil

    private func burstKillerExpiryString() -> String {
        guard balloonPositionService.currentPositionData != nil else { return "--:--" }
        guard balloonPositionService.currentPositionData?.sondeName != nil else { return "--:--" }

        var countdown: Int? = nil
        var referenceDate: Date? = nil

        // Burst killer is only available from live BLE data (not persisted)
        if let radioData = balloonPositionService.currentRadioChannel,
           radioData.burstKillerTime > 0,
           balloonPositionService.dataSource == .ble {
            countdown = radioData.burstKillerTime
            referenceDate = Date() // Use current time since BLE data is live
        }
        // Note: During APRS fallback, last known BLE burst killer value is retained in memory
        // but not persisted across app sessions

        guard let seconds = countdown,
              let reference = referenceDate else { return "--:--" }

        if Self.lastLoggedBurstKillerTime != seconds {
            appLog("DataPanelView: burst killer time raw value = \(seconds)", category: .ui, level: .debug)
            Self.lastLoggedBurstKillerTime = seconds
        }

        let expiryDate = reference.addingTimeInterval(TimeInterval(seconds))
        guard expiryDate > Date() else { return "--:--" }
        return Self.timeFormatter.string(from: expiryDate)
    }

    private func connectionIcon() -> (name: String, color: Color) {
        // State machine drives connection icon display
        // With no debouncing, state transitions occur immediately when data sources change
        switch balloonPositionService.currentState {
        case .startup:
            return ("antenna.radiowaves.left.and.right", .gray)
        case .liveBLEFlying, .liveBLELanded:
            // Check BLE staleness directly from BLE service
            let isStale = bleService.lastMessageTimestamp.map { Date().timeIntervalSince($0) > 3.0 } ?? true
            return isStale ?
                ("antenna.radiowaves.left.and.right.slash", .red) :
                ("antenna.radiowaves.left.and.right", .green)
        case .waitingForAPRS:
            // In waitingForAPRS state, show BLE connection status
            // Red if connected but no telemetry, gray if not connected
            switch bleService.connectionState {
            case .readyForCommands:
                return ("antenna.radiowaves.left.and.right", .red)  // Connected but no telemetry
            case .dataReady:
                return ("antenna.radiowaves.left.and.right", .green) // Connected with telemetry
            case .notConnected:
                return ("antenna.radiowaves.left.and.right.slash", .red) // Not connected
            }
        case .aprsFlying, .aprsLanded:
            // APRS icon color based on API call success/failure
            let aprsColor: Color = {
                switch balloonPositionService.aprsService.connectionStatus {
                case .connected:
                    return .green  // Last API call successful
                case .failed(_), .disconnected:
                    return .red    // Last API call failed/timeout
                case .connecting, .scanning:
                    return .yellow // API call in progress
                }
            }()
            return ("globe.americas.fill", aprsColor)
        case .noTelemetry:
            // Show red when connected but no telemetry, red when not connected
            switch bleService.connectionState {
            case .readyForCommands:
                return ("antenna.radiowaves.left.and.right", .red)  // Connected but no telemetry
            case .dataReady:
                return ("antenna.radiowaves.left.and.right", .green) // Connected with telemetry (shouldn't happen in noTelemetry state)
            case .notConnected:
                return ("antenna.radiowaves.left.and.right.slash", .red) // Not connected
            }
        }
    }

    // MARK: - Flash Animation

    private func triggerFlashAnimation() {
        withAnimation(.easeInOut(duration: 0.1)) {
            isFlashing = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.1)) {
                isFlashing = false
            }
        }
    }

    private var frequencyString: String {
        if showingPlaceholders {
            return "--- MHz"
        }

        // State machine drives frequency display and source indication
        switch balloonPositionService.currentState {
        case .startup, .noTelemetry:
            return "--- MHz"
        case .liveBLEFlying, .liveBLELanded, .waitingForAPRS:
            // BLE states: show programmed frequency
            let frequency = bleService.radioSettings.frequency
            return String(format: "%.2f MHz", frequency)
        case .aprsFlying, .aprsLanded:
            // APRS states: show APRS frequency if available, fallback to BLE
            if let aprsFreq = balloonPositionService.currentRadioChannel?.frequency {
                return String(format: "%.2f MHz", aprsFreq)
            } else {
                let frequency = bleService.radioSettings.frequency
                return String(format: "%.2f MHz", frequency)
            }
        }
    }

    private var signalStrengthString: String {
        if showingPlaceholders {
            return "0"
        }
        if let val = balloonPositionService.currentRadioChannel?.signalStrength {
            // signalStrength is RSSI in dBm (typically negative values like -50 to -120)
            return String(format: "%d", val)
        }
        return "0"
    }

    private var batteryPercentageString: String {
        if showingPlaceholders {
            return "0"
        }
        // Use radio channel data battery percentage
        if let val = balloonPositionService.currentRadioChannel?.batteryPercentage {
            return "\(val)"
        }
        return "0"
    }

}



#Preview {
    // Create mock services for preview
    let mockAppServices = AppServices()
    let mockServiceCoordinator = ServiceCoordinator(
        bleCommunicationService: mockAppServices.bleCommunicationService,
        currentLocationService: mockAppServices.currentLocationService,
        persistenceService: mockAppServices.persistenceService,
        predictionCache: mockAppServices.predictionCache,
        routingCache: mockAppServices.routingCache,
        predictionService: mockAppServices.predictionService,
        balloonPositionService: mockAppServices.balloonPositionService,
        balloonTrackService: mockAppServices.balloonTrackService,
        landingPointTrackingService: mockAppServices.landingPointTrackingService,
        routeCalculationService: mockAppServices.routeCalculationService,
        navigationService: mockAppServices.navigationService,
        userSettings: mockAppServices.userSettings
    )
    
    DataPanelView()
        .environmentObject(mockServiceCoordinator)
        .environmentObject(mockServiceCoordinator.predictionService)
        .environmentObject(mockAppServices.userSettings)
        .environmentObject(mockAppServices.bleCommunicationService)
        .environmentObject(mockAppServices.balloonTrackService)
        .environmentObject(mockAppServices.balloonPositionService)
        .environmentObject(mockAppServices.routeCalculationService)
}
