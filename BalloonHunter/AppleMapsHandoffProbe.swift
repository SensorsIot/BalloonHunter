/* [markdown]
# Apple Maps Handoff Probe

**Temporary. Delete once the question below is answered.**

Phase 3 wants the Apple Maps destination to follow the landing point while the
hunter drives. iOS offers no way to update a running navigation session, so the
only mechanism is calling `openInMaps` again, which starts fresh directions.

What nobody documents is what that does to a session already in progress:

1. Does Maps ask before abandoning the current route? What does it say?
2. Where does the question appear — the phone, the CarPlay screen, or both?
3. Does the calling app get pushed to the background? Apple's own documentation
   says `openInMaps` "suspends interaction with your app until the Maps app
   finishes launching", but says nothing about the CarPlay case.

None of that can be settled from a desk, and designing the auto-update around a
guess would be building on sand. This probe answers it in about half a minute,
with no balloon and no drive.

## How to run it

1. Connect to CarPlay as you normally would.
2. Tap **Nav A**. Apple Maps starts driving directions to a point west of Bern.
3. Wait until guidance is actually running.
4. Return to Balloon Hunter and tap **Nav B**, roughly 40 km away, so the route
   genuinely differs rather than merely shifting.
5. Write down: was there a prompt, what did it say, which screen showed it, and
   did Balloon Hunter stay on the phone or get replaced by Maps?

Debug builds only.
*/

import Foundation
import MapKit
import OSLog
import CoreLocation

#if DEBUG
enum AppleMapsHandoffProbe {

    /// Two destinations far enough apart that the driving route differs
    /// completely, rather than shifting along the same road.
    static let destinationA = CLLocationCoordinate2D(latitude: 46.9480, longitude: 7.4474)  // Bern
    static let destinationB = CLLocationCoordinate2D(latitude: 47.0502, longitude: 8.3093)  // Lucerne

    /// Start driving directions, exactly as `NavigationService` does in the field.
    ///
    /// Deliberately uses the same call and the same launch options as the real
    /// navigation button. A probe that behaved differently would prove nothing.
    static func navigate(to destination: CLLocationCoordinate2D, label: String) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        item.name = "Handoff probe \(label)"

        appLog("PROBE: calling openInMaps for \(label) at \(destination.latitude), \(destination.longitude)", category: .general, level: .info)
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        appLog("PROBE: openInMaps returned for \(label) - if this line appears late, the call blocked", category: .general, level: .info)
    }
}
#endif
