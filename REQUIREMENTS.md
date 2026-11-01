---
type: requirements
state: accepted
updated: 2026-11-01
---

# SwiftDossier — Requirements

SwiftDossier is the Swift implementation of
[dossier-format](https://github.com/intrusive-memory/dossier-format): it
reads, writes, validates, migrates and renders `.dossier` bundles, and ships
the `dossier` CLI. It is the only writer of `manifest.json`.

It does **not** define the format (that's dossier-format) and it does **not**
generate images, voices or descriptions (that's SwiftPersonaje, which links
it). **The format is [dossier-format `docs/DOSSIER-FORMAT.md`](https://github.com/intrusive-memory/dossier-format/blob/development/docs/DOSSIER-FORMAT.md)**
(format version 2), with its schemas and `data/tiers.json`. Every rule about
what a bundle *is* is cited from there (`DOSSIER-FORMAT §n`); this document
only says how the Swift package does it.

**Source.** This text replaces Personaje `docs/REQUIREMENTS-DOSSIER-BUNDLE.md`
§1 (D2, D14), §4, §5 (detection), §7 (as implementation), §8 (migration) and
§9. The format parts of that document already live in dossier-format
REQUIREMENTS. *Accepted 2026-10-31.* The Personaje document becomes a pointer to
the two.

## 1. The specification

dossier-format's specification, schemas, tier table and conformance fixtures
are written and tagged **`v2.0.0-rc.3`** (2026-10-31), the revision this package
pins. Its page template, field list and design tokens are not written.

| # | Rule |
|---|------|
| SD-1 | **`docs/DOSSIER-FORMAT.md` is the specification.** Where it is silent, raise the question in dossier-format; don't decide it here. |
| SD-2 | **Data files are consumed, never restated:** `schemas/*.json`, `data/tiers.json`, `data/review.json`, and later `data/fields.json`, the tokens and the template, copied as resources from a pinned dossier-format revision. A test fails if the copies differ from that revision. |
| SD-3 | **Every manifest this package writes validates** against `schemas/manifest-v2.schema.json`; every v1 fixture validates against `manifest-v1.schema.json`. The v1 fixtures are `examples/warnings/W-V1*`. `E-SCHEMA` comes from the schema files, through SD-13's evaluator; the rules are not restated in Swift (SD-2). |
| SD-4 | **Fixtures are synthetic.** This repository is public (§10 Q1), so nothing from a private project is copied into it: no images, descriptions, CAST.md or manifests from podcast-granville or any other podcast. Tests use dossier-format's `examples/` and its `conformance.json`, which includes synthetic v1 bundles of both Appendix A shapes (v1 manifest in a `.dossier` directory or a plain one, sidecars, retired kinds, path-order checksum). Real projects are checked by `make acceptance PROJECT=<path>`, which runs against a local checkout, skips when it is absent, and never runs in CI. |

## 2. Targets

| Target | Depends on | Contains |
|--------|------------|----------|
| `DossierCore` | Foundation, CryptoKit, SwiftReparto, Yams | Read-only. `Cast.load(_:)` (discovery from CAST.md, DOSSIER-FORMAT §3), `DossierBundle.open(at:)`, `Manifest`, `Asset`, `AssetKind`, `assets(kind:variant:)`, `selectedAsset(kind:variant:)`, `sampleURL(variant:)`, `identityPrompt`, `artStyle` (CHARACTER.md front matter, UD20), `pageURL`, `completeness(tier:)`, `stale()`, `DossierTabs`. No writers. Linked by the Vinetas app. |
| `Dossier` | `DossierCore`, ImageIO, Vision | Writers: `DossierBundle.create(character:role:in:)`, `add`, `select`, `reject`, `remove`, `delete()`, `deriveFace(box:)`, `refresh()`, `setPrompt(_:_:)`, `validate(template:)`, `validate(cast:template:)`, `renderPage()`, `candidates(kind:variant:in:)`, `migrate`, `CharacterDescription.read/write`, `footnoteCheck()`, `openQuestions`. Linked by SwiftPersonaje. |
| `DossierCLICore` | `Dossier`, ArgumentParser | Command logic, unit-testable without a subprocess. Not a product (SwiftReparto D-6). |
| `dossier` | `DossierCLICore` | The executable (§5). |

- **Yams** reads CHARACTER.md's front matter, in the same version range as
  SwiftReparto's (`.upToNextMajor(from: "6.2.2")`). It already arrives through
  Reparto, which doesn't re-export it, so it adds no new code to the build.
- **No MLX, no network, no generation.** SwiftDossier never depends on
  SwiftVinetas, SwiftEchada or SwiftPersonaje.
- **macOS 26 / iOS 26, Swift 6.2,** strict concurrency.
- **Sibling pattern** for the intrusive-memory dependency (SwiftReparto),
  per `toggle-sibling-libraries`.
- Builds and tests run through the Makefile and `xcodebuild` (XcodeBuildMCP
  locally). No `swift build` / `swift test`.

## 3. Writes

| # | Requirement |
|---|-------------|
| SD-5 | **Every mutation:** copy or write the file → rescan `files` → recompute `manifestChecksum` → write the manifest to a temporary file → replace → re-read and compare (DOSSIER-FORMAT §5.6). The checksum is the **sorted** form (§5.3, SwiftAcervo's `computeChecksum`); a v1 manifest is verified with the path-order form (Appendix A), which is what Personaje's `tools/record.py` writes. |
| SD-6 | **`add` names image files** `images/<kind>[-<variant>]-<sha8>.png` (DOSSIER-FORMAT §4). Voice files keep their producer's names. The source file is copied, never moved, and never modified. |
| SD-7 | **`add` folds provenance in** (DOSSIER-FORMAT §6). Given a Vinetas sidecar (`--sidecar`) or a PNG with Vinetas's embedded metadata, it records every §6 key the sidecar has; the sidecar's `generatedAt` becomes the asset's `createdAt`. `references[].source` is **never** recorded: each reference becomes `{sha256, path, role}`, where `path` is the bundle path of the asset with that sha256 (omitted when none matches) and `role` comes from `--reference-roles portrait,face`. Extra provenance (`tool`, notes, `gateOverridden`) is merged from `--provenance <json>`. |
| SD-8 | **`select`** demotes the previous `selected` of the same `kind` + `variant` to `candidate`; for a `voiceSample`, of the same `kind` + `variant` + `model` (DOSSIER-FORMAT §5.4). `--select` on `add` does both in one write. |
| SD-9 | **Nothing is deleted implicitly.** `remove` deletes one asset and its file; `delete()` deletes the bundle. Both are explicit; the CLI asks for `--yes`. |
| SD-10 | **`derivedFrom`** is written in the §7 array shape on `face`, `view`, `expression`, `voiceSample` and `dossier`. `stale()` compares each input's sha256 with the current selection, member, bundle and template. |
| SD-11 | **`refresh`** adopts files a writer didn't put there by the DOSSIER-FORMAT §5.6 rules, which include when a sample can't be adopted. Anything else stays unclassified and the command reports why. Orphan adoption follows §3 exactly. |
| SD-12 | **`CAST.md` is written only through SwiftReparto.** `create` adds the member if absent and sets `role` and `manifest`, which are real `CastMember` fields; this package requires SwiftReparto 0.2.1 or later, whose `canonicalName` matches dossier-format's `examples/names.json`. SwiftDossier owns those two fields and no others (SwiftReparto `REQUIREMENTS-personaje.md` "Who writes CAST.md"). **On a CAST.md SwiftReparto has already written, a write that changes lines of members the call didn't touch is a bug** (Reparto RP-P16). The first write to a hand-edited or 0.1.0-written file normalizes key order and quoting for every member (Reparto RQ-23 withdrawn); that is Reparto's behavior, not a SwiftDossier bug. It doesn't change a member's DOSSIER-FORMAT §7 hash, with these exceptions, which lose data or change a path: a `voices` provider value of the wrong type is dropped, a provider-case collision keeps one value, and absolute paths under the project become relative. `migrate` and `create` report any of these before writing, and say so when the file was not yet normalized (`generate(parse(x)) != x`). They suggest `reparto canonicalize --apply` first, which also renames non-canonical members. A synthetic CAST.md with Granville's layout quirks is the regression fixture, checked both ways; Granville's own is checked by `make acceptance`. *Restated 2026-10-22:* it said any reorder of untouched members was a bug, which Reparto's whole-file writer can't meet on a first write. |
| SD-13 | **A small JSON Schema evaluator lives in `Dossier`,** for exactly the keywords the pinned schemas use: `type`, `required`, `properties`, `additionalProperties`, `items`, `enum`, `const`, `pattern`, `minimum`, `minLength`, `minItems`, `allOf`, `oneOf`, `if`/`then`, and `$ref` to another of the pinned schemas (`$id`, `$schema`, `title` and `description` are ignored). `type` may be an array and `$ref` may be relative. An unsupported keyword in a schema is a failure, not a pass, and a test checks that for every pinned schema. It is tested against `conformance.json`. No third-party schema package. |
| SD-14 | **Update status** (DOSSIER-FORMAT §5.7; needs dossier-format `v2.0.0-rc.4`). `withUpdate(label:_:)` holds a marker for the length of a block: it writes it atomically, renews it in the background before it expires, and removes it after the block's last manifest replacement, including when the block throws. A single mutation (SD-5) holds one unless the caller already does, so a sequence of mutations shows as one update. `updateStatus(at:)` in the read-only core answers §5.7's question for any reader, and the update fixtures in `conformance.json` test it. The CLI adds `dossier update run <bundle> -- <command>`, and `begin`, `renew` and `end` for an update that spans separate commands. A marker never blocks a write: it is a signal, not a lock. |

## 4. Face crop, validation, page

- **Face crop (DOSSIER-FORMAT §8.5):** Vision `VNDetectFaceRectanglesRequest` on the
  selected portrait; the largest face; a square 1.8× the box's larger side,
  centred, clamped, never upscaled; PNG. `deriveFace(box:)` takes an optional
  hand-set box, recorded in provenance and reused by later refreshes. The
  output must be byte-identical for the same portrait and box. Reference:
  Personaje `tools/face_crop.swift`.
- **Validation (DOSSIER-FORMAT §14):** read-only, every finding with its
  code (`E-…`, `W-…`) and the §8.3 completeness report, tier rows read from
  `data/tiers.json` and check rows implemented by ID. `validate(cast:template:)`
  adds the CAST.md checks and orphans. The template compared against (§11) is a
  parameter, here and on `stale()`: `nil` until a template ships, the bundled one
  after, and the one `conformance.json` names in tests. Exit status: 0 clean,
  1 warnings only, 2 errors.
- **Page (DOSSIER-FORMAT §11):** `renderPage()` writes `<CHARACTER>-dossier.html`
  from CHARACTER.md, the manifest, the CAST.md member and the selected
  originals, through the dossier-format template. Page copies are made with
  ImageIO at fixed settings and embedded as `data:` URIs; nothing is stored.
  Output is deterministic: a test renders the same bundle twice and compares
  bytes. **Content parity:** every piece of content Personaje's
  `tools/render_dossier.py` shows (sources list, completeness, integrity
  banner, provenance lines, footnotes in citation order) appears in the new
  page, in the new layout.

## 5. CLI

All commands accept `--json` (one object on stdout; errors as
`{"error": {...}}` with a non-zero exit). Bundles are given by path.

```
dossier create   "THE PRACTITIONER" --role supporting --in characters/ [--cast CAST.md]
dossier add      <bundle> <file> --kind view --variant front [--select] [--sidecar x.json] [--provenance '{...}']
dossier select | reject | remove  <bundle> <path>
dossier list     <bundle> [--kind view] [--variant front] [--status selected]
dossier prompt   <bundle> identity|portrait|subject [--set "<text>" | --file f] # DOSSIER-FORMAT §5.5
dossier face     <bundle> [--box x,y,w,h]
dossier check    <bundle>                                 # CHARACTER.md: front matter, sections, footnotes, open questions
dossier validate <bundle> | --cast CAST.md
dossier render   <bundle> | --cast CAST.md
dossier refresh  <bundle>
dossier candidates <bundle> [--kind portrait]            # what's in .generations/<CHARACTER>/
dossier migrate  characters/SHANE --cast CAST.md [--apply]   # dry run by default (§6)
```

## 6. Migration (`dossier migrate`)

Implements DOSSIER-FORMAT Appendix A, per bundle, dry run by default listing
every change; `--apply` performs it. The synthetic v1 bundles (SD-4) are the test fixtures.
Granville's nine are already on version 2, so a local acceptance run uses the
version 1 manifests on its `experiment/gemini-voices` branch. The steps, in order:
rename `<NAME>/` to `<NAME>.dossier/` if needed; fold sidecars into
provenance (references mapped by sha256, absolute paths dropped; round and
seed from the old file name into `provenance.round` / `provenance.seed`);
move candidates and sidecars to `.generations/<NAME>/`; map retired kinds
(variant from `label`); rename selected images to content names; rewrite
`derivedFrom` in the §7 shape; update CAST.md pointers through Reparto;
write the v2 manifest; render the page and delete `dossier.html`; validate.
An asset that can't be mapped stays an unclassified file and is reported
(Appendix A). Until the renderer ships (§8 phase 3), `migrate` stops before the
page and says so.

## 7. Format additions

The three this package proposed (top-level `prompts`, `provenance.tool` as
an object, `provenance.copiedFrom`) were accepted into dossier-format v2 on
2026-10-19 (DOSSIER-FORMAT §5.5, §6). Further additions go to dossier-format
first (SD-1).

## 8. Phases

1. **Core:** `DossierCore` reads v1 and v2 manifests; `Dossier` create, add,
   select, reject, remove, list, prompt, refresh, validate; the CLI for
   those. Tests against the synthetic fixtures (SD-4).
2. **Face crop and `check`.**
3. **Page renderer** with the dossier-format template (blocked on the
   template, SD-2). `dossier render` waits for it: there is no bridge (Q2). The
   template's mission follows phase 1 directly. **`render_dossier.py` must not
   be run on a v2 bundle;** it rewrites the manifest with a path-order checksum.
4. **Migration,** for any remaining v1 bundle. Appendix A's order is settled, but
   not yet every field: a v1 asset can lack what v2 requires, reference paths
   aren't updated after a rename, and `rejected` assets have no stated
   destination. Those go to dossier-format first (SD-1), before this phase starts. Granville's nine are already on
   manifest v2 (`dossier/v2-migration`, by a one-off script, 2026-10-22), so
   nothing else waits on this phase. Reading v1 stays in phase 1.

## 9. Acceptance

Items 1, 2 and 4 run through `make acceptance` against a local Granville
checkout (SD-4); they are not part of CI.

1. `dossier validate` on all nine Granville bundles on `dossier/v2-migration`:
   no errors, and each manifest validates against
   `schemas/manifest-v2.schema.json`. Separately, in CI: `dossier validate`
   gives the result `conformance.json` states for every fixture.
2. `dossier add` of a Granville view with its sidecar records every field in
   SD-7, including `references` mapped to the bundle's portrait and face.
3. Rendering the same bundle twice gives identical bytes.
4. On a copy of Granville's CAST.md that Reparto has written once
   (`reparto canonicalize --apply`), `dossier create` changes only the lines
   for the member it touches, and so does `dossier migrate --apply` on a
   synthetic v1 bundle added to that copy. On the unnormalized copy, no member's
   §7 hash changes, apart from the exceptions SD-12 reports.
5. `DossierCore` builds and links without `Vision`, `ImageIO` or
   ArgumentParser.

## 10. Open questions

| # | Question | Recommendation |
|---|----------|----------------|
| Q1 | Public or private repository? (DEPENDENCY-MISSIONS OQ-13) | **Decided 2026-10-20: public.** Every Swift* package is public by convention; the apps are private. Hence SD-4. |
| Q2 | Does `render` wait for the dossier-format template, or ship the bridge in §8 phase 3? | **Decided 2026-10-31:** ship the bridge only if it is shown to read v2 bundles first. **Recon showed it can't:** it doesn't find a v2 bundle's views, face or expressions, writes the wrong file name, and corrupts the manifest. So there's no bridge, and `render` waits for the template (§8 phase 3). |
| Q3 | `check`: is CHARACTER.md linting the writer's job (here) or Personaje's? | **Decided 2026-10-31:** here. It reads a format file (DOSSIER-FORMAT §9) and is needed by every writer. Personaje only decides the gates. |
