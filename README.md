---
type: doc
updated: 2026-11-01
---

# SwiftDossier

The Swift implementation of dossier-format: read, write, validate, migrate and render .dossier character bundles; the `dossier` CLI.

It implements [dossier-format](https://github.com/intrusive-memory/dossier-format) (`docs/DOSSIER-FORMAT.md`, format version 2) and is the only writer of a bundle's `manifest.json`. It generates nothing: images, voices and descriptions come from SwiftPersonaje and the tools it drives.

## Status

Version 0.2.0-dev implements dossier-format `v2.0.0-rc.7`, a release candidate: the format can still change. It reads and writes bundles, validates them, crops faces, checks `CHARACTER.md` and renders the page. `dossier migrate` isn't built yet and exits with a not-available message. See [REQUIREMENTS.md](REQUIREMENTS.md).

## Install

```swift
.package(url: "https://github.com/intrusive-memory/SwiftDossier.git", .upToNextMinor(from: "0.2.0-dev"))
```

| Product | Use |
|---------|-----|
| `DossierCore` | Read bundles. No ImageIO, Vision or ArgumentParser. |
| `Dossier` | Write bundles, crop faces, check descriptions. |
| `dossier` | The command-line tool. Run `dossier help`. |

Build the tool from a checkout with `make release`, which puts it in `bin/`. Requires macOS 26 or iOS 26, and Swift 6.2.

## Command line: preview and render

```
dossier preview <bundle> [--cast CAST.md] [--rebuild] [--to FILE] [--json]
dossier render  <bundle> --cast CAST.md [--json]
dossier render  --cast CAST.md [--json]
```

`preview` builds the bundle's page for viewing and never touches the committed page. With no options it stores the page in the bundle's `.preview/` and prints its path; asking again for an unchanged bundle is a hit and writes nothing. `--rebuild` first brings the manifest up to the disk, then builds and stores the page even when it is already stored. `--to FILE` writes the page to FILE and stores nothing in the bundle (it can't be combined with `--rebuild`). Without `--cast` the page has no cast member; no CAST.md is searched for. `--json` gives `character`, `bundle`, `page`, `key`, `hit` and `member`, plus `refreshError` (`code`, `message`) when `--rebuild`'s refresh refused: the page is then built from the manifest as it was and the exit status is 0. It exits 1 when `CHARACTER.md` is missing or the page can't be stored.

`render` writes the committed `<NAME>-dossier.html` into the bundle. A bundle needs `--cast`; without it the command fails with `cast-required` (exit 1). With `--cast` alone it renders every member that has a dossier.

## DossierUI

`DossierView` is the whole viewer of one `.dossier` bundle, for SwiftUI on macOS 26 and iOS 26: the preview page in a web view, a header with **Rebuild**, and notes above the page (the bundle is being updated, a refresh refusal you can dismiss, a preview that couldn't be saved).

```swift
import DossierUI

DossierView(bundleURL: bundle, cast: castURL)                    // cast is CAST.md, or nil
DossierView(bundleURL: bundle, cast: castURL, refreshToken: n)   // change n to show the bundle again
```

The view watches `manifest.json` and shows the bundle again when it changes. Changing `bundleURL` or `cast` cancels any build in flight.

**Accessory.** Put your own controls in the header, after Rebuild, with a trailing view builder. The view has no app-specific actions of its own.

```swift
DossierView(bundleURL: bundle, cast: castURL) {
  Button("Edit in Personaje") { openInPersonaje(bundle) }
}
```

**Binding Rebuild to a menu.** The view publishes a `DossierRebuildAction` with `focusedSceneValue`, and puts it in the environment (`@Environment(\.dossierRebuild)`) for the accessory. Read it in a command:

```swift
struct DossierCommands: Commands {
  @FocusedValue(\.dossierRebuild) private var rebuild

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("Rebuild Preview") { rebuild?() }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(rebuild == nil || rebuild?.isRebuilding == true)
    }
  }
}
```

**Security scope.** The view needs nothing the app doesn't already hold. The app's existing security scope on the project folder covers the reads and the writes to `.preview/` and `manifest.json`.

Part of the [intrusive-memory](https://github.com/intrusive-memory) ecosystem.
