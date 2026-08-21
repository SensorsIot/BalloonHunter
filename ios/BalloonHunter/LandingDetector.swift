/* [markdown]
# Landing Detector

### Purpose
Pure, dependency-free landing detection. Owns all three detection algorithms and
the priority chain that decides whether the balloon is flying or landed.

Extracted from `BalloonPositionService` and `BalloonTrackService` so the thresholds
that drive flying/landed mode can be tested in isolation.

### Two entry points

| Method | Cost | Called |
|---|---|---|
| `classifyPhase(...)` | cheap | every telemetry update |
| `scanTrackForLanding(_:)` | expensive | after APRS fill / on restored tracks |

### Detection priority (highest first)
1. Track-based landing (blackout gap or stationary period) — definitive, sticky
2. APRS age > 120s — balloon stopped transmitting
3. Vector analysis — net speed < 3 km/h AND altitude < 3000 m

This type performs **no** mutation. `scanTrackForLanding` reports *where* a landing
was found; truncating the track, notifying the user, and persisting are the
caller's responsibility.
*/

import Foundation
import CoreLocation

// MARK: - Result Types

/// A landing found by scanning the historic track.
struct TrackLanding: Equatable {
    /// Index into the track where the balloon came to rest.
    let index: Int
    let timestamp: Date
    let coordinate: CLLocationCoordinate2D
    let reason: Reason

    enum Reason: Equatable {
        /// Balloon stopped transmitting; recovered and re-transmitted later.
        case telemetryBlackout(gap: TimeInterval)
        /// Balloon kept transmitting from the ground without moving.
        case stationaryPeriod
    }

    /// Human-readable cause, used in the track-truncation notification.
    var reasonDescription: String {
        switch reason {
        case .telemetryBlackout: return "telemetry blackout"
        case .stationaryPeriod: return "stationary period"
        }
    }

    static func == (lhs: TrackLanding, rhs: TrackLanding) -> Bool {
        lhs.index == rhs.index
            && lhs.timestamp == rhs.timestamp
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.reason == rhs.reason
    }
}

// MARK: - Landing Detector

struct LandingDetector {

    /// Tuning constants for all three detection algorithms.
    struct Thresholds {
        /// Net speed below which the balloon counts as stopped (m/s). 3 km/h.
        var landingSpeedMS: Double = 3.0 / 3.6
        /// Vector analysis only applies below this altitude (m).
        var landingAltitudeM: Double = 3000.0
        /// Minimum track points before vector analysis runs.
        var vectorMinPoints: Int = 5
        /// Maximum sliding-window size for vector analysis.
        var vectorMaxWindow: Int = 20

        /// APRS telemetry older than this means the balloon has landed (s).
        var aprsLandingAge: TimeInterval = 120.0

        /// Minimum track points before a track scan runs.
        var scanMinPoints: Int = 10
        /// Target duration the stationary window should span (s).
        var scanWindowDuration: TimeInterval = 20 * 60
        /// Minimum stationary window size in points.
        var scanMinWindow: Int = 10
        /// Per-point lat/lon drift below which the balloon counts as stationary (degrees).
        var stationaryDegrees: Double = 0.0001
        /// Per-point altitude drift below which the balloon counts as stationary (m).
        var stationaryAltitudeM: Double = 0.3
        /// Telemetry gap after burst that indicates a landing (s).
        var blackoutGap: TimeInterval = 20 * 60

        /// Altitude separating high-altitude from low-altitude descent (m).
        var descentSplitAltitudeM: Double = 10_000

        static let `default` = Thresholds()
    }

    let thresholds: Thresholds

    init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    // MARK: - Phase Classification

    /// Classify the balloon's flight phase.
    ///
    /// - Parameters:
    ///   - track: Flight history, oldest first.
    ///   - position: Latest telemetry sample, or `nil` if none received.
    ///   - trackLanding: A previously detected track-based landing. Once set this
    ///     is definitive — the balloon stays landed regardless of later movement.
    func classifyPhase(track: [BalloonTrackPoint],
                       position: PositionData?,
                       trackLanding: TrackLanding? = nil) -> BalloonPhase {

        guard let position else { return .unknown }
        if landingReason(track: track, position: position, trackLanding: trackLanding) != nil {
            return .landed
        }
        return flightPhase(for: position)
    }

    /// Why the balloon counts as landed, or `nil` if it does not. Same priority
    /// chain as `classifyPhase`, exposed so a transition log can record which
    /// rule fired — the question that took a device-log post-mortem to answer.
    enum LandingReason: String {
        case trackLanding      // definitive: a stationary period or blackout in the track
        case aprsStale         // no APRS telemetry for longer than aprsLandingAge
        case vectorAnalysis    // net speed below threshold and below the altitude ceiling
    }

