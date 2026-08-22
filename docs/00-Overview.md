# BalloonHunter — Documentation

Three planes, three questions, three readers. Every sentence belongs to exactly
one of them.

| Plane | Question | Directory | Reader |
|---|---|---|---|
| **WHAT** | What must be true of the system? | [`Functionality/`](Functionality/) | Anyone judging whether it is correct — reviewer, tester, future maintainer |
| **HOW** | How is it built and changed? | [`Harness/`](Harness/) | Whoever writes the next change, human or agent |
| **OPERATE** | How do I install and run it? | [`UserDocumentation/`](UserDocumentation/) | Whoever installs the app, hunts with it, or recovers it |

**Authority order: the FSD defines the target; the Harness defines the method.**
On conflict the FSD wins on *what must be true*, the Harness wins on *how to get
there*. User documentation describes the system as built — if it disagrees with
either it is stale, which means reality or the spec moved.

None of the three carries history or rationale narrative. Those live in `git log`.

The FSD is bound in place at
[`ios/BalloonHunter/BalloonHunterAppFSD.md`](../ios/BalloonHunter/BalloonHunterAppFSD.md)
rather than moved into `Functionality/`, because source comments cite its sections
by name. `android/` is a separate product outside this plane set.

## Where to start

| If you are… | Read |
|---|---|
| Making a change | [`Harness/AI-Workflow.md`](Harness/AI-Workflow.md) — the loop every change follows |
| Judging correctness | [the FSD](../ios/BalloonHunter/BalloonHunterAppFSD.md) — requirements, state model, landing and prediction rules |
| Installing or hunting with it | [`UserDocumentation/User-Manual.md`](UserDocumentation/User-Manual.md) |
| Wondering why | The plane that owns the thing — rationale sits beside what it explains |

## Routing a new sentence

Ask in order; the first yes wins:

1. Externally observable and must be true → **Functionality**
2. Constrains how code is written or verified → **Harness**
3. Tells a human how to run or recover the system → **UserDocumentation**
4. About collaborating with an AI assistant → `CLAUDE.md`, which is not a plane
5. Why a past decision was made → beside the requirement or rule it explains, in
   whichever plane owns that — or the commit message

Two questions settle the hard cases. *Could a black-box tester verify it?* — yes
means WHAT. *Would it survive a rewrite in another language?* — no means HOW.

Worked examples from this project: *"A landing reached by APRS silence keeps the
prediction as the landing point"* is Functionality. *"Pure rules live in
`HuntRules.swift` and carry no Combine or `@MainActor`"* is Harness. *"Pull the
diagnostic log with `devicectl device copy from`"* is UserDocumentation.

## Where rationale goes

**Beside the thing it explains, never in a standing decisions log.** Product
choices belong in the FSD next to the requirements they shaped; implementation
choices belong in the Harness next to the rule they justify.

A separate decisions file ages badly. Nothing forces a reader past it, so it
drifts while still reading as authoritative. Rationale attached to a rule is
re-read every time that rule is — which is exactly when it matters, because a
rejected alternative usually looks like an obvious improvement in isolation.

## Writing rules

**Present-state.** Write what is true now, in the present tense. No history, no
rationale narrative, no temporal comparison. Delete on sight: "now uses",
"previously", "as of v2", "we decided to", "legacy", "this was changed because".

**One canonical home.** Every fact is stated once. Anywhere else that needs it,
link. Two copies of a fact are two facts the moment one is edited.
