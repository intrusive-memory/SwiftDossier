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

The format is dossier-format's. The preview is dossier-format §11.1 (DF-68 to DF-74),
added in release candidate 8. Where this document and §11.1 differ, §11.1 wins and this
document is wrong.

## Requirements

### Format pin

- **PV-0** `DOSSIER_FORMAT_REF` is `v2.0.0-rc.8`, the first tag with §11.1, and
  `scripts/pin-resources.sh` has been run against it. The template is unchanged from
  rc.7 (0.1.1), so no bundled bytes should change. Nothing ships until the pin moves. No
  preview test depends on the pin (see *Acceptance*), so the preview work doesn't wait
  for the tag.

### Key

- **PV-1** The key is §11.1's. The function that computes it takes the template as a
  parameter, defaulting to `DossierTemplate.current`, so a test can vary it. The key is the SHA-256, as 64 lowercase hex characters, of the
  UTF-8 text of these five lines, **each ending in one LF**:
  1. `dossier-preview`
  2. `1`, which is §11.1's version. It is a constant in the library, taken from the
     format and never bumped by it. When §11.1's version changes, the pin moves and
     every key changes with it.
  3. the SHA-256 of `manifest.json`'s bytes as stored
  4. the CAST.md member's hash (§7, `Cast.Member.hash`), or nothing when there is no
     member
  5. the current template's `sha256` (§11, `DossierTemplate.sha256`). The template
     version is not part of the key.
- **PV-2** Computing the key reads `manifest.json` and CAST.md. It reads no image, voice
  or `CHARACTER.md` bytes.
- **PV-3** A project has one CAST.md, and the caller passes it in. Nothing searches the
  bundle's parent or grandparent for one (dossier-format §3: discovery starts at CAST.md,
  and nothing is found by scanning directories). The member is the one whose `manifest:`
  points at this bundle (§3, *Resolving a pointer*). No CAST.md passed, a CAST.md that is
  missing or unreadable, or one with no such member, means no member. That is not an
  error.
- **PV-4** Known blind spot, accepted: an edit that doesn't go through a SwiftDossier
  write leaves the key unchanged, so the existing preview is still shown. Examples are
  editing `CHARACTER.md` by hand or swapping an image in Finder. **Rebuild** (PV-12)
  covers this.

### Building

- **PV-5** A preview is built by `previewPage()` from the bundle as it is on disk:
  `CHARACTER.md`, the manifest, the member and the selected originals, through the same
  template as `renderPage()`. On a bundle a render accepts, with its member, the two give
  byte-identical HTML (§11.1 SHOULD; this library makes it a test).
- **PV-6** Building is lenient. Where a render refuses, a preview shows:
  - `E-FILE-HASH`, `E-FILE-MISSING` and `E-ZERO-BYTE` go in the page's integrity
    banner with the other findings;
  - an image or voice sample that is missing or can't be decoded is left off, and its
    field shows its empty text, as if no asset were selected;
  - no member means the record's `castMember` is `null`, and the fields that come from
    the member (role, tier, voice prompt) are empty;
  - `CHARACTER.md` in the bundle's root is used whether or not a `description` asset is
    selected. Front matter that isn't a YAML mapping is read as empty, and the body is
    shown;
  - the embedded manifest is the one §11 gives for a render at that moment: the manifest
    after a rescan (§5.6), leaving out every `dossier` asset, the page, and every other
    HTML file in the bundle's root;
  - any page in the bundle is neither read nor shown.

  The only failure is a `CHARACTER.md` that is missing or not UTF-8.
- **PV-7** A preview is one self-contained file. Images and samples are embedded as
  `data:` URIs, and nothing outside the file is referenced.
- **PV-8** Building writes nothing outside `<bundle>/.preview/`. In particular,
  `manifest.json`, the committed page and every other bundle file are untouched.

### Storing and cleaning up

- **PV-9** On a miss, the preview is written to a temporary file in `.preview/` whose
  name isn't a preview file's (`<key>.html.<uuid>.tmp`), then renamed to `<key>.html`.
  The `.preview/` directory is created if needed, and `.preview/.gitignore` is written
  with the one line `*` if it isn't there.
- **PV-10** Only after that rename succeeds, everything else in `.preview/` **except
  `.gitignore`** is removed: older previews, temporary files left by an earlier write,
  and anything else. If the build or the write fails, nothing is removed and the last
  preview stays.
- **PV-11** A hit writes and deletes nothing. Viewing a current dossier never touches
  the disk.

### Rebuild

