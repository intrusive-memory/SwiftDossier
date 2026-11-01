import CryptoKit
import Foundation
import Testing

@testable import DossierCore

/// SD-2: the bundled copies equal `PINNED.sha256`, and, when `.dossier-format/`
/// is present, the pinned revision itself.
@Suite("Pinned resources (DossierCore)")
struct PinnedResourcesTests {
  private static let bundle = DossierCoreResources.bundle
  private static let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// (hash, path relative to Resources/) pairs from the checked-in list.
  private static func pins() throws -> [(hash: String, path: String)] {
    let root = try #require(bundle.resourceURL)
    let text = try String(contentsOf: root.appendingPathComponent("PINNED.sha256"), encoding: .utf8)
    return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
      let parts = line.components(separatedBy: "  ")
      return (parts[0], parts[1])
    }
  }

  @Test func pinListIsNotEmpty() throws {
    #expect(try Self.pins().count == 2)
  }

  @Test func bundledCopiesMatchPinList() throws {
    let root = try #require(Self.bundle.resourceURL)
    for pin in try Self.pins() {
      let data = try Data(contentsOf: root.appendingPathComponent(pin.path))
      #expect(Self.sha256(data) == pin.hash, "\(pin.path) differs from PINNED.sha256")
    }
  }

  @Test func bundledCopiesMatchPinnedRevisionWhenPresent() throws {
    let source = Self.repoRoot.appendingPathComponent(".dossier-format")
    guard FileManager.default.fileExists(atPath: source.path) else { return }
    let root = try #require(Self.bundle.resourceURL)
    for pin in try Self.pins() {
      let upstream = source.appendingPathComponent("data").appendingPathComponent(pin.path)
      let theirs = try Data(contentsOf: upstream)
      let ours = try Data(contentsOf: root.appendingPathComponent(pin.path))
      #expect(ours == theirs, "\(pin.path) differs from dossier-format")
    }
  }
}
