// DataPanelView.swift
import SwiftUI

struct DataPanelView: View {
    @EnvironmentObject var bleService: BLECommunicationService
    @EnvironmentObject var predictionService: PredictionService
    @EnvironmentObject var routeService: RouteCalculationService

    var body: some View {
        VStack {
            // GRID 1 (Already done)
            Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                GridRow {
                    Image(systemName: bleService.connectionStatus == .connected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .foregroundColor(bleService.connectionStatus == .connected ? .green : .red)
                        .font(.headline) // Smaller font for narrower column
                    Text(bleService.latestTelemetry?.probeType ?? "N/A")
                        .font(.headline)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    Text(bleService.latestTelemetry?.sondeName ?? "N/A")
                        .font(.headline)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    Button(action: {
                        bleService.sendCommand(command: "mute=1")
                    }) {
                        Image(systemName: bleService.latestTelemetry?.buzmute == true ? "speaker.slash.fill" : "speaker.fill")
                            .font(.headline) // Smaller font for narrower column
                            .frame(minWidth: 44, minHeight: 44) // Keep tap target size
                    }
                    .gridCellAnchor(.trailing) // Pad to the right within its cell
                }
            }
            .padding(.horizontal) // Add horizontal padding to match the other grid

            // NEW GRID 2: Frequency, Signal, Battery, Alt, H.Spd, V.Spd (3 columns)
            Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                GridRow {
                    Text("\(String(format: "%.3f", bleService.latestTelemetry?.frequency ?? 0.0)) MHz") // Col 1
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity)
                    Text("RSSI: \(bleService.latestTelemetry?.signalStrength ?? 0, specifier: "%.1f")") // Col 2
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity)
                    Text("Batt: \(bleService.latestTelemetry?.batteryPercentage ?? 0)%") // Col 3
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity)
                }
                GridRow {
                    Text("Alt: \(bleService.latestTelemetry?.altitude ?? 0, specifier: "%.0f") m") // Col 1
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity)
                    Text("H: \(bleService.latestTelemetry?.horizontalSpeed ?? 0, specifier: "%.1f") m/s") // Col 2
                        .font(.headline).lineLimit(1).frame(maxWidth: .infinity)
                    Text("V: \(bleService.latestTelemetry?.verticalSpeed ?? 0, specifier: "%.1f") m/s") // Col 3
                        .font(.headline).lineLimit(1).frame(maxWidth: .infinity)
                        .foregroundColor((bleService.latestTelemetry?.verticalSpeed ?? 0) >= 0 ? .green : .red)
                }
            }
            .padding(.horizontal) // Add padding

            // NEW GRID 3: Distance, Landing, Flight, Arrival (2 columns, 2 rows)
            Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 10) {
                GridRow {
                    Text("Dist: \((routeService.routeData?.distance ?? 0) / 1000, specifier: "%.1f") km") // Col 1
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity)
                    Text("Flight: \(flightTime)") // Col 2
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity)
                }
                GridRow {
                    Text("Land: \(predictionService.predictionData?.landingTime?.formatted(date: .omitted, time: .shortened) ?? "--:--")") // Col 1
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity)
                    Text("Arrival: \(routeService.routeData?.arrivalTime?.formatted(date: .omitted, time: .shortened) ?? "--:--")") // Col 2
                        .font(.headline).minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal) // Keep padding

        }
        .background(Color(.systemGray6))
        .cornerRadius(15)
        .padding()
    }

    var flightTime: String {
        guard let landingTime = predictionService.predictionData?.landingTime else { return "--:--" }
        let interval = landingTime.timeIntervalSinceNow
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }



} // Closing brace for DataPanelView struct

#Preview {
    DataPanelView()
}
