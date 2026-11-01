---
type: mission-brief
state: completed
updated: 2026-11-01
mission: manila-folder-01
---

# OPERATION MANILA FOLDER, iteration 1: brief

## Terminology

> **Mission** — A definable, testable scope of work. **Sortie** — One agent's atomic task within it.

## Outcome

All 10 sorties met their exit criteria on `mission/manila-folder/01`. `ConformanceTests` passes every fixture in `conformance.json`. `make acceptance` passes items 1, 4 (`create` half) and 5, and **fails item 2**.

## Item 2

Against the acceptance project's committed bundles, `dossier add` of the only real view sidecars refuses with `derivedInputNotInBundle`. Those sidecars name portrait and face hashes that are no longer in the bundle, because the portrait was replaced after they were made. Recon confirmed the sidecars exist, not that their hashes match. Two questions are open, for the owner and for dossier-format:

1. Acceptance 2 can't be met as written on the project's current data.
2. §7 gives `derivedFrom` a bundle path for its input, and doesn't say what to write when the input has left the bundle.

## Lessons

- Recon verified existence and shape, and the failure was in the relation between two files. Acceptance data needs its relation checked.
- A shared checkout was hit by a second session mid-run. Isolate mission work in its own clone from the start.
- `SPEC-GAP` comments in `Sources` record each choice taken where the spec is silent.
- The test filter, the CLI directory on a case-insensitive disk and the iOS resource layout each needed a fix the plan didn't foresee.

## Rollback Verdict

**KEEP.** Nothing is merged. The branch's failures are in test data and one open format question, not in its design. `clean` is not run: the mission has an open question, so its documents stay at the root.
