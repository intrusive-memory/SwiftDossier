import CryptoKit
import DossierCore
import Foundation
import Testing

@testable import Dossier

private let body = """

  ## Logline

  A tinker who mends radios.[^a]

  [^a]: Author. Invented, 2026-01-01.
  """

/// §11.1's key, acceptance item 8. Every expected value is computed here, from the bundle as it
/// is when the test runs: no literal hashes, versions or fixtures.
@Suite("PreviewKey")
struct PreviewKeyTests {
  /// SHA-256 as 64 lowercase hex characters, computed without the library.
  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// The key's text, assembled line by line.
  private static func keyText(manifest: Data, memberHash: String, template: PageTemplate) -> String {
    var text = ""
    text += "dossier-preview\n"
    text += DossierBundle.previewVersion + "\n"
    text += sha256(manifest) + "\n"
    text += memberHash + "\n"
    text += template.sha256 + "\n"
    return text
  }

  private static func expectedKey(for bundle: DossierBundle, template: PageTemplate) throws -> String {
    let manifest = try Data(contentsOf: bundle.url.appendingPathComponent("manifest.json"))
    let text = keyText(manifest: manifest, memberHash: bundle.member?.hash ?? "", template: template)
    return sha256(Data(text.utf8))
  }

  private static func isKey(_ text: String) -> Bool {
    text.wholeMatch(of: /[0-9a-f]{64}/) != nil
  }

  @Test("The key is the SHA-256 of the five lines, with the member's hash")
  func matchesLines() throws {
    let project = try RenderProject(description: synthetic(body: body))
    try project.addImage(.portrait)
    let bundle = try project.open()
    let member = try #require(bundle.member)
    #expect(!member.hash.isEmpty)
    let template = try DossierTemplate.current
    #expect(try bundle.previewKey() == Self.expectedKey(for: bundle, template: template))
    #expect(try bundle.previewKey(template: template) == Self.expectedKey(for: bundle, template: template))
  }

  @Test("With no member the text is five lines and the fourth is empty")
  func noMember() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let bundle = try DossierBundle.openForPreview(at: project.bundleURL, cast: nil)
    #expect(bundle.member == nil)
    let template = try DossierTemplate.current
    let text = Self.keyText(
      manifest: try Data(contentsOf: project.manifestURL), memberHash: "", template: template)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 6)
    #expect(lines.last == "")
    #expect(lines[3] == "")
    #expect(try bundle.previewKey() == Self.sha256(Data(text.utf8)))
    #expect(try bundle.previewKey() != project.open().previewKey())
  }

  @Test("The key is 64 lowercase hexadecimal characters")
  func format() throws {
    let project = try RenderProject(description: synthetic(body: body))
    #expect(Self.isKey(try project.open().previewKey()))
    #expect(Self.isKey(try DossierBundle.openForPreview(at: project.bundleURL, cast: nil).previewKey()))
  }

  @Test("Rewriting an image's bytes or editing CHARACTER.md leaves the key as it was")
  func unseenEdits() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let image = try project.addImage(.portrait)
    let first = try project.open().previewKey()

    try RenderImages.png(width: 18, height: 32, shade: 200)
      .write(to: project.bundleURL.appendingPathComponent(image.path))
    #expect(try project.open().previewKey() == first)

    try Data(synthetic(body: "\n## Logline\n\nSomeone else entirely.\n").utf8)
      .write(to: project.bundleURL.appendingPathComponent("CHARACTER.md"))
    #expect(try project.open().previewKey() == first)
  }

  @Test("Editing manifest.json changes the key")
  func manifestEdit() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let first = try project.open().previewKey()
    try project.addImage(.portrait)
    let second = try project.open()
    #expect(try second.previewKey() != first)
    #expect(try second.previewKey() == Self.expectedKey(for: second, template: try DossierTemplate.current))
  }

  @Test("Editing the CAST.md member changes the key")
  func memberEdit() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let before = try project.open()
    let first = try before.previewKey()

    let cast = try String(contentsOf: project.cast, encoding: .utf8)
    #expect(cast.contains("A low voice."))
    try Data(cast.replacingOccurrences(of: "A low voice.", with: "A high voice.").utf8).write(to: project.cast)
    let after = try project.open()
    #expect(try #require(after.member).hash != (try #require(before.member).hash))
    #expect(try after.previewKey() != first)
    #expect(try after.previewKey() == Self.expectedKey(for: after, template: try DossierTemplate.current))
  }

  @Test("A template with a different sha256 changes the key, and the page carries the same key")
  func templateChange() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let bundle = try project.open()
    let current = try DossierTemplate.current
    let other = PageTemplate(version: current.version, sha256: Self.sha256(Data(current.sha256.utf8)))
    #expect(other.sha256 != current.sha256)

    let key = try bundle.previewKey(template: other)
    #expect(key != (try bundle.previewKey()))
    #expect(key == (try Self.expectedKey(for: bundle, template: other)))
    #expect(try bundle.previewPage(template: other).key == key)
    #expect(try bundle.previewPage().key == bundle.previewKey())
  }
}
