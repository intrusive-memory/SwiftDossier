---
type: doc
title: SwiftDossier — Agent Instructions
updated: 2026-11-12
---

# AGENTS.md

Canonical project context for AI agents. `CLAUDE.md` and `GEMINI.md` are
symlinks to this file.

## What this package is

The Swift implementation of dossier-format (pinned at `v2.1.0`): read, write, validate, migrate and render .dossier character and location bundles, and build a project's LOCATIONS page; the `dossier` CLI. See [REQUIREMENTS.md](REQUIREMENTS.md).
Adopters integrating the libraries into an app or tool should read [docs/INTEGRATION.md](docs/INTEGRATION.md).

## Rules

- **The format is dossier-format's.** Every rule about what a bundle is lives in
  `dossier-format/docs/DOSSIER-FORMAT.md`. If it's silent, raise the question
  there; don't decide it here.
- **Builds and tests** go through the Makefile and `xcodebuild` (XcodeBuildMCP
  locally). Never `swift build` or `swift test`.
  `make help` lists the targets: `build`, `test` (honours `TEST_FILTER=<regex>`),
  `test-ios`, `fixtures`, `release`, `smoke`, `install`, `clean`, `resolve`, `acceptance`.
  `make fixtures` clones dossier-format at `DOSSIER_FORMAT_REF` (defined only in
  the Makefile) into the gitignored `.dossier-format/`; `make test` and
  `make test-ios` run it first. `scripts/pin-resources.sh` regenerates the
  bundled resources (schemas, data, `template/`, `template-locations/`) and
  their `PINNED.sha256` lists from that clone.
- macOS 26, Swift 6.2, strict concurrency. intrusive-memory dependencies use
  the sibling pattern on `development`.
- Work on `development`; `main` takes releases.

## Queryable Codemap

A prebuilt [graphify](https://pypi.org/project/graphifyy/) knowledge graph of this
codebase lives in [`graphify-out/`](graphify-out/) (3174 nodes · 7056 edges). **Prefer
querying it before grepping** for architecture or "what connects to what" questions:

```bash
graphify query "How does X flow through the system?"
graphify path "TypeA" "TypeB"      # shortest path between two nodes
graphify explain "SomeType"        # plain-language node explanation
```

Human-readable summary: [`graphify-out/GRAPH_REPORT.md`](graphify-out/GRAPH_REPORT.md).
Refresh after significant changes with `/codemap` (or
`graphify . --backend claude-cli`).
