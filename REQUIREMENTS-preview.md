---
type: requirements
state: draft
updated: 2026-11-10
---

# SwiftDossier — Dossier preview and viewer

## Goal

Any app that links SwiftDossier can show a `.dossier` bundle's page by dropping in one
SwiftUI view. The page shown never depends on someone having rendered it first or on
that render being current. The check on whether it's current is cheap enough to run on
every selection, and an explicit **Rebuild** action makes a page from whatever the
bundle folder holds now.

## Why

Escribir and Personaje each show a dossier only if `<CHARACTER>-dossier.html` was
already rendered into the bundle. Dossiers written straight to disk (an LLM draft of
`CHARACTER.md`, images copied in) have no page. The viewers then show "no dossier page
yet", and the place they send you (Personaje) only renders when CAST.md is written.
Seen in `podcasts/mr-mr-charles`: none of its four dossiers has a page, so none can be
viewed in either app.

Each app also has its own web view and empty states (`DossierPageView`/`DossierWebView`
in Escribir, `DossierPanel`/`DossierWebView` in Personaje), which have drifted apart.

## Terms

- **Preview**: a page built for viewing, stored at `<bundle>/.preview/<key>.html`. It
  isn't the §11 page and is never recorded in the manifest.
- **Committed page**: `<CHARACTER>-dossier.html`, written by `renderPage()` and
  recorded as the selected `dossier` asset. This work doesn't change it, and the viewer
  doesn't read it.
- **Key**: the name of the preview that matches the bundle as it is now (PV-1).

## Requirements

### Key

- **PV-1** The key is `sha256` (hex) of these, in order and joined by `\n`:
  1. `dossier-preview`
  2. `previewRules`: an integer constant in the library, bumped whenever the
     preview's own rules change
  3. the template's version and its `sha256` (`DossierTemplate.current`)
  4. the bytes of `manifest.json`, exactly as on disk
  5. the CAST.md member's canonical JSON (`Cast.Member.canonicalJSON`), or an empty
     string when there is no member
- **PV-2** Computing the key reads `manifest.json` and CAST.md. It reads no image, voice
  or `CHARACTER.md` bytes. Target: under 10 ms for a bundle of any size, CAST.md
  parsing included.
- **PV-3** The member is found the way `dossier render` finds it: CAST.md in the
  bundle's parent directory, then its grandparent, and the member whose `manifest:`
  points at this bundle. A CAST.md that is missing or unreadable, or that has no such
  member, means no member. That is not an error.
- **PV-4** Known blind spot, accepted: an edit that doesn't go through a SwiftDossier
  write leaves the key unchanged, so the existing preview is still shown. Examples are
  editing `CHARACTER.md` by hand or swapping an image in Finder. **Rebuild** (PV-12)
  covers this.

### Building

- **PV-5** A preview is built by `previewPage()` from the bundle as it is on disk:
  `CHARACTER.md`, the manifest, the member and the selected originals, through the same
  template as `renderPage()`. On a clean bundle with its member, the two give
  byte-identical HTML.
- **PV-6** Building is lenient. Where a render refuses, a preview shows:
  - `E-FILE-HASH` and `E-FILE-MISSING` go in the page's integrity banner;
  - an image or voice sample that can't be read is left off, and its field shows the
    template's empty state;
  - a zero-byte file is hashed like any other;
  - no member means no role, tier or voice prompt;
  - `CHARACTER.md` on disk is used whether or not a `description` asset is selected,
    and front matter that can't be read is treated as empty.

  The only failure is a `CHARACTER.md` that is missing or not UTF-8.
- **PV-7** A preview is one self-contained file. Images and samples are embedded as
  `data:` URIs, and nothing outside the file is referenced.
- **PV-8** Building writes nothing outside `<bundle>/.preview/`. In particular,
  `manifest.json`, the committed page and every other bundle file are untouched.

### Storing and cleaning up

