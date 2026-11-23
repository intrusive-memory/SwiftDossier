# Changelog

## Unreleased

### Added

- Accepting a stale asset, dossier-format 2.2.0 (DF-100, §7). `Asset.accepted` reads an asset's `accepted` entries as `AcceptedEntry` (DossierCore). `stale(template:)` treats a mismatched `portrait`, `face`, `vox` or `description` input as current when an entry for that role has the hash of the role's current selection, and a differing `provenance.artStyle` as current when an entry has the front matter's `artStyle`, so the validator reports no `W-STALE` for it. A later change matches no entry and the asset is stale again.
- `acceptStale(path:at:)` (Dossier) and `dossier accept <bundle> <path>`: record each mismatch that makes a selected asset stale and can be accepted, at a person's request. Only `manifest.json` changes, under the update marker; `derivedFrom` and `provenance` don't. A page is refused with `DossierWriteError.acceptanceNotAllowed`.
- `SuggestiveTextEditor` (DossierUI, #36): a text editor that, when it's empty and loses focus, asks a host-supplied `SuggestionProvider` and shows the answer as dimmed text in the box. Tab or **Accept** puts it in, **Another suggestion** asks again with the passed-over ones in `SuggestionRequest.rejected`, typing drops it, and a failed ask shows its message under the box. Nothing goes into the text until it's accepted. `.suggestionProvider(_:)` sets the provider for a view tree; the section boxes of `CharacterEditor` and `LocationEditor` use it, and with no provider they are plain text editors as before.

### Changed

- Pins dossier-format `v2.2.0` (2026-11-23) in place of `v2.1.0`. The bundled `manifest-v2.schema.json` gains `accepted`, so an entry of another shape, a `voice` entry, or `accepted` on a page is `E-SCHEMA`. `make fixtures` takes a tag or a full commit hash.
- The fixture-page render tests leave out fixtures whose manifest fails its schema, which a writer refuses; a new test checks that refusal.

## 0.8.2

### Fixed

- `locations.view` is reachable again inside a page-mode `LocationsIndexPreview`. The preview held only `LocationsView`, which is already an accessibility element, so its `.contain` container modified that element and `locations.indexPreview` replaced `locations.view`. A clear 1 pt probe, `locations.indexPreview.mode` (value `page`, `list` or `problem`), gives the container a second child.
- Read-only rows in `CharacterEditor` and `LocationEditor` carry `field.<key>`, like writable rows. It is on the value's own text, so the value is readable; the `character` key, always read-only, can now be found.

## 0.8.1

### Fixed

- `LocationsIndexPreview` contains its children for accessibility. Its container identifier, `locations.indexPreview`, now follows `.accessibilityElement(children: .contain)`, so a host's accessory and the embedded LOCATIONS page (`locations.view`) can be found on macOS.

## 0.8.0

### Added

- Views over a single document's text (DossierUI): `CharacterPreview`, `LocationPreview` and `LocationsIndexPreview` take a `String`, and `CharacterEditor` and `LocationEditor` take a `Binding<String>`. Each also takes a `SingleFileContext` (the file's URL, for display only, and an optional project folder). A view never reads or writes the file; the host saves. `SingleFileViewIdentity` gives each view's label and SF Symbol.
- `CharacterEditor` edits the front-matter keys `fields.json` takes (age, pronouns, occupation, languages, sampleLine, artStyle) and `role`. `LocationEditor` edits `location` and `theme` (§16.3). Each has an editor for every `##` section. Every other key is shown read-only, as is any key whose lines hold a YAML comment or anchor.
- `LocationsIndexPreview`: with a project folder, the LOCATIONS page built from the saved index; without one, the entries read from the text. Both show an accessory slot the host fills.
- `LocationDescription` (Dossier): LOCATION.md read from text, with `setFrontMatter(_:_:)`, `sections` and `write(to: inout DossierBundle)`, matching `CharacterDescription`.
- `setSection(named:content:)` and `isEditable(key:)` on `CharacterDescription` and `LocationDescription`. `setSection` replaces one section and keeps every other byte, line endings included. A missing CHARACTER.md section is inserted in §9.2's order; a missing LOCATION.md section is appended.
- `LocationsIndex(text:url:)` (DossierCore): the index read from text. `load(_:)` uses it.
- `make acceptance PROJECT=<path>` runs a round trip on a real project's CHARACTER.md, locally only.

### Changed

- `CharacterDescription` and `LocationDescription` share one lossless front-matter writer.
- `CharacterDescriptionError` is now a typealias for `DescriptionError`.
- SwiftReparto floor raised to 0.4.0.

## 0.7.0

### Added

- `LocationsView` (DossierUI): a project's locations pane. It shows a header (the project's title, the selected bundle's path, the update state and **Rebuild**, with no accessory), the validator's findings for what is selected, and the project's LOCATIONS page scrolled to the selected location's section. In the page's place it shows a note for a bundle that isn't one of the project's locations, the `E-CAST` finding of an index that can't be read, or progress while the page is built.
- `LocationsPaneModel` (DossierUI): what the locations pane shows, following §16.6's *Showing the page*, with `rebuild()`, selection, orphans, findings and `isUpdating`.
- `PreviewContent.storedPage(page:readAccess:)` and `PreviewWebView(content:section:onMessage:)`: a stored page outside a bundle, and scrolling to a LOCATIONS page section without reloading. Changing `section` back to `nil` scrolls to the top.
