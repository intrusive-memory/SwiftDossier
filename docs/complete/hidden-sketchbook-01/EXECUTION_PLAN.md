---
type: execution-plan
feature_name: OPERATION HIDDEN SKETCHBOOK
starting_point_commit: e35023cb0df41121f4a05238647f6a3a5c91e6fd
mission_branch: mission/hidden-sketchbook/01
iteration: 1
refined: 2026-11-10
requirements_file: REQUIREMENTS-preview.md
recon_report: RECON_REPORT.md
generated: 2026-11-10
state: completed
mission: hidden-sketchbook-01
updated: 2026-11-10
---

# EXECUTION_PLAN.md — SwiftDossier: Dossier preview and viewer

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

## Source and ground truth

- Requirements: `REQUIREMENTS-preview.md` (PV-0 to PV-28, Acceptance 1–18).
- Recon: `RECON_REPORT.md`, run 2, **CLEAR**. Every fact marked CONFIRMED there is ground
  truth. Sorties cite it and don't re-prove it.
- The format: dossier-format §11.1 (DF-68 to DF-74) at `~/Projects/dossier-format`,
  `a52dce9` (rc.8, unreleased). Where the requirements and §11.1 differ, §11.1 wins.

## Rules for every sortie

- Build and test only through `make` (`make build`, `make test`, `make test-ios`,
  `TEST_FILTER=<Suite> make test`). Never `swift build` or `swift test`.
- Tests use Swift Testing (`import Testing`), with synthetic bundles from `RenderProject`
  (`Tests/DossierTests/RenderSupport.swift`) in temporary directories.
- **No version-tied tests.** A preview test must not:
  - read a dossier-format fixture or `conformance.json`;
  - hard-code a key, a hash, a template version or §11.1's version.

  Expected values are computed when the test runs. A test that builds key text assembles
  it itself, without calling the library helper.
- No test writes under `~/Library/Caches` or anywhere outside its temporary directory.
- `DossierCore` and `Dossier` import no UI framework (recon A-14). This must still hold at
  the end of every sortie.
- Swift 6 language mode with strict concurrency. New targets use
  `swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]` like the existing ones.
- Never edit `~/Projects/dossier-format`, `~/Projects/apps/*`, or
  `~/Projects/podcasts/*`, except as Sortie 13's entry criteria allow.

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| A. Preview core | `Sources/Dossier/Rendering`, `Tests/DossierTests` | 5 (S1–S5) | 0 | none |
| B. CLI | `Sources/DossierCLICore`, `Tests/DossierCLICoreTests` | 2 (S6, S7) | 0 / 1 | S6: none. S7: A (S5) and S6 |
| C. DossierUI | `Sources/DossierUI`, `Tests/DossierUITests`, `Package.swift` | 4 (S8–S11) | 1 | A (S5) |
| D. Release gate | `Makefile`, `Sources/*/Resources`, mr-mr-charles (read + `.preview/` only) | 2 (S12, S13) | 2 | S12: rc.8 tag (deferred). S13: S7 |

---

## Work Unit A — Preview core

### Sortie 1: The member comes from the project's one CAST.md

**Priority**: 38. Every other preview sortie (11 of them) builds on `openForPreview(at:cast:)`.

**Entry criteria**:
- [ ] First sortie. No prerequisites.
- [ ] `make build` succeeds at the mission's starting commit.

**Tasks**:
1. In `Sources/Dossier/Rendering/DossierBundle+Preview.swift`:
   - Change `openForPreview(at:)` to `openForPreview(at: URL, cast: URL?)`.
   - The member is the one in `cast` whose `manifest:` points at the bundle (§3,
     *Resolving a pointer*, the same comparison `Cast.manifestURL(of:)` uses).
   - A nil, missing or unreadable `cast`, or no matching member, gives `member: nil` and
     is not an error (PV-3).
2. Delete `previewMember(of:)`, the parent/grandparent search (PV-27). Rewrite the doc
   comments that describe the search.
3. In the preview's page record, an absent member is `castMember: null`. Today it is an
   empty object at `DossierBundle+Preview.swift:90` (recon A-13) (PV-6).
4. Update every caller of `openForPreview(at:)`. The CLI's `PreviewCommand` passes `nil`
   until Sortie 7 adds `--cast`.
