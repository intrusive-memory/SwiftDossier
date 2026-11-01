---
type: recon-report
state: current
requirements_file: REQUIREMENTS.md
requirements_sha256: 1eca678060f63ef4e3a6ac836efc20f90a8f325afcd5ea4d58292ba87c2cf5d6
project_head: 1938da4
search_root: ~/Projects
generated: 2026-10-31
verdict: CLEAR
---

# RECON_REPORT.md — SwiftDossier

## Terminology

> **Mission** — A definable, testable scope of work.
> **Sortie** — An atomic, testable unit of work executed by a single agent in one dispatch.
> **Work Unit** — A grouping of sorties.

## Verdict

**CLEAR** — 61 assumptions checked: 57 confirmed, 0 blocking, 4 unverifiable.

This is the third run. The first found eight fixes, and rc.2 and Reparto 0.2.1 made
them. The second found seven more, and rc.3 made them. Instead of a further read, rc.3
was run as tests: a validator written blind from the text, and mutations of each rule.
The results are in **Test evidence** below.

## Assumption Findings

"Spec" is dossier-format `docs/DOSSIER-FORMAT.md` at `v2.0.0-rc.3`.

| ID | Kind | Claim | Locus | Verdict | Evidence |
|----|------|-------|-------|---------|----------|
| D-01 | A-FILE | Spec, four schemas, `tiers.json`, `review.json` exist | dossier-format | CONFIRMED | `git ls-tree -r v2.0.0-rc.3` |
| D-02 | A-FILE | `fields.json`, `tokens.json`, `template/` don't exist | dossier-format | CONFIRMED | same listing |
| D-03 | A-DATA | Sorted checksum (v2), files-order (v1) | dossier-format | CONFIRMED | Spec §5.3, Appendix A |
| D-04 | A-DATA | `prompts`: identity, portrait, subject | dossier-format | CONFIRMED | Spec §5.5 |
| D-05 | A-DATA | Write sequence and refresh adoption rules | dossier-format | CONFIRMED | Spec §5.6 |
| D-06 | A-DATA | Image naming | dossier-format | CONFIRMED | Spec §4 |
| D-07 | A-DATA | `references`, `tool`, `gateOverridden`, `notes` | dossier-format | CONFIRMED | Spec §6 |
| D-08 | A-DATA | `derivedFrom` shape, and the five kinds that need it | dossier-format | CONFIRMED | Spec §7 |
| D-09 | A-DATA | Discovery and orphan adoption | dossier-format | CONFIRMED | Spec §3 |
| D-10 | A-DATA | `tiers.json` check rows equal §8.3's table (10 IDs) | dossier-format | CONFIRMED | `data/tiers.json`; Spec §8.3 |
| D-11 | A-DATA | Face crop and `provenance.box` | dossier-format | CONFIRMED | Spec §8.5, §6 |
| D-12 | A-DATA | CHARACTER.md front matter, sections, footnotes | dossier-format | CONFIRMED | Spec §9 |
| D-13 | A-DATA | The page, and `fields.json` as its source | dossier-format | CONFIRMED | Spec §11 |
| D-14 | A-DATA | Every §14 code can be implemented from the spec, on what fixtures assert | dossier-format | CONFIRMED | 96 of 96 on a blind validator after one wording round; see Test evidence. Open choices no fixture depends on remain |
| D-15 | A-DATA | Appendix A's order matches §6; its remaining gaps precede phase 4 | dossier-format | CONFIRMED | Requirements §8 phase 4 now says so |
| D-16 | A-DATA | Synthetic v1 fixtures in both shapes | dossier-format | CONFIRMED | `examples/conformance.json`; checksum recomputed by hand |
| D-17 | A-DATA | v1 fixtures fit the v1 schema | dossier-format | CONFIRMED | Read, and run through a validator during step 1 |
| D-18 | A-DATA | Selection uniqueness, with `model` for samples | dossier-format | CONFIRMED | Spec §5.4 |
| R-01 | A-API | `CastMember.role`, `.manifest` are real fields | SwiftReparto | CONFIRMED | `CastMember.swift:87`, `:151` |
| R-02 | A-API | Parse, `generate(document:)`, `write(document:to:)` are public | SwiftReparto | CONFIRMED | `CastMarkdownParser.swift:102`, `CastMarkdownGenerator.swift:106`, `:158` |
| R-03 | A-API | `[CastMember].merging(_:)` | SwiftReparto | CONFIRMED | `CastMember+Merging.swift:67`, `:140` |
| R-04 | A-API | `canonicalName(_:)`, `hasCanonicalName` | SwiftReparto | CONFIRMED | `CharacterName.swift:106`, `:147` |
| R-05 | A-BEHAVIOR | `canonicalName` gives `names.json`'s results | SwiftReparto | CONFIRMED | Fixed in `v0.2.1`. All 18 run through a release build's `canonicalize --apply`: no mismatch |
| R-06 | A-API | `reparto canonicalize --apply` | SwiftReparto | CONFIRMED | `CanonicalizeCommand.swift:29`, `:49` |
| R-07 | A-BEHAVIOR | Write locality on a normalized file; second write identical | SwiftReparto | CONFIRMED | `RoleManifestTests.swift:324-333`, `:335` |
| R-08 | A-BEHAVIOR | Extras survive parse and write | SwiftReparto | CONFIRMED | `CastMember.swift:165`, `CastMemberCodingTests.swift:183-250` |
| R-09 | A-DATA | `voicePrompt`, `language`, `actor`, `voices: [String: [String]]` | SwiftReparto | CONFIRMED | `CastMember.swift:91-139` |
| R-10 | A-DATA | `CastRole` has the seven tiers | SwiftReparto | CONFIRMED | `CastRole.swift:42-62` |
| R-11 | A-FILE | "Who writes CAST.md" section | SwiftReparto | CONFIRMED | `REQUIREMENTS-personaje.md:79` |
| R-12 | A-DEP | `DossierCore` can read CHARACTER.md's YAML | SwiftReparto | CONFIRMED | Requirements §2 now lists Yams, range as in Reparto's `Package.swift` |
| V-01 | A-DATA | Sidecar has `generatedAt` | SwiftVinetas | CONFIRMED | `ImageOutput.swift:61`, `:133` |
| V-02 | A-DATA | `references[]` has `source`, `sha256` and sizes | SwiftVinetas | CONFIRMED | `ImageOutput.swift:260-295` |
| V-03 | A-DATA | PNG embeds the same metadata (`iTXt`, keyword `vinetas`) | SwiftVinetas | CONFIRMED | `ImageOutput.swift:429`, `:452`, `:462` |
| V-04 | A-DATA | Sidecar supplies §6's image keys, except `tool` | SwiftVinetas | CONFIRMED | `ImageOutput.swift:61-256` |
| V-05 | A-DATA | `generatedAt` is RFC 3339 with `Z`, whole seconds | SwiftVinetas | CONFIRMED | `ImageOutput.swift:347-348` |
| V-06 | A-BEHAVIOR | `computeChecksum` sorts, joins, hashes | SwiftAcervo | CONFIRMED | `CDNManifest.swift:263-268` |
| P-01 | A-FILE | `tools/face_crop.swift` is the crop reference | Personaje | CONFIRMED | `face_crop.swift:14-26` |
| P-02 | A-BEHAVIOR | `record.py` uses path order, hashes unsorted | Personaje | CONFIRMED | `record.py:45`, `:49-51`. Adjudicated from the spoke's split verdict by reading the lines. The docstring's "sorted" is wrong |
| P-03 | A-BEHAVIOR | `render_dossier.py` shows all the content SwiftDossier §4 lists | Personaje | CONFIRMED | `render_dossier.py:83`, `:289-294`, `:436`, `:448-452`, `:455` |
| P-04 | A-BEHAVIOR | Nothing depends on a render bridge | requirements | CONFIRMED | §8 phase 3 and Q2 drop it; `render_dossier.py` remains only as a content reference and a warning |
| P-05 | A-BEHAVIOR | Its page uses relative paths | Personaje | CONFIRMED | `render_dossier.py:62-63`, `:238`, `:244`, `:397` |
| P-06 | A-DATA | Granville has nine v2 bundles, each pointed at | Granville | CONFIRMED | `CAST.md`; each manifest |
| P-07 | A-DATA | v1 manifests remain on `experiment/gemini-voices` | Granville | CONFIRMED | `git show`, one bundle read; the other eight not checked |
| P-08 | A-DATA | Sidecars exist for acceptance 2 | Granville | CONFIRMED | 80 in `.generations/`, for four characters plus `scenes` |
| P-09 | A-DATA | Granville's CAST.md isn't normalized | Granville | CONFIRMED | Key order differs between members |
| P-10 | A-DATA | Selected samples use the spec's variant names | Granville | CONFIRMED | Fixed in `1922640`; checksums unchanged |
| H-01 | A-CONFIG | Xcode 27, Swift 6.4 available | toolchain | CONFIRMED | `xcodebuild -version`: Xcode 27.2; Swift 6.4.2 |
| H-02 | A-DEP | Reparto fits macOS 26 / iOS 26, Swift 6.2 | SwiftReparto | CONFIRMED | `Package.swift`: tools 6.2, `.macOS(.v26)`, `.iOS(.v26)` |
| H-03 | A-DEP | SD-13's keyword list covers the schemas | requirements | CONFIRMED | A schema walk at rc.2 finds exactly those keywords. It needs `type` as an array and a relative `$ref` |
| H-04 | A-BEHAVIOR | Granville's nine have no errors (acceptance 1) | Granville | CONFIRMED | Two throwaway validators: no errors. Warnings: `W-INCOMPLETE`, `W-ROLE`, `W-VOICE-PROMPT` |
| H-05 | A-DEP | `DossierCore` can stay free of ArgumentParser (acceptance 5) | SwiftReparto | CONFIRMED | `Package.swift`: only `RepartoCLICore` links it |
| H-06 | A-DATA | SD-3 is accurate about v1 fixtures | requirements | CONFIRMED | The aside is gone; both v1 fixtures validate against the v1 schema |
| H-07 | A-BEHAVIOR | A Reparto write keeps §7's `castMember` hash | SwiftReparto | CONFIRMED | Three fixtures through a real `canonicalize --apply`: unchanged. U-2 still covers Swift's own encoding |
| H-08 | A-FILE | SwiftDossier has its Makefile, CI and sibling pattern | repo | CONFIRMED absent | Not present. They're build work, listed for breakdown |
| N-01 | A-BEHAVIOR | SD-11: `refresh` adopts only what makes a valid manifest | requirements | CONFIRMED | §5.6's rules, by reading; no writer exists yet |
| N-02 | A-BEHAVIOR | SD-12: Reparto's first write keeps §7's hash, except as listed | SwiftReparto | CONFIRMED | Exceptions named, each observed in the second run |
| N-03 | A-BEHAVIOR | Acceptance 1: `validate` can meet every fixture in CI, in phase 1 | requirements | CONFIRMED | The template is a parameter; `conformance.json` names it |