    /// Does this landing reason fix *where* the balloon lies, or only *that* the
    /// flight is over?
    ///
    /// `vectorAnalysis` and `trackLanding` come from a stationary, near-ground
    /// observation — in practice close-range BLE — so they confirm the actual
    /// touchdown, and the marker/route should lock to it. `aprsStale` means the
    /// balloon went silent while still descending: the flight is over but the
    /// position is only the prediction, so the marker/route must stay on the
    /// predicted landing, not the last-heard-at-altitude point. See FSD *How a
    /// Landing Is Determined*.
    func confirmsTouchdown(_ reason: LandingReason?) -> Bool {
        switch reason {
        case .vectorAnalysis, .trackLanding: return true
        case .aprsStale, .none: return false
        }
    }

    /// The whole landing-display decision, as a pure value: where the landing
    /// marker and car route should point, and whether the predicted-descent line
    /// should still be drawn. The services only apply this — so the behaviour
    /// through the drive and the touchdown is unit-testable end to end without
    /// them. See FSD *How a Landing Is Determined*.
    enum LandingTarget: Equatable {
        case none                                              // nothing to show yet
        case prediction                                       // the predicted landing (estimate)
        case confirmed(latitude: Double, longitude: Double)   // the BLE-confirmed touchdown
    }

    struct LandingResolution: Equatable {
        let target: LandingTarget
        let showPredictionPath: Bool
    }

    /// - Parameters:
    ///   - reason: `landingReason` for the current sample (nil while flying).
    ///   - currentPosition: latest fix, used only to lock a confirmed touchdown.
    ///   - hasPrediction: whether a predicted landing currently exists.
    func resolveLanding(reason: LandingReason?,
                        currentPosition: PositionData?,
                        hasPrediction: Bool) -> LandingResolution {
        // A confirmed touchdown (stationary, near ground — in practice BLE) locks
        // the marker and route to the actual point, and the descent line is done.
        if confirmsTouchdown(reason), let p = currentPosition {
            return LandingResolution(target: .confirmed(latitude: p.latitude, longitude: p.longitude),
                                     showPredictionPath: false)
        }
        // Flying, or landed-by-silence: the prediction is the estimate. Keep the
        // marker, route and line on it — the last-heard-at-altitude point is never
        // the target. Nothing to show until a prediction exists.
        return LandingResolution(target: hasPrediction ? .prediction : .none,
                                 showPredictionPath: hasPrediction)
    }

    func landingReason(track: [BalloonTrackPoint],
                       position: PositionData?,
                       trackLanding: TrackLanding? = nil) -> LandingReason? {
        guard let position else { return nil }

        // 1. Track-based landing is definitive and sticky.
        if trackLanding != nil { return .trackLanding }

        // 2. Stale APRS telemetry means the flight is over: a balloon silent for
        // longer than aprsLandingAge has reached the ground. But APRS coverage
        // almost always ends while the balloon is still descending, so this tells
        // us *that* it landed, not *where* — the position is only an estimate (the
        // prediction). The confirmed touchdown position comes from a fixed,
        // near-ground observation (rule 3, in practice close-range BLE). The
        // caller distinguishes the two by `landingReason`. See FSD *How a Landing
        // Is Determined*.
        if position.telemetrySource == .aprs,
           Date().timeIntervalSince(position.timestamp) > thresholds.aprsLandingAge {
            return .aprsStale
        }

        // 3. Vector analysis over the recent track.
        if isStoppedByVectorAnalysis(track: track) { return .vectorAnalysis }

        return nil
    }

    /// Flight phase for a moving balloon, from vertical speed and altitude.
    private func flightPhase(for position: PositionData) -> BalloonPhase {
        if position.verticalSpeed > 0 { return .ascending }
        guard position.verticalSpeed < 0 else { return .unknown }
        return position.altitude < thresholds.descentSplitAltitudeM
            ? .descendingBelow10k
            : .descendingAbove10k
    }

    // MARK: - Vector Analysis

    /// Net 3D displacement across a sliding window, converted to average speed.
    ///
    /// Uses *net* displacement rather than summed path length so that GPS jitter
    /// around a stationary point does not read as movement.
    func isStoppedByVectorAnalysis(track: [BalloonTrackPoint]) -> Bool {
        guard track.count >= thresholds.vectorMinPoints else { return false }

        let windowSize = min(thresholds.vectorMaxWindow, track.count)
        let window = track.suffix(windowSize)
        guard let start = window.first, let end = window.last else { return false }

        let elapsed = end.timestamp.timeIntervalSince(start.timestamp)
        guard elapsed > 0 else { return false }

        let netSpeedMS = netDisplacement(from: start, to: end) / elapsed

        return netSpeedMS < thresholds.landingSpeedMS
            && end.altitude < thresholds.landingAltitudeM
    }

