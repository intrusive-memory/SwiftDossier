import Dossier
import DossierCore
import Foundation
import Testing

@testable import DossierUI

/// ``LocationsPaneModel`` on writable copies of dossier-format's LOCATIONS page examples (§16.6).
@MainActor
@Suite("LocationsPaneModel (LV-2, LV-3, LV-11)")
struct LocationsPaneModelTests {
  /// A writable copy of `examples/<path>` in a new temporary directory.
  private func copy(of path: String) throws -> URL {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocationsPaneModelTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let root = parent.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.copyItem(at: SpecTree.examples.appendingPathComponent(path), to: root)
    return root
  }

  private func remove(_ root: URL) { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

  private func store(_ root: URL) -> URL { root.appendingPathComponent(".locations-page", isDirectory: true) }

  private func storeContents(_ root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: store(root).path).sorted()
  }

  @Test("A current store: the stored page is shown, a hit, and nothing is built")
  func current() async throws {
    let root = try copy(of: "valid/locations-page-current")
    defer { remove(root) }
    let before = try storeContents(root)
    let model = LocationsPaneModel(projectDirectory: root, selectedBundleURL: nil, refreshToken: nil)
    await model.show()
    let result = try #require(model.result)
    #expect(result.hit)
    #expect(result.key == "95898bc7b519d3d5437542fe6d66f8666c7738cb22d1c49ad3d0bd49914c85a6")
    #expect(model.pageFile?.lastPathComponent == result.key + ".html")
    #expect(model.pageHTML == nil)
    #expect(model.storeNote == nil)
    #expect(model.failure == nil)
    #expect(!model.isBuilding)
    #expect(try storeContents(root) == before)
  }

  @Test("An out-of-date store: the page is built off the main actor, stored and shown")
  func outOfDate() async throws {
    let root = try copy(of: "valid/locations-page-out-of-date")
    defer { remove(root) }
    let model = LocationsPaneModel(projectDirectory: root, selectedBundleURL: nil, refreshToken: nil)
    await model.show()
    let result = try #require(model.result)
    #expect(!result.hit)
    #expect(result.storeError == nil)
    #expect(model.pageFile == result.pageURL)
    #expect(model.pageFile?.lastPathComponent == result.key + ".html")
    #expect(model.pageHTML == nil)
    #expect(model.storeNote == nil)
    #expect(!model.isBuilding)
    #expect(try storeContents(root) == [".gitignore", result.key + ".html"])
  }

  @Test("An active update marker in an entry's bundle: any stored page is shown and nothing is built")
  func updating() async throws {
    let root = try copy(of: "valid/locations-page-out-of-date")
    defer { remove(root) }
    // The marker's shape is `valid/update-active`'s `.update-live.json`, live for an hour from now.
    let formatter = ISO8601DateFormatter()
    let now = Date()
    let marker = """
      {
        "writer": "fixture-writer",
        "startedAt": "\(formatter.string(from: now.addingTimeInterval(-60)))",
        "expiresAt": "\(formatter.string(from: now.addingTimeInterval(3600)))"
      }
      """
    try Data(marker.utf8).write(
      to: root.appendingPathComponent("locations/HARBOR-LIGHT.dossier/.update-live.json"))
    let index = try #require(DossierProject(directory: root).discoverLocations().index)
    #expect(index.isUpdatingABundle())
    let before = try storeContents(root)
    let stored = try #require(LocationsPageStore(index: index).anyStoredPage())

    let model = LocationsPaneModel(projectDirectory: root, selectedBundleURL: nil, refreshToken: nil)
    await model.show()
    #expect(model.pageFile?.standardizedFileURL == stored.standardizedFileURL)
    #expect(model.pageHTML == nil)
    #expect(model.result == nil)
    #expect(!model.isBuilding)
    #expect(try storeContents(root) == before)
  }

  @Test("A store that can't be written: the built page is shown from memory, with a note")
  func readOnlyStore() async throws {
    let root = try copy(of: "valid/locations-page-out-of-date")
    let storeDirectory = store(root)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: storeDirectory.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeDirectory.path)
      remove(root)
    }
    let before = try storeContents(root)
    let model = LocationsPaneModel(projectDirectory: root, selectedBundleURL: nil, refreshToken: nil)
    await model.show()
    let result = try #require(model.result)
    #expect(result.storeError != nil)
    #expect(model.storeNote != nil)
    #expect(model.storeNote?.hasPrefix("This page couldn't be saved in the project, so it's shown from memory.") == true)
    #expect(model.pageFile == nil)
    #expect(model.pageHTML?.isEmpty == false)
    #expect(model.pageHTML == result.html)
    #expect(model.failure == nil)
    #expect(try storeContents(root) == before)
  }

  @Test("Rebuild stores a fresh page even on a hit")
  func rebuild() async throws {
    let root = try copy(of: "valid/locations-page-current")
    defer { remove(root) }
    let model = LocationsPaneModel(projectDirectory: root, selectedBundleURL: nil, refreshToken: nil)
    await model.show()
    let hit = try #require(model.result)
    #expect(hit.hit)
    let file = try #require(model.pageFile)
    let past = Date(timeIntervalSince1970: 1_000_000_000)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)

    let started = Date().addingTimeInterval(-1)
    await model.rebuild()
    let result = try #require(model.result)
    #expect(!result.hit)
    #expect(result.key == hit.key)
    #expect(result.storeError == nil)
    #expect(model.pageFile == result.pageURL)
    #expect(!model.isBuilding)
    #expect(try storeContents(root) == [".gitignore", result.key + ".html"])
    let modified = try #require(
      try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
    #expect(modified > started)
  }

  @Test("A new refresh token shows the page again, and an edited manifest rebuilds it")
  func refreshToken() async throws {
    let root = try copy(of: "valid/locations-page-current")
    defer { remove(root) }
    let model = LocationsPaneModel(projectDirectory: root, selectedBundleURL: nil, refreshToken: 1)
    #expect(model.pending == nil, "init shows nothing on its own")
    await model.show()
    let first = try #require(model.result)
    #expect(first.hit)

    let manifest = root.appendingPathComponent("locations/HARBOR-LIGHT.dossier/manifest.json")
    try (try Data(contentsOf: manifest) + Data(" ".utf8)).write(to: manifest)
    model.refreshToken = 1
    #expect(model.pending == nil)

    model.refreshToken = 2
    await model.pending?.value
    let second = try #require(model.result)
    #expect(second.key != first.key)
    #expect(!second.hit)
    #expect(model.pageFile?.lastPathComponent == second.key + ".html")
    #expect(try storeContents(root) == [".gitignore", second.key + ".html"])
  }
}
