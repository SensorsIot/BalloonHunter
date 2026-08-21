/* [markdown]
# Navigation Handoff

Decides when it is worth asking the hunter to re-point Apple Maps.

Handing over a new destination is not free. An active route cannot be replaced
from another app, so every handover costs the hunter a cancel and a tap while
driving. The question is therefore not "has the landing point moved" - it moves
constantly - but "has the drive changed enough to be worth interrupting them".

**Two guards, and both must pass.**

*Has the drive materially changed?* Measured in **route travel time**, never in how
far the landing point moved. In alpine terrain 500 m can put the landing across a
ridge and add half an hour; 5 km along the same motorway changes nothing.

*Has enough time passed since the last one?* Without this, a prediction that
wanders back and forth across the threshold would ask repeatedly for no gain.

A handover is also pointless once the hunter is nearly there, since the last
stretch is on foot and the map is the guide by then.
*/

import Foundation
import CoreLocation

struct NavigationHandoff {

    /// How much the drive must change before it is worth interrupting.
    ///
    /// PROPOSED, not measured. A drive that changes by less than this does not
    /// change which roads are taken, so re-pointing Maps costs a cancel and a tap
    /// for nothing.
    let minimumTravelTimeChange: TimeInterval

    /// Shortest gap between two offers, however much the drive changes.
    ///
    /// PROPOSED, not measured. Guards against a prediction oscillating across the
    /// threshold and asking again every minute.
    let minimumInterval: TimeInterval

    /// Below this distance the hunt is on foot and Maps has nothing left to add.
    let handoverPointlessWithin: CLLocationDistance

    init(minimumTravelTimeChange: TimeInterval = 10 * 60,
         minimumInterval: TimeInterval = 10 * 60,
         handoverPointlessWithin: CLLocationDistance = 2_000) {
        self.minimumTravelTimeChange = minimumTravelTimeChange
        self.minimumInterval = minimumInterval
        self.handoverPointlessWithin = handoverPointlessWithin
    }

    /// What the app knows when deciding whether to ask.
    struct Situation {
        /// Travel time of the route as it stands now.
        let currentTravelTime: TimeInterval
        /// Travel time when Maps was last pointed somewhere, or `nil` if never.
        let travelTimeAtLastHandover: TimeInterval?
        /// When the last offer was made, or `nil` if never.
        let lastOfferedAt: Date?
        /// How far the hunter still is from the landing point.
        let distanceToLanding: CLLocationDistance
    }

    enum Decision: Equatable {
        /// Worth asking. Carries how much the drive changed, for the message.
        case offer(travelTimeDelta: TimeInterval)
        /// Maps has never been pointed anywhere for this hunt.
        case offerFirstTime
        /// Say nothing.
        case stayQuiet
    }

    func decide(_ s: Situation, now: Date = Date()) -> Decision {
        guard s.currentTravelTime.isFinite, s.currentTravelTime > 0 else { return .stayQuiet }

        // On foot. The map is the guide from here.
        guard s.distanceToLanding > handoverPointlessWithin else { return .stayQuiet }

        guard let previous = s.travelTimeAtLastHandover else { return .offerFirstTime }

        if let last = s.lastOfferedAt, now.timeIntervalSince(last) < minimumInterval {
            return .stayQuiet
        }

        let delta = s.currentTravelTime - previous
        guard abs(delta) >= minimumTravelTimeChange else { return .stayQuiet }
        return .offer(travelTimeDelta: delta)
    }
}
