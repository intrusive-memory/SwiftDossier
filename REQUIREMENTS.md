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

dossier-format's specification, schemas, tier table, conformance fixtures, page
template, field list and design tokens are written and tagged **`v2.0.0-rc.6`**
(2026-11-01), the revision this package pins. All of them are copied as resources:
the field list in `DossierCore`, the template and tokens in `Dossier`. The `dossier`
CLI carries that template when it validates and renders (§4); `renderPage()` fills it.

| # | Rule |
|---|------|
| SD-1 | **`docs/DOSSIER-FORMAT.md` is the specification.** Where it is silent, raise the question in dossier-format; don't decide it here. |
| SD-2 | **Data files are consumed, never restated:** `schemas/*.json`, `data/tiers.json`, `data/review.json`, `data/fields.json`, `data/tokens.json` and the template, copied as resources from a pinned dossier-format revision. A test fails if the copies differ from that revision. |
| SD-3 | **Every manifest this package writes validates** against `schemas/manifest-v2.schema.json`; every v1 fixture validates against `manifest-v1.schema.json`. The v1 fixtures are `examples/warnings/W-V1*`. `E-SCHEMA` comes from the schema files, through SD-13's evaluator; the rules are not restated in Swift (SD-2). |
| SD-4 | **Fixtures are synthetic.** This repository is public (§10 Q1), so nothing from a private project is copied into it: no images, descriptions, CAST.md or manifests from podcast-granville or any other podcast. Tests use dossier-format's `examples/` and its `conformance.json`, which includes synthetic v1 bundles of both Appendix A shapes (v1 manifest in a `.dossier` directory or a plain one, sidecars, retired kinds, path-order checksum). Real projects are checked by `make acceptance PROJECT=<path>`, which runs against a local checkout, skips when it is absent, and never runs in CI. |

## 2. Targets

| Target | Depends on | Contains |
|--------|------------|----------|
| `DossierCore` | Foundation, CryptoKit, SwiftReparto, Yams | Read-only. `Cast.load(_:)` (discovery from CAST.md, DOSSIER-FORMAT §3), `DossierBundle.open(at:)`, `Manifest`, `Asset`, `AssetKind`, `assets(kind:variant:)`, `selectedAsset(kind:variant:)`, `sampleURL(variant:)`, `identityPrompt`, `artStyle` (CHARACTER.md front matter, UD20), `pageURL`, `completeness(tier:)`, `stale()`, `DossierTabs`. No writers. Linked by the Vinetas app. |
| `Dossier` | `DossierCore`, ImageIO, Vision | Writers: `DossierBundle.create(character:role:in:)`, `add`, `select`, `reject`, `remove`, `delete()`, `deriveFace(box:)`, `refresh()`, `setPrompt(_:_:)`, `validate(template:)`, `validate(cast:template:)`, `DossierTemplate`, `renderPage()` (built, §8 phase 3), `candidates(kind:variant:in:)`, `migrate` (not built, §8 phase 4), `CharacterDescription.read/write`, `footnoteCheck()`, `openQuestions`. Linked by SwiftPersonaje. |
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

**The files on disk are the source of truth, and the manifest is an index of them.**
`E-FILE-HASH` means the manifest is behind the disk, not that the file is wrong, and
`refresh` is how the manifest catches up. Unsaved in-memory state doesn't count:
readers and validators judge only what's on disk.

