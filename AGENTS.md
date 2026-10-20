---
type: doc
title: SwiftDossier — Agent Instructions
updated: 2026-10-19
---

# AGENTS.md

Canonical project context for AI agents. `CLAUDE.md` and `GEMINI.md` are
symlinks to this file.

## What this package is

The Swift implementation of dossier-format: read, write, validate, migrate and render .dossier character bundles; the `dossier` CLI. See [REQUIREMENTS.md](REQUIREMENTS.md).

## Rules

- **The format is dossier-format's.** Every rule about what a bundle is lives in
  `dossier-format/docs/DOSSIER-FORMAT.md`. If it's silent, raise the question
  there; don't decide it here.
- **Builds and tests** go through the Makefile and `xcodebuild` (XcodeBuildMCP
  locally). Never `swift build` or `swift test`.
- macOS 26, Swift 6.2, strict concurrency. intrusive-memory dependencies use
  the sibling pattern on `development`.
- Work on `development`; `main` takes releases.
