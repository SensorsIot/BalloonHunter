import SwiftUI
import MapKit

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