| # | Requirement |
|---|-------------|
| SD-5 | **Every mutation:** copy or write the file → rescan `files` → recompute `manifestChecksum` → write the manifest to a temporary file → replace → re-read and compare (DOSSIER-FORMAT §5.6). **The rescan doesn't clear a finding:** a file not yet listed is recorded as found; a listed file keeps its recorded `sha256` and `sizeBytes` whatever its bytes now are, and a listed file that's missing keeps its entry, unless this write itself created, replaced or removed that file, which it records exactly (`ManifestWriter.update(accepting:removing:)`). So `prompt --set`, `add`, `select`, `reject`, `remove`, `create`, face crop, `CharacterDescription.write` and a render leave `E-FILE-HASH` and `E-FILE-MISSING` on every file they didn't write; `refresh` (SD-11) brings the index up to the disk. The new entries' checksum is recomputed as ever, so no `E-CHECKSUM` follows. An asset whose file is missing makes every write refuse (`assetFilesMissing`), `refresh` included even with nothing else to write, and for the moment `remove` is the way out; a zero-byte or unreadable file in the inventory refuses every write. `add` of a listed file that it finds in place with the bytes it would write doesn't write it, so it doesn't accept it: the asset is recorded and `E-FILE-HASH` stays until `refresh`. Other bytes are `destinationExists`, as any overwrite is. `CharacterDescription.write` of the text a hand edit already put there changes nothing; of other text, it replaces the file and records that. `derivedFrom` and `references` record the bytes on disk, which are what a tool read, so an asset made from a mismatched file reads `W-STALE` until `refresh` accepts that file, and one made from what's recorded reads `W-STALE` after. The checksum is the **sorted** form (§5.3, SwiftAcervo's `computeChecksum`); a v1 manifest is verified with the path-order form (Appendix A), which is what Personaje's `tools/record.py` writes. |
| SD-6 | **`add` names image files** `images/<kind>[-<variant>]-<sha8>.png` (DOSSIER-FORMAT §4). Voice files keep their producer's names. The source file is copied, never moved, and never modified. **A PNG image copied in loses its metadata in the bundle's copy:** the chunks `tEXt`, `zTXt`, `iTXt`, `eXIf` and `tIME` go, and every other chunk (`iCCP`, `gAMA`, `sRGB`, `IDAT`) stays byte for byte. The embedded Vinetas record is read for provenance first. The stored hash, size and file name come from the stripped bytes. A malformed PNG is refused and not copied. Images that aren't PNG are copied as they are. A file already inside the bundle is never modified: `add` of a file in place keeps its bytes and name, and so does `refresh` adoption. |
| SD-7 | **`add` folds provenance in** (DOSSIER-FORMAT §6). Given a Vinetas sidecar (`--sidecar`) or a PNG with Vinetas's embedded metadata, it records every §6 key the sidecar has; the sidecar's `generatedAt` becomes the asset's `createdAt`. `references[].source` is **never** recorded: each reference becomes `{sha256, path, role}`, where `sha256` stays what was sent, `role` comes from `--reference-roles portrait,face`, and `path` is the bundle path of the asset with that sha256; when none has it and the reference's role has a current selection, that selection's path; otherwise omitted. A `derivedFrom` input records the hash actually sent: when those bytes are no longer in the bundle, it carries the path of the current selection for that role, so a selected asset reads `W-STALE`, and when the role has no current selection `add` refuses with `missingDerivedInput`, since §7 requires the input. Extra provenance (`tool`, notes, `gateOverridden`) is merged from `--provenance <json>`. |
| SD-8 | **`select`** demotes the previous `selected` of the same `kind` + `variant` to `candidate`; for a `voiceSample`, of the same `kind` + `variant` + `model` (DOSSIER-FORMAT §5.4). `--select` on `add` does both in one write. |
| SD-9 | **Nothing is deleted implicitly.** `remove` deletes one asset and its file; `delete()` deletes the bundle. Both are explicit; the CLI asks for `--yes`. |
| SD-10 | **`derivedFrom`** is written in the §7 array shape on `face`, `view`, `expression`, `voiceSample` and `dossier`. `stale()` compares each input's sha256 with the current selection, member, bundle and template. |
| SD-11 | **`refresh`** brings the manifest up to the disk, and is the one way to accept a changed file: for each listed file whose bytes aren't its entry's, images included, it records the new hash and size, and reports the file by path (`RefreshReport.accepted`; `accepted` in `--json`, one `Accepted <path>` line in text). **The file keeps its name:** when an accepted file's name is of the DOSSIER-FORMAT §4 `<kind>[-<variant>]-<sha8>.png` form and its `<sha8>` isn't the new hash's first 8, that's reported (`RefreshReport.nameMismatches`; `nameMismatches` in `--json`, a line in text) and nothing is renamed. **A listed file with no asset that's missing has its entry dropped,** which clears `E-FILE-MISSING`, and is reported (`RefreshReport.dropped`; `dropped` in `--json`, one `Dropped <path>` line in text). **A missing file an asset points at refuses the call,** with nothing changed, even with nothing else to write: the paths are reported (`assetFilesMissing`; the message in text, `error.paths` in `--json`), the exit status is 1, and for the moment `dossier remove` is the way out. It writes when there's anything to accept, drop or adopt, and otherwise doesn't touch the manifest. It also adopts files a writer didn't put there by the DOSSIER-FORMAT §5.6 rules, which include when a sample can't be adopted; a listed file that's both changed and adoptable is in both lists, and a new file adopted is only in `adopted`. Anything else stays unclassified and the command reports why. Orphan adoption follows §3 exactly. |
| SD-12 | **`CAST.md` is written only through SwiftReparto.** `create` adds the member if absent and sets `role` and `manifest`, which are real `CastMember` fields; this package requires SwiftReparto 0.2.1 or later, whose `canonicalName` matches dossier-format's `examples/names.json`. SwiftDossier owns those two fields and no others (SwiftReparto `REQUIREMENTS-personaje.md` "Who writes CAST.md"). **On a CAST.md SwiftReparto has already written, a write that changes lines of members the call didn't touch is a bug** (Reparto RP-P16). The first write to a hand-edited or 0.1.0-written file normalizes key order and quoting for every member (Reparto RQ-23 withdrawn); that is Reparto's behavior, not a SwiftDossier bug. It doesn't change a member's DOSSIER-FORMAT §7 hash, with these exceptions, which lose data or change a path: a `voices` provider value of the wrong type is dropped, a provider-case collision keeps one value, and absolute paths under the project become relative. `migrate` and `create` report any of these before writing, and say so when the file was not yet normalized (`generate(parse(x)) != x`). They suggest `reparto canonicalize --apply` first, which also renames non-canonical members. A synthetic CAST.md with Granville's layout quirks is the regression fixture, checked both ways; Granville's own is checked by `make acceptance`. *Restated 2026-10-22:* it said any reorder of untouched members was a bug, which Reparto's whole-file writer can't meet on a first write. |
| SD-13 | **A small JSON Schema evaluator lives in `Dossier`,** for exactly the keywords the pinned schemas use: `type`, `required`, `properties`, `additionalProperties`, `items`, `enum`, `const`, `pattern`, `minimum`, `minLength`, `minItems`, `allOf`, `oneOf`, `if`/`then`, `$defs`, and `$ref`, to another of the pinned schemas or a `#/` pointer into its own (`$id`, `$schema`, `title` and `description` are ignored). `type` may be an array and `$ref` may be relative. An unsupported keyword in a schema is a failure, not a pass, and a test checks that for every pinned schema. It is tested against `conformance.json`. No third-party schema package. |
| SD-14 | **Update status** (DOSSIER-FORMAT §5.7). `withUpdate(label:_:)` holds a marker for the length of a block: it writes it atomically, renews it in the background before it expires, and removes it after the block's last manifest replacement, including when the block throws. A single mutation (SD-5) holds one unless the caller already does, so a sequence of mutations shows as one update. `updateStatus(at:)` in the read-only core answers §5.7's question for any reader, and the update fixtures in `conformance.json` test it. The CLI adds `dossier update run <bundle> -- <command>`, and `begin`, `renew` and `end` for an update that spans separate commands. A marker never blocks a write: it is a signal, not a lock. |

