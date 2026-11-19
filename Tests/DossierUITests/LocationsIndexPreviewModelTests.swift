import Foundation
import Testing

@testable import DossierUI

@Suite("LocationsIndexPreviewModelTests")
struct LocationsIndexPreviewModelTests {
  private static func entries(_ model: LocationsIndexPreviewModel) -> [LocationsIndexPreviewEntry]? {
    if case .list(let entries) = model.mode { return entries }
    return nil
  }

  @Test func noFolderListsTheFixtureEntriesIncludingOneWithoutAManifest() throws {
    let text = try SingleFilePreviewModelTests.fixture("locations-project/LOCATIONS.md")
    let model = LocationsIndexPreviewModel(text: text, context: SingleFileContext())
    let entries = try #require(Self.entries(model))
    #expect(entries.map(\.location) == ["HARBOR-LIGHT", "THE OLD QUAY", "SALT-STORE"])
    #expect(entries.map(\.name) == ["The harbor light at the end of the mole", "Not built yet", "The salt store on the quay"])
    #expect(entries.map(\.hasManifest) == [true, false, true])
    #expect(model.html.contains("No manifest yet"))
    #expect(model.html.contains("THE OLD QUAY"))
  }

  @Test func aFileURLWithoutAFolderStillListsTheEntries() throws {
    let text = try SingleFilePreviewModelTests.fixture("locations-project/LOCATIONS.md")
    let context = SingleFileContext(fileURL: URL(fileURLWithPath: "/x/LOCATIONS.md"))
    #expect(Self.entries(LocationsIndexPreviewModel(text: text, context: context))?.count == 3)
  }

  @Test func malformedTextShowsTheErrorMessage() {
    let model = LocationsIndexPreviewModel(text: "not an index", context: SingleFileContext())
    guard case .problem(let message) = model.mode else {
      Issue.record("expected a problem, got \(model.mode)")
      return
    }
    #expect(!message.isEmpty)
    #expect(model.html.contains("class=\"problem\""))
  }

  @Test func aFolderPicksTheLocationsViewModeWithoutReadingTheText() {
    let folder = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
    let model = LocationsIndexPreviewModel(
      text: "not an index", context: SingleFileContext(projectFolder: folder))
    #expect(model.mode == .page(projectFolder: folder))
    #expect(model.html.isEmpty)
  }

  @Test func entryValuesAreHTMLEscaped() {
    let text = """
      ---
      type: locations
      schemaVersion: 1
      locations:
      - location: "<script>alert(1)</script>"
        name: "A & B \\"quoted\\""
      ---
      """
    let model = LocationsIndexPreviewModel(text: text, context: SingleFileContext())
    #expect(Self.entries(model)?.count == 1)
    #expect(!model.html.contains("<script>"))
    #expect(model.html.contains("&lt;script&gt;"))
    #expect(model.html.contains("A &amp; B"))
  }

  @Test func identityIsLocationsAndMap() {
    #expect(SingleFileViewIdentity.locationsIndexPreview == SingleFileViewIdentity(label: "Locations", systemImage: "map"))
  }
}