- **PV-12** `rebuild()` holds an update marker (§5.7) from the start of the refresh to
  the end of the store. Under it, `rebuild()` brings the manifest up to the disk with
  `refresh()`, computes the key, then builds and stores a preview (PV-9, PV-10) **even
  if `<key>.html` already exists**. A rebuild is the only time a viewer writes in the
  bundle outside `.preview/` (§11.1).
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

### One CAST.md per project

- **PV-27** Nothing in SwiftDossier looks for a CAST.md. The parent/grandparent search
  goes from every path that has it: `previewMember(of:)` (preview) and
  `RenderCommand.findCast(near:)` (`dossier render`). Every API and command that reads a
  member takes the project's CAST.md from its caller. `dossier render <bundle>` without
  `--cast` fails with `cast-required` and says to pass `--cast CAST.md`. It no longer
  looks beside the bundle. This changes the shipped CLI; see REQUIREMENTS.md §5.
- **PV-28** A project has exactly one CAST.md. Every script in the project (each
  screenplay or episode) adds its characters to that file, and no write creates a second
  one. In SwiftDossier: `create`, `refresh` and `migrate` add to or update members in the
  CAST.md they are given, through SwiftReparto (SD-12). None of them creates a CAST.md. A
  `--cast` path that doesn't exist is an error (`DossierError.castUnreadable`, CLI code
  `castUnreadable`, as today), not a new file.
  Creating a project's CAST.md belongs to Personaje. When there isn't one, Personaje
  shows CAST.md as missing and lets the person create it.

### Viewer: the `DossierUI` product

- **PV-17** A new library product, `DossierUI`, depends on `Dossier`, SwiftUI and
  WebKit and supports macOS 26 and iOS 26. `DossierCore` and `Dossier` gain no UI
  dependency.
- **PV-18** `DossierView(bundleURL:cast:)` is the whole viewer, where `cast` is the
  project's CAST.md URL, or nil (PV-3). It gets the key, builds on a
  miss, shows the page in a web view, and offers **Rebuild**. It follows §11.1's
  *Showing a bundle* steps: while an update marker (§5.7, `UpdateStatus`) is active it
  shows the stored preview if there is one, builds nothing, and shows a header note
  ("being updated"). When no marker is active, it computes the key. Its states:
  - **updating**: a marker is active. The stored preview (if any) shows under the note.
    No key is computed and nothing is built until the marker clears.
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
- **PV-21** Changing `bundleURL` or `cast` cancels any build in flight for the previous bundle.
  A late result for a bundle no longer selected is discarded.
- **PV-22** The web view loads the preview with read access to `.preview/` only.
  JavaScript is on, because the template's tabs need it. Navigation to anything but
  the page itself is blocked. `http`, `https` and `mailto` links (the ones §11 allows)
  open outside the viewer, in the default browser or mail app. A click on a name or a
  field is handled as on a page (DF-51). Personaje's `DossierWebView` containment logic
  (`navigationPolicy(for:inBundle:)`) is the starting point. It cancels external links
  today, so opening them outside the viewer is new.
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

- **PV-26** `dossier preview <bundle> [--cast CAST.md] [--rebuild] [--to FILE]`. Without
  `--cast` there is no member (PV-3). With no options it
  stores the preview (PV-9 to PV-11) and prints its path. `--rebuild` is PV-12.
  `--to` writes the HTML to `FILE` and stores nothing in the bundle. `--json` gives
  `character`, `bundle`, `page`, `key`, `hit` and `member`, plus `refreshError` when
  PV-13 applies.

## Not in scope

- Changing `renderPage()` or the committed page. The viewer ignores it, and Personaje's
  render-on-CAST.md-write continues as now. (`dossier render`'s CAST.md lookup *is* in
  scope: PV-27.)
- Editing in the viewer.
- Escribir and Personaje adoption. Escribir's requirements come after this ships.
- Pruning previews of bundles that were deleted. They go with their bundle.

## Acceptance

Tests use synthetic bundles (the existing `RenderProject` helper), except item 16.

**No test is tied to a version.** No preview test reads a dossier-format fixture or
`conformance.json`. None hard-codes a key, a hash, a template version or §11.1's version.
Every expected value is computed when the test runs, from the inputs the library uses:
the bundle's `manifest.json` bytes, `Cast.Member.hash`, the template passed in, and the
library's section-version constant. A test that builds the key text assembles it itself,
line by line, and doesn't call the library's own helper for it. Moving the pin or changing
the template never breaks a preview test.

