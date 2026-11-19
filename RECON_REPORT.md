---
type: recon-report
state: current
requirements_file: docs/REQUIREMENTS-single-file-views.md
requirements_sha256: de3cee2730539d1cb3aa7326ea09065abc51906e24622428cab5b0160ae34890
project_head: 6dacdef
search_root: ~/Projects
generated: 2026-11-18
verdict: CLEAR
---

# RECON_REPORT.md: SwiftDossier single-file views (0.8.0)

## Terminology

> **Mission**: a scope of work that can be defined and tested.
> **Sortie**: one unit of work that one agent does in one dispatch, and that can be tested.
> **Work Unit**: a group of sorties.

## Verdict

**CLEAR** after two passes. 24 assumptions checked.

- **Pass 1 (A-01 to A-18):** found the four findings below.
  - F-1 (fixtures), F-2 (editor keys) and F-3 (saving a location) were decided by the user as D-3, D-4 and D-5.
  - F-4's corrections of fact are in the requirements.
- **Pass 2 (A-19 to A-24):** checked the facts those decisions rest on.
  - Two were REFUTED: A-20 (the fields.json key list) and A-23 (section ranges).
  - A-24 was REFUTED for §9.2 (no rule says where a missing section goes) and confirmed for §16.3.
  - All three are corrected in the requirements: D-6 (`role` is editable), SFV-5's insertion rule, and the range tracking SFV-5 needs.
- Nothing blocking remains. The requirements are on file at the hash above.

## Assumption Findings

