---
type: doc
title: Integrating SwiftDossier
updated: 2026-11-10
---

# Integrating SwiftDossier

For app and tool developers who read, write or show `.dossier` character bundles. The format
is defined by [dossier-format](https://github.com/intrusive-memory/dossier-format)
(`docs/DOSSIER-FORMAT.md`, format version 2); `§` numbers below refer to that document.

## 1. Choose a product

| Product | Use it to | Depends on |
|---------|-----------|------------|
| `DossierCore` | Read bundles and `CAST.md`: assets, selections, staleness, completeness, update status. No writers. | Foundation, CryptoKit, SwiftReparto, Yams |
| `Dossier` | Create and write bundles, refresh, crop faces, check `CHARACTER.md`, validate, render the committed page, and build the preview. | `DossierCore`, SwiftReparto, Yams, ImageIO, Vision, CoreGraphics, UniformTypeIdentifiers |
| `DossierUI` | Show one bundle in SwiftUI with `DossierView`. | `Dossier`, `DossierCore`, SwiftUI, WebKit |
| `dossier` | Use the command-line tool from scripts. Run `dossier help`; build it with `make release`. | `Dossier`, swift-argument-parser |

Link the smallest product that does the job. A read-only app should link `DossierCore`
alone, so ImageIO and Vision stay out of its build. `Dossier` links `DossierCore` but doesn't
re-export it: `import Dossier` and `import DossierCore` when you use both.

```swift
.package(url: "https://github.com/intrusive-memory/SwiftDossier.git", .upToNextMinor(from: "0.3.0"))
// in a target: .product(name: "Dossier", package: "SwiftDossier")   // or DossierCore, DossierUI
```

Requirements: macOS 26 or iOS 26, Swift 6.2 (Swift 6 language mode, strict concurrency).

Some public types come from SwiftReparto and are not re-exported: `Cast.Member.fields` is a
`CastMember`, and `completeness(tier:)` takes a `CastRole`. If you name those types, add
SwiftReparto as a direct dependency and `import SwiftReparto`.

## 2. Open and read a bundle (`DossierCore`)

Open a bundle directly, or through the project's `CAST.md`. Going through `CAST.md` attaches
the member, which staleness and completeness need.

```swift
import DossierCore

// Directly. No member, so member-dependent checks are left out.
let bundle = try DossierBundle.open(at: bundleURL)

// Through CAST.md.
let cast = try Cast.load(castURL)
for member in cast.members {
  guard let bundle = try cast.openBundle(for: member) else { continue }  // nil: no dossier
  let portrait = bundle.selectedAsset(kind: .portrait)
  let portraitFile = portrait.flatMap { bundle.fileURL(forPath: $0.path) }
  let neutral = bundle.sampleURL(variant: "neutral")
  let stale = bundle.stale()                    // [StaleFinding]
  let report = try bundle.completeness()        // CompletenessReport?, nil without a role
}
```

Reading API at a glance:

| API | Returns |
|-----|---------|
| `bundle.manifest` | `Manifest`: `character`, `role`, `assets`, `files`, `prompts`, ... |
| `bundle.assets(kind:variant:)` | `[Asset]` in manifest order; `nil` arguments match anything |
| `bundle.selectedAsset(kind:variant:)` | The `selected` asset, or `nil` |
| `bundle.fileURL(forPath:)` | A file URL inside the bundle, or `nil` for a path that breaks §5.2 |
| `bundle.sampleURL(variant:model:)` | The selected voice sample's file |
| `bundle.identityPrompt`, `bundle.artStyle`, `bundle.pageURL` | Convenience reads |
| `bundle.stale(template:)` | `[StaleFinding]`. Pass `try DossierTemplate.current` (from `Dossier`) to include the page template. |
| `bundle.completeness()` / `completeness(tier:)` | `CompletenessReport?` |
| `bundle.updateStatus(at:)` | `UpdateStatus`; `isUpdating` is true while another writer holds a marker (§5.7) |
| `CanonicalName.canonicalize(_:)` / `isCanonical(_:)` | §2 names |

`Asset`, `Manifest` and the other model types are read-only views over the manifest JSON.
Their setters are not public.

## 3. Validate and handle findings (`Dossier`)

Validation never changes anything. It throws only when a resource bundled with the package
can't be read. Problems in the bundle are findings, not errors.

```swift
import Dossier
import DossierCore

let template = try DossierTemplate.current
let report = try bundle.validate(template: template)
// Or: try DossierBundle.validate(at: url, template: template)    // any directory, no member
// Or: try DossierBundle.validate(cast: castURL, template: template) // whole project

for finding in report.findings where finding.level == .error {
  print(finding.code.rawValue, finding.path ?? "", finding.message)
}
for entry in report.completeness where !entry.report.isComplete {
  print(entry.bundlePath, "missing", entry.report.missingRequired)
}
// report.exitStatus: 0 clean, 1 warnings only, 2 errors
```

`Finding.Code` holds §14's stable codes (`E-FILE-HASH`, `W-STALE`, ...); match on the code,
not the message. `template: nil` skips the template comparison. `E-FILE-HASH` and
`E-FILE-MISSING` usually mean "run `refresh`", not "the bundle is broken" (section 4).

## 4. Write and update a bundle (`Dossier`)

**SwiftDossier is the only writer of `manifest.json`.** Never edit, generate or patch it
yourself. Every write below copies or writes the file, rescans, recomputes the checksum,
writes the manifest atomically and reads it back. When a write throws, `manifest.json` holds
what it held before.

`DossierBundle` is a value type. The writing methods are `mutating` and leave your variable
holding the bundle as written, so keep it in a `var`.

```swift
import Dossier
import DossierCore

// Create an empty bundle and add its member to CAST.md (through SwiftReparto).
let created = try DossierBundle.create(
  character: "Mary Smith", role: "lead", in: charactersDirectory, cast: castURL
) { castReport in
  if let suggestion = castReport.suggestion { print(suggestion) }  // throw here to stop
}
var bundle = created.bundle

// Add a generated portrait and select it in the same write.
let portrait = try bundle.add(
  portraitPNG, kind: .portrait,
  options: AddOptions(sidecar: sidecarURL, select: true))

try bundle.reject(path: oldPath)              // kept, marked rejected
try bundle.setPrompt(.identity, "A tall woman in her forties")
```

| API | What it does |
|-----|--------------|
| `DossierBundle.create(character:role:in:cast:beforeCastWrite:)` | New empty bundle; canonicalizes the name; sets the member's `role` and `manifest` in `CAST.md`. Returns `CreatedBundle`. |
| `add(_:kind:options:)` | Copies a file in, names images by content, folds provenance from a sidecar or PNG metadata, records `derivedFrom`. Never overwrites. |
| `select(path:)` / `reject(path:)` | Status changes (§5.4). `select` demotes the previous selection to `candidate`. |
| `setPrompt(_:_:)` | Sets one `prompts` key (`PromptKey.identity`, `.portrait`, `.subject`). |
| `remove(path:)` | Deletes one asset and its file. Derived assets stay and read as stale. |
| `delete()` | Deletes the whole bundle. `CAST.md` is not changed. |
| `refresh(cast:beforeCastWrite:)` | Brings the manifest up to the disk. Returns `RefreshReport`. |
| `candidates(kind:variant:in:)` | Lists `.generations/<CHARACTER>/` (outside the bundle) so you can `add` from it. |

`AddOptions` carries `variant`, `model`, `sampleText`, `language`, `label`, `sidecar`,
`referenceRoles`, `provenance`, `derivedFrom`, `createdAt`, `select` and more. `JSONObject`
has no public initializer, so build `provenance` by parsing JSON:
`try JSONValue.parse(Data(#"{"notes":"hand-picked"}"#.utf8)).objectValue`.

### How refresh works

The files on disk are the source of truth; the manifest is an index of them. Other writes
record exactly the files they wrote and leave every other entry alone, so a file someone
changed in Finder or a text editor stays `E-FILE-HASH` until you refresh.

`refresh(cast:)`:

- accepts listed files whose bytes changed (`report.accepted`), keeping their names and
  reporting names that no longer match their hash (`report.nameMismatches`);
- drops entries of listed files that are gone and have no asset (`report.dropped`);
- adopts files another tool put in the bundle, as `candidate`, by §5.6's rules
  (`report.adopted`), and says why the rest stay unclassified (`report.unclassified`);
- given `CAST.md`, points an orphan's member at the bundle when its name matches exactly
  (`report.orphan`). A near match is never adopted.

It writes nothing when there is nothing to accept, drop or adopt. If an asset's file is
missing it refuses the whole call with `DossierWriteError.assetFilesMissing(_:)`; every other
write refuses that bundle too, and `remove(path:)` is the way out.

```swift
do {
  let report = try bundle.refresh(cast: castURL)
  report.unclassified.forEach { print($0.path, $0.reason) }
} catch DossierWriteError.assetFilesMissing(let paths) {
  // Ask the user: restore the files, or remove those assets.
}
```

### Editing CHARACTER.md

```swift
var description = try CharacterDescription.read(from: bundle) ?? CharacterDescription(text: "")
try description.setFrontMatter("artStyle", .string("ink and wash"))  // edits one key only
try description.markEdited("artStyle")                               // leaves draft.generated
try description.write(to: &bundle)
```

### Showing that a bundle is being updated

Each single write holds an update marker (§5.7) on its own. To make a sequence show as one
update to viewers, wrap it:

```swift
try bundle.withUpdate(label: "regenerate views") { bundle in
  _ = try bundle.add(front, kind: .view, options: AddOptions(variant: "front", select: true))
  _ = try bundle.add(back, kind: .view, options: AddOptions(variant: "back", select: true))
}
```

There is an `async` overload of `withUpdate(label:isolation:_:)` for a body that suspends.
For an update spanning separate calls or processes, use `beginUpdate(label:writer:lifetime:now:)`,
`renewUpdate(id:lifetime:now:)` and `endUpdate(id:)`. A marker is a signal, not a lock.

## 5. Crop faces and check descriptions (`Dossier`)

```swift
// Crop the face out of the selected portrait and select it.
let face = try bundle.deriveFace()                                    // Vision finds the face
let fixed = try bundle.deriveFace(box: FaceBox(x: 120, y: 80, width: 200, height: 200))
print(face.asset.path, face.crop.side, face.wasWritten, fixed.handSet)

// Check CHARACTER.md against the member's tier. Read-only.
let check = try bundle.checkDescription()
for issue in check.issues {
  print(issue.area.rawValue, issue.level.rawValue, issue.codeText ?? "", issue.message)
}
```

`deriveFace(box:detector:)` uses, in order: the box you pass, the selected face's recorded
box, or the largest face the detector finds. The default detector is `VisionFaceDetector()`;
pass your own `FaceDetector` in tests. With no selected portrait it throws
`DossierWriteError.noSelectedPortrait`; with no face, `.noFaceFound(_:)`.

`checkDescription()` reports front matter, sections against the tier, footnotes and open
questions in a `DescriptionCheckReport`. A missing or unreadable file is an issue in the
report, not a throw. `exitStatus` follows `ValidationReport`'s convention.

## 6. Render the committed page (`Dossier`)

`renderPage()` writes `<CHARACTER>-dossier.html` into the bundle and registers it as the
selected `dossier` asset. It needs the bundle's `CAST.md` member, so open the bundle through
the cast:

```swift
let cast = try Cast.load(castURL)
guard let member = cast.members.first(where: { $0.character == name }),
  var bundle = try cast.openBundle(for: member)
else { return }

let page = try bundle.renderPage()         // RenderedPage: asset, url, sizeBytes, banner
```

Without a member it throws `DossierWriteError.missingDerivedInput(kind:role:)`. It also refuses
when the integrity check finds changed or missing files (`renderRefusedByIntegrity`); run
`refresh` first. The same inputs and template give the same bytes. On failure the previous
page and manifest are left as they were.

## 7. Build and show the preview (`Dossier`)

The preview is the page built for viewing only. It never touches the committed page, works
without a `CAST.md` member, and lists integrity problems in a banner instead of refusing.

```swift
// The member comes from the CAST.md you pass. Nothing searches for one; nil means no member.
let bundle = try DossierBundle.openForPreview(at: bundleURL, cast: castURL)
let result = try bundle.showPreview()      // PreviewResult
// Show result.pageURL (<bundle>/.preview/<key>.html), or result.html when it couldn't be stored.
```

`PreviewResult`:

| Property | Meaning |
|----------|---------|
| `key` | The preview key (§11.1): a hash of `manifest.json`'s bytes, the member's hash and the template's hash. |
| `hit` | `true` when `.preview/<key>.html` was already there. Nothing was built or written. |
| `pageURL` | The stored page, or `nil` when it was built but couldn't be stored. |
| `html` | The page built this time; `nil` on a hit. Self-contained (images as `data:` URIs). |
| `banner` | Integrity findings shown on the page; `nil` on a hit. |
| `storeError` | Why storing failed (read-only volume, no permission), or `nil`. Not thrown. |

**What a hit means.** The key reads only `manifest.json`. A hit means the manifest, member
and template are unchanged since the stored page was built. An edit that bypasses the writer,
such as `CHARACTER.md` saved from a text editor, leaves the key as it was, so the stale page
still hits. That is what **Rebuild** is for.

**Rebuild** refreshes the manifest, then builds and stores the page even on a hit, while
holding an update marker:

```swift
var bundle = try DossierBundle.openForPreview(at: bundleURL, cast: castURL)
let rebuilt = try await bundle.rebuild(cast: castURL)   // RebuildResult
// rebuilt.preview: hit is always false. rebuilt.refreshError: the refresh refused (say, an
// asset's file is missing); the page was still built, from the manifest as it was.
```

### Showing a stored page without building

`showPreview()` builds on a miss, which reads every file in the bundle. Two calls only look
at what is already stored, so a viewer can show something at once and build later, off the
main actor.

| API | Returns | Use it when |
|-----|---------|-------------|
| `bundle.storedPreview()` (throws) | A `PreviewResult` with `hit == true`, `pageURL` set and `html`/`banner` `nil` when `.preview/<key>.html` exists; `nil` on a miss. Reads only `manifest.json` (for the key) and the file's metadata. Builds and writes nothing. | You are on the main actor or must stay cheap: show a hit at once, and on `nil` start `showPreview()` off the main actor. |
| `PreviewStore(bundle: url).anyStoredPage()` | The URL of a `.preview/*.html` file whatever its key (the most recently modified if there are several), or `nil`. Reads only the directory listing and metadata. Doesn't open the bundle or compute a key. | The bundle is being updated (`updateStatus(at:).isUpdating`): the manifest may be mid-change, so don't compute a key or build. Show the last stored page and wait for the marker to clear. |

```swift
// The order DossierView follows (§11.1, Showing a bundle).
if UpdateStatus.read(bundle: bundleURL, at: Date()).isUpdating {
  show(PreviewStore(bundle: bundleURL).anyStoredPage())         // may be out of date, or nil
} else if let hit = try bundle.storedPreview(), let page = hit.pageURL {
  show(page)                                                    // current; nothing built
} else {
  let result = try await buildOffMain(bundle)                   // your wrapper around showPreview()
  show(result)
}
```

`previewPage()` builds a `PreviewPage` (`html`, `key`, `banner`) and writes nothing;
`previewKey()` gives the key alone. `PreviewStore(bundle:)` also has `directory`,
`storedPage(forKey:)` and `store(_:)`. `showPreview`, `storedPreview`, `previewPage` and `previewKey` each have a `template:`
overload. The ones without it use `DossierTemplate.current`.

**The `.preview/` store.** Previews live in `<bundle>/.preview/` as `<key>.html`. Storing a
page writes it to a temporary file, renames it into place, then removes everything else in
`.preview/` except `.gitignore`. The library creates `.preview/.gitignore` containing `*`, so
previews are never committed. Building writes nothing in the bundle outside `.preview/`.
`manifest.json` changes only on a rebuild, and only when its refresh finds something to change.

## 8. Embed the viewer (`DossierUI`)

The README shows the basics: `DossierView(bundleURL:cast:)`, the `refreshToken` variant, the
accessory, and a `Commands` that reads `@FocusedValue(\.dossierRebuild)`. This section adds
what you need to wire it into an app.

```swift
import DossierUI

// In the accessory: DossierView(bundleURL: url, cast: castURL) { RebuildBadge() }
struct RebuildBadge: View {
  @Environment(\.dossierRebuild) private var rebuild
  var body: some View {
    if rebuild.isRebuilding { Text("Rebuilding...") }
  }
}
```

- **What it shows.** On a hit the stored page appears at once. On a miss it builds off the
  main actor and shows a spinner. While another writer holds an update marker it shows the
  last stored page with a note, and computes nothing until the marker clears.
- **When it reloads.** It watches the bundle directory for `manifest.json` replacements and
  update markers coming and going, without polling. Changing `refreshToken` forces a recheck.
  Changing `bundleURL` or `cast` cancels any build in flight. An edit that doesn't go through
  the writer isn't seen; that's what Rebuild is for.
- **`DossierRebuildAction`.** The view publishes it in the environment (`\.dossierRebuild`,
  non-optional, a no-op outside a `DossierView`) and as a focused scene value
  (`\.dossierRebuild`, `nil` when no `DossierView` is in the focused scene). Calling it is
  `@MainActor` and does nothing while `isRebuilding` is true.
- **Notes.** A refresh refusal and a failure to store the preview appear as dismissible notes
  above the page. The view has no other controls; put app actions in the accessory.
- **Links.** The page's `http`, `https` and `mailto` links open in the system browser or mail
  app. Other navigation is cancelled. The web view gets read access to `.preview/` only.
- **Security scope.** The view asks for nothing new. The app's existing security scope on
  the project folder covers its reads and its writes to `.preview/` and `manifest.json`, so
  the bundle and the `CAST.md` you pass must be inside a folder the app already holds.

`DossierViewModel`, `PreviewWebView`, `ManifestWatcher` and the `PreviewBuilding` protocol are
public so the view can be tested. Prefer `DossierView`; build your own UI on the `Dossier`
preview API instead of these pieces.

## 9. Errors and concurrency

### What throws

| Error type | Module | Thrown by |
|------------|--------|-----------|
| `DossierError` | `DossierCore` | Opening and reading: missing or invalid manifest, unknown version, not a `.dossier` directory, unreadable `CAST.md`, bad pointer, unreadable bundled resource. |
| `DossierWriteError` | `Dossier` | Every write: schema violations, missing asset files, duplicates, name and cast problems, face cropping, render refusals, update markers. |
| `CharacterDescriptionError` | `Dossier` | Reading or editing `CHARACTER.md`; also preview and rebuild when `CHARACTER.md` is missing or not UTF-8. |
| `PreviewStoreError` | `Dossier` | `PreviewStore.store(_:)` with an invalid key. |

All of them conform to `LocalizedError` except `PreviewStoreError`. Validation findings,
description-check issues, refresh refusals during a rebuild and preview store failures are
reported in results, not thrown. `DossierTemplate.current`, `.version` and `.sha256` are
throwing getters: write `try DossierTemplate.current`.

### What is async

Only `rebuild(cast:)`, `rebuild(cast:template:)` and the `async` overload of `withUpdate` are
`async`. Everything else in `DossierCore` and `Dossier` is synchronous, does file I/O, and is
not bound to any actor.

### The main actor

- `DossierView`, `DossierViewModel` and `DossierRebuildAction.callAsFunction()` are
  `@MainActor`. The `perform` closure you give `DossierRebuildAction(isRebuilding:perform:)`
  must be `@MainActor @Sendable`.
- Don't build previews, render, refresh, crop faces or validate on the main actor; they read
  every file in the bundle and may decode images. `rebuild(cast:)` is `nonisolated`; `await`
  it. Wrap the synchronous calls in a `@concurrent` function or a task off the main actor.
- `storedPreview()` and `updateStatus(at:)` read only `manifest.json`, metadata and markers,
  and are fine on the main actor.

### Sendable

`DossierBundle`, `Cast`, `Manifest`, `Asset`, every report and result type, and the error
enums are `Sendable`; `RebuildResult.refreshError` and `PreviewResult.storeError` are
`(any Error)?`. `FaceDetector`, `PreviewBuilding` and `ManifestWatchStarting` require
`Sendable` conformers. `beforeCastWrite` closures are synchronous and not `Sendable`.
Copies of a `DossierBundle` share no state: reopen to see another writer's changes.

## 10. Rules for integrators

- **The format belongs to dossier-format.** What a bundle is, what a field means and what a
  code means are defined in
  [dossier-format `docs/DOSSIER-FORMAT.md`](https://github.com/intrusive-memory/dossier-format).
  If it is silent on something you need, raise it there. Don't encode your own rule in an app.
- **Don't hand-edit `manifest.json`.** Write through `Dossier` or the `dossier` CLI. To bring
  the manifest up to files changed on disk, call `refresh`.
- **Don't write `.preview/` yourself, and don't commit it.** The library owns the store and
  writes its `.gitignore`.
- **Write `CAST.md` through SwiftReparto.** SwiftDossier sets only a member's `role` and
  `manifest`, and only through Reparto.
- **The format is a release candidate.** This version pins dossier-format `v2.0.0-rc.8`.
  Expect changes before 2.0.0.