- **PV-9** On a miss, the preview is written to a temporary file inside `.preview/`,
  then renamed to `<key>.html`. The `.preview/` directory is created if needed.
- **PV-10** Only after that rename succeeds, everything else in `.preview/` is deleted:
  older previews, temporary files left by a write that died, and anything else. If the
  build or the write fails, nothing is deleted and the previous preview stays.
- **PV-11** A hit writes and deletes nothing. Viewing a current dossier never touches
  the disk.

### Rebuild

- **PV-12** `rebuild()` brings the manifest up to the disk with `refresh()`, then
  builds and stores a preview (PV-9, PV-10) **even if `<key>.html` already exists**.
- **PV-13** If `refresh()` refuses (for example an asset's file is missing), the preview
  is still built from the disk under the key of the unchanged manifest. The refusal is
  returned alongside the page, so the viewer can say why the manifest wasn't updated.
- **PV-14** `refresh()` writes `manifest.json` only when something changed (existing
  behaviour). So a rebuild of an unchanged bundle gives the same key and rewrites only
  the preview.

### Concurrency

- **PV-15** Building and rebuilding never run on the main actor.
- **PV-16** Two processes may build the same bundle at once, with no locks. Whichever
  renames last wins, and its cleanup deletes the other's file. If the survivor came
  from an older manifest, the next selection computes the new key, misses and builds.

### Viewer: the `DossierUI` product

- **PV-17** A new library product, `DossierUI`, depends on `Dossier`, SwiftUI and
  WebKit and supports macOS 26 and iOS 26. `DossierCore` and `Dossier` gain no UI
  dependency.
- **PV-18** `DossierView(bundleURL:)` is the whole viewer. It gets the key, builds on a
  miss, shows the page in a web view, and offers **Rebuild**. Its states:
  - **loading**: a spinner while a build runs. A hit shows no spinner.
  - **page**: the preview.
  - **rebuilding**: the current page stays visible, the Rebuild button is disabled and
    shows progress.
  - **failed**: the reason in plain words (no `CHARACTER.md`, `CHARACTER.md` isn't
    UTF-8, not a bundle) and a Rebuild button.
- **PV-19** Rebuild is a button in the view's header and a `rebuild()` call an app can
  attach to a menu item or shortcut. A refresh refusal (PV-13) shows as a dismissible
  note above the page.
- **PV-20** The view watches `manifest.json` (a file-system event source, not polling).
  When it changes, the view recomputes the key, which either hits or builds. An app can
  also force a recheck by changing a `refreshToken` value it passes in.
- **PV-21** Changing `bundleURL` cancels any build in flight for the previous bundle.
  A late result for a bundle no longer selected is discarded.
- **PV-22** The web view loads the preview with read access to `.preview/` only.
  JavaScript is on, because the template's tabs need it. Navigation to anything but
  the page itself is blocked, and `http`/`https` links open in the default browser.
  Personaje's `DossierWebView` containment logic is the starting point.
- **PV-23** If writing the preview fails (read-only volume, no permission), the view
  shows the built HTML from memory and a note that it couldn't be saved. The page
  still renders because it is self-contained (PV-7).
- **PV-24** An app can put its own controls in the header (Escribir's "Edit in
  Personaje", for example) through a trailing-accessory view builder. The view has no
  app-specific actions of its own.
- **PV-25** The view needs nothing the app doesn't already hold. The app's existing
  security scope on the project folder covers the reads, and the `.preview/` and
  `manifest.json` writes.

### CLI

- **PV-26** `dossier preview <bundle> [--rebuild] [--to FILE]`. With no options it
  stores the preview (PV-9 to PV-11) and prints its path. `--rebuild` is PV-12.
  `--to` writes the HTML to `FILE` and stores nothing in the bundle. `--json` gives
  `character`, `bundle`, `page`, `key`, `hit` and `member`, plus `refreshError` when
  PV-13 applies.

## Not in scope

- Changing `renderPage()` or the committed page. The viewer ignores it, and Personaje's
  render-on-CAST.md-write continues as now.
- Editing in the viewer.
- Escribir and Personaje adoption. Escribir's requirements come after this ships.
- Pruning previews of bundles that were deleted. They go with their bundle.

## Acceptance

Tests use synthetic bundles (the existing `RenderProject` helper), except the last item.

1. Clean bundle with member: preview HTML == `renderPage()` HTML.
2. A preview leaves every file outside `.preview/` byte-identical (tree compare).
3. Committed page present and stale: the preview shows the current `CHARACTER.md` and
   the committed page is unchanged.
4. Image changed on disk: `renderPage()` throws, and the preview builds with
   `E-FILE-HASH` in the banner.
5. Image missing: the preview builds with the image left off.
6. No CAST.md / no member: the preview builds; with CAST.md beside `characters/`, the
   member is found.
7. No `CHARACTER.md`: building throws `CharacterDescriptionError`.
8. The key is unchanged by touching an image's bytes and changed by a `manifest.json`
   edit, a member edit or a `previewRules` bump.
9. Hit: no file in `.preview/` is created, deleted or has its modification date
   changed.
10. Miss after a manifest change: the new preview exists, the old one is gone, and a
    leftover temporary file is gone.
11. Failed build (`CHARACTER.md` removed): the old preview is still there.
12. `rebuild()` on an unchanged bundle rewrites the preview under the same key.
13. `rebuild()` after a hand edit of an image: the manifest is refreshed, the key
    changes and the old preview is gone.
14. `rebuild()` with an asset's file missing: it returns the refresh error and still
    gives a page.
15. `DossierView` state machine: loading → page on a miss, straight to page on a hit,
    failed on no `CHARACTER.md`, a stale result discarded after `bundleURL` changes
    (view-model tests, no UI automation).
16. Manual, local, not in CI: the four `podcasts/mr-mr-charles` dossiers show in
    `DossierView` in a test host, with `git status` in that project clean apart from
    `.preview/` (or fully clean once OQ-2 adds the ignore rule).

## Open questions

- **OQ-1, format:** §11 says the page is "the only HTML file in the bundle", and §5.2
  keeps hidden files out of `files`, `manifestChecksum` and validation. Is a hidden
  `.preview/` HTML file allowed? It follows the precedent of the hidden update marker.
  This should be settled in dossier-format, and the README there should name
  `.preview/` as a viewer's store. **This blocks a release, not the implementation.**
- **OQ-2, git:** projects should ignore `*.dossier/.preview/`. Who adds the rule: the
  library on first write (a `.gitignore` inside `.preview/` containing `*`), the apps,
  or the user? Recommendation: the library writes `.preview/.gitignore` with `*`, and
  PV-10's cleanup keeps it. That one file means no project-level change.
- **OQ-3:** should the viewer show the update marker ("Personaje is updating this
  dossier") from `DossierCore`'s `UpdateStatus`? Escribir does today, through
  `DossierUpdateStore`. Probably yes, as a header note, but it can follow.
- **OQ-4:** what `previewRules` starts at, and the rule for bumping it. Proposal: start
  at 1, and bump on any change to `previewPage()`'s inputs or leniency, even when the
  template is unchanged.

## What the current branch has

`feature/preview-page`, uncommitted. It builds previews into `~/Library/Caches`, keyed
by a hash of every file.

- **Kept:** `previewPage()`, `openForPreview(at:)`, the lenient modes of `PageFiller`
  and `BundleScan`, and the preview tests that don't involve the cache.
- **Replaced:** `DossierPreviewCache` becomes the in-bundle store (PV-9 to PV-14).
  `previewKey()` becomes PV-1's manifest-based key. The CLI gains `--rebuild` and
  `key`/`hit` in its output.
- **New:** `rebuild()` and the `DossierUI` product.