5. Tests in `Tests/DossierTests/PreviewTests.swift` (suite `previewPage`):
   - Rewrite `noMember` and `findsMember` for acceptance item 6.
   - Add a test that a CAST.md in the bundle's parent and grandparent is **not** read
     when `cast` is nil.
   - Add a test that the record's `castMember` is JSON `null` with no member.

**Exit criteria**:
- [ ] `grep -rn "previewMember" Sources` prints nothing.
- [ ] `grep -n "func openForPreview(at" Sources/Dossier/Rendering/DossierBundle+Preview.swift | grep -c "cast"` prints `1`.
- [ ] `TEST_FILTER=PreviewTests make test` passes. It includes the three tests from task 5.
- [ ] `make build` succeeds.

### Sortie 2: Leniency matches §11.1's *Building* rules

**Priority**: 33. It is on the critical path (10 sorties depend on it), and the page builder must be settled before the key and store.

**Entry criteria**:
- [ ] Sortie 1 exit criteria met.
- [ ] Read §11.1 *Building*: `~/Projects/dossier-format/docs/DOSSIER-FORMAT.md:885-907`.

**Tasks**:
1. `E-ZERO-BYTE` findings go on the preview's banner with `E-FILE-HASH` and
   `E-FILE-MISSING`.
   - Code: `Finding.Code.zeroByte` (recon B-05). Zero-byte files are already hashed
     (`BundleScan(allowingEmpty: true)`, recon A-03).
2. The embedded manifest is the one §11 gives for a render: after a rescan, leaving out
   every `dossier` asset, the page, and every other HTML file in the bundle's root.
   - Confirm `previewParts()` does this, and fix it where it doesn't.
3. Any page in the bundle is neither read nor shown. Front matter that isn't a YAML
   mapping is read as empty, and the body is shown.
4. Tests in `PreviewTests.swift`:
   - a zero-byte image gives `E-ZERO-BYTE` in `PreviewPage.banner`;
   - a stray `notes.html` in the bundle root is absent from the embedded manifest;
   - front matter that is a YAML list still builds, with the body shown.

**Exit criteria**:
- [ ] `TEST_FILTER=PreviewTests make test` passes. It includes the three tests from task 4.
- [ ] Acceptance items 1, 3, 4, 5 and 7 (`matchesRender`, `ignoresCommittedPage`,
      `changedImage`, `missingImage`, `noDescription`) still pass.

### Sortie 3: The key is §11.1's

**Priority**: 32. The key is used by the store, rebuild, the CLI and the view model.

**Entry criteria**:
- [ ] Sortie 2 exit criteria met.
- [ ] Read §11.1 *The key*: `DOSSIER-FORMAT.md:852-873`.

**Tasks**:
1. Add a library constant for §11.1's version (`"1"`), named `previewVersion`. It
   replaces `previewRules`.
2. Rewrite `previewKey()` as `previewKey(template: PageTemplate = DossierTemplate.current)`.
   - It returns the SHA-256 (64 lowercase hex characters) of five LF-terminated lines:
     1. `dossier-preview`
     2. `previewVersion`
     3. the SHA-256 of `manifest.json`'s bytes as stored
     4. `member?.hash ?? ""`
     5. the template's `sha256`
   - It reads only `manifest.json` (and the member already loaded). No `BundleScan`, and
     no image, voice or `CHARACTER.md` bytes (PV-2).
3. `PreviewPage.key` uses the same function. `previewPage()` accepts the same
   `template:` parameter, so the key and the page agree.
4. New suite `PreviewKeyTests` in `Tests/DossierTests/PreviewKeyTests.swift`, covering
   acceptance item 8 with **no literal hashes**:
   - The expected key is computed in the test from the bundle's `manifest.json` bytes,
     `member.hash` and the template's `sha256`, assembled line by line in the test.
   - With no member, the text is five lines and the fourth is empty.
   - The key matches `^[0-9a-f]{64}$`.
   - Unchanged after rewriting an image's bytes and after editing `CHARACTER.md`.
   - Changed after a `manifest.json` edit, after a member edit, and with a test
     `PageTemplate` whose `sha256` differs.
5. Delete the old `key` test in `PreviewTests.swift`. Delete `diskChecksum()` if nothing
   else uses it.

