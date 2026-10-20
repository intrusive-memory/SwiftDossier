---
type: doc
updated: 2026-10-19
status: draft
---

# SwiftDossier

The Swift implementation of dossier-format: read, write, validate, migrate and render .dossier character bundles; the `dossier` CLI.

It implements [dossier-format](https://github.com/intrusive-memory/dossier-format) (`docs/DOSSIER-FORMAT.md`, format version 2) and is the only writer of a bundle's `manifest.json`. It generates nothing: images, voices and descriptions come from SwiftPersonaje and the tools it drives.

> **Status: requirements only.** No code yet. See [REQUIREMENTS.md](REQUIREMENTS.md).

Part of the [intrusive-memory](https://github.com/intrusive-memory) ecosystem.
