import SwiftUI
import CoreLocation

public struct DataPanelView: View {
    public let isBleConnected: Bool
    @Binding public var isBuzzerOn: Bool
    public let telemetry: TelemetryStruct?
    public let landingTime: Date?
    public let arrivalTime: Date?
    public let routeDistance: CLLocationDistance?
    
    public init(isBleConnected: Bool, isBuzzerOn: Binding<Bool>, telemetry: TelemetryStruct?, landingTime: Date?, arrivalTime: Date?, routeDistance: CLLocationDistance?) {
        self.isBleConnected = isBleConnected
        self._isBuzzerOn = isBuzzerOn
        self.telemetry = telemetry
        self.landingTime = landingTime
        self.arrivalTime = arrivalTime
        self.routeDistance = routeDistance
    }
    
    public var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: isBleConnected ? "dot.radiowaves.left.and.right" : "dot.radiowaves.left.and.right.slash")
                    .foregroundColor(isBleConnected ? .green : .red)
                    .font(.system(size: 16))
                Spacer()
                Button(action: { isBuzzerOn.toggle() }) {
                    Image(systemName: isBuzzerOn ? "speaker.wave.3.fill" : "speaker.slash.fill")
                        .foregroundColor(isBuzzerOn ? .orange : .secondary)
                        .font(.system(size: 20))
                        .padding(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            
            if let t = telemetry {
                HStack(spacing: 6) {
                    Text("\(t.probeType)")
                        .bold()
                    Text("#\(t.sondeName)")
                        .foregroundColor(.secondary)
                    Text(String(format: "@ %.3f MHz", t.frequency))
                        .foregroundColor(.blue)
                    Spacer()
                }
                .font(.caption2)
                .padding(.horizontal, 8)
            }
            
            if let t = telemetry {
                InfoRowView(label: "Alt:") {
                    Text("\(Int(t.altitude)) m")
                        .bold()
                }
                InfoRowView(label: "VS:") {
                    Text(String(format: "%+.1f m/s", t.verticalSpeed))
                        .bold()
                        .foregroundColor(t.verticalSpeed > 0 ? .green : (t.verticalSpeed < 0 ? .red : .primary))
                }
                InfoRowView(label: "Signal:") {
                    Text("\(Int(t.rssi)) dB")
                }
                InfoRowView(label: "Bat:") {
                    Text("\(t.batPercentage)%")
                }
            }
            
            if let landing = landingTime {
                InfoRowView(label: "Landing:") {
                    Text(landing, style: .time)
                }
            }
            
            if let arrival = arrivalTime {
                InfoRowView(label: "Arrival:") {
                    Text(arrival, style: .time)
                }
            }
            
            remainingTimeView()
            
            if let dist = routeDistance {
                InfoRowView(label: "Route Dist:") {
                    Text(String(format: "%.1f km", dist/1000))
                }
            }
        }
        .font(.footnote)
        .foregroundColor(.primary)
        .background(Color(.systemBackground).opacity(0.95))
        .cornerRadius(10)
        .padding(.horizontal, 8)
        .shadow(radius: 4)
    }
    
    @ViewBuilder
    private func remainingTimeView() -> some View {
        if let landing = landingTime {
            InfoRowView(label: "Remaining:") {
                let mins = Int((landing.timeIntervalSinceNow)/60)
                Text(mins <= 0 ? "now" : "\(mins) min")
            }
        }
    }
}
