// DataPanelView.swift
import SwiftUI
import OSLog
import Foundation

struct DataPanelView: View {
    // MapState eliminated - ServiceCoordinator now holds all state
    @EnvironmentObject var serviceCoordinator: ServiceCoordinator
    @State private var refreshTrigger = false

    var body: some View {
        GeometryReader { geometry in // Added GeometryReader
            let columnWidth: CGFloat = 120

            VStack {
                // Table 1: 4 columns
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    GridRow {
                        Image(systemName: serviceCoordinator.bleCommunicationService.connectionStatus == ConnectionStatus.connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(serviceCoordinator.bleCommunicationService.connectionStatus == ConnectionStatus.connected ? .green : .red)
                            .font(.system(size: 32))
                        Text(serviceCoordinator.balloonTelemetry?.probeType ?? "N/A")
                            .frame(maxWidth: .infinity)
                        Text(serviceCoordinator.balloonTelemetry?.sondeName ?? "N/A")
                            .frame(width: columnWidth, alignment: .leading)
                        Text("Alt: \(serviceCoordinator.balloonTelemetry != nil ? "\(Int(serviceCoordinator.balloonTelemetry!.altitude)) m" : "N/A")")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)

                // Table 2: 3 columns x 3 rows
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    GridRow {
                        Text("\(String(format: "%.3f", serviceCoordinator.balloonTelemetry?.frequency ?? 0.0)) MHz")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("RSSI: \(signalStrengthString) dB")
                            .frame(width: columnWidth, alignment: .leading)
                        Text("Batt: \(batteryPercentageString)%")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GridRow {
                        Text("V: \(String(format: "%.1f", smoothedVerticalSpeed)) m/s")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor((serviceCoordinator.balloonTelemetry?.verticalSpeed ?? 0) >= 0 ? .green : .red)
                        Text("H: \(String(format: "%.1f", smoothedHorizontalSpeed)) km/h")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Dist: \(distanceString) km")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GridRow {
                        Text("Flight: \(flightTime)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Landing: \(landingTimeString)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Arrival: \(arrivalTimeString)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GridRow {
                        Text("Descent: \(adjustedDescentRateString) m/s")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("")
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                    .stroke(isTelemetryStale ? Color.red : Color.clear, lineWidth: 3)
            )
        } // End GeometryReader
        .onAppear {
            // Start timer to check for stale telemetry every second
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                refreshTrigger.toggle() // Force view refresh to check telemetry staleness
            }
        }
    }

    // MARK: - Helpers for smoothing
    
    private var smoothedHorizontalSpeed: Double {
        let last5 = Array(serviceCoordinator.balloonTrackHistory.suffix(5))
        let speeds = last5.compactMap { $0.horizontalSpeed }
        guard !speeds.isEmpty else { return serviceCoordinator.balloonTelemetry?.horizontalSpeed ?? 0 }
        return speeds.reduce(0, +) / Double(speeds.count)
    }
    private var smoothedVerticalSpeed: Double {
        let last5 = Array(serviceCoordinator.balloonTrackHistory.suffix(5))
        let speeds = last5.compactMap { $0.verticalSpeed }
        guard !speeds.isEmpty else { return serviceCoordinator.balloonTelemetry?.verticalSpeed ?? 0 }
        return speeds.reduce(0, +) / Double(speeds.count)
    }

    // MARK: - Computed properties and helpers
    
    private var isTelemetryStale: Bool {
        // Use refreshTrigger to ensure view updates when staleness changes
        _ = refreshTrigger
        
        guard let telemetry = serviceCoordinator.balloonTelemetry else {
            // No telemetry available at all
            return true
        }
        
        let timeSinceUpdate = Date().timeIntervalSince(telemetry.timestamp)
        let isStale = timeSinceUpdate > 3.0 // 3 seconds threshold
        
        if isStale {
            appLog("DataPanelView: Telemetry is stale - last update \(String(format: "%.1f", timeSinceUpdate))s ago", category: .ui, level: .debug)
        }
        
        return isStale
    }

    var flightTime: String {
        return "--:--"  // Flight time calculation not implemented yet
    }

    private var landingTimeString: String {
        return "--:--"  // Landing time calculation not implemented yet
    }

    private var arrivalTimeString: String {
        if let travelTime = serviceCoordinator.routeData?.expectedTravelTime {
            let arrivalTime = Date().addingTimeInterval(travelTime)
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: arrivalTime)
        }
        return "--:--"
    }

    private var distanceString: String {
        if let distanceMeters = serviceCoordinator.routeData?.distance {
            let distanceKm = distanceMeters / 1000.0
            return String(format: "%.1f", distanceKm)
        }
        return "--"
    }

    private var signalStrengthString: String {
        if let val = serviceCoordinator.balloonTelemetry?.signalStrength {
            // Assuming signalStrength is a value that can be directly used as a percentage (0-100)
            // If it's RSSI in dB, this conversion is incorrect and needs clarification from the user.
            return String(format: "%.0f", val)
        }
        return "0"
    }

    private var batteryPercentageString: String {
        if let val = serviceCoordinator.balloonTelemetry?.batteryPercentage {
            return "\(val)"
        }
        return "0"
    }

    private var verticalSpeedAvg: Double {
        return serviceCoordinator.balloonTelemetry?.verticalSpeed ?? 0
    }
    private var verticalSpeedAvgString: String {
        String(format: "%.1f", verticalSpeedAvg)
    }

    private var horizontalSpeedString: String {
        if let hs = serviceCoordinator.balloonTelemetry?.horizontalSpeed {
            return String(format: "%.1f", hs)
        }
        return "N/A"
    }
    
    private var adjustedDescentRateString: String {
        if let adjustedRate = serviceCoordinator.smoothedDescentRate {
            appLog("DataPanelView: Displaying smoothed descent rate: \(String(format: "%.2f", adjustedRate)) m/s", category: .ui, level: .debug)
            return String(format: "%.1f", abs(adjustedRate))
        }
        return "--"
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
        balloonTrackService: mockAppServices.balloonTrackService
    )
    
    DataPanelView()
        .environmentObject(mockServiceCoordinator)
}

