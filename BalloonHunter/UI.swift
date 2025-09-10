import MapKit
import SwiftUI

// MARK: - MapKit Extensions

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

// MARK: - Custom UI Components

struct BalloonAnnotationView: View {
    let altitude: Double
    let isAscending: Bool

    var body: some View {
        ZStack {
            Image(systemName: "balloon.fill")
                .font(.system(size: 76))
                .foregroundColor(isAscending ? .green : .red)
            Text("\(Int(altitude))m")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .shadow(color: .black, radius: 2, x: 0, y: 0)
                .offset(y: -20)
        }
    }
}

// MARK: - UI State Management

extension TransportationMode {
    var displayName: String {
        switch self {
        case .car:
            return "Car"
        case .bike:
            return "Bike"
        }
    }
    
    var systemImageName: String {
        switch self {
        case .car:
            return "car.fill"
        case .bike:
            return "bicycle"
        }
    }
}

extension ConnectionStatus {
    var displayName: String {
        switch self {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .disconnected:
            return "Disconnected"
        }
    }
    
    var color: Color {
        switch self {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        }
    }
    
    var systemImageName: String {
        switch self {
        case .connected:
            return "antenna.radiowaves.left.and.right"
        case .connecting:
            return "antenna.radiowaves.left.and.right.circle.fill"
        case .disconnected:
            return "antenna.radiowaves.left.and.right.slash"
        }
    }
}

// MARK: - UI Helper Views

struct StatusIndicator: View {
    let status: ConnectionStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.systemImageName)
                .foregroundColor(status.color)
            Text(status.displayName)
                .foregroundColor(status.color)
                .font(.caption)
        }
    }
}

struct TransportModeButton: View {
    let mode: TransportationMode
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: mode.systemImageName)
                    .font(.title2)
                Text(mode.displayName)
                    .font(.caption)
            }
            .padding(8)
            .background(isSelected ? Color.blue.opacity(0.2) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.gray, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ModeIndicator: View {
    let mode: AppMode
    
    var body: some View {
        Text(mode.displayName)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor(for: mode))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
    
    private func backgroundColor(for mode: AppMode) -> Color {
        switch mode {
        case .explore:
            return .blue
        case .follow:
            return .green
        case .finalApproach:
            return .red
        }
    }
}

struct MetricRow: View {
    let title: String
    let value: String
    let unit: String?
    
    init(_ title: String, value: String, unit: String? = nil) {
        self.title = title
        self.value = value
        self.unit = unit
    }
    
    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .fontWeight(.medium)
                if let unit = unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct ToggleRow: View {
    let title: String
    let isOn: Binding<Bool>
    let systemImage: String?
    
    init(_ title: String, isOn: Binding<Bool>, systemImage: String? = nil) {
        self.title = title
        self.isOn = isOn
        self.systemImage = systemImage
    }
    
    var body: some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(SwitchToggleStyle())
    }
}

// MARK: - UI Constants

struct UIConstants {
    struct Spacing {
        static let small: CGFloat = 4
        static let medium: CGFloat = 8
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 24
    }
    
    struct CornerRadius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
    }
    
    struct AnimationConstants {
        static let quick = SwiftUI.Animation.easeInOut(duration: 0.2)
        static let standard = SwiftUI.Animation.easeInOut(duration: 0.3)
        static let slow = SwiftUI.Animation.easeInOut(duration: 0.5)
    }
    
    struct MapDefaults {
        static let defaultLatitudeDelta: Double = 0.01
        static let defaultLongitudeDelta: Double = 0.01
        static let maxZoomLatitudeDelta: Double = 0.001
        static let minZoomLatitudeDelta: Double = 1.0
    }
}