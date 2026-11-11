---
type: recon-report
state: current
requirements_file: REQUIREMENTS-preview.md
requirements_sha256: 1f1d64994d38d555e8d96677609315aff26dbafdaa16909d43c3f46145fd85bf
project_head: e35023cb0df41121f4a05238647f6a3a5c91e6fd
search_root: ~/Projects
generated: 2026-11-10
verdict: CLEAR
run: 2
---

# RECON_REPORT.md — SwiftDossier: Dossier preview and viewer

## Terminology

> **Mission** — A definable, testable scope of work.
> **Sortie** — An atomic, testable unit of work executed by a single agent in one dispatch.
> **Work Unit** — A grouping of sorties.

## Verdict

**CLEAR** (run 2): 44 assumptions checked: 42 confirmed, 1 resolved by scope (A-36), 0 blocking, 1 unverifiable.

Run 1 was BLOCKED on A-35 to A-38. The requirements doc disagreed with dossier-format
§11.1 (rc.8, `a52dce9`, untagged), and this package pins rc.7. The doc has since been
amended:

- PV-1 now uses §11.1's key.
- PV-6, PV-9, PV-10, PV-12, PV-18 and PV-22 now follow §11.1's rules.
- OQ-1 to OQ-4 are closed.
- New PV-0 puts the pin bump to `v2.0.0-rc.8` in scope. That bump is the work unit the
  run-1 report gave as option 3 for A-36.

The rc.8 *tag* itself is outside this repo. It is the one item a person must do (B-01).

## Assumption Findings

