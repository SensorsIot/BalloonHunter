// DataPanelView.swift
import SwiftUI

struct DataPanelView: View {
    @EnvironmentObject var mapState: MapState
    @EnvironmentObject var serviceManager: ServiceManager

    var body: some View {
        GeometryReader { geometry in // Added GeometryReader
            let columnWidth: CGFloat = 120

            VStack {
                // Table 1: 4 columns
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    GridRow {
                        Image(systemName: serviceManager.bleCommunicationService.connectionStatus == .connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(serviceManager.bleCommunicationService.connectionStatus == .connected ? .green : .red)
                            .font(.system(size: 32))
                        Text(mapState.balloonTelemetry?.probeType ?? "N/A")
                            .frame(maxWidth: .infinity)
                        Text(mapState.balloonTelemetry?.sondeName ?? "N/A")
                            .frame(width: columnWidth, alignment: .leading)
                        Text("Alt: \(mapState.balloonTelemetry != nil ? "\(Int(mapState.balloonTelemetry!.altitude)) m" : "N/A")")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal)

                // Table 2: 3 columns x 3 rows
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    GridRow {
                        Text("\(String(format: "%.3f", mapState.balloonTelemetry?.frequency ?? 0.0)) MHz")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("RSSI: \(signalStrengthString) dB")
                            .frame(width: columnWidth, alignment: .leading)
                        Text("Batt: \(batteryPercentageString)%")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GridRow {
                        Text("V: \(String(format: "%.1f", smoothedVerticalSpeed)) m/s")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor((mapState.balloonTelemetry?.verticalSpeed ?? 0) >= 0 ? .green : .red)
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
                }
                .padding(.horizontal)
            }
            .padding(.top, -10) // Reduced top padding
            .font(.system(size: 18)) // Apply font size to the VStack
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Fill available space
            .background(Color(.systemGray6))
        } // End GeometryReader
        // DataPanelView now gets all data from MapState - no onChange needed
    }

    // MARK: - Helpers for smoothing
    
    private var smoothedHorizontalSpeed: Double {
        let last5 = Array(mapState.balloonTrackHistory.suffix(5))
        let speeds = last5.compactMap { $0.horizontalSpeed }
        guard !speeds.isEmpty else { return mapState.balloonTelemetry?.horizontalSpeed ?? 0 }
        return speeds.reduce(0, +) / Double(speeds.count)
    }
    private var smoothedVerticalSpeed: Double {
        let last5 = Array(mapState.balloonTrackHistory.suffix(5))
        let speeds = last5.compactMap { $0.verticalSpeed }
        guard !speeds.isEmpty else { return mapState.balloonTelemetry?.verticalSpeed ?? 0 }
        return speeds.reduce(0, +) / Double(speeds.count)
    }

    // MARK: - Computed properties and helpers

    var flightTime: String {
        guard let landingTime = mapState.predictionData?.landingTime else { return "--:--" }
        let interval = landingTime.timeIntervalSinceNow

        if interval < 0 {
            return "00:00"
        }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    private var landingTimeString: String {
        mapState.predictionData?.landingTime?.formatted(date: .omitted, time: .shortened) ?? "--:--"
    }

    private var arrivalTimeString: String {
        mapState.routeData?.arrivalTime?.formatted(date: .omitted, time: .shortened) ?? "--:--"
    }

    private var distanceString: String {
        if let distanceMeters = mapState.routeData?.distance {
            let distanceKm = distanceMeters / 1000.0
            return String(format: "%.1f", distanceKm)
        }
        return "--"
    }

    private var signalStrengthString: String {
        if let val = mapState.balloonTelemetry?.signalStrength {
            // Assuming signalStrength is a value that can be directly used as a percentage (0-100)
            // If it's RSSI in dB, this conversion is incorrect and needs clarification from the user.
            return String(format: "%.0f", val)
        }
        return "0"
    }

    private var batteryPercentageString: String {
        if let val = mapState.balloonTelemetry?.batteryPercentage {
            return "\(val)"
        }
        return "0"
    }

    private var verticalSpeedAvg: Double {
        return mapState.balloonTelemetry?.verticalSpeed ?? 0
    }
    private var verticalSpeedAvgString: String {
        String(format: "%.1f", verticalSpeedAvg)
    }

    private var horizontalSpeedString: String {
        if let hs = mapState.balloonTelemetry?.horizontalSpeed {
            return String(format: "%.1f", hs)
        }
        return "N/A"
    }
    
    private var adjustedDescentRateString: String {
        if let adjustedRate = mapState.smoothedDescentRate {
            return String(format: "%.1f", abs(adjustedRate))
        }
        return "--"
    }
}



#Preview {
    DataPanelView()
        .environmentObject(MapState())
        .environmentObject(ServiceManager())
}

