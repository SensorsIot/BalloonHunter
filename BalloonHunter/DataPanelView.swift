// DataPanelView.swift
import SwiftUI
import OSLog
import Foundation

struct DataPanelView: View {
    // MapState eliminated - ServiceCoordinator now holds all state
    @EnvironmentObject var serviceCoordinator: ServiceCoordinator
    @EnvironmentObject var predictionService: PredictionService
    @EnvironmentObject var userSettings: UserSettings
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var balloonTrackService: BalloonTrackService
    @EnvironmentObject var balloonPositionService: BalloonPositionService

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
                        Image(systemName: flightStatusIconName)
                            .foregroundColor(flightStatusTint)
                            .font(.system(size: 24))
                            .frame(width: 48, alignment: .center)
                            .accessibilityLabel(Text(flightStatusString))
                        Text(balloonPositionService.currentTelemetry?.probeType ?? "N/A")
                            .frame(width: 70, alignment: .center)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                        Text(balloonPositionService.currentTelemetry?.sondeName ?? "N/A")
                            .frame(width: 120, alignment: .center)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                        Text("\(balloonPositionService.currentTelemetry != nil ? "\(Int(balloonPositionService.currentTelemetry!.altitude)) m" : "N/A")")
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
                        Text("\(batteryPercentageString) Batt%")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Row 2: Vertical speed, Horizontal speed, Distance
                    GridRow {
                        Text("V: \(String(format: "%.1f", balloonTrackService.motionMetrics.smoothedVerticalSpeedMS)) m/s")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(balloonTrackService.motionMetrics.smoothedVerticalSpeedMS >= 0 ? .green : .red)
                        Text("H: \(String(format: "%.1f", balloonTrackService.motionMetrics.smoothedHorizontalSpeedMS * 3.6)) km/h")
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
                        let descentRate = serviceCoordinator.smoothedDescentRate
                        let descentValue = String(format: "%.1f", abs(descentRate ?? userSettings.descentRate))
                        let burstKillerExpiry = burstKillerExpiryString()
                        Text("Descent Rate: \(descentValue) m/s  •  Burst killer: \(burstKillerExpiry)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(serviceCoordinator.predictionUsesSmoothedDescent ? .green : .primary)
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
        } // End GeometryReader
    }

    // MARK: - Computed properties for presentation only (business logic moved to services)

    private var frameStyle: (color: Color, lineWidth: CGFloat) {
        if balloonPositionService.isTelemetryStale {
            return (.red, 6)
        }
        if balloonPositionService.lastTelemetrySource == .ble {
            return (.green, 6)
        }
        if balloonPositionService.lastTelemetrySource == .aprs {
            return (.orange, 6)
        }
        return (.clear, 6)
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
        if let routeData = serviceCoordinator.routeData {
            let arrivalTime = Date().addingTimeInterval(routeData.expectedTravelTime)
            return Self.timeFormatter.string(from: arrivalTime)
        }
        return "--:--"
    }
    
    private var distanceString: String {
        guard let distanceMeters = serviceCoordinator.routeData?.distance else { return "--" }
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
        guard balloonPositionService.currentTelemetry != nil else { return "--:--" }
        guard let sondeName = balloonPositionService.currentTelemetry?.sondeName else { return "--:--" }

        var countdown: Int? = nil
        var referenceDate: Date? = nil

        if let liveCountdown = balloonPositionService.burstKillerCountdown,
           let liveReference = balloonPositionService.burstKillerReferenceDate,
           liveCountdown > 0,
           balloonPositionService.lastTelemetrySource == .ble {
            countdown = liveCountdown
            referenceDate = liveReference
        } else if let record = serviceCoordinator.persistenceService.loadBurstKillerRecord(for: sondeName),
                  record.seconds > 0 {
            countdown = record.seconds
            referenceDate = record.referenceDate
        }

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
        // Show icon based on actual telemetry source being used
        if balloonPositionService.lastTelemetrySource == .ble {
            return ("antenna.radiowaves.left.and.right", .green)
        }
        if balloonPositionService.lastTelemetrySource == .aprs {
            return ("globe.americas.fill", .orange)
        }
        // No telemetry - show BLE connection status
        if bleService.telemetryState.isConnected {
            return ("antenna.radiowaves.left.and.right", .gray)
        }
        return ("antenna.radiowaves.left.and.right.slash", .red)
    }

    private var frequencyString: String {
        // Display the frequency programmed into RadioSondyGo
        let frequency = bleService.deviceSettings.frequency
        return String(format: "%.2f MHz", frequency)
    }

    private var signalStrengthString: String {
        if let val = balloonPositionService.currentTelemetry?.signalStrength {
            // signalStrength is RSSI in dBm (typically negative values like -50 to -120)
            return String(format: "%d", val)
        }
        return "0"
    }

    private var batteryPercentageString: String {
        if let val = balloonPositionService.currentTelemetry?.batteryPercentage {
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
        balloonPositionService: mockAppServices.balloonPositionService,
        balloonTrackService: mockAppServices.balloonTrackService,
        landingPointTrackingService: mockAppServices.landingPointTrackingService
    )
    
    DataPanelView()
        .environmentObject(mockServiceCoordinator)
        .environmentObject(mockServiceCoordinator.predictionService)
        .environmentObject(mockAppServices.userSettings)
        .environmentObject(mockAppServices.bleCommunicationService)
        .environmentObject(mockAppServices.balloonTrackService)
        .environmentObject(mockAppServices.balloonPositionService)
}
