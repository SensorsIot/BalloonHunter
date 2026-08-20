/* [markdown]
# Departure Time

While the hunter is still at home, the question is not where the balloon will land.
It is **when to leave in order to meet it**.

```
leave at  =  predicted landing time  -  driving time
```

No margin is added. The hunter judges their own slack.

Both halves move: the landing time changes as the flight develops, and the driving
time changes as the route is recalculated. So this is a live countdown, not a fixed
clock time.

When the drive is longer than the time left in the air, the balloon cannot be met.
The countdown simply goes negative and says nothing more.

This is a different question from the `Arrival:` figure the app already shows,
which answers "when would I get there if I left this second".
*/

import Foundation

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