### Test evidence

| Test | Result |
|------|--------|
| Author's checker on `conformance.json` | 96 of 96 |
| Blind validator, first run on 75 fixtures | 70 of 75. All five were `W-POINTER` wording; the text was fixed, not the fixtures. `CAST.md`'s layout was also found unstated |
| Blind validator, after the text fixes, on 96 fixtures | 96 of 96. Its gender list, guessed before the text gave one, was replaced |
| Mutations | The six requested and every extra one rerun are caught, except one the spec doesn't require and three recommended-only rows |
| `names.json` through Reparto 0.2.1 | 18 of 18 |
| `castMember` hash across a real Reparto write | Unchanged, including `1.5`, `0755`, `no` and multi-line values |
| Granville's nine, both validators | No errors |

**What this doesn't show.** Both validators are throwaway Python and their author read the
fixtures after writing. Nothing has run through Swift, ImageIO or Vision. The extra mutations
for `W-SHAPE`, `W-ORPHAN`, `W-PAGE-EXTERNAL`, `W-VOICE-ELSEWHERE`, `E-CAST` and names were
answered with fixtures, and those fixtures pass, but those specific mutants weren't rerun.

### Carried to `## Open Questions` in breakdown

None blocks phases 1 and 2.

| # | Item | Why it can wait |
|---|------|-----------------|
| N1 | Appendix A: v2-required fields with no v1 source, reference paths after renames, `rejected` destination | Phase 4, and §8 says they come first |
| N2 | `W-PAGE-EXTERNAL`: CSS comments, `<template>`, page found by name or lookup | Pages wait on the template |
| N3 | §2: whitespace before the first step, and which characters are whitespace | The table covers real cues; Reparto is the reference |
| N4 | §3: a leading `..` or `/` in a pointer | No real project |
| N5 | `W-VOICE-*`: no `voices.voxalta`, no prompt in provenance | None in the acceptance project |
| N6 | Provider-case collision gives a different winner per run in Reparto | No real project; a small Reparto bug |
| N7 | Rules with no code: page at another path, unsorted `files`, `manifestVersion` missing | Improvised `E-SCHEMA` is defensible |
| N8 | SD-6 and `source/`, `training/`; `--reference-roles` missing from §5; `W-FOOTNOTE` in code spans | Editorial, or fix during build |
| N9 | About 30 more choices the blind validator marked open, on which no fixture depends | When the Swift validator meets one, raise it in dossier-format (SD-1) |

