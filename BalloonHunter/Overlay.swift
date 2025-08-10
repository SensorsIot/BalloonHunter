import SwiftUI
import MapKit

// MARK: - MapMarkerOverlay
public struct MapMarkerOverlay: View {
    public let coordinate: CLLocationCoordinate2D
    public let systemImage: String
    public let color: Color
    public init(coordinate: CLLocationCoordinate2D, systemImage: String, color: Color) {
        self.coordinate = coordinate
        self.systemImage = systemImage
        self.color = color
    }
    public var body: some View {
        MapAnnotation(coordinate: coordinate) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundColor(color)
                .shadow(radius: 3)
        }
    }
}

// MARK: - MapPolylineOverlay
public struct MapPolylineOverlay: View {
    public let coordinates: [CLLocationCoordinate2D]
    public let color: Color
    public let lineWidth: CGFloat
    public var dash: [CGFloat] = []
    public init(coordinates: [CLLocationCoordinate2D], color: Color, lineWidth: CGFloat, dash: [CGFloat] = []) {
        self.coordinates = coordinates
        self.color = color
        self.lineWidth = lineWidth
        self.dash = dash
    }
    public var body: some View {
        if coordinates.count > 1 {
            MapPolyline(coordinates: coordinates, color: color, lineWidth: lineWidth, dash: dash)
        } else {
            EmptyView()
        }
    }
}

// MARK: - MapAnnotationItem
public struct MapAnnotationItem: Identifiable {
    public enum Kind { case user, balloon }
    public let id = UUID()
    public let coordinate: CLLocationCoordinate2D
    public let kind: Kind
    public let status: MarkerStatus?
    public enum MarkerStatus { case fresh, stale }
    @ViewBuilder
    public var annotationView: some View {
        switch kind {
        case .user:
            MapMarkerOverlay(coordinate: coordinate, systemImage: "figure.walk", color: .blue)
        case .balloon:
            MapMarkerOverlay(coordinate: coordinate, systemImage: "balloon.fill", color: status == .fresh ? .green : .red)
        }
    }
}
