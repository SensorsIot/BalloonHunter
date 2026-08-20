/* [markdown]
# Close Range Guidance

What the hunter is shown in the last stretch, on foot.

Two sources count here and no others:

- **the receiver**, which carries the sonde's own GPS position
- **the phone**, which carries the hunter's position and heading

**SondeHub must not be used.** Its last frame marks where the sonde stopped being
*heard*, not where it came down. On flight W4214915 that frame was recorded at
1 173 m, still falling. At fifty metres from the target, a position that is
confidently wrong is worse than none.

The distance shown is a calculation between two GPS fixes. Neither of them comes
from the radio link, so a momentary dropout - trees, a body over the antenna, a
ridge - must not blank the number. Losing signal at the moment of closest approach
is normal, and is exactly when the hunter needs the figure most.
*/

import Foundation
import CoreLocation

struct CloseRangeGuidance {

    /// Where a position came from. Only one of these is trusted on foot.
    enum PositionSource: Equatable {
        /// The sonde's own GPS, received over the radio link.
        case receiver
        /// SondeHub. Reports where the sonde was last heard, not where it lies.
        case network
    }

    /// A known position and where it came from.
    struct SondePosition: Equatable {
        let coordinate: CLLocationCoordinate2D
        let source: PositionSource

        static func == (lhs: SondePosition, rhs: SondePosition) -> Bool {
            lhs.source == rhs.source
                && lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    /// Distance the hunter should be shown, in metres.
    ///
    /// Returns `nil` when there is nothing trustworthy to measure between, which
    /// is the only case where the figure should be hidden.
    ///
    /// - Parameters:
    ///   - sonde: the sonde's last known position, with its source.
    ///   - hunter: the hunter's position from the phone.
    func distanceToSonde(sonde: SondePosition?, hunter: CLLocationCoordinate2D?) -> CLLocationDistance? {
        guard let sonde, let hunter else { return nil }
        guard sonde.source == .receiver else { return nil }

        return CLLocation(latitude: sonde.coordinate.latitude, longitude: sonde.coordinate.longitude)
            .distance(from: CLLocation(latitude: hunter.latitude, longitude: hunter.longitude))
    }

    /// Whether the distance should be on screen.
    ///
    /// It depends on the two GPS fixes, never on the radio link being up at this
    /// instant, so a dropout while walking does not hide it.
    func shouldShowDistance(sonde: SondePosition?, hunter: CLLocationCoordinate2D?) -> Bool {
        distanceToSonde(sonde: sonde, hunter: hunter) != nil
    }

    /// Bearing from the hunter to the sonde, in degrees clockwise from true north.
    ///
    /// The map rotated to the hunter's heading turns this into "which way to walk":
    /// they turn until the marker sits at the top.
    func bearingToSonde(sonde: SondePosition?, hunter: CLLocationCoordinate2D?) -> Double? {
        guard let sonde, let hunter, sonde.source == .receiver else { return nil }

        let lat1 = hunter.latitude * .pi / 180
        let lat2 = sonde.coordinate.latitude * .pi / 180
        let dLon = (sonde.coordinate.longitude - hunter.longitude) * .pi / 180

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}