## Local Dependency Map

| Dependency | Declared | Target revision | Local checkout | Local HEAD | Status |
|------------|----------|-----------------|----------------|-----------|--------|
| intrusive-memory/SwiftReparto | §2, SD-12: "0.2.1 or later"; sibling pattern planned | `v0.2.1` (`94c4369`) | `~/Projects/package-collection/pkg/SwiftReparto` | `a881de3` | LOCAL_AHEAD, version marker only |
| intrusive-memory/dossier-format | SD-2: resources from a pinned revision | `v2.0.0-rc.3` (`8509790`) | `~/Projects/dossier-format` | `5f44840` | LOCAL_BEHIND, by a merge commit; no content difference |
| jpsim/Yams | §2: `.upToNextMajor(from: "6.2.2")` | — | — | — | NO_LOCAL_CHECKOUT |
| apple/swift-argument-parser | §2 `DossierCLICore`; no version given | — | — | — | NO_LOCAL_CHECKOUT |

Read-only references, not dependencies:

| Project | Revision read | Local HEAD | Status |
|---------|---------------|-----------|--------|
| SwiftVinetas | `v0.26.0` (`07b3e61`) | `458e829` | LOCAL_AHEAD |
| SwiftAcervo | `v0.25.0` (`87ec22c`) | `13e2879` | LOCAL_AHEAD, untracked doc |
| Personaje | f19d8a2 | f19d8a2 | LOCAL_MATCHES |
| podcast-granville | `1922640` (`dossier/v2-migration`) | `1922640` | LOCAL_MATCHES; uncommitted work in two other bundles |

