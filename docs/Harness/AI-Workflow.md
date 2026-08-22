# BalloonHunter — AI Workflow (the build contract)

Read this before any change. It is how new functionality is built and how the
documentation stays in sync with it.

## The loop

**1. Locate the contract.** Find the FSD rule the work serves in
[`ios/BalloonHunter/BalloonHunterAppFSD.md`](../../ios/BalloonHunter/BalloonHunterAppFSD.md).
If none exists, the work starts by defining the **WHAT** — a new, atomic,
falsifiable requirement — not by writing code.

**2. Write the specification first, then the test, then the code.** In that
order, per requirement rather than as project phases. A test written after the
code describes the code, including its bugs; running the three as phases produces
a plan that reads finished while nothing is verified. See
[`standards/documentation.md`](standards/documentation.md).

**3. Build per the Harness.** Follow `standards/` and `project/`. Reuse an
existing rule type, service, or helper before adding new code. Make the smallest
change that satisfies the rule.

**4. Test — the gate, not an afterthought.** A change is not done until its test
exists and passes. A bug fix writes its **regression test first**, and that test
must fail before the fix and pass after — a regression test that never failed
proves nothing. Prove a new test can fail by mutating the source and watching it
go red. See [`standards/testing.md`](standards/testing.md).

**5. Reconcile the documentation.**
- The **FSD** absorbs new or changed behaviour — verify, don't transcribe. Where
  the code deviates from the intended spec, fix the code rather than enshrining
  the defect as a requirement.
- The **user documentation** absorbs anything a hunter would notice.
- The **Harness stays put** unless the change taught a rule universally true for
  this project.
- All present-state. No history in any plane.

**6. Verify both directions.** Confirm the implementation matches the FSD, and
that no FSD rule is silently unimplemented. Deviations fix the code; genuine gaps
are documented as gaps; contradictions are escalated rather than guessed at.

## Requirement quality gate

Before a new requirement enters the FSD it must be:

- **Atomic** — one obligation. Split anything joining two verbs, a behaviour and a
  deadline, or a success and a failure path.
- **Falsifiable** — precondition, stimulus, observable response, deadline,
  tolerance, failure behaviour, verification tier.
- **Free of weasel words** — *appropriate, graceful, user-friendly, reasonable,
  sufficient, robust, seamless, acceptable, normal operation, best effort*.
- **Carrying no invented number.** See
  [`standards/engineering.md`](standards/engineering.md) — thresholds are the
  domain owner's to set.

## Commands

Run from `ios/`:

```
xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter \
  -destination 'platform=iOS Simulator,name=iPhone 16' build test
```

Installing to a device and pulling diagnostics are operator procedures and live in
[`../UserDocumentation/User-Manual.md`](../UserDocumentation/User-Manual.md).
