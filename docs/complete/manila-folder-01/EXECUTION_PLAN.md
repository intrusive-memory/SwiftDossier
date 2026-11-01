---
type: execution-plan
feature_name: OPERATION MANILA FOLDER
mission_branch: mission/manila-folder/01
iteration: 1
starting_point_commit: 1938da4
requirements: REQUIREMENTS.md
recon: RECON_REPORT.md
state: completed
updated: 2026-11-01
mission: manila-folder-01
---

# EXECUTION_PLAN.md — SwiftDossier core (phases 1 and 2)

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

## Scope

In: REQUIREMENTS §8 phase 1 and phase 2, and `make acceptance` items 1, 2, 4 (`create` half) and 5.

Out, each with its reason:

| Item | Why |
|------|-----|
| `renderPage`, `dossier render`, `DossierTabs`, acceptance 3 | Phase 3. Needs the dossier-format template, field list and tokens, which aren't written and aren't in the pinned tag. A separate mission |
| `migrate`, acceptance 4's migrate half | Phase 4. REQUIREMENTS §8 says Appendix A's field gaps go to dossier-format first |

## Spec access

The pin is `v2.0.0-rc.3` (`8509790`). **Read it only at the tag.** `~/Projects/dossier-format`'s working tree is on another branch with uncommitted changes for a later format revision; those aren't this package's spec, and that checkout must not be switched, edited or written to. `make fixtures` (Sortie 1) extracts the tag into `.dossier-format/` in this repository, which is gitignored. Read `.dossier-format/docs/DOSSIER-FORMAT.md`, `.dossier-format/schemas`, `.dossier-format/data` and `.dossier-format/examples`.

## Rules for every sortie

- Never run `swift build` or `swift test`. Use `make build`, `make test`, or a `TEST_FILTER=<regex> make test`. Never run any `tools/*.py` from Personaje.
- macOS 26 / iOS 26, `swift-tools-version: 6.2`, Swift 6 language mode. Don't raise these.
- Public, MIT, synthetic data only. No real project's names, images, prompts or text anywhere in the repository, tests, comments or commit messages. Invented characters only.
- SD-1: where the spec is silent or contradicts itself, don't decide a format rule in code. If no fixture depends on it, take the most conservative reading, mark it `// SPEC-GAP: <section>: <choice>` and list it in your report. If a fixture or requirement can't be met without deciding it, file REPLAN.
- SD-2: rules live in data files. Never restate tiers, review IDs or schema rules in Swift. Check IDs in §8.3 are implemented by ID.
- Every `public` declaration has a `///` comment.
- Commit on `mission/manila-folder/01` only, with a message that describes the change. End each message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Push after each commit. Never merge, tag, or touch another branch.
- Never commit, delete or mention `default.profraw`.
- Never read or print `.env` files or secrets.

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| SwiftDossier core | . | 10 | 1 | none |

## Sorties

### Sortie 1: Scaffold, pinned resources, fixtures

**Priority**: 33 — blocks all nine others; establishes targets and build interface.

**Entry criteria**:
- [ ] On `mission/manila-folder/01`. No `Package.swift` exists.

