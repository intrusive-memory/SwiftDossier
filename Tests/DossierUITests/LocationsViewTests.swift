import Dossier
import DossierCore
import Foundation
import SwiftUI
import Testing

@testable import DossierUI

/// ``LocationsView`` and ``LocationsHeader`` on writable copies of dossier-format's examples.
@MainActor
@Suite("LocationsView (LV-1, LV-3, LV-4, LV-7, LV-8)")
struct LocationsViewTests {
  /// A writable copy of `examples/<path>` in a new temporary directory.
  private func copy(of path: String) throws -> URL {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocationsViewTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let root = parent.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.copyItem(at: SpecTree.examples.appendingPathComponent(path), to: root)
    return root
  }

  private func remove(_ root: URL) { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

  private func bundle(_ root: URL, _ name: String) -> URL {
    root.appendingPathComponent("locations/\(name).dossier", isDirectory: true)
  }

  // MARK: Header (LV-8)

  @Test("The header shows the selected bundle's path relative to the project as text (LV-8)")
  func headerShowsPath() async throws {
    let root = try copy(of: "valid/locations-page-current")
    defer { remove(root) }
    let model = LocationsPaneModel(projectDirectory: root, selectedBundleURL: bundle(root, "HARBOR-LIGHT"))
    #expect(model.selectedBundlePath == "locations/HARBOR-LIGHT.dossier")
    #expect(LocationsHeader.pathText(model.selectedBundlePath) == "locations/HARBOR-LIGHT.dossier")
    #expect(
      LocationsHeader.texts(title: "The Lamp Keepers", path: model.selectedBundlePath)
        .contains("locations/HARBOR-LIGHT.dossier"))
  }

  @Test("Project mode has no path, and the header still shows the title")
  func headerInProjectMode() throws {
    let root = try copy(of: "valid/locations-page-current")
    defer { remove(root) }
    let model = LocationsPaneModel(projectDirectory: root)
    #expect(model.selectedBundlePath == nil)
    #expect(LocationsHeader.pathText(model.selectedBundlePath) == nil)
    #expect(LocationsHeader.titleText("The Lamp Keepers") == "The Lamp Keepers")
    #expect(LocationsHeader.titleText(nil) == "Locations")
  }

  @Test("No Personaje label appears anywhere in the header (LV-8)")
  func noPersonaje() {
    let texts = LocationsHeader.texts(title: "The Lamp Keepers", path: "locations/HARBOR-LIGHT.dossier")
    #expect(texts.contains(LocationsHeader.rebuildTitle))
    #expect(!texts.contains { $0.localizedCaseInsensitiveContains("Personaje") })
  }

  // MARK: What shows in the page's place (LV-4, LV-7)

  @Test("A bundle an entry points at: the page, scrolled to its section")
  func pageState() async throws {
    let root = try copy(of: "valid/locations-page-current")
    defer { remove(root) }
    let model = LocationsPaneModel(projectDirectory: root, selectedBundleURL: bundle(root, "HARBOR-LIGHT"))
    await model.show()
    let state = LocationsView.state(of: model)
    #expect(state.identifier == "locations.page")
    #expect(state.canRebuild)
    #expect(LocationsView.sectionValue(model.section) == LocationsIndex.sectionID(forLocation: "HARBOR-LIGHT"))
  }

  @Test("Project mode: the page from the top")
  func projectModeState() async throws {
    let root = try copy(of: "valid/locations-page-current")
    defer { remove(root) }
    let model = LocationsPaneModel(projectDirectory: root, selectedBundleURL: nil)
    await model.show()
    #expect(LocationsView.state(of: model).identifier == "locations.page")
    #expect(LocationsView.sectionValue(model.section) == "top")
  }

  @Test("An orphan shows locations.orphan, with no locations.page, and can't be rebuilt (LV-7)")
  func orphanState() async throws {
    let root = try copy(of: "warnings/W-ORPHAN-location")
    defer { remove(root) }
    let model = LocationsPaneModel(projectDirectory: root, selectedBundleURL: bundle(root, "DRY-DOCK"))
    await model.show()
    let state = LocationsView.state(of: model)
    #expect(state == .orphan)
    #expect(state.identifier == "locations.orphan")
    #expect(state.identifier != "locations.page")
    #expect(!state.canRebuild)
    // Its W-ORPHAN is listed above.
    #expect(LocationsView.listedFindings(model.findings, state: state).contains { $0.code == .orphan })
  }

  @Test("An index that can't be read shows its E-CAST as locations.unreadable (LV-4)")
  func unreadableState() async throws {
    let root = try copy(of: "errors/E-CAST-locations-yaml")
    defer { remove(root) }
    let model = LocationsPaneModel(projectDirectory: root, selectedBundleURL: nil)
    await model.show()
    let state = LocationsView.state(of: model)
    #expect(state.identifier == "locations.unreadable")
    guard case .unreadable(let lines) = state else {
      Issue.record("expected .unreadable, got \(state)")
      return
    }
    #expect(!lines.isEmpty)
    #expect(lines.allSatisfy { $0.hasPrefix("E-CAST") })
    // Shown in the page's place, not listed twice.
    #expect(LocationsView.listedFindings(model.findings, state: state).allSatisfy { $0.code != .cast })
    #expect(!state.canRebuild)
  }

  @Test("Before show() there is nothing to show")
  func emptyState() throws {
    let root = try copy(of: "valid/locations-page-current")
    defer { remove(root) }
    let model = LocationsPaneModel(projectDirectory: root)
    #expect(LocationsView.state(of: model) == .empty)
    #expect(LocationsView.state(of: model).identifier == nil)
  }
}
