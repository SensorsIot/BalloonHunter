# CODEX.md

This file provides guidance to the Codex CLI coding agent when working in this repository.

## Project Overview

BalloonHunter is an iOS SwiftUI app that connects via Bluetooth Low Energy to MySondyGo devices to receive balloon telemetry, predicts trajectory/landing, and provides routing and a map UI for recovery.

## Quick Commands

- Open in Xcode: `xed .`
- Build (Debug): `xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter -configuration Debug build`
- Run tests: `xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter -destination 'platform=iOS Simulator,name=iPhone 15' test`
- Simulator tip: In Xcode, set the scheme’s Run destination to a current iPhone simulator before testing.

## Code Organization

- App code: `BalloonHunter/`
  - Views: `*View.swift`
  - Services (BLE, location, prediction, routing, persistence): `*Service.swift`
  - Caches: `*Cache.swift`
  - Coordinators: `*Coordinator*.swift`
  - Entry point: `BalloonHunterApp.swift`
- Project: `BalloonHunter.xcodeproj/`
- Data model: `BalloonHunter.xcdatamodeld/`
- Agent guidelines: `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`

## Architecture (Current)

- Pattern: Service → Coordinator → Views with Combine.
- Coordinator: `ServiceCoordinator` subscribes to services and publishes consolidated state for views.
- Services: `BLECommunicationService`, `CurrentLocationService`, `PredictionService` (Tawhiri API), `RouteCalculationService` (Apple Maps), `PersistenceService`.
- Caches: `PredictionCache`, `RoutingCache` reduce API and compute load.
- Views observe only coordinator state via `@EnvironmentObject`; they do not call services directly.

## Development Guidelines

- Separation of concerns:
  - Views: presentation only; bind to coordinator state; no calculations, timers, API, BLE, or persistence.
  - Services: business logic, external I/O, background work.
  - Coordinator: wiring and state aggregation; no heavy business logic.
- Add features by:
  1) Defining/expanding a service (`BalloonHunter/*Service.swift`) with `@Published` outputs.
  2) Injecting it via `AppServices` and subscribing in `ServiceCoordinator`.
  3) Surfacing derived state from coordinator for views to use.
- Place files by role and follow naming: `PascalCaseView.swift`, `PascalCaseService.swift`, `PascalCaseCache.swift`, `PascalCaseCoordinator.swift`.
- Swift style: Swift 5+, 4-space indentation, ~120-char lines, `final` where appropriate, explicit access control.

## Testing

- Framework: XCTest. Targets: `BalloonHunterTests` (and optional `BalloonHunterUITests`).
- Mirror types under test with file names like `FooServiceTests.swift`, `PredictionCacheTests.swift`.
- Prefer testing services and caches (e.g., cache eviction, BLE parsing, prediction throttling).
- Run tests from Xcode (⌘U) or the `xcodebuild ... test` command above.

## iOS/Config Notes

- Permissions (BLE/Location) require `Info.plist` updates and device testing.
- Do not change bundle identifier or deployment target without explicit approval.
- No secrets in repo; prefer build settings or environment.

## Common Tasks for Codex

- Implement a new service: add `*Service.swift`, register in `AppServices`, subscribe in `ServiceCoordinator`, expose state.
- Move logic out of views: extract to the appropriate service and surface via coordinator.
- Optimize predictions/routing: use caches; keep network usage efficient.
- Add targeted tests for service behavior; avoid UI logic in tests.

Refer to `CLAUDE.md` for a deeper architecture narrative and planned improvements (compass/camera, zoom management). Follow `AGENTS.md` conventions for structure, naming, and commands.