**Tasks**:
1. `Package.swift`: tools 6.2; targets per REQUIREMENTS §2 (`DossierCore`, `Dossier`, `DossierCLICore`, `dossier`), test targets `DossierCoreTests`, `DossierTests`, `DossierCLICoreTests`. Yams `.upToNextMajor(from: "6.2.2")`; ArgumentParser `.upToNextMajor(from: "1.7.1")` linked only by `DossierCLICore`. SwiftReparto through the `sibling()` helper of the `toggle-sibling-libraries` skill (`~/.claude/skills/toggle-sibling-libraries/SKILL.md`), remote floor `0.2.1`.
2. `Makefile`, modelled on `~/Projects/package-collection/pkg/SwiftReparto/Makefile` (read-only): `help` (default), `build`, `test` (honours `TEST_FILTER`), `test-ios`, `fixtures`, `release`, `install`, `clean`, `resolve`, `acceptance` (stub that says Sortie 10 fills it). `DOSSIER_FORMAT_REF = v2.0.0-rc.3` is defined only here.
3. `make fixtures`: shallow-clones `https://github.com/intrusive-memory/dossier-format` at `DOSSIER_FORMAT_REF` into `.dossier-format/`, skipping if that directory is already at the ref. Add `.dossier-format/` to `.gitignore`. It must never read or write `~/Projects/dossier-format`.
4. Resources copied from the tag: `schemas/*.json` into `Sources/Dossier/Resources/schemas/`; `data/tiers.json`, `data/review.json` into `Sources/DossierCore/Resources/`. Add `Resources/PINNED.sha256` beside each (U-3's decision: a checked-in hash list naming the ref), with `scripts/pin-resources.sh` as its generator.
5. `Tests/*/PinnedResourcesTests.swift` (SD-2): bundled copies equal `PINNED.sha256`; when `.dossier-format/` is present, they also equal it. `make test` depends on `make fixtures`. A conformance test later *fails* when the fixtures are absent, never skips.
6. `.github/workflows/tests.yml`: `runs-on: xcode-27`, jobs "Test on macOS" and "Test on iOS Simulator", each with a timeout, each running only `make` targets. Runs on `pull_request` to `main` and `development`.
7. Update `AGENTS.md`'s build section with the make targets; don't change its rules.

**Exit criteria**:
- [ ] `make build` exits 0.
- [ ] `make test` exits 0 with `PinnedResourcesTests` passing.
- [ ] `make help` lists all targets above.
- [ ] `grep -nE 'swift (build|test)' Makefile .github/workflows/tests.yml` finds nothing.
- [ ] `git check-ignore .dossier-format` succeeds and `git ls-files | grep -c '^.dossier-format'` is 0.

### Sortie 2: DossierCore read model

**Priority**: 28 — every later sortie reads through these types.

**Entry criteria**:
- [ ] Sortie 1 exit criteria hold.
- [ ] Recon U-2 settled here: a test on `valid/non-ascii-underfive`'s member.

**Tasks**:
1. `Manifest`, `Asset`, `AssetKind`, `FileEntry`: decode v1 and v2, preserving unknown top-level, asset and provenance keys byte-faithfully through a re-encode (§5.1, §5.4, §6). Encoder writes §5's form: 2-space, sorted keys, final newline, no `\/`.
2. `Checksum`: sorted form (§5.3) and path-order form (Appendix A). Test §5.3's worked example.
3. `CanonicalName`: use Reparto's `canonicalName`; test all of `examples/names.json`.
4. `Cast.load(_:)` (§3, pointer resolution) and `MemberHash`: read the member as a Yams `Node` so scalar style is known, apply §7's normal form and canonical JSON. Test §7's worked hash and `valid/member-scalars`.
5. `DossierBundle.open(at:)`, `assets(kind:variant:)`, `selectedAsset(kind:variant:)`, `sampleURL(variant:)`, `identityPrompt`, `artStyle`, `pageURL`.
6. `completeness(tier:)` from `tiers.json` with the §8.3 check rows by ID; `stale(template:)` per §7 (template is an optional parameter). Assert against `conformance.json`'s `complete`/`missingRequired` for every fixture that has them.

**Exit criteria**:
- [ ] `TEST_FILTER=DossierCoreTests make test` exits 0.
- [ ] Tests named for §5.3, §7's hash and `names.json` exist and pass.
- [ ] `grep -rE 'import (Vision|ImageIO|ArgumentParser)' Sources/DossierCore` finds nothing.

### Sortie 3: SD-13 schema evaluator

**Priority**: 17 — the validator's `E-SCHEMA`, and SD-3's check on every write.

**Entry criteria**:
- [ ] Sortie 2 exit criteria hold.

**Tasks**:
1. `Sources/Dossier/SchemaEvaluator.swift`: exactly SD-13's keywords, `type` as array, relative `$ref` among pinned schemas. Unsupported keyword is a failure.
2. Tests: every keyword, positive and negative; every pinned schema loads with no unsupported keyword; a synthetic schema using an unsupported keyword fails; both `W-V1*` fixtures validate against `manifest-v1`; every `valid/` manifest validates against `manifest-v2`; `errors/E-SCHEMA*` fails.

**Exit criteria**:
- [ ] `TEST_FILTER=SchemaEvaluatorTests make test` exits 0.
- [ ] `grep -iE 'schema|jsonschema' Package.swift` shows no third-party package.

### Sortie 4: Validator and conformance

**Priority**: 22 — the requirement this mission is judged by.

**Entry criteria**:
- [ ] Sorties 2 and 3 exit criteria hold.

**Tasks**:
1. `Finding` (code, level, message, path), `ValidationReport` (findings, completeness rows with state, exit status 0/1/2).
2. `validate(template:)`, `validate(cast:template:)` implementing every §14 code, including §3 orphans and pointers, §5.2 disk inventory, §8.1 `W-SHAPE` read by ImageIO in the `Dossier` target, §11 `W-PAGE-EXTERNAL` by attribute and `url()` scan, §9.3 `W-FOOTNOTE`.
3. `Tests/DossierTests/ConformanceTests.swift`: one parameterized test per fixture in `conformance.json`, passing the named template (`templateVersion`, `templateSha256`). For each: every `codes` entry reported; nothing outside `codes` + `mayAlso`; `verdict` matches; `complete`/`missingRequired` match where asserted. A summary test asserts the fixture count is 96. Absent fixtures fail.

**Exit criteria**:
- [ ] `TEST_FILTER=ConformanceTests make test` exits 0 with 96 of 96 fixtures passing. Don't edit a fixture, `conformance.json` or a pinned copy to reach this.
- [ ] Any SPEC-GAP listed in the report.

### Sortie 5: Writers: create, add, select, reject, remove, delete

**Priority**: 15 — the write path.

**Entry criteria**:
- [ ] Sortie 4 exit criteria hold.

**Tasks**:
1. `ManifestWriter`: SD-5's sequence; `sha256`/`sizeBytes` rescan under §5.2's rules; refuses zero-byte files; validates against `manifest-v2` before replacing (SD-3).
2. `DossierBundle.add`: SD-6 naming, copy not move; SD-7 provenance fold from `--sidecar` or PNG `iTXt` keyword `vinetas` (recon V-03), `references` to `{sha256, path, role}` with `source` never recorded, `generatedAt` to `createdAt`, unknown keys preserved (recon handoff), `--provenance` merge; SD-10 `derivedFrom` for derived kinds; `select` on add.
3. `select`, `reject`, `remove`, `delete()` per SD-8, SD-9.
4. Tests with synthetic bundles copied to a temp directory: each op; every written manifest validates and re-validates clean; source file unchanged; second-selection demotion including `voiceSample` per `model`; a sidecar's absolute reference source never appears in any written byte.

**Exit criteria**:
- [ ] `TEST_FILTER=WriterTests make test` exits 0.
- [ ] `TEST_FILTER=ConformanceTests make test` still 96 of 96.

### Sortie 6: create, CAST.md through Reparto, prompts, refresh, candidates

**Priority**: 13 — remaining phase 1 writers; SD-11, SD-12.

**Entry criteria**:
- [ ] Sortie 5 exit criteria hold.

**Tasks**:
1. `DossierBundle.create(character:role:in:)` with §2's refusals, and the CAST.md update through Reparto owning only `role` and `manifest`. SD-12: report data-changing exceptions and non-normalized files before writing, suggesting `reparto canonicalize --apply`.
2. `setPrompt(_:_:)` (§5.5).
3. `refresh()` per SD-11 and §5.6, §3 orphan adoption.
4. `candidates(kind:variant:in:)` over `.generations/<CHARACTER>/`.
5. Synthetic `CAST.md` with layout quirks (mixed key order, quoted values, comments, multi-line values, odd scalars) as the regression fixture, checked both ways: after one Reparto write only the touched member's lines change; on a non-normalized file no member's §7 hash changes except the SD-12 exceptions.

**Exit criteria**:
- [ ] `TEST_FILTER=CastWriteTests make test` and `TEST_FILTER=RefreshTests make test` exit 0.
- [ ] `git diff --stat HEAD~1 -- Sources/DossierCore | tail -1` shows no write API added to `DossierCore`: `grep -rE 'func (add|select|reject|remove|create|delete)\b' Sources/DossierCore` finds nothing.

### Sortie 7: CLI for phase 1

**Priority**: 8 — the `dossier` product.

**Entry criteria**:
- [ ] Sortie 6 exit criteria hold.

**Tasks**:
1. `DossierCLICore`: `create`, `add` (with `--reference-roles`, which SD-7 names and §5 omits), `select`, `reject`, `remove`, `list`, `prompt`, `validate`, `refresh`, `candidates`. `--json` on all: one object on stdout, errors as `{"error": {...}}`, non-zero exit. `remove` asks for `--yes`. `validate` exits 0/1/2. Logic testable in-process.
2. `dossier` executable. `render` and `migrate` subcommands exist and exit non-zero with a message that says they're not available yet.
3. `make release` produces `bin/dossier` with its resource bundles; the CI macOS job runs it on one conformance fixture.

**Exit criteria**:
- [ ] `TEST_FILTER=DossierCLICoreTests make test` exits 0.
- [ ] `make release && ./bin/dossier validate '.dossier-format/examples/valid/complete-lead/characters/WREN HALLOWAY.dossier' --cast .dossier-format/examples/valid/complete-lead/CAST.md --json` exits 0, or the §5 usage form the implementation adopts for bundle-plus-cast, recorded in the report.

### Sortie 8: Face crop

**Priority**: 8 — phase 2.

**Entry criteria**:
- [ ] Sortie 7 exit criteria hold.
- [ ] Recon U-1 settled here: byte-identical test. U-4 is for acceptance.

**Tasks**:
1. `deriveFace(box:)`: §8.5's arithmetic as a pure function, tested on its worked example and edge clamps. Vision `VNDetectFaceRectanglesRequest`, largest face. PNG through ImageIO at fixed settings, stripped metadata. Hand-set box recorded in `provenance.box` and reused on refresh. `derivedFrom` includes `portrait`.
2. No face and no box is a reported error that writes nothing.
3. `dossier face <bundle> [--box x,y,w,h]`.
4. Test: same portrait and box give identical bytes, twice, on a synthetic image. Vision-dependent paths tested only through an injected detector, so CI needs no face.

**Exit criteria**:
- [ ] `TEST_FILTER=FaceCropTests make test` exits 0.
- [ ] A test named for §8.5's worked example asserts 180 × 180 at (0, 20).

### Sortie 9: check

**Priority**: 6 — phase 2.

**Entry criteria**:
- [ ] Sortie 8 exit criteria hold.

**Tasks**:
1. `CharacterDescription.read/write` (§9): writer preserves the text of keys it doesn't change.
2. `footnoteCheck()` (§9.3), `openQuestions` (§9.2 `###` groups), section presence against the tier.
3. `dossier check <bundle>` with `--json`.
4. Tests on synthetic CHARACTER.md files, including footnotes in code spans recorded as SPEC-GAP (recon N8).

**Exit criteria**:
- [ ] `TEST_FILTER=CharacterDescriptionTests make test` exits 0.
- [ ] `TEST_FILTER=DossierCLICoreTests make test` exits 0.

### Sortie 10: make acceptance

**Priority**: 5 — closes the mission.

**Entry criteria**:
- [ ] Sortie 9 exit criteria hold.

**Tasks**:
1. `scripts/acceptance.sh`, called as `make acceptance PROJECT=<path> [REF=<git ref>]`. Default `REF`: `dossier/v2-migration`. Skips with a message, exit 0, when `PROJECT` is absent (SD-4). Not in CI.
2. It never writes to `PROJECT`. It extracts `REF` with `git archive` into a `mktemp` directory (committed state, so unrelated uncommitted work in `PROJECT` can't affect the result), and all commands run on that copy.
3. Items: (1) `dossier validate` on every member's bundle: no errors, plus each manifest against `manifest-v2`; (2) `dossier add` of a view with its sidecar, printing whether every SD-7 field and the portrait and face `references` are there; (4) `reparto canonicalize --apply` on a copy, then `dossier create`, diffing lines; and on the unnormalized copy the §7 hashes before and after; (5) a check that `DossierCore`'s build doesn't link `Vision`, `ImageIO` or ArgumentParser.
4. Output: one PASS/FAIL per bundle and per item, codes per bundle, final count, exit non-zero on any failure. Output contains no character description text or prompts.
5. Nothing in the script names a real project or character; the character for item 2 is discovered by finding a member with a sidecar in `.generations/`.

**Exit criteria**:
- [ ] `make acceptance PROJECT=/nonexistent` exits 0 and prints a skip message.
- [ ] `grep -ciE 'granville' scripts/acceptance.sh Makefile` is 0 except for the REF default, which is a branch name without the project name.
- [ ] The script has no write to `$PROJECT`: `grep -n '\$PROJECT' scripts/acceptance.sh` shows reads only.

Running it on the real checkout is the supervisor's job after this sortie; results go in the report, not the repository.

## Parallelism Structure

**Critical Path**: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 (10 sorties).

**Parallel Execution Groups**: none. Every sortie compiles and tests the same package, and two agents building one SwiftPM checkout contend for the same build directory. Sorties 8 and 9 touch different files but need the CLI target's tests, so they stay sequential.

**Agent Constraints**: one agent at a time, and each builds, since each one's exit criteria are build gates. The skill's "supervising agent builds" rule exists to stop concurrent builds, which this order rules out.

## Decisions taken in breakdown (conventional defaults, not format questions)

| # | Decision | Why |
|---|----------|-----|
| B-1 | U-3: `PINNED.sha256` beside resources, plus a live comparison when the tag is present | Recon's suggested mechanism; works in CI with no sibling |
| B-2 | Fixtures come from a shallow clone of the tag in `.dossier-format/`, not vendored | 20+ MB of someone else's files; one pin in the Makefile; CI and local are the same path |
| B-3 | `DossierTabs` moves with the renderer | It's the `fields.json` list, which doesn't exist. REQUIREMENTS §2 lists it in `DossierCore`; the target doesn't change |
| B-4 | `--reference-roles` added to `dossier add` | SD-7 specifies it and §5's summary omits it (recon N8) |
| B-5 | `RECON_REPORT.md` is committed on the mission branch | Inside the mission-branch limit; reaches `development` with the PR |

## Local Dependency Map

<!-- Carried from RECON_REPORT.md. Sortie agents may read these paths; they may not edit them. -->

| Dependency | Resolved version | Local checkout | Status |
|------------|------------------|----------------|--------|
| intrusive-memory/SwiftReparto | `v0.2.1` (`94c4369`) | `~/Projects/package-collection/pkg/SwiftReparto` | LOCAL_AHEAD, version marker only (`a881de3`). `sibling()` resolves here locally |
| intrusive-memory/dossier-format | `v2.0.0-rc.3` (`8509790`) | `~/Projects/dossier-format` | **Don't read the working tree.** Use `.dossier-format/` |
| jpsim/Yams | `.upToNextMajor(from: "6.2.2")` | — | NO_LOCAL_CHECKOUT |
| apple/swift-argument-parser | `.upToNextMajor(from: "1.7.1")`, as in SwiftReparto | — | NO_LOCAL_CHECKOUT |

Read-only references: Personaje `tools/face_crop.swift` (`~/Projects/apps/Personaje`, read, never run), SwiftVinetas `Sources/**/ImageOutput.swift` at `v0.26.0` (`~/Projects/package-collection/pkg/SwiftVinetas`; sidecar and `iTXt` shapes, `git show v0.26.0:<path>`, the local checkout is ahead).

## Open Questions

_No blocking open questions identified during breakdown._

Recon's N1 to N9 are carried as non-blocking. N1 (phase 4), N2 (pages) are outside this mission. N3 to N9 become `SPEC-GAP` comments and report lines if a sortie meets one. U-1 and U-2 are entry steps in Sorties 8 and 2. U-4 is reported by acceptance. U-3 is B-1.

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 10 |
| Open questions | 0 |
| Dependencies mapped | 4 |
| Dependency structure | sequential |
| Refinement | Passes 1 to 5 run: 0 blockers; oversized sorties split during breakdown; priority annotated on the first sorties in order; no parallel groups; criteria rewritten as commands |
