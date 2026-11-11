import DossierCore
import Foundation
import Testing

@testable import Dossier

private let body = """

  ## Logline

  A tinker who mends radios.[^a]

  [^a]: Author. Invented, 2026-01-01.
  """

/// The store's directory, its entries' names and modification dates, for comparing before and after.
private struct StoreSnapshot: Equatable {
  let entries: [String: Date]

  init(_ directory: URL) throws {
    var entries: [String: Date] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
      entries[name] = try #require(attributes[.modificationDate] as? Date)
    }
    self.entries = entries
  }

  var names: Set<String> { Set(entries.keys) }
}

/// A key that isn't the bundle's: 64 lowercase hex characters, made when the test runs.
private func otherKey(_ seed: String) -> String { Checksum.sha256("not the bundle's key: " + seed) }

@Suite("PreviewStore")
struct PreviewStoreTests {
  private func project() throws -> RenderProject {
    let project = try RenderProject(description: synthetic(body: body))
    try project.addImage(.portrait)
    return project
  }

  private func store(_ project: RenderProject) -> PreviewStore { PreviewStore(bundle: project.bundleURL) }

  @Test("A miss stores the built page as <key>.html with a .gitignore of *, and leaves no temporary file")
  func missStores() throws {
    let project = try project()
    let bundle = try project.open()
    let result = try bundle.showPreview()
    let key = try bundle.previewKey()

    #expect(!result.hit)
    #expect(result.key == key)
    #expect(result.storeError == nil)
    let file = try #require(result.pageURL)
    #expect(file == store(project).directory.appendingPathComponent(key + ".html"))
    #expect(try String(contentsOf: file, encoding: .utf8) == bundle.previewPage().html)
    #expect(try result.html == String(contentsOf: file, encoding: .utf8))
    #expect(result.banner != nil)
    #expect(try StoreSnapshot(store(project).directory).names == [".gitignore", key + ".html"])
    #expect(
      try Data(contentsOf: store(project).directory.appendingPathComponent(".gitignore")) == Data("*\n".utf8))
    #expect(store(project).storedPage(forKey: key) == file)
  }

  @Test("Storing leaves every file outside .preview/ byte-identical (item 2)")
  func treeUnchanged() throws {
    let project = try project()
    try Data(synthetic(body: "\n## Logline\n\nEdited by hand.\n").utf8)
      .write(to: project.bundleURL.appendingPathComponent("CHARACTER.md"))
    let before = try project.tree()

    let result = try project.open().showPreview()
    #expect(result.pageURL != nil)
    let after = try project.tree()
    #expect(after.filter { !$0.key.hasPrefix(".preview/") } == before)
    #expect(after.keys.contains { $0.hasPrefix(".preview/") })
  }

  @Test("A hit creates, deletes and touches nothing in .preview/ (item 9)")
  func hitTouchesNothing() throws {
    let project = try project()
    let first = try project.open().showPreview()
    let directory = store(project).directory
    let before = try StoreSnapshot(directory)
    let tree = try project.tree()

    let second = try project.open().showPreview()
    #expect(second.hit)
    #expect(second.pageURL == first.pageURL)
    #expect(second.key == first.key)
    #expect(second.html == nil)
    #expect(try StoreSnapshot(directory) == before)
    #expect(try project.tree() == tree)
  }

  @Test("A current page beside an older preview and a .tmp is a hit, and nothing changes (item 10)")
  func currentWithLeftovers() throws {
    let project = try project()
    let first = try project.open().showPreview()
    let directory = store(project).directory
    let old = otherKey("older")
    try Data("<p>older</p>".utf8).write(to: directory.appendingPathComponent(old + ".html"))
    try Data("<p>half</p>".utf8).write(to: directory.appendingPathComponent("\(first.key).html.\(UUID().uuidString).tmp"))
    let before = try StoreSnapshot(directory)
    let tree = try project.tree()

    let result = try project.open().showPreview()
    #expect(result.hit)
    #expect(result.pageURL == first.pageURL)
    #expect(try StoreSnapshot(directory) == before)
    #expect(try project.tree() == tree)
  }

  @Test("A store holding only another key ends holding exactly .gitignore and <key>.html (item 10)")
  func outOfDate() throws {
    let project = try project()
    let directory = store(project).directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let old = otherKey("out of date")
    try Data("<p>older</p>".utf8).write(to: directory.appendingPathComponent(old + ".html"))

    let bundle = try project.open()
    let result = try bundle.showPreview()
    let key = try bundle.previewKey()
    #expect(!result.hit)
    #expect(result.key == key)
    #expect(try StoreSnapshot(directory).names == [".gitignore", key + ".html"])
    #expect(try Data(contentsOf: directory.appendingPathComponent(".gitignore")) == Data("*\n".utf8))
  }

  @Test("A manifest change stores a new key, removes the old one and keeps .gitignore (item 10)")
  func manifestChange() throws {
    let project = try project()
    let first = try project.open().showPreview()
    let directory = store(project).directory
    let gitignore = directory.appendingPathComponent(".gitignore")
    let custom = Data("*\n# kept as written\n".utf8)
    try custom.write(to: gitignore)

    try project.addImage(.portrait, shade: 120)
    let second = try project.open().showPreview()
    #expect(!second.hit)
    #expect(second.key != first.key)
    #expect(try second.key == project.open().previewKey())
    #expect(try StoreSnapshot(directory).names == [".gitignore", second.key + ".html"])
    #expect(try Data(contentsOf: gitignore) == custom)
  }

  @Test("A failed build (CHARACTER.md removed) throws and the old preview remains (item 11)")
  func failedBuildKeepsOld() throws {
    let project = try project()
    let first = try project.open().showPreview()
    let old = try #require(first.pageURL)
    try project.addImage(.portrait, shade: 120)
    try FileManager.default.removeItem(at: project.bundleURL.appendingPathComponent("CHARACTER.md"))
    let directory = store(project).directory
    let before = try StoreSnapshot(directory)

    let bundle = try project.open()
    #expect(try bundle.previewKey() != first.key)
    #expect(throws: CharacterDescriptionError.self) { try bundle.showPreview() }
    #expect(FileManager.default.fileExists(atPath: old.path))
    #expect(try StoreSnapshot(directory) == before)
  }

  @Test("A store that can't be written gives the built HTML and a storeError, without throwing (PV-23)")
  func readOnlyStore() throws {
    let project = try project()
    let directory = store(project).directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("*\n".utf8).write(to: directory.appendingPathComponent(".gitignore"))
    let old = otherKey("read-only")
    try Data("<p>older</p>".utf8).write(to: directory.appendingPathComponent(old + ".html"))
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
    let before = try StoreSnapshot(directory)

    let bundle = try project.open()
    let result = try bundle.showPreview()
    #expect(!result.hit)
    #expect(result.pageURL == nil)
    #expect(result.storeError != nil)
    #expect(try result.html == bundle.previewPage().html)
    #expect(result.html?.contains("A tinker who mends radios.") == true)
    #expect(try StoreSnapshot(directory) == before)
  }
}
