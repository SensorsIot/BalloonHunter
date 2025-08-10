import SwiftUI
import MapKit

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
