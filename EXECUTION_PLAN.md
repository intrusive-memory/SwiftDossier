---
type: execution-plan
feature_name: OPERATION LOOSE LEAF
starting_point_commit: c3fa7629b94d5815aa018369854c76af8a6d1b7b
mission_branch: mission/single-file-views
iteration: 1
---

# EXECUTION_PLAN.md: SwiftDossier single-file views (0.8.0)

## Terminology

> **Mission**: a scope of work that can be defined and tested. It sets the scope, the acceptance criteria and the order of the work.

> **Sortie**: one unit of work, done by one AI agent in one dispatch, that can be tested. One aircraft, one mission, one return.

> **Work Unit**: a group of sorties (a package, a component or a phase).

Source: `docs/REQUIREMENTS-single-file-views.md` (SFV-1 to SFV-16, D-1 to D-6). Recon: `RECON_REPORT.md` (CLEAR, 24 assumptions).

## Rules for every sortie

- The worktree is `/Users/stovak/Projects/worktrees/SwiftDossier-sfv`, on branch `mission/single-file-views`. Work only there.
- **Never** run `swift build` or `swift test`. Use these instead:
  - `make build`
  - `make test`, which runs every target on macOS
  - `make test TEST_FILTER=<Target/Suite>`
  - `make test-ios`
- `make test` first runs `make fixtures`, which clones dossier-format v2.1.0 into `.dossier-format/` the first time.
- The format spec is dossier-format v2.1.0's `docs/DOSSIER-FORMAT.md`. Read it at `/Users/stovak/Projects/worktrees/dossier-format-v2.1.0/docs/DOSSIER-FORMAT.md`:
  - §9 starts at `:909`, with §9.1 at `:913` and §9.2 at `:936`.
  - §16 starts at `:1303`, with §16.3 at `:1409` and §16.6 at `:1510`.
- Fixtures are synthetic (SD-4). Nothing from `~/Projects/podcasts/` may be copied into this repo.
- There is no `lint` target. Match the existing code style.
- Sortie agents do not commit. The supervisor commits.

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| SwiftDossier SFV | `/Users/stovak/Projects/worktrees/SwiftDossier-sfv` | 7 | 1 | none |

### Sortie 1: One lossless front-matter writer, and `LocationDescription` reads text

**Entry criteria**:
- [ ] First sortie. HEAD is at or after `6ead64c` on `mission/single-file-views`.
- [ ] Recon facts:
  - The lossless writer is inline in `CharacterDescription` (`Sources/Dossier/Description/CharacterDescription.swift`):
    - `setFrontMatter` is at `:151-186`;
    - `keySpans`, `rendered` and `node(for:)` are near `:375`.
  - `FrontMatter.split` is at `Sources/DossierCore/CharacterDocument.swift:9`.
  - `DossierBundle.init` (`Sources/DossierCore/DossierBundle.swift:34-39`) already reads LOCATION.md through `CharacterDocument`.

**Tasks**:
1. Move the front-matter parsing and the lossless key write out of `CharacterDescription` into one internal type in `Sources/Dossier/Description/`, for example `FrontMatterEditor`. `CharacterDescription` keeps its public API and behaviour, and delegates to the new type.
2. Add `public struct LocationDescription` in the same folder (SFV-4), with these members:
   - `init(text:)`, `text`, `frontMatter`, `frontMatterProblem`, `sections`, `section(named:)`;
   - `setFrontMatter(_:_:)`, using the shared writer and the same lossless rule.
3. Copy Escribir's synthetic fixture to `Tests/DossierTests/Fixtures/locations-project/`:
   - Source: `/Users/stovak/Projects/apps/Escribir/TestFixtures/locations-project/`.
   - Copy LOCATIONS.md, the three `locations/*.dossier` bundles with their images, CAST.md, PROJECT.md and `characters/`.
   - Exclude `Fixtures` from target sources if needed, as `DossierUITests` does (`Package.swift:121`), and load fixtures by `#filePath`.
4. Write `Tests/DossierTests/LocationDescriptionTests.swift`:
   - Read HARBOR-LIGHT's and SALT-STORE's LOCATION.md.
   - Check `location`, `theme` (present on HARBOR-LIGHT, absent on SALT-STORE) and the section headings.
   - Check that `setFrontMatter("theme", …)` changes only the `theme` line.

