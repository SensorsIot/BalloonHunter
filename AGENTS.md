# Repository Guidelines

## Project Structure & Module Organization
- `BalloonHunter/`: App source. SwiftUI views (`*View.swift`), services (`*Service.swift`), caches (`*Cache.swift`), and coordinators (`*Coordinator*.swift`). App entry: `BalloonHunterApp.swift`; config in `Info.plist`.
- `BalloonHunter.xcodeproj/`: Xcode project and scheme (`BalloonHunter`).
- `BalloonHunter.xcdatamodeld/`: Core Data model.
- Docs and plans: `ACTION_PLAN.md`, `FINAL_REQUIREMENTS_CHECK.md`, `CLAUDE.md`, `GEMINI.md`.

## Build, Test, and Development Commands
- Open in Xcode: `xed .` (or open `BalloonHunter.xcodeproj`).
- Build (Debug): `xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter -configuration Debug build`.
- Run tests (when a test target exists): `xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter -destination 'platform=iOS Simulator,name=iPhone 15' test`.
- Simulator tip: set the scheme’s Run destination to a current iPhone simulator in Xcode before testing.

## Coding Style & Naming Conventions
- Swift 5+, 4‑space indentation, no hard tabs. Keep lines ~120 chars.
- Follow Swift API Design Guidelines; prefer value types, explicit access control, and `final` where appropriate.
- File naming: views `PascalCaseView.swift`, services `PascalCaseService.swift`, caches `PascalCaseCache.swift`, coordinators `PascalCaseCoordinator.swift`.
- Organize by feature: colocate view, service, and cache where they collaborate. Keep BLE and routing logic in services, not views.
- No linter is enforced; match existing style and add minimal doc comments for non‑obvious logic.

## Testing Guidelines
- Framework: XCTest. Create `BalloonHunterTests` and (optional) `BalloonHunterUITests` targets.
- Test files mirror types under test: `FooServiceTests.swift`, `PredictionCacheTests.swift`.
- Name tests `test...` and assert observable behavior (e.g., cache eviction, BLE parsing). Aim for coverage on services and caches first.
- Run in Xcode (⌘U) or via the `xcodebuild ... test` command above.

## Commit & Pull Request Guidelines
- Commit messages: imperative, concise subject (≤72 chars), optional body for context.
  - Example: `Fix descent rate calc and reduce debug logs`.
- PRs: clear description (what/why), linked issues, screenshots or screen recordings for UI changes, and steps to validate. Keep PRs focused and small.

## Security & Configuration Tips
- Changing BLE/Location permissions requires updating `Info.plist` and testing on device.
- Avoid storing secrets in the repo; use Xcode build settings or environment where needed.
- Do not change bundle identifier or deployment target without prior discussion.
