---
type: requirements
state: draft
updated: 2026-11-18
---

# SwiftDossier — Views over a single document's text

A host app shows one Markdown file whose front matter says `type: character`, `type: location` or `type: locations`. It asks DossierUI for a preview of that file and, for the first two, an editor. It hands the views the document's text and keeps the file to itself: DossierUI never reads or writes the file it is showing. The host decides which one appears (Escribir: Plain Text, the editor, or Preview), and saves.

This is the supplier half of Escribir's typed documents, Escribir `docs/REQUIREMENTS-typed-documents.md` (TD-0 to TD-23). The editors' first host is Personaje, which designs them (Personaje `docs/REQUIREMENTS-APP-UI.md` UD25, UD26), and Escribir is the second. It ships as SwiftDossier 0.8.0.

This document is the requirements input for the mission supervisor's breakdown.

**Governing documents:** dossier-format's `docs/DOSSIER-FORMAT.md` at v2.1.0 (the Makefile's `fixtures` pin), §9 (CHARACTER.md) and §16 (locations, LOCATION.md, LOCATIONS.md, the LOCATIONS page). Where this document and the format disagree, the format wins.

## What exists today (checked 2026-11-18, at v0.7.0)

| Piece | Where | State |
|-------|-------|-------|
| `CharacterDescription(text:)`, `frontMatter`, `frontMatterProblem`, `sections`, `section(named:)`, `openQuestions`, `footnoteCheck()` | `Dossier/Description/CharacterDescription.swift` | Released. Reads a CHARACTER.md from text |
| `setFrontMatter(_:_:)`: changes only the edited key's lines and throws if the change would alter another key | `CharacterDescription` | Released. This is the lossless write. It is inline in `CharacterDescription` (about 150 lines). A comment inside the edited key's own lines is lost |
| `write(to: inout DossierBundle)`: atomic write of CHARACTER.md that also updates the manifest | `CharacterDescription` | Released. Bundles only |
| `markEdited(_:)`: removes a name from `draft.generated` | `CharacterDescription` | Released |
| A body-section write (replace one `##` section) | | **Missing** |
| A reader for LOCATION.md | `DossierBundle`, `Rendering/LocationsPage.swift`, `Validation/Validator.swift` | **Internal only.** There is no public `LocationDescription`; the validator and the page renderer read LOCATION.md for themselves |
| `LocationsIndex.load(_ url:)` | `DossierCore/Locations.swift` | Released. Reads from disk only; reading and parsing are inline in one function. Throws `LocationsError.indexUnreadable(String)` |
| `LocationsView(projectDirectory: URL, selectedBundleURL: URL?, refreshToken: AnyHashable? = nil, project: DossierProjectContext = .init())` | DossierUI | Released. Builds the LOCATIONS page from the project folder, and stores it in `.locations-page/` |
| `DossierView` | DossierUI | Released. Takes a bundle URL |
| `fields.json` | `DossierCore/Resources` (from dossier-format, SD-2) | The page field list (§11). Its `frontMatter` sources are age, pronouns, occupation, languages, sampleLine, artStyle, and the dotted `draft.generatedBy` and `draft.reviewedAt`. `role` is read from the record, not front matter. It names no `aliases` and no LOCATION.md key |
| `CharacterDocument.parseSections` | `DossierCore/CharacterDocument.swift:131` | Released. Keeps heading and content strings only, with no range into the original text, and normalises line endings. Location bundles already read LOCATION.md through `CharacterDocument` (`DossierBundle.init`) |
| `make acceptance PROJECT=` | `Makefile:176`, `scripts/acceptance.sh` | A shell script that drives the built `dossier` CLI over a copy of a project. It skips when the path is absent and never runs in CI. It runs no test target |

## Requirements

### The rule

- **SFV-1.** Every view in this document takes the document's text, never its URL for reading or writing. A preview takes a `String`. An editor takes a `Binding<String>` and changes the document only by setting it. A view never writes a file. The one exception is the LOCATIONS page's own store (SFV-11), as today.
- **SFV-2.** Every view also takes a read-only context: the file's URL, used only for display, and the project folder, which may be `nil`. Only the LOCATIONS page uses the folder.
- **SFV-3.** Each view exposes the label and SF Symbol a host shows for it: "Character" and "Location" for the editors.

### Readers and writers

- **SFV-4.** A `LocationDescription`, with the same shape as `CharacterDescription`: `init(text:)`, `text`, `frontMatter`, `frontMatterProblem`, `setFrontMatter(_:_:)` with the same lossless rule, `sections`, and `write(to: inout DossierBundle)` with the same atomic write and manifest update as `CharacterDescription.write(to:)` (D-5). The shared front-matter code moves into one internal type that both use, so there is only one copy of the lossless write. `LocationDescription` is built on `CharacterDocument`, which `DossierBundle.init` and the validator already use for LOCATION.md, so their behaviour doesn't change: lossy UTF-8, no throwing, the same `E-NAME-MISMATCH` and `W-FOOTNOTE` findings. `LocationsPage` keeps its own strict-UTF-8 read, which leaves a non-UTF-8 description off the page (§16.6).
- **SFV-5.** `setSection(named:content:)` on both description types. It replaces one `##` section's contents and leaves every other byte of the text as it was. This needs each section's range in the original text, which `parseSections` doesn't keep today. A CHARACTER.md section that isn't there is inserted after the nearest earlier section in §9.2's order (or before the first later one, else at the end). A LOCATION.md section that isn't there is appended at the end, since §16.3 gives no order.
- **SFV-6.** `isEditable(key:)` on both description types. It answers `false` when that key's lines contain a YAML comment or an anchor, because `setFrontMatter` would replace them. An editor shows such a key read-only, with a note pointing to the host's plain-text mode. `HUNTER`'s `aliases:` is the case: its comments survive because the editor won't touch it.
- **SFV-7.** `LocationsIndex(text:url:)` in DossierCore: the index read from text, with `url` giving where its manifest pointers resolve from. `load(_:)` calls it.

