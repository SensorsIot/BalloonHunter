/* [markdown]
# Hunt Rules

The decisions the app makes during a hunt, as plain values.

Each of these lived inside a service wired to Bluetooth, the network and the
phone's location, which is why none of them had ever been tested: the constants
deciding whether a balloon is flying or down, or whether a stored track is still
this hunt, could not be exercised without a radio and a balloon in the sky. Pulled
out here they are ordinary types, and the rules that send a hunter to a field are
under test.

Grouped by the phase they serve:

| type | phase | decides |
|---|---|---|
| `HuntState` | 1, starting up | same hunt or a new one; what may be drawn when nothing is arriving |
| `DepartureTime` | 2, stationary | when to leave in order to meet the landing |
| `NavigationHandoff` | 3, on the road | when a changed drive is worth interrupting for |
| `CloseRangeGuidance` | 4, on foot | how far and which way, and whose position to trust |

Landing detection, the descent rate correction and stray-decode handling live in
their own files: they belong to the radio and the predictor rather than to the
hunt, and `LandingDetector` alone is longer than everything here.
*/

import Foundation
import CoreLocation



// MARK: - Phase 1: Which sonde is hunted?

/// What startup does once the services have answered: take the sonde that is
/// up, or ask the user.
///
/// Startup owns no idea of flying and landed. `LandingDetector` decides,
/// `BalloonPositionService` publishes the verdict as `balloonPhase`, and this
/// rule does nothing but read it. Startup once re-decided from the raw SondeHub
/// list on vertical speed alone: on 21 August 2026 that auto-selected W4214520
/// from a frame 6.8 h old, 2.4 seconds after the detector had classified that
/// same sonde as landed, and the picker never appeared.
enum StartupSelection: Equatable {
    /// The sonde is up. Track it and skip the picker.
    case autoSelect(serial: String)
    /// Landed, undetermined, or nothing to name. Ask.
    case showPicker

    /// - Parameters:
    ///   - phase: the detector's verdict, as published by the position service.
    ///   - trackedSerial: the serial of the telemetry that verdict was reached
    ///     on. Taken from the telemetry rather than the SondeHub list, so a live
    ///     decode of an unlisted sonde is not lost.
    static func decide(phase: BalloonPhase, trackedSerial: String?) -> StartupSelection {
        // `unknown` is not airborne. It means the detector could not tell, and
        // that must never be spent on an auto-select.
        guard phase.isAirborne else { return .showPicker }

        // Airborne, but nothing names it — there is no sonde to select.
        guard let serial = trackedSerial,
              !serial.trimmingCharacters(in: .whitespaces).isEmpty else { return .showPicker }

        return .autoSelect(serial: serial)
    }
}

// MARK: - Phase 1: Is this still the same hunt?

struct HuntState {

    /// How long a hunt stays current once nothing is arriving.
    let staleAfter: TimeInterval

    init(staleAfter: TimeInterval = 6 * 60 * 60) {
        self.staleAfter = staleAfter
    }

    /// What the app should do with what it remembers.
    enum Decision: Equatable {
        /// Same sonde, and recent enough to still be the hunt in progress.
        /// Draw the track, the landing point and the route.
        case resumeHunt

        /// Same sonde, but nothing has arrived for longer than a hunt lasts.
        /// Say so and draw nothing, while continuing to wait for data.
        case tooOldToShow

        /// A different sonde. The stored hunt is not this one; discard it.
        case startNewHunt

        /// Nothing stored to make a decision about.
        case nothingStored
    }

    /// What is known when the app comes up.
    struct StoredHunt: Equatable {
        /// Serial the stored track belongs to.
        let serial: String
        /// When the last data for it arrived.
        let lastDataAt: Date
    }

    /// Decide what to do with a stored hunt.
    ///
    /// - Parameters:
    ///   - stored: what was on disk, or `nil` if nothing was.
    ///   - hunting: the serial now being hunted, or `nil` if none is chosen yet.
    ///   - now: the current time.
    func decide(stored: StoredHunt?, hunting: String?, now: Date = Date()) -> Decision {
        guard let stored else { return .nothingStored }

        // A different sonde is a different hunt, whatever its age.
        if let hunting, hunting != stored.serial { return .startNewHunt }

        // Same sonde: age decides only whether it is worth showing.
        let age = now.timeIntervalSince(stored.lastDataAt)
        return age <= staleAfter ? .resumeHunt : .tooOldToShow
    }

    /// Whether the stored flight may be drawn on the map.
    func mayDisplay(stored: StoredHunt?, hunting: String?, now: Date = Date()) -> Bool {
        decide(stored: stored, hunting: hunting, now: now) == .resumeHunt
    }

    /// Whether the stored flight must be cleared before hunting `hunting`.
    ///
    /// Only a different sonde clears. Age never does: re-fetching the same serial
    /// returns the same flight, so discarding it loses the receiver's own detail
    /// for nothing.
    func mustClear(stored: StoredHunt?, hunting: String?) -> Bool {
        decide(stored: stored, hunting: hunting) == .startNewHunt
    }
}

// MARK: - Phase 2: When to leave

struct DepartureTime {

    /// When to set off, and how long until then.
    struct Plan: Equatable {
        /// Clock time to leave.
        let leaveAt: Date
        /// Time remaining until then. Negative once the landing cannot be met.
        let timeUntilDeparture: TimeInterval

        /// True once the balloon will be down before the hunter can arrive.
        var isTooLate: Bool { timeUntilDeparture < 0 }
    }

    /// Work out when to leave.
    ///
    /// - Parameters:
    ///   - landingTime: when the balloon is predicted to touch down.
    ///   - drivingTime: how long the route takes, in seconds.
    ///   - now: the current time.
    /// - Returns: the plan, or `nil` if either input is missing or unusable.
    func plan(landingTime: Date?, drivingTime: TimeInterval?, now: Date = Date()) -> Plan? {
        guard let landingTime, let drivingTime else { return nil }
        guard drivingTime.isFinite, drivingTime >= 0 else { return nil }

        let leaveAt = landingTime.addingTimeInterval(-drivingTime)
        return Plan(leaveAt: leaveAt, timeUntilDeparture: leaveAt.timeIntervalSince(now))
    }
}

// MARK: - Phase 3: When to re-point Apple Maps

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

// MARK: - Phase 4: How far, and which way

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