    /// Straight-line 3D distance between two track points, in metres.
    private func netDisplacement(from start: BalloonTrackPoint,
                                 to end: BalloonTrackPoint) -> Double {
        let metersPerDegreeLat = 111_320.0
        let metersPerDegreeLon = metersPerDegreeLat * cos(end.latitude * .pi / 180)

        let dx = (end.longitude - start.longitude) * metersPerDegreeLon
        let dy = (end.latitude - start.latitude) * metersPerDegreeLat
        let dz = end.altitude - start.altitude

        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    // MARK: - Track Scan

    /// Scan a complete track for the point where the balloon landed.
    ///
    /// Only searches *after* the burst point, so a slow ascent is never mistaken
    /// for a landing. Blackout gaps are checked before stationary periods because
    /// a gap is the stronger signal.
    ///
    /// - Returns: The landing, or `nil` if the track shows no landing.
    func scanTrackForLanding(_ track: [BalloonTrackPoint]) -> TrackLanding? {
        guard track.count >= thresholds.scanMinPoints else { return nil }

        guard let windowSize = stationaryWindowSize(for: track),
              track.count >= windowSize else { return nil }

        let burstIndex = indexOfMaxAltitude(in: track)

        // Both scans require enough post-burst points to fill a window.
        guard burstIndex + windowSize < track.count else { return nil }

        if let blackout = findBlackout(in: track, after: burstIndex) { return blackout }
        return findStationaryPeriod(in: track,
                                    from: burstIndex + windowSize,
                                    windowSize: windowSize)
    }

    /// Window size that spans `scanWindowDuration` at the track's actual point density.
    private func stationaryWindowSize(for track: [BalloonTrackPoint]) -> Int? {
        guard let first = track.first, let last = track.last, track.count > 1 else { return nil }

        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        let averageInterval = duration / Double(track.count - 1)
        guard averageInterval > 0 else { return nil }

        return max(thresholds.scanMinWindow,
                   Int(thresholds.scanWindowDuration / averageInterval))
    }

    /// Index of the highest point — the burst.
    private func indexOfMaxAltitude(in track: [BalloonTrackPoint]) -> Int {
        var burstIndex = 0
        var maxAltitude = track[0].altitude
        for (index, point) in track.enumerated() where point.altitude > maxAltitude {
            maxAltitude = point.altitude
            burstIndex = index
        }
        return burstIndex
    }

    /// First post-burst telemetry gap long enough to mean the balloon is down.
    private func findBlackout(in track: [BalloonTrackPoint], after burstIndex: Int) -> TrackLanding? {
        guard burstIndex < track.count - 1 else { return nil }

        for i in burstIndex..<(track.count - 1) {
            let gap = track[i + 1].timestamp.timeIntervalSince(track[i].timestamp)
            guard gap > thresholds.blackoutGap else { continue }

            let point = track[i]
            return TrackLanding(
                index: i,
                timestamp: point.timestamp,
                coordinate: CLLocationCoordinate2D(latitude: point.latitude,
                                                   longitude: point.longitude),
                reason: .telemetryBlackout(gap: gap)
            )
        }
        return nil
    }

    /// First window where lat, lon and altitude all stop changing.
    ///
    /// Altitude is included so a near-vertical descent is not read as a landing.
    private func findStationaryPeriod(in track: [BalloonTrackPoint],
                                      from searchStart: Int,
                                      windowSize: Int) -> TrackLanding? {
        guard searchStart < track.count else { return nil }

        for i in searchStart..<track.count {
            let window = Array(track[(i - windowSize)..<i])
            guard window.count > 1 else { continue }

            var latDrift = 0.0, lonDrift = 0.0, altDrift = 0.0
            for j in 1..<window.count {
                latDrift += abs(window[j].latitude - window[j - 1].latitude)
                lonDrift += abs(window[j].longitude - window[j - 1].longitude)
                altDrift += abs(window[j].altitude - window[j - 1].altitude)
            }

            let steps = Double(window.count - 1)
            guard latDrift / steps < thresholds.stationaryDegrees,
                  lonDrift / steps < thresholds.stationaryDegrees,
                  altDrift / steps < thresholds.stationaryAltitudeM else { continue }

            let point = track[i]
            return TrackLanding(
                index: i,
                timestamp: point.timestamp,
                coordinate: CLLocationCoordinate2D(latitude: point.latitude,
                                                   longitude: point.longitude),
                reason: .stationaryPeriod
            )
        }
        return nil
    }
}