## 4. Face crop, validation, page

- **Face crop (DOSSIER-FORMAT §8.5):** Vision `VNDetectFaceRectanglesRequest` on the
  selected portrait; the largest face; a square 1.8× the box's larger side,
  centred, clamped, never upscaled; PNG. `deriveFace(box:)` takes an optional
  hand-set box, recorded in provenance and reused by later refreshes. The
  output must be byte-identical for the same portrait and box. Reference:
  Personaje `tools/face_crop.swift`. It crops the portrait's bytes as they are,
  so a crop of a portrait changed by hand records those in `derivedFrom`, leaves
  the portrait's entry and its `E-FILE-HASH` alone, and reads `W-STALE` until
  `refresh` accepts the portrait (SD-5).
- **Validation (DOSSIER-FORMAT §14):** read-only, every finding with its
  code (`E-…`, `W-…`) and the §8.3 completeness report, tier rows read from
  `data/tiers.json` and check rows implemented by ID. `validate(cast:template:)`
  adds the CAST.md checks and orphans. The template compared against (§11) is a
  parameter, here and on `stale()`: `nil` makes no comparison, the CLI passes the
  bundled one (`DossierTemplate.current`), and tests pass the one `conformance.json`
  names. Exit status: 0 clean,
  1 warnings only, 2 errors.
- **Page (DOSSIER-FORMAT §11):** `renderPage()` writes `<CHARACTER>-dossier.html`
  from CHARACTER.md, the manifest, the CAST.md member and the selected
  originals, through the dossier-format template. Page copies are made with
  ImageIO at fixed settings and embedded as `data:` URIs; nothing is stored.
  A bundle with `E-FILE-HASH` or `E-FILE-MISSING` on any file but the page being
  replaced is refused, with nothing changed (DOSSIER-FORMAT §11), until `refresh` has
  run (SD-11). The refusal names `dossier refresh` for `E-FILE-HASH`; for
  `E-FILE-MISSING` it says a missing file must be restored, that `refresh` drops one
  with no asset, and that `remove` takes out an asset. A render records its own page
  (SD-5), so a tampered or missing page doesn't block it.
  Output is deterministic: a test renders the same bundle twice and compares
  bytes. It needs the bundle's `CAST.md` member (§7's `castMember` input), so a bundle opened
  with none is refused, and it runs as one update (SD-14). A failed render leaves the
  previous page and manifest as they were. **Content parity:** every piece of content Personaje's
  `tools/render_dossier.py` shows (sources list, completeness, integrity
  banner, provenance lines, footnotes in citation order) appears in the new
  page, in the new layout.

