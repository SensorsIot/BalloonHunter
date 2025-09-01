import MapKit
import SwiftUI

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

import SwiftUI

struct BalloonAnnotationView: View {
    let altitude: Double
    let isRecent: Bool

    var body: some View {
        ZStack {
            Image(systemName: "balloon.fill")
                .font(.system(size: 76))
                .foregroundColor(isRecent ? .green : .red)
            Text("\(Int(altitude))")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .shadow(radius: 3)
                .offset(y: -20)
        }
    }
}
