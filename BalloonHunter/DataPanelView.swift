import SwiftUI
import CoreLocation

public struct DataPanelView: View {
    public let isBleConnected: Bool
    @Binding public var isBuzzerOn: Bool
    public let telemetry: Telemetry?
    public let landingTime: Date?
    public let arrivalTime: Date?
    public let routeDistance: CLLocationDistance?
    
    public init(isBleConnected: Bool, isBuzzerOn: Binding<Bool>, telemetry: Telemetry?, landingTime: Date?, arrivalTime: Date?, routeDistance: CLLocationDistance?) {
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
                    Text("#\(t.name)")
                        .foregroundColor(.secondary)
                    Text(String(format: "@ %.3f MHz", t.frequency))
                        .foregroundColor(.blue)
                    Spacer()
                }
                .font(.caption2)
                .padding(.horizontal, 8)
            }
            
            if let t = telemetry {
                HStack(spacing: 10) {
                    Group {
                        Text("Alt:")
                            .foregroundColor(.secondary)
                        Text("\(Int(t.altitude)) m")
                            .bold()
                    }
                    Group {
                        Text("VS:")
                            .foregroundColor(.secondary)
                        let vSpeed = t.verticalSpeed
                        Text(String(format: "%+.1f m/s", vSpeed))
                            .bold()
                            .foregroundColor(vSpeed > 0 ? .green : (vSpeed < 0 ? .red : .primary))
                    }
                    Spacer()
                }
                .font(.caption2)
                .padding(.horizontal, 8)
            }
            
            if let t = telemetry {
                HStack(spacing: 10) {
                    Group {
                        Text("Signal:")
                            .foregroundColor(.secondary)
                        Text("\(Int(t.signalStrength)) dB")
                    }
                    Group {
                        Text("Bat:")
                            .foregroundColor(.secondary)
                        Text("\(t.batteryPercentage)%")
                    }
                    Spacer()
                }
                .font(.caption2)
                .padding(.horizontal, 8)
            }
            
            HStack(spacing: 10) {
                if let landing = landingTime {
                    Group {
                        Text("Landing:")
                            .foregroundColor(.secondary)
                        Text(landing, style: .time)
                    }
                }
                if let arrival = arrivalTime {
                    Group {
                        Text("Arrival:")
                            .foregroundColor(.secondary)
                        Text(arrival, style: .time)
                    }
                }
                Spacer()
            }
            .font(.caption2)
            .padding(.horizontal, 8)
            
            HStack(spacing: 10) {
                if let landing = landingTime {
                    let mins = Int((landing.timeIntervalSinceNow)/60)
                    Text("Remaining:")
                        .foregroundColor(.secondary)
                    Text(mins <= 0 ? "now" : "\(mins) min")
                }
                Spacer()
            }
            .font(.caption2)
            .padding(.horizontal, 8)
            
            HStack(spacing: 10) {
                if let dist = routeDistance {
                    Text("Route Dist:")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f km", dist/1000))
                }
                Spacer()
            }
            .font(.caption2)
            .padding(.horizontal, 8)
        }
        .font(.footnote)
        .foregroundColor(.primary)
        .background(Color(.systemBackground).opacity(0.95))
        .cornerRadius(10)
        .padding(.horizontal, 8)
        .shadow(radius: 4)
    }
}
