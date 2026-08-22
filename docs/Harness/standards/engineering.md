# Standard — Engineering conventions

Present-state rules for how code is written here.

## Every decision has one owner, and the owner is named

**One canonical owner per decision, and the exclusion is stated with it.** Naming
the owner is the easy half; the useful half is the sentence that says nothing else
may answer. *"`readBalloonContext` is the canonical sonde data loader. Nothing else
loads sonde data, ever."* The exclusion is what tells the next change where not to
go.

Two answers to the same question in one system means one of them is unauthorised.
Delete it rather than reconciling the two — a system with two authorities disagrees
the moment either is edited, and no reader can tell which is current.

## The owner is answerable for the stability of what it publishes

Owning a decision means owning its behaviour over time, not just its value now. A
published value that oscillates under unchanging inputs is a defect belonging to
its owner, wherever the oscillation is observed.

Anything computed from a live input — a position, a distance, a snapped route —
must be examined for whether it can feed itself. If output can influence the next
input, the owner damps it: a floor on how often it may change, a threshold below
which a change is not a change, or a guard that declines to produce a value nobody
will use.

## Encapsulated functions, one responsibility

A function does one thing and is named for it. A function that sometimes shows UI
is still one function: whether it had to ask the user is an internal branch, never
a second code path callers must know about.

Dependencies belong in the orchestrator's ordering, not inside the components. A
step lacking its inputs **refuses to run** rather than emitting a placeholder.

Independent inputs stay independent. Two feeds for the same fact do not consult
each other; each publishes what it has, and the absence of one is a normal state
rather than an error to coordinate around.

## Fix the cause, then delete the guard

No workarounds. When a defect appears, instrument first — log the real data at the
point of failure and read it — then trace upstream until removing the cause makes
the guard unnecessary, and delete the guard.

A guard that survives the fix is a fix that failed. Build instruments that can
disprove the current guess, not only confirm it: measuring every case finds the
outlier wherever it lands, while a filter shaped around the suspected cause finds
nothing when the cause is elsewhere.

Say plainly which parts of a change are diagnostics and which change behaviour.

## Never invent a threshold

Numeric thresholds, tolerances, timeouts and radii are the domain owner's to
choose. Propose a value **with its consequence**, then use the one given back.

Show what the number would invalidate, not just the number. Prefer a natural
signal to a tuned constant — vertical speed beats an altitude cutoff, travel time
beats a coordinate displacement — and handle the undetermined case explicitly:
"unknown" must never collapse into a definite answer.

A value the assistant proposed stays marked as proposed until it is accepted.

## Reuse, scope, and structure

- **Reuse before adding** — search for an existing rule type, service, or helper
  before writing new code.
- **Smallest change that satisfies the rule** — no speculative scope, no drive-by
  refactors bundled with a fix.
- **One module per component.** A component that cannot be named cannot be tested.
- **Dependencies point one way** — lower layers never import higher ones.
- **Extract pure cores** — separate the decision from the I/O, so the cheapest test
  tier can reach it. This project's binding for that is
  [`../project/pure-rules.md`](../project/pure-rules.md).
- **Errors fail loudly** — actionable messages, no silent catches. An ignored error
  is a defect even when nothing breaks yet.
- **Secrets are never in code or documentation** — only their location is recorded.

## Logging

Report **changes, not events**. The diagnostic log is capped and rotates, so
anything emitted per packet or per UI render pushes out the decisions worth
reading. A message repeated at 1 Hz has told the reader nothing after the first.

A log line answers: where the trigger came from, what was executed, and what was
delivered — one line each.

## Verification before commit

Build and the full test suite pass before committing. Never commit generated
output, build artefacts, or secrets.
