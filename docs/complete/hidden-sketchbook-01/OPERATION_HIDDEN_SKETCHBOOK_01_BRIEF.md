---
type: mission-brief
state: completed
mission: hidden-sketchbook-01
updated: 2026-11-10
---

# Iteration 01 Brief — OPERATION HIDDEN SKETCHBOOK

**Mission:** Preview pages for `.dossier` bundles, built from the bundle on disk and stored in the bundle's `.preview/`, with the `dossier preview` CLI, the DossierUI viewer and a release gate on dossier-format rc.8.
**Branch:** mission/hidden-sketchbook/01 (PR intrusive-memory/SwiftDossier#9 → development)
**Starting Point Commit:** e35023cb0df41121f4a05238647f6a3a5c91e6fd
**Sorties Planned:** 13
**Sorties Completed:** 13
**Sorties Failed/Blocked:** 0
**Duration:** about 2h40m wall clock (about 100 min of it waiting on the rc.8 tag). Relative cost 231x.
**Outcome:** Complete
**Verdict:** `KEEP` — every sortie passed its exit criteria on the first attempt, both platforms' tests pass on rc.8, and test-cleanup removed nothing.
**Tests pruned:** 0
**Tests flagged for review:** 4 (plus the `make smoke` temp directories)

## Section 1: Hard Discoveries

### 1. `DossierTemplate.current` throws, so it can't be a default argument

**What happened:** The plan's signatures used `template: PageTemplate = .current`. Swift doesn't allow a throwing expression as a default argument.
**What was built to handle it:** Overload pairs: `previewKey(template:)` plus `previewKey()`, and the same for `showPreview` and `rebuild`.
**Should we have known this?** Yes. Recon could have checked whether `.current` throws.
**Carry forward:** When a plan gives a signature with a default argument, check that the default expression doesn't throw.

### 2. `await` doesn't make Swift pick the async overload

**What happened:** `main.swift` called `await DossierCLI.run(...)`. That resolved to the synchronous `run`, so the released binary answered `dossier preview` with `async-required` (exit 70). The tests only called the async API, so they all passed.
**What was built to handle it:** The async entry point was renamed `runAsync`, and `make smoke` now runs `preview` twice on the release binary (a miss, then a hit).
**Should we have known this?** Partly. Overloads that differ only by `async` are a known trap. The real gap was that no exit criterion ran the shipped binary.
**Carry forward:** Every new CLI subcommand gets a `make smoke` check against the release binary, not only unit tests.

### 3. Watching a bundle means watching the directory

**What happened:** Writers replace `manifest.json` by atomic rename, so a watch on the file itself goes silent after the first replace. A watch on the directory also fires on the viewer's own `.preview/` writes.
**What was built to handle it:** A DispatchSource on the bundle directory. Each event is judged by a pure `BundleSnapshot.change(from:to:)`, which compares `manifest.json`'s inode, size and mtime plus the names of the `.update-*.json` markers. The snapshot is taken under the lock, so a late event can't report a step backwards.
**Should we have known this?** Yes, it's standard for atomic-rename writers. The plan named the hazard but not the design.
**Carry forward:** An event source that watches files is two parts: a thin OS shell with no tests, and a pure decision function tested synchronously.

### 4. Tests that count fixtures break on every spec pin

**What happened:** rc.8 added two fixtures, and four tests pin exact fixture counts (19, 99, 104, 56). Each failed by exactly 2.
**What was built to handle it:** The counts were updated (2fc2e60), and each +2 was traced to the two new fixtures.
**Should we have known this?** Yes. The plan's Sortie 12 said "make test passes" but didn't list these tests as expected changes.
**Carry forward:** A plan that pins a new dossier-format version must list the count-pinned tests (SchemaEvaluatorTests, ChecksumTests, ManifestTests, CompletenessTests) as expected changes.

## Section 2: Process Discoveries

### What the Agents Did Right

#### 1. Holding to the spec's key

**What happened:** The §11.1 key was built as the spec defines it, from the manifest bytes, the member hash and the template hash.
**Right or wrong?** Right. dossier-format's rc.8 conformance fixtures expect exactly the keys our binary computes, and this was checked before rc.8 was tagged.
**Evidence:** `preview-current` gave `b80f93f3…` with a hit and no writes. `preview-out-of-date` gave `08ad529b…` with a miss, and afterwards the store held only `.gitignore` and the new page.
**Carry forward:** Run new conformance fixtures against the implementation before tagging the spec.

#### 2. Stopping on a plan problem

**What happened:** The Sortie 12 agent stopped without committing when the tests failed, and reported the exact assertions.
**Right or wrong?** Right. The prompt told it to stop, and it did.
**Evidence:** No speculative test edits. The supervisor made the call, and the follow-up took one round.
**Carry forward:** Keep the "stop and report, don't fix" instruction in prompts for pin-bump sorties.

### What the Agents Did Wrong

#### 1. Shipping a binary that couldn't run its new command

**What happened:** Sortie 7 passed every exit criterion while `bin/dossier preview` was broken.
**Right or wrong?** Wrong. The supervisor caught it by hand.
**Evidence:** c349917 was fixed by 39e8e07.
**Carry forward:** See Hard Discovery 2.

#### 2. A race and a live event source in the first ManifestWatcher

**What happened:** In Sortie 9's first commit, the snapshot was taken outside the lock, and one test ran a live DispatchSource alongside manual events.
**Right or wrong?** Wrong. The test's counts depended on scheduling.
**Evidence:** 21e574a was fixed by 1b87c05.
**Carry forward:** Prompts for concurrent code must ask where each piece of shared state is read and written.

#### 3. A stray file

**What happened:** The Sortie 6 agent left a sed backup, `FileAcceptanceCommandTests.swift-E`, in the tree.
**Right or wrong?** Wrong.
**Evidence:** The supervisor deleted it.
**Carry forward:** Use `sed -i ''` on macOS, or the Edit tool.

### What the Planner Did Wrong

#### 1. Planning timed tests

**What happened:** The plan's Sortie 9 text asked for "bounded waits with a timeout". The supervisor passed that to the agent. The user rejected it: no timed tests in CI.
**Right or wrong?** Wrong. This is a standing user rule.
**Evidence:** A correction was sent mid-sortie, and a memory was saved (no-timed-tests-in-ci).
**Carry forward:** Every plan and every sortie prompt touching watchers, timers or async state says: no test depends on time; split the pure decision from the OS shell.

#### 2. An exit criterion the plan's own Sortie 8 couldn't meet

**What happened:** Sortie 9 required that `grep Task.sleep Sources/DossierUI` print nothing. Sortie 8 legitimately needed one marker-expiry wait.
**Right or wrong?** Wrong. It needed a user decision and a plan amendment (0854e45).
**Carry forward:** Check that each sortie's exit criteria hold given what earlier sorties must produce.

#### 3. A deferred dependency with no owner

**What happened:** Sortie 12 waited on a human release. The 100-minute wait ended NOT_MET, and in the end the user asked the supervisor to release it.
**Right or wrong?** It cost about 100 minutes of waiting, but nothing else was blocked.
**Carry forward:** For a release in a sibling repo, ask at `start` whether the supervisor may perform it.

#### 4. The completion log wasn't kept during the run

**What happened:** COMPLETE_SWIFTDOSSIER.md was written at the end, from the Decisions Log.
**Right or wrong?** Wrong (supervisor). Per-sortie durations and turn counts are lost, and some logged timestamps were estimates that ran ahead of the real clock.
**Carry forward:** Append to COMPLETE_*.md at each COMPLETED transition, with `date -u` timestamps.

## Section 3: Open Decisions

### 1. Cleanup flags: fix or accept?

**Why it matters:** These tests don't fail in CI today, but they could under conditions CI doesn't currently have.
**Options:**
- (a) `DossierViewModelTests:storeNote` makes a directory read-only with chmod 0o555. It would pass the wrong way if CI ran as root. GitHub's macOS runners don't run tests as root.
- (b) `ManifestWatcherTests:liveSourceConstructs` builds a live DispatchSource and cancels it at once. It doesn't wait on anything.
- (c) `RebuildTests:unchanged` sets an mtime a day in the past and checks the new mtime is later. The one-day margin makes it deterministic.
- (d) `make smoke` leaves its `mktemp` directories behind.

**Recommendation:** Accept (a) through (c) as they are. Fix (d) with a `trap 'rm -rf' EXIT` in the smoke recipe as a small follow-up.

### 2. Public API added beyond the plan

**Why it matters:** These become API that consumers depend on. SwiftDossier is a library.
**Options:** Keep `storedPreview()`, `PreviewStore.anyStoredPage()`, `DossierCLI.runAsync` and the overload pairs, or make the helpers `package`-scoped before the next release.
**Recommendation:** Make `storedPreview()` and `anyStoredPage()` `package`-scoped if DossierUI is the only user. Keep the rest.

### 3. Rendering check by eye

**Why it matters:** No check looked at how the page renders in a `DossierView` host.
**Recommendation:** Open one mr-mr-charles bundle in a test host before release.

## Section 4: Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| 1 | openForPreview(cast:) | opus | 1 | ✓ | |
| 2 | Building-rule tests | sonnet | 1 | ✓ | Tests only; the code already complied |
| 3 | §11.1 key | opus | 1 | ✓ | Matches dossier-format's rc.8 fixtures |
| 4 | In-bundle store | opus | 1 | ✓ | Replaced DossierPreviewCache |
| 5 | rebuild() | opus | 1 | ✓ | |
| 6 | render --cast required | sonnet | 1 | ✓ | Left a stray sed backup |
| 7 | dossier preview CLI | sonnet | 1 + continuation | ~ | Shipped a broken binary; fixed in the follow-up |
| 8 | DossierUI view model | opus | 1 | ✓ | Its one sleep forced the plan amendment |
| 9 | ManifestWatcher | sonnet | 1 + 2 corrections | ~ | Timed tests (planner's fault), then a race |
| 10 | Preview web view | sonnet | 1 | ✓ | |
| 11 | DossierView | sonnet | 1 + verifier | ✓ | Verifier PASS (PV-24) |
| 12 | Pin rc.8 | sonnet | 1 + continuation | ✓ | Stopped correctly on count tests |
| 13 | mr-mr-charles acceptance | haiku | 1 | ✓ | Cheapest sortie, clean |

No sortie's output was reverted or made moot by a later one.

## Section 5: Harvest Summary

The preview design held: the key, the store and rebuild matched the spec's own conformance fixtures on the first try. The defects were all at the edges. One was the shipped binary, which unit tests never ran. Another was a concurrency race in the watcher. The third was a plan that asked for timed tests. The most important change for the next iteration is to make the real artifact and the user's standing rules part of every exit criterion: run the release binary in `make smoke`, and say "no test depends on time" in every plan and prompt. Test-cleanup removed 0 of the mission's tests and flagged 4, all low-risk. The agents wrote no timed tests once the rule was stated, so the lesson belongs in the prompts, not in a code fix.

## Section 6: Files

**Preserve (read-only reference for the next iteration):**

| File | Branch | Why |
|------|--------|-----|
| docs/complete/hidden-sketchbook-01/* | development (via PR #9) | The plan, recon, state, completion log, cleanup report and this brief |
| docs/REQUIREMENTS-preview.md | development | The preview requirements. REQUIREMENTS.md cites PV-27 |
| ACCEPTANCE_PREVIEW.md | archived with the mission | mr-mr-charles keys from the S13 acceptance run |

**Discard:** none. The verdict is KEEP.

## Section 7: Iteration Metadata

**Starting point commit:** `e35023c`
**Mission branch:** `mission/hidden-sketchbook/01`
**Final commit on mission branch:** the archive commit that follows ee1cb03 (test-cleanup)
**Rollback target:** `e35023c`
**Next iteration branch:** `mission/hidden-sketchbook/02` (not needed)

## Rollback Verdict

**Verdict:** `KEEP`

**Reasoning:** All 13 sorties completed with no BACKOFF, FATAL or REPLAN. Every continuation fixed a concrete defect the supervisor found. The implementation agrees with dossier-format's rc.8 conformance fixtures. `make test` and `make test-ios` pass, and test-cleanup removed nothing (0%).

**Recommended action:** Merge PR #9 into development. Follow-ups:
- Clean up the smoke `mktemp` directories.
- Decide whether the two new Dossier helpers become `package`-scoped.
- Check by eye how a mr-mr-charles page renders in a `DossierView` host.
