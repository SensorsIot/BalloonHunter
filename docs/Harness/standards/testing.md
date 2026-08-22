# Standard — Testing

## What is tested

**Pure rule types, not services.** The decisions that send a hunter to a field are
extracted as plain value types with no Combine, no `@MainActor` and no service
dependencies, so they can be exercised without a radio, a balloon, or a network.
The project's rule inventory is [`../project/pure-rules.md`](../project/pure-rules.md).

A decision still embedded in a service with a network client and a Combine
subscription is, in practice, untested — which is why extraction comes before the
test rather than after.

## Order

Specification, then test, then code — per requirement. A bug fix writes its
regression test first, and that test must fail before the fix and pass after.

## A test that has never failed proves nothing

Mutate the source and confirm the test goes red. This is the only evidence that an
assertion is connected to the behaviour it claims to check.

Mutation testing earns its keep on the cases where two rules coincide in the
fixture but not in reality. A fixture where every BLE point follows every APRS
point cannot distinguish "the points after the last APRS fix" from "every BLE
point"; only a mutant reveals that the test never separated them.

## What a test asserts

Assert the rule, not the implementation. Where a rule has a boundary, test both
sides of it and the boundary itself. Where two inputs must stay distinguishable —
"nothing there" versus "could not ask" — assert that they produce different
answers, because collapsing them is the failure that will actually happen.

## Running

From `ios/`:

```
xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter \
  -destination 'platform=iOS Simulator,name=iPhone 16' build test
```

The suite runs on the simulator and needs no hardware. A device build additionally
proves the stricter concurrency settings compile.

## CI

`.github/workflows/ios-tests.yml` runs the suite on every push to `main` and every
pull request that touches `ios/`. A red run blocks the merge, so the gate no longer
depends on someone remembering.

The workflow discovers its toolchain rather than pinning one: it selects the newest
Xcode on the runner and asks `xcodebuild -showdestinations` for a simulator UDID. A
device *name* is ambiguous — the same iPhone exists under several runtimes and
xcodebuild refuses a destination it cannot resolve to one device — so the UDID is
what it uses. On failure the `.xcresult` bundle is uploaded, because a red run
without it means reproducing the failure locally to find out what broke.

Running the suite locally before committing still matters: CI reports after the
push, and the loop is faster here.
