---
type: doc
updated: 2026-11-01
---

# SwiftDossier

The Swift implementation of dossier-format: read, write, validate, migrate and render .dossier character bundles; the `dossier` CLI.

It implements [dossier-format](https://github.com/intrusive-memory/dossier-format) (`docs/DOSSIER-FORMAT.md`, format version 2) and is the only writer of a bundle's `manifest.json`. It generates nothing: images, voices and descriptions come from SwiftPersonaje and the tools it drives.

## Status

Version 0.1.0-dev implements dossier-format `v2.0.0-rc.5`, a release candidate: the format can still change. It reads and writes bundles, validates them, crops faces and checks `CHARACTER.md`. `dossier render` and `dossier migrate` aren't built yet and exit with a not-available message. See [REQUIREMENTS.md](REQUIREMENTS.md).

## Install

```swift
.package(url: "https://github.com/intrusive-memory/SwiftDossier.git", .upToNextMinor(from: "0.1.0-dev"))
```

| Product | Use |
|---------|-----|
| `DossierCore` | Read bundles. No ImageIO, Vision or ArgumentParser. |
| `Dossier` | Write bundles, crop faces, check descriptions. |
| `dossier` | The command-line tool. Run `dossier help`. |

Build the tool from a checkout with `make release`, which puts it in `bin/`. Requires macOS 26 or iOS 26, and Swift 6.2.

Part of the [intrusive-memory](https://github.com/intrusive-memory) ecosystem.