**Exit criteria**:
- [ ] `grep -rn "previewRules" Sources Tests` prints nothing.
- [ ] `TEST_FILTER=PreviewKeyTests make test` passes, with at least 6 tests.
- [ ] `grep -nE '"[0-9a-f]{64}"' Tests/DossierTests/PreviewKeyTests.swift` prints nothing.
- [ ] `TEST_FILTER=PreviewTests make test` passes.

### Sortie 4: The in-bundle store replaces the cache

**Priority**: 30.5. It creates the store and the shared entry point, and atomic file I/O makes it the highest-risk sortie.

**Entry criteria**:
- [ ] Sortie 3 exit criteria met.
- [ ] Read §11.1 *The store*, *Showing a bundle* and *Storing*: `DOSSIER-FORMAT.md:843-848,875-883,909-922`.

**Tasks**:
1. Replace `Sources/Dossier/Rendering/DossierPreviewCache.swift` with an in-bundle store
   in `Sources/Dossier/Rendering/PreviewStore.swift`.
   - Shape: `public struct PreviewStore: Sendable`, rooted at `<bundle>/.preview/`.
   - `storedPage(forKey:) -> URL?`. A hit reads and writes nothing (PV-11).
   - `store(_ page: PreviewPage) throws -> URL`. It writes `<key>.html.<uuid>.tmp`, then
     renames it to `<key>.html`. It creates `.preview/` if needed and writes `.gitignore`
     containing `*\n` if absent (PV-9).
   - Only after the rename succeeds, it removes everything in `.preview/` except
     `<key>.html` and `.gitignore`. A failed build or write removes nothing (PV-10).
2. Add the library entry point the viewer and CLI share:
   `public func showPreview(template: PageTemplate = DossierTemplate.current) throws -> PreviewResult`.
   - It returns the page URL, `hit: Bool`, the key and the banner.
   - On a write failure (read-only volume) it returns the built HTML with a
     `storeError`, and doesn't throw (PV-23).
3. Remove all `~/Library/Caches` code (`cachesDirectory`, `"Dossier Previews"`). Its only
   other caller is `PreviewCommand` at `Sources/DossierCLICore/ReadCommands.swift:417`.
   Switch that call to `showPreview()` and print `PreviewResult`'s page URL. Sortie 7 adds
   the CLI's new flags.
4. New suite `PreviewStoreTests` (`Tests/DossierTests/PreviewStoreTests.swift`) covering
   acceptance items 2, 9, 10 and 11. Stores are seeded by the test with keys computed at
   run time:
   - **Item 2:** tree compare. Every file outside `.preview/` is byte-identical after a
     store.
   - **Item 9:** on a hit, nothing in `.preview/` is created or deleted, and no
     modification date changes.
   - **Item 10, current:** `<key>.html` plus an older preview plus a `.tmp` is a hit, and
     nothing changes.
   - **Item 10, out of date:** a store holding only another key ends holding exactly
     `.gitignore` and `<key>.html`.
   - **Item 10, manifest change:** a new key, the old one gone, `.gitignore` kept.
   - **Item 11:** with `CHARACTER.md` removed, building throws and the old preview
     remains.
   - **PV-23:** a store in a read-only `.preview/` (`chmod 0555`) gives the HTML and a
     `storeError`.
5. Delete `cacheLifecycle` and the `cache()` helper from `PreviewTests.swift`.

**Exit criteria**:
- [ ] `grep -rn "cachesDirectory\|DossierPreviewCache\|Dossier Previews" Sources Tests` prints nothing.
- [ ] `TEST_FILTER=PreviewStoreTests make test` passes, with at least 7 tests.
- [ ] `make test` passes (full macOS suite).

### Sortie 5: rebuild()

**Priority**: 27.5. It is the last library piece. It gates work units B (S7) and C.

**Entry criteria**:
- [ ] Sortie 4 exit criteria met.
- [ ] Read §11.1 *Rebuild*: `DOSSIER-FORMAT.md:924-933`.
- [ ] Recon facts:
  - `refresh()` writes only on change and throws `DossierWriteError.assetFilesMissing`
    (A-08);
  - `withUpdate(label:isolation:_:)` is `mutating async` (B-06).

