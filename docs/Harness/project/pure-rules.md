# BalloonHunter — Pure rule types

The decisions that send a hunter to a field, extracted as plain value types in
`ios/BalloonHunter/HuntRules.swift` and its siblings: no Combine, no `@MainActor`,
no service dependencies. **Put a new rule here rather than inside a service.**

| Type | Decides |
|---|---|
| `LandingDetector` | The landing algorithms and their priority; whether a touchdown is confirmed |
| `PredictionPolicy` | Whether a prediction runs now — on whether the position is known, not on whether the balloon is landed |
| `StartupSelection` | Auto-select an airborne sonde, or ask |
| `ForeignSondeTracker` | A stray decode versus a real retune |
| `TestSonde` | Whether a serial SondeHub holds nothing for may take over the hunt |
| `FetchWindow` | How much history to request, sized from when the serial was last asked about |
| `HuntTail` | Which track points are worth persisting, and whether a stored tail may be restored |
| `RoutePolicy` | Whether a route is wanted at all, and the close-range radius |
| `RouteRenewalPolicy` | Whether a new route is built now |
| `DepartureTime` | When to leave to meet the landing |
| `CloseRangeGuidance` | Distance and bearing on foot; refuses SondeHub positions |

A rule reaches this list by being a decision someone can get wrong in a way a
hunter would notice. The test that it belongs here: could it be exercised with no
radio, no balloon and no network?

## Isolation

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so plain value types
are swept onto the main actor unless marked otherwise. Rule types and pure data are
declared `nonisolated`, which is also what lets them be reached from the nonisolated
code that needs them.
