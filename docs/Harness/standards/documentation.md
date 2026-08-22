# Standard — Documentation governance

## Document, then tests, then code

In that order, **per requirement** rather than as project phases.

A test written after the code describes the code, including its bugs. Running the
three as project-wide phases produces a plan that reads finished while nothing is
verified. Where retrofitting onto existing code is unavoidable, prove each test can
fail by mutating the source and watching it go red — an assertion that has never
failed is an assertion nobody has checked.

## No history in documentation or code

State the rule and its reason in the present tense. What broke on a given day, and
which defect a rule guards against, belong in the commit message — `git log`
already records them, and repeating them makes every future reader pay for a bug
they will never see.

The test is the tense. *"Cancelling ran the handler it was meant to call off"* is
history. *"Cancelling must not run the handler"* is the rule. Write the second.

Delete on sight, from prose and from comments alike: dates, serials, timings,
*"used to"*, *"no longer"*, *"any more"*, *"previously"*, changelog tags such as
`— NEW` or `MOVED TO`, and parentheticals naming the regression a rule prevents.

Two things are not history and stay:
- **Runtime conditions** — *"no longer has telemetry"*, *"a previously detected
  landing"* describe state, not the past.
- **A measurement justifying a physical constraint that still holds** — anchored to
  the test fixture that proves it, never to a date.

Historic narrative does not merely add noise: it goes stale and starts
contradicting the code, at which point the comment above a function is worse than
no comment at all.

## One canonical home

Every fact is stated once, in the plane that owns it. Anywhere else that needs it,
link. Two copies of a fact are two facts the moment one is edited, and the reader
cannot tell which is current.

This applies to assistant memory as much as to documents: memory points at the
FSD or the Harness and records only what they cannot say — that the code lags the
spec, that a shipped guard is superseded, whose number a constant is.

## Rationale sits beside what it explains

Not in a standing decisions log. A separate decisions file drifts while still
reading as authoritative, because nothing forces a reader past it. Rationale
attached to a rule is re-read every time that rule is.

## New files

Do not create a new source or documentation file without asking. A new file beside
an existing one that fills the same role is where the first one goes stale.
