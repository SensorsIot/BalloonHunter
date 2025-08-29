// DataPanelView.swift
import SwiftUI

struct DataPanelView: View {
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var predictionService: PredictionService
    @EnvironmentObject var routeService: RouteCalculationService
    @EnvironmentObject var locationService: CurrentLocationService

    @State private var lastRouteCalculationTime: Date? = nil

    var body: some View {
        VStack {
            // Table 1: 4 columns
            Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                GridRow {
                    Image(systemName: bleService.connectionStatus == .connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .foregroundColor(bleService.connectionStatus == .connected ? .green : .red)
                        .font(.headline)
                        .scaleEffect(1.5)
                    Text(bleService.latestTelemetry?.probeType ?? "N/A")
                        .font(.headline)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    Text(bleService.latestTelemetry?.sondeName ?? "N/A")
                        .font(.headline)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: {
                        if bleService.latestTelemetry?.buzmute == true {
                            bleService.sendCommand(command: "mute=0") // Unmute
                        } else {
                            bleService.sendCommand(command: "mute=1") // Mute
                        }
                    }) {
                        Image(systemName: bleService.latestTelemetry?.buzmute == true ? "speaker.slash.fill" : "speaker.fill")
                            .font(.headline)
                            .scaleEffect(1.8)
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
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("RSSI: \(signalStrengthString) dB")
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Batt: \(batteryPercentageString)%")
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("V: \(verticalSpeedAvgString) m/s")
                        .font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundColor((bleService.latestTelemetry?.verticalSpeed ?? 0) >= 0 ? .green : .red)
                    Text("H: \(horizontalSpeedString) km/h")
                        .font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Dist: \(distanceString) km")
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("Flight: \(flightTime)")
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Land: \(landingTimeString)")
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Arrival: \(arrivalTimeString)")
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal)



        }
        .background(Color(.systemGray6))
        .cornerRadius(15)
        .padding()
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
            return String(format: "%.1f", val)
        }
        return "0.0"
    }

    private var batteryPercentageString: String {
        if let val = bleService.latestTelemetry?.batteryPercentage {
            return "\(val)"
        }
        return "0"
    }

    private var verticalSpeedAvg: Double {
        let last5 = bleService.telemetryHistory.suffix(5)
        let speeds = last5.compactMap { $0.verticalSpeed }
        guard !speeds.isEmpty else { return bleService.latestTelemetry?.verticalSpeed ?? 0 }
        let sum = speeds.reduce(0, +)
        return sum / Double(speeds.count)
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
