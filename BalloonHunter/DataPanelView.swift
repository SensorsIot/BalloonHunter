// DataPanelView.swift
import SwiftUI

struct DataPanelView: View {
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var predictionService: PredictionService
    @EnvironmentObject var routeService: RouteCalculationService
    @EnvironmentObject var locationService: CurrentLocationService
    @EnvironmentObject var balloonTrackingService: BalloonTrackingService

    @State private var lastRouteCalculationTime: Date? = nil

    var body: some View {
        GeometryReader { geometry in // Added GeometryReader
            VStack {
                // Table 1: 4 columns
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    GridRow {
                        Image(systemName: bleService.connectionStatus == .connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(bleService.connectionStatus == .connected ? .green : .red)
                            .font(.system(size: 32))
                        Text(bleService.latestTelemetry?.probeType ?? "N/A")
                            .frame(maxWidth: .infinity)
                        Text(bleService.latestTelemetry?.sondeName ?? "N/A")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: {
                            let newMuteState = !(bleService.latestTelemetry?.buzmute ?? false)
                            bleService.latestTelemetry?.buzmute = newMuteState
                            let command = "o{mute=\(newMuteState ? 1 : 0)}o"
                            bleService.sendCommand(command: command)
                        }) {
                            Image(systemName: bleService.latestTelemetry?.buzmute == true ? "speaker.slash.fill" : "speaker.fill")
                                .font(.system(size: 32))
                                .frame(minWidth: 60, minHeight: 60)
                                .contentShape(Rectangle())
                        }
                        .gridCellAnchor(.trailing)
                    }
                }
                .padding(.horizontal)

                // Table 2: 3 columns
                Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                    GridRow {
                        Text("\(String(format: "%.3f", bleService.latestTelemetry?.frequency ?? 0.0)) MHz")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("RSSI: \(signalStrengthString) dB") // Reverted to dB
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Batt: \(batteryPercentageString)%")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GridRow {
                        Text("V: \(String(format: "%.1f", smoothedVerticalSpeed)) m/s")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor((bleService.latestTelemetry?.verticalSpeed ?? 0) >= 0 ? .green : .red)
                        Text("H: \(String(format: "%.1f", smoothedHorizontalSpeed)) km/h")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Dist: \(distanceString) km")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GridRow {
                        Text("Flight: \(flightTime)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Land: \(landingTimeString)")
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
        .onChange(of: predictionService.predictionData) { _, _ in
            // Trigger update for flight time, landing time, arrival time, and distance
            // These are already computed properties, so just re-rendering the view is enough
        }
        .onChange(of: routeService.routeData) { _, _ in
            // Trigger update for flight time, landing time, arrival time, and distance
            // These are already computed properties, so just re-rendering the view is enough
        }
        .onChange(of: locationService.locationData) { _, newLocation in
            if let lastCalcTime = lastRouteCalculationTime {
                if Date().timeIntervalSince(lastCalcTime) > 60 {
                    // Recalculate route if user moved and last calculation was more than 1 minute ago
                    // This logic should be in MapView or AppState, not DataPanelView
                    // DataPanelView just displays the data
                    lastRouteCalculationTime = Date()
                }
            } else {
                lastRouteCalculationTime = Date()
            }
        }
    }

    // MARK: - Helpers for smoothing
    
    private var smoothedHorizontalSpeed: Double {
        let speeds = balloonTrackingService.last5Telemetry.compactMap { $0.horizontalSpeed }
        guard !speeds.isEmpty else { return bleService.latestTelemetry?.horizontalSpeed ?? 0 }
        return speeds.reduce(0, +) / Double(speeds.count)
    }
    private var smoothedVerticalSpeed: Double {
        let speeds = balloonTrackingService.last5Telemetry.compactMap { $0.verticalSpeed }
        guard !speeds.isEmpty else { return bleService.latestTelemetry?.verticalSpeed ?? 0 }
        return speeds.reduce(0, +) / Double(speeds.count)
    }

    // MARK: - Computed properties and helpers

    var flightTime: String {
        guard let landingTime = predictionService.predictionData?.landingTime else { return "--:--" }
        let interval = landingTime.timeIntervalSinceNow

        if interval < 0 {
            return "00:00"
        }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    private var landingTimeString: String {
        predictionService.predictionData?.landingTime?.formatted(date: .omitted, time: .shortened) ?? "--:--"
    }

    private var arrivalTimeString: String {
        routeService.routeData?.arrivalTime?.formatted(date: .omitted, time: .shortened) ?? "--:--"
    }

    private var distanceString: String {
        if let distanceMeters = routeService.routeData?.distance {
            let distanceKm = distanceMeters / 1000.0
            return String(format: "%.1f", distanceKm)
        }
        return "--"
    }

    private var signalStrengthString: String {
        if let val = bleService.latestTelemetry?.signalStrength {
            // Assuming signalStrength is a value that can be directly used as a percentage (0-100)
            // If it's RSSI in dB, this conversion is incorrect and needs clarification from the user.
            return String(format: "%.0f", val)
        }
        return "0"
    }

    private var batteryPercentageString: String {
        if let val = bleService.latestTelemetry?.batteryPercentage {
            return "\(val)"
        }
        return "0"
    }

    private var verticalSpeedAvg: Double {
        return bleService.latestTelemetry?.verticalSpeed ?? 0
    }
    private var verticalSpeedAvgString: String {
        String(format: "%.1f", verticalSpeedAvg)
    }

    private var horizontalSpeedString: String {
        if let hs = bleService.latestTelemetry?.horizontalSpeed {
            return String(format: "%.1f", hs)
        }
        return "N/A"
    }
}



#Preview {
    DataPanelView()
}