**Exit criteria**:
- [ ] `make test TEST_FILTER=DossierTests/CharacterDescriptionTests` passes, with the same test count as before the sortie.
- [ ] `make test TEST_FILTER=DossierTests/LocationDescriptionTests` passes.
- [ ] `grep -rn "func keySpans" Sources | wc -l` prints 1, and that one is in the new shared type. The lossless span replacement exists once.
- [ ] `make build` succeeds.

### Sortie 2: `setSection` and `isEditable(key:)`

**Priority**: the heaviest sortie (it needs range tracking). Use opus.

**Entry criteria**:
- [ ] Sortie 1 is complete.
- [ ] Recon facts:
  - `CharacterDocument.parseSections` (`CharacterDocument.swift:131-145`) keeps heading and content strings only, with no ranges, and normalises line endings.
  - Heading matching is at `:121-124`: the exact name, or the name followed by " (…)".
  - §9.2's order is Logline, Appearance, Personality, Backstory, Arc, Relationships, Voice & Speech, Pronunciation, Wardrobe, Canon & Guardrails, Open Questions.

**Tasks**:
1. Track each `##` section's range in the original text (line ranges in the shared type, or a new internal parser), aware of code fences, so one section can be replaced without changing any other byte. Leave `CharacterDocument.parseSections`' public behaviour unchanged.
2. Add `setSection(named:content:)` to both description types (SFV-5):
   - It replaces the section's contents.
   - A missing CHARACTER.md section is inserted after the nearest earlier section in §9.2's order, or before the first later one, or at the end of the body.
   - A missing LOCATION.md section is appended at the end.
3. Add `isEditable(key:)` to both types (SFV-6). It returns `false` when the key's span holds a `#` comment (on the key line or on a value line) or a YAML anchor or alias (`&`, `*`).
4. Write the synthetic character fixture `Tests/DossierTests/Fixtures/character-hunter-shape/CHARACTER.md`. It has `aliases:` items with trailing `# NAME` comments and a plain `age:`. It is invented, not copied.
5. Write `Tests/DossierTests/SectionEditTests.swift`, covering SFV-14 on both fixtures and SFV-15:
   - Change one key with `setFrontMatter` and one section with `setSection`. The line diff against the original shows only those lines.
   - The `aliases:` comment lines are byte-for-byte the same.
   - `isEditable` is `false` for `aliases` and `true` for `age`.
   - Inserting a missing section obeys task 2.

**Exit criteria**:
- [ ] `make test TEST_FILTER=DossierTests/SectionEditTests` passes, with at least one test per bullet in task 5.
- [ ] `make test TEST_FILTER=DossierTests/CharacterDescriptionTests` and `…/LocationDescriptionTests` pass.
- [ ] `grep -rn "podcasts\|granville" Tests/DossierTests/Fixtures` prints nothing.

### Sortie 3: `LocationDescription.write(to:)` and `LocationsIndex(text:url:)`

**Entry criteria**:
- [ ] Sortie 2 is complete.
- [ ] Recon facts:
  - `CharacterDescription.write(to bundle: inout DossierBundle) throws` is at `:284`. It writes atomically and updates the manifest through ManifestWriter.
  - `LocationsIndex.load(_:)` is at `Sources/DossierCore/Locations.swift:187-217`. Its read and parse are inline, and it throws `LocationsError.indexUnreadable(String)` with 10 detail messages.