| ID | Kind | Claim | Verdict | Evidence |
|----|------|-------|---------|----------|
| A-01 | A-API | `CharacterDescription` has `init(text:)`, `frontMatter`, `frontMatterProblem`, `sections`, `section(named:)`, `openQuestions`, `footnoteCheck()` | CONFIRMED | `Sources/Dossier/Description/CharacterDescription.swift:79,118,138,201,207,212,224` |
| A-02 | A-BEHAVIOR | `setFrontMatter(_:_:)` changes only the key's lines and throws if another key would change | CONFIRMED | `:151`, check `:174-183`. Comments inside the edited key's span are replaced and lost. A no-op set leaves the text unchanged (`:162`) |
| A-03 | A-API | `markEdited(_:)` removes a name from `draft.generated` | CONFIRMED | `:190` |
| A-04 | A-API | `CharacterDescription.write(to:)` | STALE | `:284` `write(to bundle: inout DossierBundle) throws`. It goes through ManifestWriter and works on bundles only. There is no LOCATION.md equivalent |
| A-05 | A-INVARIANT | No body-section write exists | CONFIRMED | No `setSection` anywhere. Sections come from `CharacterDocument.parseSections` (fence-aware) |
| A-06 | A-INVARIANT | No LOCATION.md reader exists | REFUTED in part | There is no public `LocationDescription`. `DossierBundle.swift`, `Rendering/LocationsPage.swift` and `Validation/Validator.swift` read LOCATION.md internally |
| A-07 | A-API | `LocationsIndex.load(_ url:)` reads from disk only | CONFIRMED | `Sources/DossierCore/Locations.swift:187`. Reading and parsing are inline (`:187-217`), and the error is `LocationsError.indexUnreadable(String)` with 10 detail messages. `FrontMatter.split` is shared (`CharacterDocument.swift:9`) |
| A-08 | A-API | `LocationsView(projectDirectory:selectedBundleURL:refreshToken:project:)` | STALE (signature detail) | `LocationsView.swift:44-47`: `selectedBundleURL: URL?` has no default; `refreshToken` and `project` are defaulted. The store is `<index dir>/.locations-page/` |
| A-09 | A-API | `DossierView` takes a bundle | CONFIRMED | `DossierView.swift:124,257`: `init(bundleURL:cast:refreshToken:project:onField:header:)` |
| A-10 | A-DATA | `docs/DOSSIER-FORMAT.md` §9 and §16 | STALE (location) | Not in this repo. dossier-format v2.1.0 (the Makefile pin) has §9 at `:909` (§9.1 `:913`, §9.2 `:936`) and §16 at `:1303` (§16.3 LOCATION.md `:1409`, §16.6 page `:1510`). §16.3 requires `type` and `location`, makes `theme` optional, and requires no sections (`## Blocking` and `## Views` are recommended) |
| A-11 | A-DATA | `fields.json` lists the §9.1 keys | STALE | `Sources/DossierCore/Resources/fields.json` is the page field list (§11), consumed from dossier-format under SD-2. Its `frontMatter` sources cover role, age, pronouns, occupation, languages, artStyle and sampleLine. It **omits `aliases`** and has **no LOCATION.md fields** |
| A-12 | A-DATA | Fixture `HUNTER.dossier/CHARACTER.md` (granville) | STALE | Only in the private repo `~/Projects/podcasts/granville`. The `aliases` comments are on lines 7-9 and `age:` is on line 11. **SD-4: this repo is PUBLIC, so fixtures must be synthetic** |
| A-13 | A-DATA | Fixture `locations-project` | STALE (location) | It lives in Escribir `TestFixtures/locations-project` (a186d5a). It says "Synthetic data only", so it may be copied here |
| A-14 | A-CONFIG | Makefile targets | CONFIRMED with a caveat | `build test test-ios fixtures clean acceptance`. There is no `lint` or `format` target. `test-ios` passes `ARCHS=arm64`, against the house rule that iOS never pins an arch (not this mission's concern) |
| A-15 | A-INVARIANT | DossierUI imports no host package | CONFIRMED | The imports are Foundation, SwiftUI, WebKit, Dossier, DossierCore and SwiftReparto, plus system modules |
| A-16 | A-BEHAVIOR | The front-matter writer is in one place | CONFIRMED (inline) | About 150 lines inside `CharacterDescription` (`setFrontMatter`, `keySpans`, `rendered`, and others). The extraction SFV-4 asks for is new work |
| A-17 | A-BEHAVIOR | Is there a comment or anchor detector for a key's lines? | CONFIRMED (none) | `keySpans` trims trailing `#` lines only. Anchors are caught only after the fact |
| A-18 | A-CONFIG | Platforms and tools | CONFIRMED | `Package.swift:1,10-11`: tools 6.2, macOS 26, iOS 26, Swift 6 |

| A-19 | A-BEHAVIOR | LOCATION.md readers can adopt `LocationDescription` | CONFIRMED with a correction | `DossierBundle.swift:34-39` already reads LOCATION.md through `CharacterDocument` (lossy UTF-8). `Validator.swift:413-419` (`E-NAME-MISMATCH`) and `:553-559` (`W-FOOTNOTE`) read it from there: drop-in. `LocationsPage.swift:~308` reads strict UTF-8 itself and is NOT a drop-in, so it is kept as is (SFV-4) |
| A-20 | A-DATA | fields.json front-matter keys are role, age, pronouns, occupation, languages, artStyle, sampleLine | REFUTED | The `from: frontMatter` keys are age, pronouns, occupation, languages, sampleLine, artStyle, draft.generatedBy and draft.reviewedAt. `role` comes `from: record`. Fixed in SFV-9, with `role` editable (D-6) |
| A-21 | A-DATA | Escribir `locations-project` is synthetic and usable | CONFIRMED | Bundles HARBOR-LIGHT (rich: `theme`, `## Views`, a footnote), SALT-STORE (minimal) and DRY-DOCK (orphan, not in the index). THE OLD QUAY has no manifest by design. The body says "Synthetic data only", and there are no podcast names |
| A-22 | A-CONFIG | `make acceptance` can run a round trip | CONFIRMED partly | `Makefile:176` → `scripts/acceptance.sh` (bash and Python driving `bin/dossier`, which SKIPs a missing project at `:41-44`). It runs no test target and is in no CI workflow. SFV-14 now runs a suite through `make test TEST_FILTER` with a path variable |
| A-23 | A-BEHAVIOR | `parseSections` keeps ranges | REFUTED | `CharacterDocument.swift:131-145` keeps heading and content strings only and normalises line endings. SFV-5 now names the range tracking it needs |
| A-24 | A-DATA | §9.2 gives an insertion rule; §16.3 gives fields and sections | REFUTED / CONFIRMED | §9.2 (`:936-964`) gives the order and the heading-match rule only. §16.3 (`:1409-1453`): `type` and `location` are required, `theme` is optional, and the sections are free (Blocking and Views are recommended). SFV-5 now sets the insertion rule |

### Blocking findings (pass 1, all resolved)

#### F-1: The real fixtures can't come into this public repo (A-12, A-13)

SFV-14 and SFV-16 name HUNTER (private granville) and locations-project (Escribir) as fixtures. SD-4 bans private content here.

**Options:**
1. *(recommended)* Copy Escribir's `locations-project`, which is already synthetic. Write a synthetic CHARACTER.md with HUNTER's shape: an `aliases:` list with trailing `#` comments and a plain `age:`. Run the real HUNTER through `make acceptance PROJECT=~/Projects/podcasts/granville`, which is local-only and skipped in CI.
2. Build both fixtures synthetically and drop the real-file check.

#### F-2: Which keys an editor offers (A-11)

SFV-8 and SFV-9 say "the §9.1 keys `fields.json` lists".
- For characters this gives 7 keys. `aliases` is not among them, so it would be read-only for every character, not only for those with comments.
- For locations the file lists nothing, so SFV-10 has no field source.
- SD-1 and SD-2 say not to restate format data in Swift.

**Options:**
1. *(recommended)* Characters: keep fields.json as the source, and accept that `aliases` is read-only in 0.8.0. Locations: the editor offers §16.3's two writable keys (`location` and `theme`) from a small internal list that cites §16.3, and lists any other key read-only. This is a narrow exception to SD-2, recorded as a decision.
2. Add a "description fields" data file to dossier-format, cut a release, and pin it. This is cleaner, but it adds a cross-repo release before this mission can start.
3. Generic editors: a field for every key present in the file, with no list. This drops the "fields.json lists" rule.

#### F-3: Saving a LOCATION.md into a bundle (A-04)

SFV-12a has Personaje save through "the location equivalent" of `write(to:)`. That doesn't exist, and the existing one takes `inout DossierBundle`, not a URL.

**Options:**
1. *(recommended)* Put `LocationDescription.write(to: inout DossierBundle)` in scope, mirroring the character one.
2. Leave bundle saving to Personaje.

#### F-4: Corrections of fact (A-06, A-08, A-10), with no decision needed

- The governing format document is dossier-format v2.1.0's `docs/DOSSIER-FORMAT.md`, not a file in this repo.
- The `LocationsView` signature has `selectedBundleURL: URL?` with no default.
- LOCATION.md is read internally by the validator and the page renderer, so `LocationDescription` should reuse that code, not add a second parser.

## Local Dependency Map

SwiftDossier is a library and tracks no `Package.resolved`, so every dependency resolves at build time (UNPINNED). No requirement rests on a dependency's API.

| Dependency | Declared | Local checkout | Local HEAD | Status |
|------------|----------|----------------|-----------|--------|
| intrusive-memory/SwiftReparto | `from: 0.3.0` | `~/Projects/package-collection/pkg/SwiftReparto` | `fc6cad4` (v0.4.0) | UNPINNED |
| jpsim/Yams | `from: 6.2.2` | none | none | UNPINNED |
| apple/swift-argument-parser | `from: 1.7.1` | none | none | UNPINNED |
| dossier-format (Makefile `fixtures`) | v2.1.0 | `~/Projects/worktrees/dossier-format-v2.1.0` | v2.1.0 | matches the pin |

### Drift and ambiguity notes

- Main checkout `~/Projects/package-collection/pkg/SwiftDossier` is 1 local commit ahead (a stale `0.6.0-dev` marker) and 8 behind origin/development. The mission works in `~/Projects/worktrees/SwiftDossier-sfv` (branch `mission/single-file-views`, from origin/development 6dacdef).

## Handoff to breakdown

- The CONFIRMED rows are safe entry criteria.
- F-1 to F-4 and pass 2's corrections are in the requirements (D-3 to D-6, SFV-4, SFV-5, SFV-9, SFV-14).
- Plan against the requirements, not against this report.