## 5. CLI

All commands accept `--json` (one object on stdout; errors as
`{"error": {...}}` with a non-zero exit). Bundles are given by path. The disk is the
source of truth and the manifest its index (§3), so a command judges what's on disk.

```
dossier create   "THE PRACTITIONER" --role supporting --in characters/ [--cast CAST.md]
dossier add      <bundle> <file> --kind view --variant front [--select] [--sidecar x.json] [--provenance '{...}']
dossier select | reject | remove  <bundle> <path>
dossier list     <bundle> [--kind view] [--variant front] [--status selected]
dossier prompt   <bundle> identity|portrait|subject [--set "<text>" | --file f] # DOSSIER-FORMAT §5.5
dossier face     <bundle> [--box x,y,w,h]
dossier check    <bundle>                                 # CHARACTER.md: front matter, sections, footnotes, open questions
dossier validate <bundle> | --cast CAST.md
dossier render   <bundle> [--cast CAST.md] | --cast CAST.md   # §4. Without --cast, CAST.md in the bundle's parent, then grandparent
dossier refresh  <bundle> [--cast CAST.md]                # brings the manifest up to the disk (SD-11): accepts changed files, drops missing ones with no asset, adopts by §5.6; refuses an asset's missing file; --json has accepted, nameMismatches, dropped, adopted, unclassified
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
(Appendix A). The renderer has shipped (§8 phase 3); `migrate` hasn't (phase 4).

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
3. **Page renderer** with the dossier-format template, which is in the pinned
   tag and copied as resources (SD-2). **Built:** `renderPage()` and `dossier render`;
   there is no bridge (Q2). **`render_dossier.py` must not
   be run on a v2 bundle;** it rewrites the manifest with a path-order checksum.
4. **Migration,** for any remaining v1 bundle. Appendix A's order is settled, but
   not yet every field: a v1 asset can lack what v2 requires, reference paths
   aren't updated after a rename, and `rejected` assets have no stated
   destination. Those go to dossier-format first (SD-1), before this phase starts. Granville's nine are already on
   manifest v2 (`dossier/v2-migration`, by a one-off script, 2026-10-22), so
   nothing else waits on this phase. Reading v1 stays in phase 1.

## 9. Acceptance

Items 1 to 4 run through `make acceptance` against a local Granville
checkout (SD-4); they are not part of CI, though a test renders the fixtures twice in CI.

The disk is the source of truth (§3), so `make acceptance PROJECT=<path>` takes the
project as it is on disk: it copies the tree, `.git` aside and hidden `.generations/`
included, into a temporary directory and runs there. `REF=<ref>` extracts that commit
instead, and has no default. The output says which source was used: `disk`, or the ref
and SHA. Either way it never writes to the project and a file that's an LFS pointer reports `SKIP(lfs pointer)`. From disk, a link leading out of the tree is left out; from a ref,
it stops the run.

1. `dossier validate` on all nine Granville bundles: no errors, and each manifest validates against
   `schemas/manifest-v2.schema.json`. Separately, in CI: `dossier validate`
   gives the result `conformance.json` states for every fixture.
2. `dossier add` of a Granville view with its sidecar records every field in
   SD-7, with `references` mapped where a hash matches. With `REF=`, a commit doesn't
   usually hold `.generations/`, so it's read from the working tree and the output says so.
   *Note 2026-11-01:* mapping a reference to a `face` on real data is unproven.
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
| Q2 | Does `render` wait for the dossier-format template, or ship the bridge in §8 phase 3? | **Decided 2026-10-31:** ship the bridge only if it is shown to read v2 bundles first. **Recon showed it can't:** it doesn't find a v2 bundle's views, face or expressions, writes the wrong file name, and corrupts the manifest. So there's no bridge, and `render` waited for the template (§8 phase 3, now built). |
| Q3 | `check`: is CHARACTER.md linting the writer's job (here) or Personaje's? | **Decided 2026-10-31:** here. It reads a format file (DOSSIER-FORMAT §9) and is needed by every writer. Personaje only decides the gates. |
