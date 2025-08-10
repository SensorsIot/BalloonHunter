import SwiftUI
import MapKit

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
            MapMarkerOverlay(coordinate: coordinate, systemImage: "balloon", color: status == .fresh ? .green : .red)
        }
    }
}