**Tasks**:
1. Add
   `public mutating func rebuild(cast: URL?, template:) async throws -> RebuildResult`
   in `Sources/Dossier/Rendering/DossierBundle+Rebuild.swift`:
   - inside `withUpdate`, call `refresh(cast:)`;
   - re-open the member, recompute the key, build, and store even on a hit (PV-12);
   - `RebuildResult` carries the store result and an optional `refreshError` (PV-13).
2. If `refresh` throws, it continues with the unchanged manifest, still builds and stores,
   and returns the error in `refreshError`. Only `CHARACTER.md` missing or not UTF-8
   throws.
3. `rebuild` is nonisolated. Its doc comment says callers run it off the main actor
   (PV-15).
4. New suite `RebuildTests` (`Tests/DossierTests/RebuildTests.swift`):
   - **Item 12:** on an unchanged bundle, the same key, and `<key>.html` is rewritten
     (modification date moves). `manifest.json` bytes are unchanged.
   - **Item 13:** after hand-editing an image, the manifest is refreshed, the key differs,
     and the old preview is gone.
   - **Item 14:** with an asset's file deleted, `refreshError` is
     `assetFilesMissing`, a page is returned, and its key is the unchanged manifest's.
   - An update marker is held for the whole rebuild. `rebuild` takes an `internal`
     test-only closure, `duringUpdate: ((DossierBundle) -> Void)? = nil`. It is called
     after the refresh and before the store, and tests reach it through
     `@testable import Dossier`.
     - Inside the closure the test asserts exactly one `.update-*.json` in the bundle
       root, following `UpdateMarkerTests`' `hiddenNames` pattern.
     - After the rebuild returns, none remains.

**Exit criteria**:
- [ ] `TEST_FILTER=RebuildTests make test` passes, with at least 4 tests.
- [ ] `make test` passes.
- [ ] `grep -rnE "import (SwiftUI|WebKit|AppKit|UIKit)" Sources/DossierCore Sources/Dossier` prints nothing.

---

## Work Unit B — CLI

### Sortie 6: `dossier render` needs `--cast`; no CAST.md search anywhere

**Priority**: 11. Nothing in A or C depends on it, so it can go any time before S7.

**Entry criteria**:
- [ ] No sortie prerequisites (the dependency graph allows it any time before S7). The
      recommended order dispatches it after S8, because S1 and S4 also edit
      `ReadCommands.swift` (see Parallelism Structure).

**Tasks**:
1. In `Sources/DossierCLICore/ReadCommands.swift`, delete `RenderCommand.findCast(near:)`
   (PV-27).
2. In `RenderCommand.validate()`, a bundle with no `--cast` fails with code
   `cast-required` and a message telling you to pass `--cast CAST.md`. Nothing is
   written. `--cast` alone (render all) is unchanged.
3. Update the command's help text and `REQUIREMENTS.md` §5's comment if needed (already
   amended: `dossier render [<bundle>] --cast CAST.md`).
4. Tests in `Tests/DossierCLICoreTests/RenderCommandTests.swift`:
   - Replace `noCast` and `noScanning` with acceptance item 17. With a CAST.md in the
     bundle's parent and grandparent and no `--cast`: exit 1, `error.code == "cast-required"`,
     and the page is byte-identical before and after. With `--cast` it renders.
   - Update every other render test that relied on the search so it passes `--cast`.
5. Add acceptance item 18 to `Tests/DossierCLICoreTests/CommandTests.swift`, which holds
   the `create` tests:
   - `dossier create --cast <missing>` exits non-zero with `castUnreadable`, and no file
     exists at that path afterwards.
   - Two `create` calls with one `--cast` leave one CAST.md with both members, and no
     other `CAST.md` under the temp root (`find`).

**Exit criteria**:
- [ ] `grep -rn "findCast\|cast-not-found" Sources Tests` prints nothing.
- [ ] `TEST_FILTER=RenderCommandTests make test` passes.
- [ ] `TEST_FILTER=CommandTests make test` passes, including both item-18 tests.

### Sortie 7: `dossier preview` uses the store, `--cast` and `--rebuild`

**Priority**: 8. It is a leaf except for S13.

**Entry criteria**:
- [ ] Sortie 5 and Sortie 6 exit criteria met.

