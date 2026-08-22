# BalloonHunter — Source layout and boundaries

Swift sources live in `ios/BalloonHunter/`, tests in `ios/BalloonHunterTests/`.

## Layer responsibilities

| Layer | Owns | Never does |
|---|---|---|
| **Views** | Presentation | Business logic, or side effects in a view body |
| **Services** | Data processing and domain rules | Cross-service orchestration |
| **`ServiceCoordinator`** | Cross-service coordination only | Work a single service can do alone |
| **`MapPresenter`** | Map-specific transformation | Decisions the services own |
| **Rule types** | The decisions themselves | Combine, `@MainActor`, I/O |

**No logging or computation in a view body.** A SwiftUI body runs on every render,
so a side effect there executes at a rate nobody intends.

## Direct versus coordinated access

A view reads a service directly when one service owns the data exclusively and no
cross-service state is involved. It goes through `ServiceCoordinator` when several
services must agree, or for lifecycle and startup sequencing. Using the coordinator
as a pass-through for single-service data adds a layer that owns nothing.

## Prohibitions

- **Do not create a new file without asking.**
- **Telemetry source** is the `.ble` / `.aprs` enum, never a string literal.
- **Nothing bypasses an owner.** Where a service owns a decision, every trigger
  reaches it through that service's entry point rather than calling the builder
  underneath. A trigger that calls past the owner is how a decision comes to be
  made twice, differently.
