---
type: requirements
state: draft
updated: 2026-10-19
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
REQUIREMENTS. Once this file is accepted, the Personaje document becomes a
pointer to the two.

## 1. The specification

dossier-format's specification, schemas and tier table are written
(2026-10-19). Its page template, field list, design tokens and conformance
fixtures are not.

| # | Rule |
|---|------|
| SD-1 | **`docs/DOSSIER-FORMAT.md` is the specification.** Where it is silent, raise the question in dossier-format; don't decide it here. |
| SD-2 | **Data files are consumed, never restated:** `schemas/*.json`, `data/tiers.json`, `data/review.json`, and later `data/fields.json`, the tokens and the template, copied as resources from a pinned dossier-format revision. A test fails if the copies differ from that revision. |
| SD-3 | **Every manifest this package writes validates** against `schemas/manifest-v2.schema.json`; every Granville v1 manifest validates against `manifest-v1.schema.json` (they do today). |
| SD-4 | **Fixtures:** private fixtures copied from Granville (HUNTER, GARETH, SHANE, ARCHER) live in this package's tests; public fixtures are dossier-format's (its Q2). |

## 2. Targets

| Target | Depends on | Contains |
|--------|------------|----------|
| `DossierCore` | Foundation, CryptoKit, SwiftReparto | Read-only. `Cast.load(_:)` (discovery from CAST.md, DOSSIER-FORMAT §3), `DossierBundle.open(at:)`, `Manifest`, `Asset`, `AssetKind`, `assets(kind:variant:)`, `selectedAsset(kind:variant:)`, `sampleURL(variant:)`, `identityPrompt`, `artStyle` (CHARACTER.md front matter, UD20), `pageURL`, `completeness(tier:)`, `stale()`, `DossierTabs`. No writers. Linked by the Vinetas app. |
| `Dossier` | `DossierCore`, ImageIO, Vision | Writers: `DossierBundle.create(character:role:in:)`, `add`, `select`, `reject`, `remove`, `delete()`, `deriveFace(box:)`, `refresh()`, `setPrompt(_:_:)`, `validate()`, `validate(cast:)`, `renderPage()`, `candidates(kind:variant:in:)`, `migrate`, `CharacterDescription.read/write`, `footnoteCheck()`, `openQuestions`. Linked by SwiftPersonaje. |
| `DossierCLICore` | `Dossier`, ArgumentParser | Command logic, unit-testable without a subprocess. Not a product (SwiftReparto D-6). |
| `dossier` | `DossierCLICore` | The executable (§5). |

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
| SD-8 | **`select`** demotes the previous `selected` of the same `kind` + `variant` to `candidate` (DOSSIER-FORMAT §5.4). `--select` on `add` does both in one write. |
| SD-9 | **Nothing is deleted implicitly.** `remove` deletes one asset and its file; `delete()` deletes the bundle. Both are explicit; the CLI asks for `--yes`. |
| SD-10 | **`derivedFrom`** is written in the §7 array shape on `face`, `view`, `expression`, `voiceSample` and `dossier`. `stale()` compares each input's sha256 with the current selection, member, bundle and template. |
| SD-11 | **`refresh`** adopts files a writer didn't put there by the DOSSIER-FORMAT §5.6 rules (`voice/<CHARACTER>.vox` → `vox`; `voice/sample-<variant>[-<model>].m4a` → `voiceSample`, with `model` from the suffix or the vox default). Anything else stays unclassified. Orphan adoption follows §3 exactly. |
| SD-12 | **`CAST.md` is written only through SwiftReparto.** `create` adds the member if absent and sets `role` and `manifest`; until Reparto 0.2.0 these are `extraKeys`. A write that would reorder or reformat members the call didn't touch is a bug (Granville's CAST.md is the regression fixture). |

## 4. Face crop, validation, page

- **Face crop (DOSSIER-FORMAT §8.5):** Vision `VNDetectFaceRectanglesRequest` on the
  selected portrait; the largest face; a square 1.8× the box's larger side,
  centred, clamped, never upscaled; PNG. `deriveFace(box:)` takes an optional
  hand-set box, recorded in provenance and reused by later refreshes. The
  output must be byte-identical for the same portrait and box. Reference:
  Personaje `tools/face_crop.swift`.
- **Validation (DOSSIER-FORMAT §14):** read-only, every finding with its
  code (`E-…`, `W-…`) and the §8.3 completeness report, tier rows read from
  `data/tiers.json` and check rows implemented by ID. `validate(cast:)` adds the CAST.md checks and
  orphans. Exit status: 0 clean, 1 warnings only, 2 errors.
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
every change; `--apply` performs it. Granville's nine bundles (version 1
contents in `.dossier` directories) are the fixtures. The steps, in order:
rename `<NAME>/` to `<NAME>.dossier/` if needed; fold sidecars into
provenance (references mapped by sha256, absolute paths dropped; round and
seed from the old file name into `provenance.round` / `provenance.seed`);
move candidates and sidecars to `.generations/<NAME>/`; map retired kinds
(variant from `label`); rename selected images to content names; rewrite
`derivedFrom` in the §7 shape; update CAST.md pointers through Reparto;
write the v2 manifest; render the page and delete `dossier.html`; validate.

## 7. Format additions

The three this package proposed (top-level `prompts`, `provenance.tool` as
an object, `provenance.copiedFrom`) were accepted into dossier-format v2 on
2026-10-19 (DOSSIER-FORMAT §5.5, §6). Further additions go to dossier-format
first (SD-1).

## 8. Phases

1. **Core:** `DossierCore` reads v1 and v2 manifests; `Dossier` create, add,
   select, reject, remove, list, prompt, refresh, validate; the CLI for
   those. Tests against the Granville fixtures.
2. **Face crop and `check`.**
3. **Page renderer** with the dossier-format template (blocked on the
   template, SD-2). Until it lands, `render` may shell out to Personaje's
   `render_dossier.py` behind a flag, so a run can finish; remove the flag
   when the template ships. The bridge's page is a v1-style page and is
   reported `W-PAGE-EXTERNAL`.
4. **Migration,** then migrate Granville on a branch.

## 9. Acceptance

1. `dossier validate` on every migrated Granville bundle: no errors, and the
   manifest validates against `schemas/manifest-v2.schema.json`.
2. `dossier add` of a Granville view with its sidecar records every field in
   SD-7, including `references` mapped to the bundle's portrait and face.
3. Rendering the same bundle twice gives identical bytes.
4. `dossier create` and `dossier migrate --apply` on a copy of Granville's
   CAST.md change only the lines for the members they touch.
5. `DossierCore` builds and links without `Vision`, `ImageIO` or
   ArgumentParser.

## 10. Open questions

| # | Question | Recommendation |
|---|----------|----------------|
| Q1 | Public or private repository? (DEPENDENCY-MISSIONS OQ-13) | Private until the private Granville fixtures are out of the tests. |
| Q2 | Does `render` wait for the dossier-format template, or ship the bridge in §8 phase 3? | Ship the bridge; the start-to-finish run needs a page. |
| Q3 | `check`: is CHARACTER.md linting the writer's job (here) or Personaje's? | Here: it reads a format file (DOSSIER-FORMAT §9) and is needed by every writer. Personaje only decides the gates. |
