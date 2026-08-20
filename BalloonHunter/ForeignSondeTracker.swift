/* [markdown]
# Foreign Sonde Tracker

Decides when telemetry from an unexpected serial means the receiver has been
retuned, rather than having briefly decoded something else.

A receiver picks up whatever is on frequency. Now and then that is a different
sonde: a unit on the bench, or a neighbour close enough in frequency to slip
through for a packet or two. Treating one such packet as a sonde change wipes the
live hunt and adopts the intruder, stitching its position into the flight track.

A run of packets is different. If the same unexpected serial keeps arriving and
the hunted one has stopped, the receiver has moved, and per the FSD's Sonde
Change Flow every trace of the previous sonde must be cleared before the new one
is adopted.

This type only counts. The packets themselves are discarded by the caller either
way, so nothing from a foreign sonde reaches the rest of the app.
*/

import Foundation

struct ForeignSondeTracker {

    struct Outcome: Equatable {
        /// How many times this serial has arrived in succession.
        let streak: Int
        /// Whether the run is now long enough to call it a retune.
        let isConfirmedChange: Bool
    }

    /// Consecutive packets from one unexpected serial before it counts as a
    /// change. Five packets is several seconds of the receiver reporting the
    /// same thing, which interference does not survive.
    let confirmCount: Int

    private var current: (name: String, count: Int)?

    init(confirmCount: Int = 5) {
        self.confirmCount = confirmCount
    }

    /// Record a packet from a sonde other than the hunted one.
    ///
    /// A different serial restarts the count: two foreign sondes alternating are
    /// interference, not a retune, and neither should reach the threshold.
    /// Confirming resets the run, so the next change starts from zero.
    mutating func sawForeignSonde(_ name: String) -> Outcome {
        if current?.name == name {
            current?.count += 1
        } else {
            current = (name: name, count: 1)
        }

        let streak = current?.count ?? 1
        guard streak >= confirmCount else {
            return Outcome(streak: streak, isConfirmedChange: false)
        }

        current = nil
        return Outcome(streak: streak, isConfirmedChange: true)
    }

    /// Called when the hunted sonde is heard again, which ends any foreign run.
    mutating func reset() {
        current = nil
    }
}
