---
type: requirements
state: draft
updated: 2026-11-18
---

# SwiftDossier — Views over a single document's text

A host app shows one Markdown file whose front matter says `type: character`, `type: location` or `type: locations`. It asks DossierUI for a preview of that file and, for the first two, an editor. It hands the views the document's text and keeps the file to itself: DossierUI never reads or writes the file it is showing. The host decides which one appears (Escribir: Plain Text, the editor, or Preview), and saves.

This is the supplier half of Escribir's typed documents, Escribir `docs/REQUIREMENTS-typed-documents.md` (TD-0 to TD-23). It ships as SwiftDossier 0.8.0.

This document is the requirements input for the mission supervisor's breakdown.

**Governing documents:** `docs/DOSSIER-FORMAT.md` §9 (CHARACTER.md) and §16 (locations, LOCATION.md, LOCATIONS.md, the LOCATIONS page). Where this document and the format disagree, the format wins.

## What exists today (checked 2026-11-18, at v0.7.0)

| Piece | Where | State |
|-------|-------|-------|
| `CharacterDescription(text:)`, `frontMatter`, `frontMatterProblem`, `sections`, `section(named:)`, `openQuestions`, `footnoteCheck()` | `Dossier/Description/CharacterDescription.swift` | Released. Reads a CHARACTER.md from text |
| `setFrontMatter(_:_:)`: changes only the edited key's lines and throws if the change would alter another key | `CharacterDescription` | Released. This is the lossless write |
| `markEdited(_:)`: removes a name from `draft.generated` | `CharacterDescription` | Released |
| A body-section write (replace one `##` section) | | **Missing** |
| A reader for LOCATION.md | | **Missing.** `CharacterDescription` is the only description type |
| `LocationsIndex.load(_ url:)` | `DossierCore/Locations.swift` | Released. Reads from disk only |
| `LocationsView(projectDirectory:selectedBundleURL:refreshToken:project:)` | DossierUI | Released. Builds the LOCATIONS page from the project folder, and stores it in `.locations-page/` |
| `DossierView` | DossierUI | Released. Takes a bundle |

## Requirements

### The rule

- **SFV-1.** Every view in this document takes the document's text, never its URL for reading or writing. A preview takes a `String`. An editor takes a `Binding<String>` and changes the document only by setting it. A view never writes a file. The one exception is the LOCATIONS page's own store (SFV-11), as today.
- **SFV-2.** Every view also takes a read-only context: the file's URL, used only for display, and the project folder, which may be `nil`. Only the LOCATIONS page uses the folder.
- **SFV-3.** Each view exposes the label and SF Symbol a host shows for it: "Character" and "Location" for the editors.

### Readers and writers

- **SFV-4.** A `LocationDescription`, with the same shape as `CharacterDescription`: `init(text:)`, `text`, `frontMatter`, `frontMatterProblem`, `setFrontMatter(_:_:)` with the same lossless rule, and `sections`. The shared front-matter code moves into one internal type that both use, so there is only one copy of the lossless write.
- **SFV-5.** `setSection(named:content:)` on both description types. It replaces one `##` section's contents and leaves every other byte of the text as it was. A section that isn't there is added in §9.2's (or §16's) order.
- **SFV-6.** `isEditable(key:)` on both description types. It answers `false` when that key's lines contain a YAML comment or an anchor, because `setFrontMatter` would replace them. An editor shows such a key read-only, with a note pointing to the host's plain-text mode. `HUNTER`'s `aliases:` is the case: its comments survive because the editor won't touch it.
- **SFV-7.** `LocationsIndex(text:url:)` in DossierCore: the index read from text, with `url` giving where its manifest pointers resolve from. `load(_:)` calls it.

### Character

- **SFV-8.** `CharacterPreview(text:context:)` draws the character from `CharacterDescription`: the name, role, aliases and the other §9.1 fields `fields.json` lists, then the §9.2 sections in order, then open questions. A file with front matter that doesn't read shows `frontMatterProblem` and the body as Markdown. It draws no portrait. A loose file has no images.
- **SFV-9.** `CharacterEditor(text:context:)` shows a field for each §9.1 key `fields.json` lists and an editor for each §9.2 section. Keys that aren't in `fields.json` are listed read-only. Every change goes through `setFrontMatter` or `setSection`, and then `markEdited`. A change `setFrontMatter` refuses leaves the text as it was and shows its error on that field.

### Location

- **SFV-10.** `LocationPreview(text:context:)` and `LocationEditor(text:context:)`, as SFV-8 and SFV-9, over `LocationDescription` and the §16 LOCATION.md fields and sections.

### LOCATIONS.md

- **SFV-11.** `LocationsIndexPreview(text:context:)`. With a project folder, it shows the LOCATIONS page as `LocationsView` does, built from the **saved** index and the bundles beside it. The host passes a new refresh token after each save. Without a folder, it shows the index read from the text (SFV-7): each entry's `location`, `name`, and whether it points to a manifest. It also shows an accessory slot the host fills (Escribir: Open Project).
- **SFV-12.** No editor for LOCATIONS.md in 0.8.0.

### Dependencies

- **SFV-13.** No new package dependencies. DossierUI doesn't import any host package (ProjectBrowser, SwiftEscribo, Escribir).

### Tests and fixtures

- **SFV-14.** Round trip on real fixtures: for `HUNTER.dossier/CHARACTER.md` (granville) and a `LOCATION.md` from `locations-project`, change one key through `setFrontMatter` and one section through `setSection`, and compare with the original: only those lines differ. The `aliases:` comments are byte-for-byte the same.
- **SFV-15.** `isEditable(key:)`: `false` for HUNTER's `aliases:`, `true` for `age:`.
- **SFV-16.** `LocationsIndex(text:url:)` gives the same entries as `load(_:)` for `locations-project/LOCATIONS.md`, and refuses the same malformed cases with the same messages.

## Non-goals

- Portraits, views or any image in the single-file previews.
- Generating anything.
- An editor for LOCATIONS.md.
- Changing `DossierView`, `LocationsView` or the bundle format.

## Open questions

- **OQ-1.** Does Personaje move to `CharacterEditor`, so that one editor serves both apps?