**Tasks**:
1. `PreviewCommand` (`ReadCommands.swift:390-428`) becomes
   `dossier preview <bundle> [--cast CAST.md] [--rebuild] [--to FILE] [--json]` (PV-26):
   - With no options, it stores via Sortie 4's entry point and prints the page path.
   - `--rebuild` calls `rebuild(cast:)`.
   - `--to` writes the HTML to FILE and stores nothing in the bundle (no `.preview/`
     created).
   - Without `--cast` there is no member.
2. The `--json` object has `character`, `bundle`, `page`, `key`, `hit` and `member`
   (Bool). It adds `refreshError` (code and message) when rebuild's refresh refused.
3. New suite `PreviewCommandTests` (`Tests/DossierCLICoreTests/PreviewCommandTests.swift`),
   using synthetic projects in temp directories:
   - the first run is `hit: false` and the second is `hit: true` with the same `key`;
   - `--to` leaves no `.preview/`;
   - `--rebuild` on an unchanged bundle is `hit: false` with the same key;
   - `--rebuild` with a missing asset file has `refreshError` and exits 0;
   - no `--cast` gives `member: false` even with CAST.md beside the bundle, and `--cast`
     gives `member: true`;
   - a missing `CHARACTER.md` exits 1.
4. Update `README.md`'s CLI section for `preview` and `render`.

**Exit criteria**:
- [ ] `TEST_FILTER=PreviewCommandTests make test` passes, with at least 6 tests.
- [ ] `make test` passes.
- [ ] `grep -n "rebuild" Sources/DossierCLICore/ReadCommands.swift` matches the new flag.

---

## Work Unit C — DossierUI

### Sortie 8: The `DossierUI` target and its view model

**Priority**: 18.5. It is the foundation of work unit C, with new concurrency code. Run it before S6/S7 when sequential.

**Entry criteria**:
- [ ] Sortie 5 exit criteria met.

**Tasks**:
1. In `Package.swift`, add the library product `DossierUI`, the target
   `Sources/DossierUI` (depends on `Dossier`; links SwiftUI and WebKit), and the test
   target `DossierUITests`, with the same `swiftSettings` (PV-17).
   - `DossierCore` and `Dossier` are unchanged.
   - The auto-generated `SwiftDossier-Package` scheme picks it up (recon A-24).
2. `Sources/DossierUI/DossierViewModel.swift`, an `@MainActor @Observable` class:
   - **Inputs:** `bundleURL`, `cast: URL?`, `refreshToken`.
   - **States:** `updating`, `loading`, `page(PreviewResult)`, `rebuilding`,
     `failed(reason)`, plus dismissible `refreshNote` and `storeNote` (PV-18, PV-19,
     PV-23).
   - **Showing:**
     - If `UpdateStatus` shows an active marker, it shows the stored preview if any, and
       goes to `updating` without computing a key.
     - Otherwise it computes the key. A hit goes straight to `page` with no `loading`.
     - A miss goes to `loading`, then builds off the main actor (a detached task or a
       nonisolated helper), then `page` (PV-15, PV-18).
   - **`rebuild()`** keeps the current page visible in `rebuilding`, and surfaces
     `refreshError` as `refreshNote`.
   - **Changing inputs:** changing `bundleURL` or `cast` cancels the in-flight task. A
     result for a previous input is discarded, matched by a generation counter (PV-21).
   - **Failure reasons** in plain words: no `CHARACTER.md`, `CHARACTER.md` isn't UTF-8,
     not a bundle.
3. Make the build step injectable (a protocol or closure), so tests can hold a build open
   to test cancellation.
4. New suite `DossierViewModelTests` (`Tests/DossierUITests/DossierViewModelTests.swift`),
   acceptance item 15:
   - a miss goes `loading` → `page`;
   - a hit goes straight to `page` with no `loading` observed;
   - no `CHARACTER.md` gives `failed`;
   - when `bundleURL` changes mid-build, the late result is discarded;
   - an active marker gives `updating` and no build call;
   - `rebuild` keeps `page` visible during `rebuilding`.

**Exit criteria**:
- [ ] `grep -n "DossierUI" Package.swift` shows a product, a target and a test target.
- [ ] `TEST_FILTER=DossierViewModelTests make test` passes, with at least 6 tests.
- [ ] `make test-ios` passes.
- [ ] `grep -rnE "import (SwiftUI|WebKit|AppKit|UIKit)" Sources/DossierCore Sources/Dossier` prints nothing.