| ID | Kind | Claim | Locus | Verdict | Evidence |
|----|------|-------|-------|---------|----------|
| A-01 | A-API | `previewPage()` exists, builds leniently | repo | CONFIRMED | `Sources/Dossier/Rendering/DossierBundle+Preview.swift:34` — `public func previewPage() throws -> PreviewPage` (sync, nonisolated) |
| A-02 | A-API | `openForPreview(at:)` exists | repo | CONFIRMED | `DossierBundle+Preview.swift:56` — `public static func openForPreview(at:) throws -> DossierBundle` |
| A-03 | A-API | `PageFiller` and `BundleScan` have lenient modes | repo | CONFIRMED | `PageFiller.swift:40` has `lenient: Bool = false`. BundleScan's equivalent is `allowingEmpty: Bool = false` (`ManifestWriter.swift:59`, used at `Preview.swift:72`), not a flag called "lenient". Both are internal. |
| A-04 | A-API | `DossierPreviewCache` caches in ~/Library/Caches; `previewKey()` hashes every file | repo | CONFIRMED | `DossierPreviewCache.swift:14,22-24` writes to `Caches/Dossier Previews/<sha(path)[0..<32]>/<key>.html`. `Preview.swift:73-77` uses `scan.diskChecksum()`. |
| A-05 | A-API | `DossierTemplate.current` gives version + sha256 | repo | CONFIRMED | `Sources/Dossier/DossierTemplate.swift:9,27,32,39`. Both values come from `template/VERSION.json`. |
| A-06 | A-API | `Cast.Member.canonicalJSON` exists | repo | CONFIRMED | `Sources/DossierCore/Cast.swift:62`. `hash` (sha256 of it) is at `:64`. |
| A-07 | A-BEHAVIOR | `renderPage()` writes the page, selects the `dossier` asset, and refuses on E-FILE-HASH/E-FILE-MISSING | repo | CONFIRMED | `DossierBundle+Render.swift:33,67-71,106-120` throws `DossierWriteError.renderRefusedByIntegrity` |
| A-08 | A-BEHAVIOR | `refresh()` writes manifest only on change and refuses on a missing asset file | repo | CONFIRMED | `DossierBundle+Refresh.swift:124-169`. Writes only `if hasManifestWrite`. Throws `DossierWriteError.assetFilesMissing`. |
| A-09 | A-BEHAVIOR | Member lookup: parent then grandparent CAST.md; none found means no member, not an error | repo | CONFIRMED (nuance) | `Preview.swift:118-132` `previewMember(of:)` (private). The first CAST.md that exists wins: there is no fall-through to the grandparent if the parent's CAST.md lacks the member. The CLI's `render` uses a separate lookup that throws (`ReadCommands.swift:323`, `Support.swift:12`). |
| A-10 | A-API | `CharacterDescriptionError` thrown on missing / non-UTF-8 CHARACTER.md | repo | CONFIRMED | `CharacterDescription.swift:7`. `Render.swift:178-182` throws `.unreadable` / `.notUTF8`. |
| A-11 | A-DATA | E-FILE-HASH / E-FILE-MISSING codes and an integrity banner | repo | CONFIRMED | `Validation/Finding.swift:30,32`. Banner is a `fields.json` field (`role: banner`), filled at `PageFiller.swift:413-419`. |
| A-12 | A-API | `UpdateStatus` exists in DossierCore | repo | CONFIRMED | `Sources/DossierCore/UpdateStatus.swift:4,31,50` |
| A-14 | A-INVARIANT | DossierCore/Dossier import no UI framework | repo | CONFIRMED | `grep -rnE "import (SwiftUI\|WebKit\|AppKit\|UIKit)"` found no matches |
| A-15 | A-BEHAVIOR | Render and preview both embed media as `data:` URIs (PV-5 and PV-7 compatible) | repo | CONFIRMED | `PageFiller.swift:449` (image JPEG), `:512` (audio). Same code in both modes. |
| A-16 | A-DATA | Template tabs need JavaScript | repo | CONFIRMED | `template/skeleton.html:15-21`, `dossier.js:126-138,200` (`dossier-tabs` custom element) |
| A-17 | A-BEHAVIOR | Is there an existing async / off-main build API? | repo | CONFIRMED (none) | All build/render APIs are sync and nonisolated. `DossierBundle`, `PreviewPage`, `RefreshReport` are `Sendable` (`DossierCore/DossierBundle.swift:16`). |
| A-20 | A-API | `dossier preview` exists; options | repo | CONFIRMED | `ReadCommands.swift:390-428`. Has `<bundle>`, `--to`, `--json` (fields `character`, `bundle`, `page`, `member: Bool`). No `--rebuild`; that is the deliverable. |
| A-21 | A-API | `dossier render` exists | repo | CONFIRMED | `ReadCommands.swift:270-330` |
| A-22 | A-API | `RenderProject` test helper | repo | CONFIRMED | `Tests/DossierTests/RenderSupport.swift:11-82`. DossierTests target only. CAST.md sits beside `characters/`. |
| A-23 | A-FILE | `PreviewTests.swift` and which tests use the cache | repo | CONFIRMED | 10 tests. Only `key` and `cacheLifecycle` touch `previewKey()` / `DossierPreviewCache` (temp dir). |
| A-24 | A-CONFIG | `build` / `test` / `test-ios` targets; -Package scheme picks up new targets | repo | CONFIRMED | `Makefile:12,20`. No checked-in `.xcscheme`. |
| A-25 | A-CONFIG | CI runs make test / test-ios | repo | CONFIRMED | `.github/workflows/tests.yml`: `test-macos`, `test-ios` on `xcode-27`. Also runs on draft PRs. |
| A-26 | A-CONFIG | Test framework | repo | CONFIRMED | Swift Testing only. No SwiftUI or @MainActor tests exist. |
| A-27 | A-CONFIG | Platforms macOS 26/iOS 26; no `DossierUI` yet | repo | CONFIRMED | `Package.swift:11-20` |
| A-28 | A-CONFIG | No test hits real ~/Library/Caches | repo | CONFIRMED | Only temp-dir cache in tests. No CLI test covers `dossier preview`. |
| A-30 | A-API | Personaje `DossierWebView` containment is a usable starting point | external:Personaje | CONFIRMED (partial) | `Personaje/Dossier/DossierWebView.swift:67-95,179-192` allows file URLs inside the bundle and cancels everything else. It does **not** open http/https links in a browser (`:70`), so PV-22's link-opening is new work. |
| A-31 | A-API | Escribir `DossierPageView` / `DossierWebView` / `DossierUpdateStore` | external:Escribir | CONFIRMED | `Shared/DossierPageView.swift:38`, `Shared/DossierWebView.swift:53`, `Shared/DossierUpdateStore.swift:90` (committed HEAD e1b1f96) |
| A-32 | A-DATA | mr-mr-charles has 4 dossiers, none with a page | external:mr-mr-charles | CONFIRMED | `characters/{BILLY,DONNIE,MIMI,MITCH}.dossier`, no `*.html`. CAST.md at repo root (the bundles' grandparent). No `.preview` ignore rule. |
| A-33a | A-DATA | §11: page is "the only HTML file in the bundle" | dep:dossier-format@rc.7 | CONFIRMED | `.dossier-format/docs/DOSSIER-FORMAT.md:769-770` |
| A-33b | A-DATA | §5.2 keeps hidden files out of `files`, `manifestChecksum`, validation | dep:dossier-format@rc.7 | CONFIRMED | `:232-241,382-383` |
| A-33c | A-DATA | The hidden update marker is a precedent | dep:dossier-format@rc.7 | CONFIRMED | `:370-371,399-400` |
| A-35 | A-DATA | PV-1's key matches the format's key | dep:dossier-format@a52dce9 | CONFIRMED (run 2) | PV-1 now restates `DOSSIER-FORMAT.md:852-868` line for line |
| A-36 | A-DATA | Preview rules are in the format the build uses | dep:dossier-format | Resolved by scope (run 2) | §11.1 exists only at `a52dce9`. PV-0 makes the pin bump part of the mission and gates shipping on it. See B-01. |
| A-37 | A-BEHAVIOR | Store, cleanup and `.gitignore` match the format | dep:dossier-format@a52dce9 | CONFIRMED (run 2) | PV-9/PV-10 now follow `DOSSIER-FORMAT.md:843-848,909-916` |
| A-38 | A-BEHAVIOR | Rebuild, showing, leniency and link rules match the format | dep:dossier-format@a52dce9 | CONFIRMED (run 2) | PV-6/PV-12/PV-18/PV-22 now follow `DOSSIER-FORMAT.md:875-944` |
| B-02 | A-API | `Cast.Member.hash` is §7's member hash (SHA-256 of canonical JSON) | repo + format | CONFIRMED | `Sources/DossierCore/Cast.swift:64`; `DOSSIER-FORMAT.md:491` |
| B-03 | A-API | `DossierTemplate.sha256` exists | repo | CONFIRMED | `Sources/Dossier/DossierTemplate.swift:32` (A-05) |
| B-04 | A-DATA | The bundled template is rc.8's: same sha256 as §11.1's worked example | repo + format | CONFIRMED | `Sources/Dossier/Resources/template/VERSION.json` and `~/Projects/dossier-format/template/VERSION.json` are both `0.1.1` / `8819dcef…d76c`. This equals `DOSSIER-FORMAT.md` worked example. PV-0's re-pin should change no template bytes. |
| B-05 | A-DATA | `E-ZERO-BYTE` finding code exists | repo | CONFIRMED | `Sources/Dossier/Validation/Finding.swift:34` |
| B-06 | A-API | An update-marker API exists for `rebuild()` to hold | repo | CONFIRMED | `Sources/Dossier/Writing/DossierBundle+Update.swift:34,48` `withUpdate` (mutating, async). Readers use `UpdateStatus` (A-12). |
| B-07 | A-DATA | Fixtures `valid/preview-current` / `valid/preview-out-of-date` carry expected keys | dep:dossier-format@a52dce9 | CONFIRMED, not used | `examples/conformance.json:74-99`. The requirements now forbid preview tests that read fixtures or hard-code keys, so no sortie rests on these. |
| B-08 | A-BEHAVIOR | A missing `--cast` file is an error, not created (PV-28) | repo | CONFIRMED (after fix) | `CastFile.swift:76-78` (`Cast.load`) throws `DossierError.castUnreadable`; the CLI reports the case name (`Runner.swift:109`), so the code is `castUnreadable`. Run 2 first found PV-28 saying `cast-unreadable`, which was STALE; PV-28 was corrected. |
| B-09 | A-DATA | DF-51 click handling is in the template | repo | CONFIRMED | `template/dossier.js:6` |

(A-13 was a check on the WIP commit message, not on the requirements doc. Dropped: the key
already uses `""` for no member, as PV-1 asks.)

### Blocking findings

_None in run 2._ Run 1's four (A-35 to A-38) were resolved by amending the requirements
doc on 2026-11-10. See the rows above.

## Local Dependency Map

| Dependency | Declared | Resolved | Local checkout | Local HEAD | Status |
|------------|----------|----------|----------------|-----------|--------|
| intrusive-memory/SwiftReparto | `upToNextMajor 0.2.1` | `0.2.1` (`94c4369`) | `~/Projects/package-collection/pkg/SwiftReparto` | `6638dc8` (`spec/cast-linecount`) | LOCAL_AHEAD (4 commits) |
| jpsim/Yams | `upToNextMajor 6.2.2` | `6.2.2` (`a27b21e`) | — | — | NO_LOCAL_CHECKOUT |
| apple/swift-argument-parser | `upToNextMajor 1.7.1` | `1.8.2` (`6a52f32`) | — | — | NO_LOCAL_CHECKOUT |
| intrusive-memory/dossier-format (fixtures, Makefile pin) | `DOSSIER_FORMAT_REF` | `v2.0.0-rc.7` (`.dossier-format/`) | `~/Projects/dossier-format` | `a52dce9` (`development`, rc.8 untagged) | LOCAL_AHEAD |

Resolved copy of SwiftReparto: `~/Library/Developer/Xcode/DerivedData/SwiftDossier-bluqdwvkjmyykbakubzpcoexytyo/SourcePackages/checkouts/SwiftReparto`
at `94c4369`, which equals the pin. No assumption in this mission rests on SwiftReparto:
`canonicalJSON` and the member lookup are in this repo.

### Drift and ambiguity notes

- **dossier-format is ahead of the pin, and that gap is the whole mission.** See A-36.
- **SwiftReparto is 4 commits ahead of its pin** (CAST.md `lineCount`, `castVersion`). No
  sortie should read it. If a sortie touches CAST.md parsing, use the resolved copy.
- **Escribir is AMBIGUOUS** (three checkouts share the remote): `~/Projects/apps/Escribir`
  (`fix/ios-pasted-underline`, dirty), `~/Projects/worktrees/Escribir-doc-grants`,
  `~/Projects/worktrees/Escribir-release-1.3.0`. Adopting the viewer in Escribir is out of
  scope, so this only matters as reference reading.
- **mr-mr-charles is dirty** (`dossier/start-to-finish`). Acceptance item 16 checks
  `git status` there, so start that check from a clean tree.

## Unverifiable

| ID | Claim | Why | What would settle it |
|----|-------|-----|----------------------|
| B-01 | dossier-format `v2.0.0-rc.8` is tagged (PV-0) | `git ls-remote --tags origin` shows tags up to `v2.0.0-rc.7` only (on `main`, `a28eb13`). rc.8 (`a52dce9`) is on `development` only, and its CHANGELOG says "unreleased". | Release rc.8 in dossier-format (development → main, tag). Blocks shipping, not the work. |

## Handoff to breakdown

- `CONFIRMED` facts (A-01 to A-38, B-02 to B-09) are safe as sortie entry criteria without
  re-checking. §11.1 citations are against `~/Projects/dossier-format` at `a52dce9`. Preview
  tests are synthetic and version-free, so they run under the current pin.
- B-01 gates only the pin-bump sortie and the release, not the preview sorties, which no
  longer depend on the pin. B-11 (Personaje relying on the CAST.md search) was settled by the user: Personaje shows
  a missing CAST.md and lets the person create one (PV-28).
- The dependency map's paths carry into EXECUTION_PLAN.md. Sorties read dossier-format at
  `~/Projects/dossier-format` (read-only) and never edit it.
