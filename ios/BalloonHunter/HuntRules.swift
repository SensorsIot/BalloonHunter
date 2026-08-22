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



// MARK: - When predictions run

/// Whether the 60-second prediction timer should run in a given state.
///
/// Pure so it is testable without the coordinator.
///
/// Predictions run **only while the balloon is flying**. Once it is landed — by a
/// confirmed touchdown or by silence — no new prediction is needed or wanted: the
/// last estimate made while flying is the landing, and re-predicting a fixed
/// position only makes the landing marker drift as the wind forecast for "now"
/// advances (and, for an old sonde, asks the predictor for GFS data it no longer
/// has). States with no basis for a prediction (startup, waiting, no telemetry)
/// also stop. See FSD *How a Landing Is Determined*.
enum PredictionPolicy {

    /// Whether a prediction should be made now.
    ///
    /// The question is **"do we know where the balloon is?"**, never "is it landed?".
    /// A sonde whose APRS coverage ended while it was still descending is down, but
    /// nobody has seen where — the predicted landing point is the only estimate of
    /// where it lies, so it must have one.
    ///
    /// - Parameters:
    ///   - state: the data state the machine is in.
    ///   - touchdownConfirmed: `LandingDetector`'s verdict that a fixed, near-ground
    ///     observation has pinned the balloon. Passed in rather than re-derived, so
    ///     that question keeps one owner.
    ///   - hasPrediction: whether an estimate already exists.
    ///
    /// See FSD *How a Landing Is Determined → When prediction runs*.
    static func shouldPredict(state: DataState,
                              touchdownConfirmed: Bool,
                              hasPrediction: Bool) -> Bool {
        switch state {
        case .startup, .waitingForAPRS, .noTelemetry:
            // Nothing is arriving to predict from.
            return false

        case .liveBLEFlying, .aprsFlying:
            // Every run has fresher telemetry than the last, so each answer is better.
            return true

        case .liveBLELanded, .aprsLanded:
            // A confirmed touchdown *is* the position — nothing left to estimate.
            guard !touchdownConfirmed else { return false }
            // Down but never seen. Make the one estimate that says where it lies, and
            // then leave it alone: no new telemetry is arriving, so re-running would
            // move the marker only because the wind forecast advanced — under a hunter
            // who is driving to it.
            return !hasPrediction
        }
    }
}

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
nonisolated enum StartupSelection: Equatable {
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

nonisolated struct HuntState {

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

nonisolated struct DepartureTime {

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

nonisolated struct NavigationHandoff {

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

nonisolated struct CloseRangeGuidance {

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

// MARK: - The BLE hunt tail

/// The one piece of sonde data worth keeping on disk.
///
/// For the whole flight, APRS carries the same frames the receiver does and
/// SondeHub serves them on demand, so storing them locally would duplicate an
/// authoritative source. **One segment is different: the final hunt.** From the last
/// APRS fix to where the balloon actually lies there is no APRS coverage — that
/// stretch exists only in this phone's close-range BLE decode, and it is exactly the
/// stretch that decides where the hunter walks.
///
/// Persistence exists to survive backgrounding, nothing more, so only what cannot be
/// re-fetched is written. The serial is stored *with* the points so a tail can prove
/// it belongs to the sonde now being hunted — it answers "whose tail is this?", never
/// "who am I hunting?", which is the picker's question alone.
///
/// See FSD *APRS Telemetry → The BLE hunt tail*.
nonisolated struct HuntTail: Codable {

    /// How long a stored tail stays usable. A hunt does not outlive a day.
    static let retention: TimeInterval = 24 * 60 * 60

    /// The sonde these points belong to.
    let serial: String
    /// When the tail was written.
    let savedAt: Date
    /// The BLE stretch beyond APRS coverage.
    let points: [BalloonTrackPoint]

    /// The part of `track` worth persisting, or `nil` if there is none.
    ///
    /// Everything after the newest APRS point is BLE the network never saw. When a
    /// track holds no APRS points at all — a test sonde, or a hunt run off-grid —
    /// that is the whole BLE track, so the same rule covers the offline case with no
    /// special handling.
    static func from(track: [BalloonTrackPoint], serial: String, at savedAt: Date) -> HuntTail? {
        guard !track.isEmpty else { return nil }

        let ordered = track.sorted { $0.timestamp < $1.timestamp }
        let tail: [BalloonTrackPoint]
        if let lastAPRS = ordered.lastIndex(where: { $0.source == .aprs }) {
            tail = Array(ordered[(lastAPRS + 1)...])
        } else {
            tail = ordered
        }

        // Only what APRS cannot return is worth writing.
        let irreplaceable = tail.filter { $0.source == .ble }
        return irreplaceable.isEmpty ? nil : HuntTail(serial: serial, savedAt: savedAt, points: irreplaceable)
    }

    /// The points to restore for `serial`, or empty when this tail cannot serve it.
    ///
    /// A tail belonging to another sonde is not the hunted sonde's data, and one
    /// older than `retention` is no longer this hunt.
    func points(for serial: String, now: Date, retention: TimeInterval = HuntTail.retention) -> [BalloonTrackPoint] {
        guard serial == self.serial else { return [] }
        guard now.timeIntervalSince(savedAt) <= retention else { return [] }
        return points
    }
}


// MARK: - Sizing a SondeHub telemetry request

/// How much history to ask SondeHub for.
///
/// The window is measured from **when this serial was last successfully asked
/// about**, never from how old its newest held frame is. Those two come apart the
/// moment a sonde goes quiet: a balloon silent for eighteen hours, asked about two
/// minutes ago, can have at most two minutes of new data. Sizing from the frame
/// asks for a full day and re-downloads what is already held, on every resume.
///
/// It also keeps the recovery case working. A landed sonde is not finished
/// transmitting — a finder can move it and it reports again from somewhere else —
/// so it must still be asked. Sizing from the last fetch catches those frames;
/// skipping the fetch because the balloon is "landed" would lose them silently.
///
/// See FSD *APRS Telemetry: the delta-fetch → How the delta is decided*.
nonisolated enum FetchWindow {

    /// Covers the BLE/APRS relay skew and any clock difference.
    static let margin: TimeInterval = 60

    /// SondeHub accepts only these windows, so a delta rounds up to one of them.
    private static let buckets: [(TimeInterval, String)] = [
        (15, "15s"), (60, "1m"), (1800, "30m"), (3600, "1h"),
        (10800, "3h"), (21600, "6h"), (43200, "12h"), (86400, "1d"), (259200, "3d")
    ]

    /// The window asked for first when the full one would be slow.
    ///
    /// It is one of SondeHub's own windows, not a new kind of request: the same
    /// thing a routine delta asks for.
    static let recentSlice = "30m"

    /// Whether `duration` is big enough that waiting for it would keep the hunter
    /// staring at a map with no landing point.
    ///
    /// The landing point needs exactly one frame — the newest — while the history
    /// behind it is thousands of points and ten seconds. For a large window the
    /// recent slice is fetched first so the overlays appear at once; for a small one
    /// the single request already does both jobs and splitting it would just double
    /// the traffic.
    static func isLarge(_ duration: String) -> Bool {
        guard let index = buckets.firstIndex(where: { $0.1 == duration }),
              let sliceIndex = buckets.firstIndex(where: { $0.1 == recentSlice }) else { return false }
        return index > sliceIndex
    }

    /// The `duration` to request.
    ///
    /// - Parameters:
    ///   - lastFetch: when this serial was last fetched successfully, or `nil` if it
    ///     never has been — in which case the whole flight is wanted. A failed fetch
    ///     must not update this, so the next attempt covers the same ground again.
    ///   - now: the current time.
    static func duration(lastFetch: Date?, now: Date) -> String {
        guard let lastFetch else { return "3d" }
        let seconds = now.timeIntervalSince(lastFetch) + margin
        return buckets.first { seconds <= $0.0 }?.1 ?? "3d"
    }
}