1. Clean bundle with member: preview HTML == `renderPage()` HTML.
2. A preview leaves every file outside `.preview/` byte-identical (tree compare).
3. Committed page present and stale: the preview shows the current `CHARACTER.md` and
   the committed page is unchanged.
4. Image changed on disk: `renderPage()` throws, and the preview builds with
   `E-FILE-HASH` in the banner.
5. Image missing: the preview builds with the image left off.
6. No CAST.md passed, or no member in it: the preview builds with no member. With the
   project's CAST.md passed, the member is found. A CAST.md beside the bundle that isn't
   passed in is not read.
7. No `CHARACTER.md`: building throws `CharacterDescriptionError`.
8. Key:
   - It equals the SHA-256 of the five lines the test assembles itself: `dossier-preview`,
     the section-version constant, the SHA-256 of the bundle's `manifest.json` bytes, the
     member's `hash`, and the template's `sha256`. Each line ends in one LF.
   - With no member, the fourth line is empty, so the text is still five LF-terminated
     lines.
   - It is 64 lowercase hex characters.
   - It is unchanged by changing an image's bytes on disk or editing `CHARACTER.md`.
   - It changes when `manifest.json` is edited, when the member is edited, and when a
     test template with a different `sha256` is passed in.
9. Hit: no file in `.preview/` is created, deleted or has its modification date
   changed.
10. Store, on synthetic bundles with the store seeded by the test (keys computed at run
    time):
    - **Current:** the store holds `<key>.html`, an older preview and a leftover
      `.tmp`. This is a hit, and nothing in `.preview/` changes.
    - **Out of date:** the store holds only a preview under another key. This is a miss,
      and afterwards the store holds exactly `.gitignore` (`*`) and `<key>.html`.
    - **Manifest change:** the new preview exists, the old one and any leftover
      temporary file are gone, and `.gitignore` is still there.
11. Failed build (`CHARACTER.md` removed): the old preview is still there.
12. `rebuild()` on an unchanged bundle rewrites the preview under the same key.
13. `rebuild()` after a hand edit of an image: the manifest is refreshed, the key
    changes and the old preview is gone.
14. `rebuild()` with an asset's file missing: it returns the refresh error and still
    gives a page.
15. `DossierView` state machine: loading → page on a miss, straight to page on a hit,
    failed on no `CHARACTER.md`, a stale result discarded after `bundleURL` changes,
    updating while a marker is active with no build until it clears (view-model tests,
    no UI automation).
16. Manual, local, not in CI: the four `podcasts/mr-mr-charles` dossiers show in
    `DossierView` in a test host, with `git status` in that project fully clean
    (`.preview/.gitignore`, PV-9).
17. `dossier render <bundle>` with no `--cast` fails with `cast-required`, even when a
    CAST.md sits in the bundle's parent or grandparent, and writes nothing. With
    `--cast` it renders as before. `RenderCommandTests.noCast` and `noScanning` are
    replaced by this test.
18. `dossier create --cast <missing path>` fails and creates no CAST.md. Two `create`
    calls for different characters with the same `--cast` leave one CAST.md with both
    members.

## Open questions

All four questions in the draft are settled by dossier-format §11.1 (release candidate 8):

- **OQ-1, format — settled.** §11.1 defines `.preview/` as a viewer's store, outside
  `files`, `manifestChecksum` and validation (§5.2). §11 now says "the only HTML file in
  the bundle's inventory". What's left is the pin (PV-0).
- **OQ-2, git — settled.** The library writes `.preview/.gitignore` with `*`, and
  cleanup keeps it (PV-9, PV-10).
- **OQ-3, update marker — settled: required.** It is step 1 of §11.1's *Showing a
  bundle* (PV-18).
- **OQ-4, `previewRules` — settled.** It is §11.1's version, `1`, set by the format
  (PV-1).

## What the current branch has

`feature/preview-page`, uncommitted. It builds previews into `~/Library/Caches`, keyed
by a hash of every file.

- **Kept:** `previewPage()`, `openForPreview(at:)`, the lenient modes of `PageFiller`
  and `BundleScan`, and the preview tests that don't involve the cache.
- **Replaced:** `DossierPreviewCache` becomes the in-bundle store (PV-9 to PV-14).
  `previewKey()` becomes §11.1's key (PV-1). The absent member becomes `null` in the
  record. `openForPreview(at:)` takes the
  project's CAST.md and its parent/grandparent search (`previewMember(of:)`) goes (PV-3).
  `dossier render`'s `findCast(near:)` goes too (PV-27). The CLI gains `--rebuild` and
  `key`/`hit` in its output.
- **New:** `rebuild()` and the `DossierUI` product.
