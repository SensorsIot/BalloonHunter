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
            let _ : CGFloat = 120 // Column width no longer needed after FSD restructure

            VStack {
                // Table 1: 5 columns - Connected, Flight Status, Sonde Type, Sonde Name, Altitude
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    GridRow {
                        Image(systemName: bleService.connectionStatus == ConnectionStatus.connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(bleService.connectionStatus == ConnectionStatus.connected ? .green : .red)
                            .font(.system(size: 28))
                        Image(systemName: flightStatusIconName)
                            .foregroundColor(flightStatusTint)
                            .font(.system(size: 24))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(Text(flightStatusString))
                        Text(balloonPositionService.currentTelemetry?.probeType ?? "N/A")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(balloonPositionService.currentTelemetry?.sondeName ?? "N/A")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(balloonPositionService.currentTelemetry != nil ? "\(Int(balloonPositionService.currentTelemetry!.altitude)) m" : "N/A")")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)

                // Table 2: 3 columns - Per FSD specification
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    // Row 1: Frequency, Signal Strength, Battery %
                    GridRow {
                        Text("\(String(format: "%.3f", bleService.deviceSettings.frequency)) MHz")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(signalStrengthString) dBm")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(batteryPercentageString) Batt%")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Row 2: Vertical speed, Horizontal speed, Distance
                    GridRow {
                        Text("V: \(String(format: "%.1f", balloonTrackService.smoothedVerticalSpeed)) m/s")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor((balloonPositionService.currentTelemetry?.verticalSpeed ?? 0) >= 0 ? .green : .red)
                        Text("H: \(String(format: "%.1f", balloonTrackService.smoothedHorizontalSpeed * 3.6)) km/h")
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
                        let descentValue: String = {
                            if let r = balloonTrackService.adjustedDescentRate { return String(format: "%.1f", abs(r)) }
                            return String(format: "%.1f", userSettings.descentRate)
                        }()
                        Text("Descent Rate: \(descentValue) m/s")
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
                    .stroke(balloonTrackService.isTelemetryStale ? Color.red : Color.clear, lineWidth: 3)
            )
        } // End GeometryReader
    }

    // MARK: - Computed properties for presentation only (business logic moved to services)
    
    private var flightStatusString: String {
        switch balloonTrackService.balloonPhase {
        case .landed: return "Landed"
        case .ascending: return "Ascending"
        case .descendingAbove10k, .descendingBelow10k: return "Descending"
        case .unknown: return "Unknown"
        }
    }

    private var flightStatusIconName: String {
        switch balloonTrackService.balloonPhase {
        case .landed: return "target"
        case .ascending: return "arrow.up.circle.fill"
        case .descendingAbove10k, .descendingBelow10k: return "arrow.down.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var flightStatusTint: Color {
        switch balloonTrackService.balloonPhase {
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
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: arrivalTime)
        }
        return "--:--"
    }
    
    private var distanceString: String {
        guard let distanceMeters = serviceCoordinator.routeData?.distance else { return "--" }
        let distanceKm = distanceMeters / 1000.0
        return String(format: "%.1f", distanceKm)
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

    private var verticalSpeedAvg: Double {
        return balloonPositionService.currentTelemetry?.verticalSpeed ?? 0
    }
    private var verticalSpeedAvgString: String {
        String(format: "%.1f", verticalSpeedAvg)
    }

    private var horizontalSpeedString: String {
        if let hs = balloonPositionService.currentTelemetry?.horizontalSpeed {
            return String(format: "%.1f", hs)
        }
        return "N/A"
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
