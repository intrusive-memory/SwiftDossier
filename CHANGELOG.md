# Changelog

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
