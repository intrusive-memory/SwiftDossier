import CryptoKit
import DossierCore
import Foundation
import Testing

@testable import Dossier

/// `template/README.md` rule 1, stated here and nowhere in the library, which only reads the
/// hash `VERSION.json` publishes.
private enum RuleOne {
  static func paths(under root: URL) throws -> [String] {
    let manager = FileManager.default
    return try manager.subpathsOfDirectory(atPath: root.path).filter { path in
      var isDirectory: ObjCBool = false
      guard manager.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { return false }
      let segments = path.split(separator: "/")
      return path != "VERSION.json" && path != "README.md" && segments.first != "example"
        && !segments.contains { $0.hasPrefix(".") }
    }
    .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }

  static func hash(of root: URL) throws -> String {
    var hasher = SHA256()
    for path in try paths(under: root) {
      hasher.update(data: Data(path.utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: try Data(contentsOf: root.appendingPathComponent(path)))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

@Suite("DossierTemplate")
struct DossierTemplateTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("DossierTemplateTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A writable copy of the bundled template.
  private func bundledCopy() throws -> URL {
    let copy = try temporaryDirectory().appendingPathComponent("template", isDirectory: true)
    try FileManager.default.copyItem(at: try DossierTemplate.directory, to: copy)
    return copy
  }

  @Test("Rule 1's worked example")
  func workedExample() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
    try Data("x\n".utf8).write(to: root.appendingPathComponent("a.css"))
    try Data("y\n".utf8).write(to: root.appendingPathComponent("b/c.js"))
    #expect(try RuleOne.hash(of: root) == "f465131ed964bfee065fecc04d28486ed88ded7a3bd01c4583ac3da801c09b74")
  }

  @Test("Rule 1 over the bundled files is the hash VERSION.json publishes")
  func bundledHash() throws {
    #expect(try RuleOne.hash(of: try DossierTemplate.directory) == (try DossierTemplate.sha256))
    #expect(try DossierTemplate.current == PageTemplate(version: try DossierTemplate.version, sha256: try DossierTemplate.sha256))
  }

  @Test("The bundled template is the one conformance.json names")
  func sameAsConformance() throws {
    if SpecTree.isOverridden {
      Issue.record("skipped: SPEC_DIR is set, so conformance.json may name another template", severity: .warning)
      return
    }
    #expect(try DossierTemplate.current == (try Conformance.template()))
  }

  @Test("Changing any hashed file changes the hash")
  func tampering() throws {
    let copy = try bundledCopy()
    defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
    let published = try DossierTemplate.sha256
    let paths = try RuleOne.paths(under: copy)
    #expect(paths.count == 19)
    for path in paths {
      let url = copy.appendingPathComponent(path)
      let original = try Data(contentsOf: url)
      try (original + Data([0x20])).write(to: url)
      #expect(try RuleOne.hash(of: copy) != published, "\(path)")
      try original.write(to: url)
    }
    #expect(try RuleOne.hash(of: copy) == published)

    // A file too many.
    let extra = copy.appendingPathComponent("extra.css")
    try Data().write(to: extra)
    #expect(try RuleOne.hash(of: copy) != published)
    try FileManager.default.removeItem(at: extra)

    // What rule 1 leaves out doesn't count.
    try Data("note".utf8).write(to: copy.appendingPathComponent("README.md"))
    try Data("note".utf8).write(to: copy.appendingPathComponent(".hidden"))
    try FileManager.default.createDirectory(
      at: copy.appendingPathComponent("example"), withIntermediateDirectories: true)
    try Data("note".utf8).write(to: copy.appendingPathComponent("example/page.html"))
    #expect(try RuleOne.hash(of: copy) == published)
  }

  @Test("README.md, example/ and dot files aren't bundled")
  func leftOut() throws {
    let found = try FileManager.default.subpathsOfDirectory(atPath: try DossierTemplate.directory.path)
    #expect(!found.contains("README.md"))
    #expect(!found.contains { $0 == "example" || $0.hasPrefix("example/") })
    #expect(!found.contains { $0.split(separator: "/").contains { $0.hasPrefix(".") } })
    #expect(found.contains("VERSION.json"))
  }

  @Test("Files read by path, nested ones too; a missing one throws")
  func files() throws {
    #expect(String(decoding: try DossierTemplate.data(at: "skeleton.html"), as: UTF8.self).contains("{{tab.panels}}"))
    #expect(try !DossierTemplate.data(at: "fonts/ibm-plex-mono/OFL.txt").isEmpty)
    #expect(throws: DossierError.resourceUnreadable("template/nothing.css")) {
      try DossierTemplate.data(at: "nothing.css")
    }
  }

  @Test("tokens.json is in the bundle at data/")
  func tokens() throws {
    let url = try #require(DossierResources.bundle.url(forResource: "tokens", withExtension: "json", subdirectory: "data"))
    #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) is [String: Any])
  }
}