### Drift and ambiguity notes

- **No lock file exists,** so every dependency above is UNPINNED by definition until `Package.swift` is written. All were verified at the tag, not at a local HEAD.
- **Reparto's sibling pattern:** Reparto is a leaf, but SwiftDossier will use `sibling()` for it, per §2. On this machine that will resolve to `a881de3` while CI resolves a tag. Today the two differ only in the version marker.
- No checkout is AMBIGUOUS. `~/Projects/worktrees` no longer exists.
- **New warning in the acceptance project:** four bundles report `W-VOICE-PROMPT`, because
  `425c2cd` edited their `voicePrompt` after the `.vox` was made. It's a true finding, not
  a tool fault, and acceptance 1 asks only for no errors.

## Unverifiable

| ID | Claim | Why | What would settle it |
|----|-------|-----|----------------------|
| U-1 | Face crop and page copies are byte-identical for the same input (§4) | ImageIO's output can't be read from source | A test in phase 2, on the versions CI uses |
| U-2 | A `JSONEncoder` encode of `CastMember`, with extras, gives canonical JSON | Encoded form read from source, not run. `/` is escaped unless `.withoutEscapingSlashes` is set | A test against `valid/non-ascii-underfive` |
| U-3 | SD-2's test can compare resource copies with the pinned revision | Needs a mechanism; CI has no dossier-format checkout. Likely a checked-in hash list | Decide in breakdown |
| U-4 | Vision finds a face in real portraits consistently across OS versions | Fixtures have no faces | `make acceptance` against Granville; hand-set boxes as the fallback |

## Handoff to breakdown

- `CONFIRMED` facts are safe as sortie entry criteria without re-checking.
- `UNVERIFIABLE` items become an `## Open Questions` entry or an explicit verification
  step in the first dependent sortie's entry criteria, never a silent assumption.
- Sidecar folding (SD-7): `character`, `bundle` and `glosa` are sidecar keys with no
  §6 entry; §6's "unknown keys are preserved" applies. The legacy writer's `prompt` may
  already be composed (V-04), and sidecars have no `tool`, so `--provenance` supplies it.
- Sidecars exist for four characters only, so acceptance 2 must name one of them.
