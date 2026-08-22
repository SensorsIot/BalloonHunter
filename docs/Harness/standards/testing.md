# Standard — Testing

## What is tested

**Pure rule types, not services.** The decisions that send a hunter to a field are
extracted as plain value types with no Combine, no `@MainActor` and no service
dependencies, so they can be exercised without a radio, a balloon, or a network.
The project's rule inventory is [`../project/pure-rules.md`](../project/pure-rules.md).

A decision still embedded in a service with a network client and a Combine
subscription is, in practice, untested — which is why extraction comes before the
test rather than after.

## Where the tests are declared

`testing/test-plan.yaml` lists every test — the unit suites, and the workflows
executed by hand — with what each needs and what it last produced. A test that is
not declared there does not exist for planning purposes, however green it runs.

Each case carries two independent classifications: `kind` (`atomic` or `workflow`)
and `scenario` (`standard`, `deviation`, `negative`, `security`). A **workflow is
not a loop over its children** — it is one continuous run, and its status is
independent of theirs. All children green with the workflow red is an integration
defect, which is precisely the result atomic coverage cannot produce.

Every workflow carries a start state to **establish rather than assume**, the
`must_not` failure modes that would otherwise produce a false pass, and the
`evidence_required` a run must capture. For the device and field tiers the steps
are the manual procedure: what to do, and what to observe in the app or the log.

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

## The gate is a pre-push hook, not a hosted runner

The suite runs on this machine, before the push, and refuses it when red.

```
git config --global core.hooksPath ~/Documents/Github/claude/githooks
```

The hook dispatches on what the push touches, so an unrelated change costs nothing.
For Swift it builds and runs the full suite — about twenty seconds incremental —
and prints the failing test when it refuses.

**A hosted macOS runner is not usable for this.** Its images carry several Xcode
versions and no iOS simulator runtimes, so `xcodebuild` finds only a placeholder
destination and the job fails before building; making it work means downloading
gigabytes per run for a suite that finishes in under a second here.

**What that trades away:** the gate protects this machine only. A pull request from
someone else, or a push from a second machine without the hook, is unchecked. That
is the right trade while this is a solo project and the wrong one as soon as it is
not.

Running the suite locally before committing still matters: CI reports after the
push, and the loop is faster here.
