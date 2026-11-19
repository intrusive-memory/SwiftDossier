---
type: mission-brief
state: completed
mission: loose-leaf-01
---

# Iteration 01 Brief: OPERATION LOOSE LEAF

## Terminology

> **Mission**: a scope of work that can be defined and tested.
> **Sortie**: one unit of work that one agent does in one dispatch, and that can be tested.
> **Work Unit**: a group of sorties.

**Mission:** SwiftDossier 0.8.0. Previews and editors over a single CHARACTER.md, LOCATION.md or LOCATIONS.md's text (docs/REQUIREMENTS-single-file-views.md, SFV-1 to SFV-16, D-1 to D-6).
**Branch:** mission/single-file-views (worktree ~/Projects/worktrees/SwiftDossier-sfv)
**Starting Point Commit:** c3fa7629b94d5815aa018369854c76af8a6d1b7b
**Sorties Planned:** 7
**Sorties Completed:** 7
**Sorties Failed/Blocked:** 0. Sortie 4 was continued once.
**Duration:** 1 day (2026-11-18). Models: opus ×2 (S1, S2), sonnet ×5, plus a haiku verifier.
**Outcome:** Complete
**Verdict:** `KEEP`. Every sortie landed on its first attempt, and the full macOS, iOS and real-project acceptance gates are green.
**Tests pruned:** 0
**Tests flagged for review:** 1

## 1. Hard Discoveries

### 1. The requirements named fixtures this public repo can't hold

**What happened:** SFV-14 named the private granville HUNTER file and Escribir's locations project as fixtures. SD-4 forbids private content in this public repo.
**What was built to handle it:**
- Escribir's synthetic `locations-project` was copied in.
- An invented character was written in HUNTER's shape.
- The real file is checked only by `make acceptance`, through a suite that is disabled unless the project path is set (`TEST_RUNNER_DOSSIER_ACCEPTANCE_PROJECT`).
**Should we have known this?** Yes. SD-4 is in this repo's REQUIREMENTS.md.
**Carry forward:** Requirements for a public package name synthetic fixtures. Real files go to `make acceptance`.

### 2. `fields.json` is the page field list, not the §9.1 key list

**What happened:** The requirements assumed fields.json lists the §9.1 keys. It lists page fields:
- six front-matter keys plus `draft.*`;
- `role` comes from the record;
- there is no `aliases` and no LOCATION.md key.
**What was built to handle it:** D-4 and D-6. Writable keys are fields.json's front-matter keys plus one spec-citing list (`role`, `location`, `theme`), and everything else is read-only.
**Should we have known this?** Yes. One read of the file would have shown it.
**Carry forward:** When dossier-format publishes a description-fields data file, replace the internal list and close the SD-2 exception.

### 3. Section parsing kept no ranges, and the spec gives no insertion rule

**What happened:** `CharacterDocument.parseSections` keeps strings only and normalises line endings. §9.2 says nothing about where a missing section goes.
**What was built to handle it:** `SectionEditor` tracks line ranges and is byte-faithful, including CRLF and the preamble. Missing sections are inserted in §9.2 order, and location sections are appended at the end.
**Carry forward:** If dossier-format ever states an insertion rule, align with it.

### 4. `make acceptance` couldn't find build products in a linked worktree

**What happened:** The script finds DerivedData through `info.plist` WorkspacePath, but a linked worktree's products have no such plist.
**What was built to handle it:** A fallback that matches the freshly built `bin/dossier` byte for byte.

## 2. Process Discoveries

### What the Agents Did Right

1. **They reused existing code instead of adding to it.** The previews draw through the existing `PageMarkdown` and `LocationMarkdown` code. The field list comes through `DossierTabs.bundled()`. The atomic write is shared by both description types (`DescriptionFile`).
2. **The edit APIs fail safely.** The editor refuses a `## ` line instead of splitting a section. A refused edit leaves the binding untouched. A no-op doesn't write.

### What the Agents Did Wrong

1. **The first previews dropped tables.** Sortie 4's first pass drew Markdown with `AttributedString` in inline-only mode, so tables and lists stayed raw. That would have hidden the main content of a LOCATION.md, its `## Views` table. One continuation fixed it.

### What the Planner Did Wrong

1. **Two recon passes and four user decisions before breakdown.** The requirements carried four false premises (fixtures, fields.json, section ranges, the location write). Recon caught all of them, so no sortie hit a REPLAN.
2. **No visual check was planned.** The SwiftUI views compile and their models are tested, but no sortie looked at them on screen. Personaje's adoption is the first look.

## 3. Open Decisions

### 1. Look at the editors in a host

**Why it matters:** The layout is untested.
**Recommendation:** Personaje's adoption (UD25/UD26) is the first visual check. Do it before Escribir's typed routing (TD) depends on the layout.

### 2. Rendering open questions

**Why it matters:** Bold or code inside a question shows as written.
**Recommendation:** It's minor. Render them through the Markdown code when someone asks for it.

## 4. Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| 1 | Shared writer, LocationDescription | opus | 1 | Yes | |
| 2 | setSection, isEditable, DescriptionError | opus | 1 | Yes | 22 tests, byte-faithful |
| 3 | Location write, LocationsIndex(text:url:) | sonnet | 1 | Yes | |
| 4 | Context and previews | sonnet | 1 (+1 continuation) | Partly | Inline Markdown replaced by the existing renderer |
| 5 | Editors | sonnet | 1 | Yes | Verifier PASS |
| 6 | LocationsIndexPreview | sonnet | 1 | Yes | |
| 7 | Acceptance, docs, gate | sonnet | 1 | Yes | Fixed the acceptance script for worktrees |

## 5. Harvest Summary

DossierUI can now preview and edit a character or location from text alone, and preview a LOCATIONS.md with or without its project. Every write is lossless: one key or one section changes, and comments survive because keys that carry them are read-only. Most of what was learned came from recon: the requirements made confident claims about fields.json and the fixtures that one read of the files would have corrected. Test cleanup pruned nothing. Its one flag is the acceptance-only suite, and that is intended.

## 6. Files

**Preserve:**

| File | Branch | Why |
|------|--------|-----|
| docs/REQUIREMENTS-single-file-views.md | mission/single-file-views | The spec as built |
| The mission documents | mission/single-file-views | Archived in docs/complete/loose-leaf-01/ |

**Discard:** none.

## 7. Iteration Metadata

**Starting point commit:** `c3fa7629b94d5815aa018369854c76af8a6d1b7b`
**Mission branch:** `mission/single-file-views`
**Final commit on mission branch:** `56a335a`, before this brief and the archive
**Rollback target:** `c3fa7629b94d5815aa018369854c76af8a6d1b7b`
**Next iteration branch:** not needed (KEEP)

## 8. Rollback Verdict

**Verdict:** `KEEP`

**Reasoning:** All 7 sorties completed on their first attempt, with one continuation. These are green:
- `make test`, `make test-ios`;
- `make acceptance` on the real granville project, with its git status unchanged;
- the skip path.
Test cleanup pruned nothing, and the recon findings were settled before planning.

**Recommended action:**
1. Open a PR from mission/single-file-views into development with auto-merge.
2. Ship 0.8.0 with /ship-swift-library.
3. Personaje adopts the editors (first visual check), then Escribir's typed routing.