**Tasks**:
1. Add `LocationDescription.write(to: inout DossierBundle) throws` (D-5). It mirrors the character write (the atomic temp file, the zero-byte refusal and the manifest update) and writes `LOCATION.md` for a location bundle.
2. Add `public init(text: String, url: URL) throws` to `LocationsIndex` (SFV-7). It holds the parsing that `load(_:)` does today. `load(_:)` now reads the file and calls it, keeping its "can't be read" and "isn't UTF-8" errors.
3. Write tests:
   - `LocationsTests`, or a new suite: for the copied `locations-project/LOCATIONS.md`, `init(text:url:)` and `load(_:)` give the same entries.
   - For every malformed case `load` refuses (no front matter, front matter that isn't YAML, not a mapping, the wrong type, no list, an entry that isn't a mapping, an entry with no location, a manifest that isn't a string), both refuse with the same message.
   - A write test for `LocationDescription.write(to:)` on a temporary copy of a fixture bundle.

**Exit criteria**:
- [ ] `make test TEST_FILTER=DossierTests/LocationsTests` passes. So does the write test's suite, by name.
- [ ] `make test TEST_FILTER=DossierCoreTests` passes.
- [ ] `make test TEST_FILTER=DossierUITests/LocationsPaneModelTests` passes, since `LocationsView` still reads through `load`.

### Sortie 4: The single-file context and the two previews

**Entry criteria**:
- [ ] Sortie 3 is complete.
- [ ] Recon facts:
  - DossierUI imports no host package (SFV-13), and that must stay true.
  - DossierUI tests use view models (`Tests/DossierUITests/*ModelTests.swift`, `ViewModelSupport.swift`).

**Tasks**:
1. Add a public read-only context type (SFV-2): the file URL (for display only) and the project folder, which may be nil. Add a way for each view to expose its label and SF Symbol (SFV-3): "Character" and "Location" for the editors, and a label for each preview.
2. Add `CharacterPreview(text: String, context:)` (SFV-8):
   - It shows the name, role, aliases, and the §9.1 fields that `fields.json` takes from front matter.
   - Then the §9.2 sections in order, then the open questions.
   - When the front matter doesn't read, it shows `frontMatterProblem` and the body as Markdown.
   - It shows no portrait.
3. Add `LocationPreview(text:context:)`, the same over `LocationDescription` (SFV-10).
4. Back each preview with a testable model, for example `CharacterPreviewModel(text:)`. Write `Tests/DossierUITests/SingleFilePreviewModelTests.swift` covering field order, section order, the front-matter-problem path and the location preview, on the synthetic fixtures.

**Exit criteria**:
- [ ] `make test TEST_FILTER=DossierUITests/SingleFilePreviewModelTests` passes.
- [ ] `grep -rnE "^import (ProjectBrowser|SwiftEscribo|Escribir)" Sources/DossierUI` prints nothing.
- [ ] `grep -rnE "contentsOf|write\\(to|FileManager" <the new preview files>` prints nothing (SFV-1).
- [ ] `make build` succeeds.

### Sortie 5: `CharacterEditor` and `LocationEditor`

**Entry criteria**:
- [ ] Sortie 4 is complete.

**Tasks**:
1. Add `CharacterEditor(text: Binding<String>, context:)` (SFV-9, D-4, D-6):
   - Writable fields: the top-level keys `fields.json` takes from front matter (age, pronouns, occupation, languages, sampleLine, artStyle), plus `role`.
   - A field is read-only when `isEditable(key:)` is false, with a note pointing to the host's plain-text mode.
   - Every other key is listed read-only, including `aliases` and `draft` and its dotted keys.
   - There is an editor for each §9.2 section.
   - Every change goes through `setFrontMatter` or `setSection`, then `markEdited`, and finally sets the binding.
   - When the change is refused, the text stays as it was and the error shows on that field.
2. Add `LocationEditor(text:context:)` (SFV-10):
   - Writable keys are `location` and `theme`, from one internal list that cites §16.3 (D-4 and D-6). That list also holds `role` for characters.
   - `type` and every other key are read-only.
   - There are section editors for the file's sections plus `## Blocking` and `## Views`.
3. Put the editing logic in models, for example `CharacterEditorModel`, so it can be tested without UI. Write `Tests/DossierUITests/SingleFileEditorModelTests.swift`, which checks each of these:
   - Editing `age` changes one line and calls `markEdited`.
   - A refused change leaves the text alone and reports the error.
   - `aliases` with comments is read-only.
   - `role` is writable.
   - Editing a location's `theme` and `## Blocking` changes only those lines.
   - Adding a missing `## Views` appends it.

**Exit criteria**:
- [ ] `make test TEST_FILTER=DossierUITests/SingleFileEditorModelTests` passes, with every check in task 3.
- [ ] `grep -rnE "contentsOf|write\\(to|FileManager" <the new editor files>` prints nothing (SFV-1).
- [ ] [judgment] The writable-key list exists once, cites §16.3 and §9.1 next to its entries, and every other key is read-only. Decide this from the diff.

### Sortie 6: `LocationsIndexPreview`

**Entry criteria**:
- [ ] Sortie 5 is complete.
- [ ] Recon facts:
  - The `LocationsView` signature is `(projectDirectory: URL, selectedBundleURL: URL?, refreshToken: AnyHashable? = nil, project: DossierProjectContext = .init())`.
  - Its store is `<index dir>/.locations-page/`.

**Tasks**:
1. Add `LocationsIndexPreview(text:context:accessory:)` (SFV-11):
   - With a project folder in the context, it shows the LOCATIONS page as `LocationsView` does, built from the saved index. It takes a refresh token, and the host passes a new one after each save.
   - Without a folder, it shows the index read from the text with `LocationsIndex(text:url:)`: each entry's location, its name, and whether it points to a manifest.
   - It has an accessory slot the host fills.
2. Give it no editor (SFV-12).
3. Write `Tests/DossierUITests/LocationsIndexPreviewModelTests.swift`, covering the no-folder entries for `locations-project` (including THE OLD QUAY with no manifest), malformed text showing the error, and with a folder choosing the `LocationsView` path.

**Exit criteria**:
- [ ] `make test TEST_FILTER=DossierUITests/LocationsIndexPreviewModelTests` passes.
- [ ] `make test TEST_FILTER=DossierUITests/LocationsViewTests` and `…/LocationsPaneModelTests` pass.

### Sortie 7: Real-file acceptance, docs and full gate

**Entry criteria**:
- [ ] Sortie 6 is complete.
- [ ] Recon facts:
  - `make acceptance` is `scripts/acceptance.sh` (`Makefile:176`).
  - It skips when the project is absent (`:41-44`), runs no test target, and is not in CI.

**Tasks**:
1. Add a swift-testing suite `Tests/DossierTests/RealProjectRoundTripTests.swift`:
   - It is enabled only when `DOSSIER_ACCEPTANCE_PROJECT` is set.
   - It runs SFV-14's round trip, and SFV-15, on `<project>/characters/HUNTER.dossier/CHARACTER.md`.
   - It works on a copy and never writes to the project.
2. Extend `scripts/acceptance.sh` to run `make test TEST_FILTER=DossierTests/RealProjectRoundTripTests` with that variable set, after its existing items.
3. Document the new API in `docs/INTEGRATION.md` and `README.md`:
   - the views, the context, `setSection`, `isEditable`, `LocationDescription`, `LocationsIndex(text:url:)`;
   - the editors' key rule (D-4 and D-6).
   - Docs describe current state only.
4. Run `make test` and `make test-ios`.

**Exit criteria**:
- [ ] `make test` exits 0, and its result line is pasted into the report.
- [ ] `make test-ios` exits 0, and its result line is pasted into the report.
- [ ] `make acceptance PROJECT=/Users/stovak/Projects/podcasts/granville` exits 0, and its round-trip suite passes. `git -C /Users/stovak/Projects/podcasts/granville status --porcelain` is unchanged by the run.
- [ ] `make acceptance PROJECT=/nonexistent` prints SKIP and exits 0.
- [ ] `grep -rn "podcasts/granville\|HUNTER" Tests/ --include=*.swift` matches only the acceptance suite's comment or skip message, and no fixture.

## Local Dependency Map

<!-- Carried from RECON_REPORT.md. Sortie agents may read these paths. They may not edit them. -->

| Dependency | Resolved version | Local checkout | Status |
|------------|------------------|----------------|--------|
| intrusive-memory/SwiftReparto | from 0.3.0 (resolved at build time) | `~/Projects/package-collection/pkg/SwiftReparto` (v0.4.0) | UNPINNED, not touched |
| jpsim/Yams | from 6.2.2 | none | UNPINNED |
| apple/swift-argument-parser | from 1.7.1 | none | UNPINNED |
| dossier-format | v2.1.0 (Makefile `fixtures`) | `/Users/stovak/Projects/worktrees/dossier-format-v2.1.0` | matches the pin; read-only |

## Open Questions

_No blocking open questions identified during breakdown._ Recon's findings were decided as D-3 to D-6.

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 7 |
| Open questions | 0 |
| Dependencies mapped | 4 |
| Dependency structure | sequential |
