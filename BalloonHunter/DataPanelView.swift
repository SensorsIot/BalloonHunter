// DataPanelView.swift
import SwiftUI
import OSLog
import Foundation

struct DataPanelView: View {
    // MapState eliminated - ServiceCoordinator now holds all state
    @EnvironmentObject var serviceCoordinator: ServiceCoordinator

    var body: some View {
        GeometryReader { geometry in // Added GeometryReader
            let _ : CGFloat = 120 // Column width no longer needed after FSD restructure

            VStack {
                // Table 1: 4 columns - Connected, Sonde Type, Sonde Name, Altitude
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    GridRow {
                        Image(systemName: serviceCoordinator.connectionStatus == ConnectionStatus.connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(serviceCoordinator.connectionStatus == ConnectionStatus.connected ? .green : .red)
                            .font(.system(size: 32))
                        Text(serviceCoordinator.balloonTelemetry?.probeType ?? "N/A")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(serviceCoordinator.balloonTelemetry?.sondeName ?? "N/A")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(serviceCoordinator.balloonTelemetry != nil ? "\(Int(serviceCoordinator.balloonTelemetry!.altitude)) m" : "N/A")")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)

                // Table 2: 3 columns - Per FSD specification
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    // Row 1: Frequency, Signal Strength, Battery %
                    GridRow {
                        Text("\(serviceCoordinator.frequencyString) MHz")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(signalStrengthString) dBm")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(batteryPercentageString) Batt%")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Row 2: Vertical speed, Horizontal speed, Distance
                    GridRow {
                        Text("V: \(String(format: "%.1f", serviceCoordinator.smoothedVerticalSpeed)) m/s")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor((serviceCoordinator.balloonTelemetry?.verticalSpeed ?? 0) >= 0 ? .green : .red)
                        Text("H: \(String(format: "%.1f", serviceCoordinator.smoothedHorizontalSpeed * 3.6)) km/h")
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
                        Text("Descent Rate: \(serviceCoordinator.displayDescentRateString) m/s")
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
                    .stroke(serviceCoordinator.isTelemetryStale ? Color.red : Color.clear, lineWidth: 3)
            )
        } // End GeometryReader
    }

    // MARK: - Computed properties for presentation only (business logic moved to services)
    
    private var remainingFlightTimeString: String {
        return serviceCoordinator.remainingFlightTimeString
    }
    
    private var predictedLandingTimeString: String {
        return serviceCoordinator.predictedLandingTimeString
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
        if let distanceMeters = serviceCoordinator.routeData?.distance {
            let distanceKm = distanceMeters / 1000.0
            return String(format: "%.1f", distanceKm)
        }
        return "--"
    }

    private var signalStrengthString: String {
        if let val = serviceCoordinator.balloonTelemetry?.signalStrength {
            // signalStrength is RSSI in dBm (typically negative values like -50 to -120)
            return String(format: "%d", val)
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

