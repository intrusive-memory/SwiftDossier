# Changelog

## Unreleased

### Added

- `LocationsView` (DossierUI): a project's locations pane. It shows a header (the project's title, the selected bundle's path, the update state and **Rebuild**, with no accessory), the validator's findings for what is selected, and the project's LOCATIONS page scrolled to the selected location's section. In the page's place it shows a note for a bundle that isn't one of the project's locations, the `E-CAST` finding of an index that can't be read, or progress while the page is built.
- `LocationsPaneModel` (DossierUI): what the locations pane shows, following §16.6's *Showing the page*, with `rebuild()`, selection, orphans, findings and `isUpdating`.
- `PreviewContent.storedPage(page:readAccess:)` and `PreviewWebView(content:section:onMessage:)`: a stored page outside a bundle, and scrolling to a LOCATIONS page section without reloading. Changing `section` back to `nil` scrolls to the top.
