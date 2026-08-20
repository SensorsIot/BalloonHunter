/* [markdown]
# Hunt State

Decides, at startup or on returning to the app, whether a hunt is still running
and what the hunter may be shown.

Two rules, and the order matters:

**The serial says whether it is the same hunt.** A different sonde has nothing to
do with the last one, so everything from the old hunt goes. The same sonde is the
same hunt at any age, because asking SondeHub again would return the same flight,
so throwing the local copy away only loses the detail the receiver gathered.

**Time only decides what may be shown, and only when nothing is arriving.** With
no telemetry, elapsed time is the only evidence there is. Under six hours the hunt
is treated as still running and everything known is drawn. Over six hours the app
says so and draws nothing. Six hours covers a real recovery: the climb, the fall,
the drive, and the walk.

Both cases wait. Neither gives up and neither asks the hunter anything.
*/

import Foundation

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