### Sortie 9: Watch `manifest.json`

**Priority**: 10. DispatchSource code is high-risk. It is on the critical path to S11.

**Entry criteria**:
- [ ] Sortie 8 exit criteria met.

**Tasks**:
1. Add `Sources/DossierUI/ManifestWatcher.swift`, a `DispatchSource` file-system watcher
   (no polling) that reports changes to `<bundle>/manifest.json` (PV-20).
   - Writers replace the manifest by atomic rename, so it watches the bundle directory, or
     re-arms on `.rename` / `.delete`. It keeps firing after the file is replaced.
   - It also reports marker files appearing and disappearing, so `updating` can clear.
2. The view model starts a watcher per `bundleURL`, cancels it when the input changes,
   and on an event recomputes the key (hit, or build). A `refreshToken` change does the
   same.
3. New suite `ManifestWatcherTests`:
   - an atomic replace of `manifest.json` fires;
   - two replaces in a row both fire;
   - writing a file inside `.preview/` doesn't fire as a manifest change (no loop from
     the viewer's own store);
   - a cancelled watcher fires nothing.

   Use bounded waits (confirmation with a timeout), not `sleep`.
4. Add to `DossierViewModelTests`: a manifest change while on `page` leads to a new key
   and `page`.

**Exit criteria**:
- [ ] `TEST_FILTER=ManifestWatcherTests make test` passes, with at least 4 tests.
- [ ] `TEST_FILTER=DossierViewModelTests make test` passes.
- [ ] `grep -rn "Timer\|asyncAfter\|Task.sleep" Sources/DossierUI` prints exactly one line:
      Sortie 8's one-shot marker-expiry wait in `DossierViewModel.swift` (a marker can
      expire with nothing on disk changing, so the watcher can't see it). Sortie 9 adds no
      other timer, sleep or polling. (Amended 2026-11-10 by user decision during execution.)

### Sortie 10: The preview web view and its navigation policy

**Priority**: 10. It can run alongside S9, since both only need S8. S11 needs it.

**Entry criteria**:
- [ ] Sortie 8 exit criteria met.
- [ ] Read Personaje's containment as the starting point (read-only):
      `~/Projects/apps/Personaje/Personaje/Dossier/DossierWebView.swift:67-95,179-192` (recon A-30).

**Tasks**:
1. Add `Sources/DossierUI/PreviewNavigation.swift` with a pure function,
   `PreviewNavigation.policy(for: URL, page: URL) -> Policy`, where `Policy` is `.allow`,
   `.openExternally` or `.cancel`:
   - `.allow` for the page itself and fragments on it;
   - `.openExternally` for `http`, `https` and `mailto` (the links §11 allows);
   - `.cancel` for everything else, including other files in the bundle (PV-22).
2. Add `Sources/DossierUI/PreviewWebView.swift`, a `WKWebView` representable for macOS
   (`NSViewRepresentable`) and iOS (`UIViewRepresentable`):
   - JavaScript is on.
   - Its input is either a stored page URL, loaded with
     `loadFileURL(<key>.html, allowingReadAccessTo: <bundle>/.preview/)`, or in-memory
     HTML, loaded with `loadHTMLString(html, baseURL: nil)` (PV-22, PV-23).
   - Its navigation delegate applies `PreviewNavigation.policy`. `.openExternally` opens
     with `NSWorkspace.shared.open` on macOS and `UIApplication.shared.open` on iOS.
   - It registers a `WKScriptMessageHandler` for the template's DF-51 messages
     (`template/dossier.js:6`) and forwards them to an optional
     `onMessage: ((String, Any) -> Void)?` callback.
3. New suite `PreviewNavigationTests` (`Tests/DossierUITests/PreviewNavigationTests.swift`):
   - the page is `.allow`;
   - `page#profile` is `.allow`;
   - `<bundle>/images/x.png` is `.cancel`;
   - `file:///etc/passwd` is `.cancel`;
   - `https://example.com` is `.openExternally`;
   - `mailto:a@b.c` is `.openExternally`;
   - `javascript:` / `data:` top-level navigation is `.cancel`.

**Exit criteria**:
- [ ] `TEST_FILTER=PreviewNavigationTests make test` passes, with at least 7 tests.
- [ ] `grep -n "allowingReadAccessTo" Sources/DossierUI/PreviewWebView.swift` matches a
      line whose access URL is the `.preview` directory, not the bundle.