### Character

- **SFV-8.** `CharacterPreview(text:context:)` draws the character from `CharacterDescription`: the name, role, aliases and the other §9.1 fields `fields.json` lists, then the §9.2 sections in order, then open questions. A file with front matter that doesn't read shows `frontMatterProblem` and the body as Markdown. It draws no portrait. A loose file has no images.
- **SFV-9.** `CharacterEditor(text:context:)` shows a field for each top-level key that `fields.json` names as a `frontMatter` source (in 0.8.0: age, pronouns, occupation, languages, sampleLine, artStyle), plus `role` (D-6), and an editor for each §9.2 section. Every other key is listed read-only: `aliases`, `draft` and its dotted keys, and anything unknown (D-4). Every change goes through `setFrontMatter` or `setSection`, and then `markEdited`. A change `setFrontMatter` refuses leaves the text as it was and shows its error on that field.

### Location

- **SFV-10.** `LocationPreview(text:context:)` and `LocationEditor(text:context:)`, as SFV-8 and SFV-9, over `LocationDescription` and the §16.3 LOCATION.md fields and sections. `fields.json` names no LOCATION.md key, so the editor's writable keys are `location` and `theme`, from one internal list that cites §16.3 (D-4). `type` and every other key are listed read-only. The section editors cover the sections the file has, plus §16.3's recommended `## Blocking` and `## Views`.

### LOCATIONS.md

- **SFV-11.** `LocationsIndexPreview(text:context:)`. With a project folder, it shows the LOCATIONS page as `LocationsView` does, built from the **saved** index and the bundles beside it. The host passes a new refresh token after each save. Without a folder, it shows the index read from the text (SFV-7): each entry's `location`, `name`, and whether it points to a manifest. It also shows an accessory slot the host fills (Escribir: Open Project).
- **SFV-12.** No editor for LOCATIONS.md in 0.8.0.

### Hosts

- **SFV-12a.** The editors work the same over a bundle's member file and over a loose file. Personaje binds `CharacterEditor` and `LocationEditor` to the text of a bundle's `CHARACTER.md` / `LOCATION.md` and saves through the bundle (`CharacterDescription.write(to:)` and `LocationDescription.write(to:)`, SFV-4). Escribir binds them to a loose file's text. Nothing in a view depends on which.
- **SFV-12b.** Personaje's needs set the editors' layout and fields. Escribir takes them as they are. A change Escribir needs is made here, never in either app.

### Dependencies

- **SFV-13.** No new package dependencies. DossierUI doesn't import any host package (ProjectBrowser, SwiftEscribo, Escribir).

### Tests and fixtures

- **SFV-14.** Round trip on synthetic fixtures (SD-4, D-3): a CHARACTER.md written in HUNTER's shape (an `aliases:` list whose items carry trailing `#` comments, and a plain `age:`), and a `LOCATION.md` from `locations-project`, copied from Escribir's `TestFixtures/locations-project` (already synthetic). Change one key through `setFrontMatter` and one section through `setSection`, and compare with the original: only those lines differ. The `aliases:` comments are byte-for-byte the same. `make acceptance PROJECT=<granville>` runs the same round trip on the real `HUNTER.dossier/CHARACTER.md`, locally only. It does this by running one swift-testing suite through `make test TEST_FILTER=…` with the project path in an environment variable. The suite is disabled when the variable is unset, so it is skipped in CI.
- **SFV-15.** `isEditable(key:)`: `false` for the HUNTER-shaped fixture's `aliases:`, `true` for its `age:`.
- **SFV-16.** `LocationsIndex(text:url:)` gives the same entries as `load(_:)` for the copied `locations-project/LOCATIONS.md`, and refuses the same malformed cases with the same messages.

## Non-goals

- Portraits, views or any image in the single-file previews.
- Generating anything.
- An editor for LOCATIONS.md.
- Changing `DossierView`, `LocationsView` or the bundle format.

## Decisions

- **D-1.** The editors are written here, with Personaje as their first host, not in Personaje's app target first and moved out later (Personaje UD25). *Decided 2026-11-18.*
- **D-2.** Personaje edits locations as well as characters (Personaje UD26), so `LocationEditor` has a first host too. *Decided 2026-11-18.*
- **D-3.** Fixtures are synthetic (SD-4). Escribir's `locations-project` is copied in; the character fixture is written in HUNTER's shape; the real HUNTER is checked only by `make acceptance`. *Decided 2026-11-18.*
- **D-4.** Character fields come from `fields.json`'s `frontMatter` sources, so `aliases` is read-only in 0.8.0. LOCATION.md's writable keys (`location`, `theme`) come from one internal list that cites §16.3. This is a recorded exception to SD-2 until dossier-format publishes a description-fields data file. *Decided 2026-11-18.*
- **D-5.** `LocationDescription.write(to: inout DossierBundle)` is in scope for 0.8.0. *Decided 2026-11-18.*
- **D-6.** `role` is editable in `CharacterEditor`, though `fields.json` reads it from the record. It joins `location` and `theme` in the internal, spec-citing key list (D-4). *Decided 2026-11-18.*
