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
import UIKit
import CoreLocation

#if DEBUG
enum AppleMapsHandoffProbe {

    /// Two destinations far enough apart that the driving route differs
    /// completely, rather than shifting along the same road.
    static let destinationA = CLLocationCoordinate2D(latitude: 46.9480, longitude: 7.4474)  // Bern
    static let destinationB = CLLocationCoordinate2D(latitude: 47.0502, longitude: 8.3093)  // Lucerne

    /// Variant 1: hand Maps an explicit source *and* destination.
    ///
    /// A different code path from the single-item call, and plausibly a request
    /// for a whole trip rather than a destination to bolt onto the current one.
    /// Undocumented either way - no source describes what this does to an active
    /// session, and nobody has reported trying it.
    static func navigateWithExplicitSource(to destination: CLLocationCoordinate2D, label: String) {
        let from = MKMapItem.forCurrentLocation()
        let to = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        to.name = "Handoff probe \(label)"

        appLog("PROBE: openMaps(with:) two items, destination \(label)", category: .general, level: .info)
        MKMapItem.openMaps(with: [from, to],
                           launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        appLog("PROBE: openMaps(with:) returned for \(label)", category: .general, level: .info)
    }

    /// Variant 2: the URL scheme instead of MapKit.
    ///
    /// A different entry point into Maps entirely. `dirflg=d` asks for driving
    /// directions without going through MKMapItem at all.
    static func navigateByURL(to destination: CLLocationCoordinate2D, label: String) {
        let url = URL(string: "maps://?daddr=\(destination.latitude),\(destination.longitude)&dirflg=d")!
        appLog("PROBE: opening URL \(url.absoluteString)", category: .general, level: .info)
        UIApplication.shared.open(url) { ok in
            appLog("PROBE: URL open returned \(ok) for \(label)", category: .general, level: .info)
        }
    }

    /// Try to return Maps to browse mode, in the hope that a later directions
    /// request then starts a fresh trip rather than offering to add a stop.
    ///
    /// There is no public API to end another app's navigation, so this can only
    /// nudge: it opens Maps with no directions request at all. Whether that stops
    /// guidance is exactly what the probe is for.
    static func attemptStopNavigation() {
        appLog("PROBE: opening Maps with no directions request", category: .general, level: .info)
        MKMapItem.forCurrentLocation().openInMaps(launchOptions: nil)
    }

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