- [ ] `make test-ios` passes (`PreviewWebView` compiles for iOS).

### Sortie 11: `DossierView`

**Priority**: 6.5. It puts work unit C together.

**Entry criteria**:
- [ ] Sortie 9 and Sortie 10 exit criteria met.

**Tasks**:
1. `Sources/DossierUI/DossierView.swift`:
   `public struct DossierView<Accessory: View>: View`, with
   `init(bundleURL: URL, cast: URL?, refreshToken: AnyHashable? = nil, @ViewBuilder accessory: () -> Accessory)`,
   and an `init` without `accessory` where `Accessory == EmptyView` (PV-18, PV-24).
2. Header:
   - the Rebuild button (disabled, with a `ProgressView`, while `rebuilding`);
   - then the accessory.
3. Notes above the page:
   - updating;
   - the refresh refusal (dismissible) (PV-19);
   - the store failure (PV-23).
4. Body by state:
   - `loading`: a `ProgressView`;
   - `page`: `PreviewWebView`;
   - `failed`: the reason text and a Rebuild button;
   - `updating`: the stored page under the note, or the note alone.
5. Expose rebuild to apps. A public `DossierRebuildAction` goes in the environment
   (`@Environment(\.dossierRebuild)`) and is published with `focusedSceneValue`, so an
   app can bind it to a menu item or keyboard shortcut (PV-19).
6. Add a `DossierUI` section to `README.md`:
   - the init;
   - the accessory;
   - binding rebuild to a menu;
   - the security-scope note (PV-25): the app's existing scope on the project folder
     covers reads and the `.preview/` / `manifest.json` writes.

**Exit criteria**:
- [ ] `make build` and `make test-ios` pass.
- [ ] `grep -n "public struct DossierView" Sources/DossierUI/DossierView.swift` matches.
- [ ] `grep -n "DossierUI" README.md` matches.
- [ ] [judgment] `DossierView` has no app-specific actions. Every control in the header
      other than Rebuild comes only from the `accessory` builder (PV-24).

---

## Work Unit D — Release gate

### Sortie 12: Pin dossier-format rc.8

**Priority**: 2.5. It is deferred on an external release.

**Entry criteria**:
- [ ] **deferred:** `git ls-remote --tags https://github.com/intrusive-memory/dossier-format v2.0.0-rc.8`
      prints a line. Releasing rc.8 in dossier-format is a human action (recon B-01).
- [ ] Sorties 1–11 exit criteria met.

**Tasks**:
1. Set `DOSSIER_FORMAT_REF = v2.0.0-rc.8` in `Makefile` (the only place it is defined).
2. `rm -rf .dossier-format && make fixtures`, then run `scripts/pin-resources.sh`.
3. Confirm that `Sources/Dossier/Resources/template/VERSION.json` is still `0.1.1`,
   `8819dcef…` (recon B-04). Any changed bundled resource is listed in the commit message.
4. Run `make test` and `make test-ios`.

**Exit criteria**:
- [ ] `grep -n "^DOSSIER_FORMAT_REF = v2.0.0-rc.8" Makefile` matches.
- [ ] `git diff --stat -- Sources/*/Resources` shows only `PINNED.sha256` changes, or
      none.
- [ ] `make test` and `make test-ios` pass.

### Sortie 13: Local acceptance on mr-mr-charles (item 16, not CI)

**Priority**: 2.5. It is a manual local check, run last.

**Entry criteria**:
- [ ] Sortie 7 exit criteria met.
- [ ] **User approval recorded** to write `characters/*.dossier/.preview/` in
      `~/Projects/podcasts/mr-mr-charles`. That project is on `dossier/start-to-finish`
      and dirty (recon), so record `git status --porcelain` before starting.

**Tasks**:
1. `make install` (or use `./bin/dossier` from `make release`).
2. For each of BILLY, DONNIE, MIMI and MITCH:
   `dossier preview characters/<NAME>.dossier --cast CAST.md --json`, run from the
   project root (CAST.md is at the root, recon A-32). Record `key`, `hit` and `member`.
3. Run each again. All four must be `hit: true` with the same keys.
4. Compare `git status --porcelain` with the pre-run snapshot.
5. Write the results to `ACCEPTANCE_PREVIEW.md` in SwiftDossier's root. The visual check in
   a `DossierView` test host is left to the human.

**Exit criteria**:
- [ ] All four first runs exit 0 with `member: true`, and all four second runs are
      `hit: true`.
- [ ] mr-mr-charles `git status --porcelain` is identical before and after (the
      `.preview/` stores are ignored by their own `.gitignore`).
- [ ] `ACCEPTANCE_PREVIEW.md` exists and lists the four keys.

---

## Local Dependency Map

<!-- Carried from RECON_REPORT.md. Sortie agents may read these paths; they may not edit them. -->

| Dependency | Resolved version | Local checkout | Status |
|------------|------------------|----------------|--------|
| intrusive-memory/SwiftReparto | 0.2.1 (`94c4369`) | `~/Projects/package-collection/pkg/SwiftReparto` (HEAD `6638dc8`). Read the resolved copy instead: `~/Library/Developer/Xcode/DerivedData/SwiftDossier-bluqdwvkjmyykbakubzpcoexytyo/SourcePackages/checkouts/SwiftReparto` | LOCAL_AHEAD |
| jpsim/Yams | 6.2.2 (`a27b21e`) | — | NO_LOCAL_CHECKOUT |
| apple/swift-argument-parser | 1.8.2 (`6a52f32`) | — | NO_LOCAL_CHECKOUT |
| intrusive-memory/dossier-format (Makefile pin) | v2.0.0-rc.7 (`.dossier-format/`) | `~/Projects/dossier-format` (`a52dce9`, rc.8 unreleased): the §11.1 citations | LOCAL_AHEAD |

Reference reading only, never edited:
- Personaje: `~/Projects/apps/Personaje` (`9611d92`)
- Escribir: `~/Projects/apps/Escribir` (AMBIGUOUS: three checkouts; not needed by any
  sortie)

## Open Questions

_No blocking open questions identified during breakdown._

Recorded conditions (not questions):
- **Sortie 12 waits on the rc.8 release in dossier-format** (recon B-01). It is
  `deferred`, not blocked. No other sortie depends on it.
- **Sortie 13 needs your approval** to write `.preview/` stores into mr-mr-charles. The
  supervisor asks before dispatching it.

## Parallelism Structure

**Critical Path**: S1 → S2 → S3 → S4 → S5 → S8 → S9 → S11 → S12 (9 sorties; S12 is
deferred, so the working critical path is 8).

**Parallel Execution Groups** (what the dependency graph allows):
- **Group 1:** A: S1→S5 (sequential) ∥ B: S6
- **Group 2** (after S5): C: S8 ∥ B: S7
- **Group 3** (after S8): C: S9 ∥ C: S10. Then S11 (after S9 and S10).
- **Group 4:** S13 (after S7, with approval) ∥ C. S12 when rc.8 exists.

**Agent Constraints — and why this mission runs effectively sequentially:**
- **Every sortie has build and test steps** (`make test`, `make test-ios`). By the refine
  rules, all are **supervising agent only**, and no sortie is a no-build sub-agent task.
- **Shared working tree:** every sortie builds the same scheme in the same checkout.
  - Two agents at once would compile each other's half-finished edits.
  - They would contend for one DerivedData.
- **File overlap:**
  - S6 and S1/S4 all edit `Sources/DossierCLICore/ReadCommands.swift`.
  - S7 and S6 edit the same command file.
  - S9 and S10 both add to `Sources/DossierUI` and `Package.swift`'s test target.
- **Recommendation: dispatch one sortie at a time**, in priority order:
  S1, S2, S3, S4, S5, S8, S6, S9, S10, S7, S11, then S13 (approval) and S12 (deferred).
  The real parallelism would need worktrees per agent with a merge step. That isn't worth
  it for 13 sorties of this size.

## Summary

| Metric | Value |
|--------|-------|
| Work units | 4 |
| Total sorties | 13 |
| Open questions | 0 |
| Dependencies mapped | 4 (+2 reference apps) |
| Dependency structure | layers: A (S1→S5) ∥ S6 → S7; A → C (S8 → S9 ∥ S10 → S11); S12 deferred; S13 after S7 |
| Execution order | Sequential, one supervising agent (see Parallelism Structure) |
