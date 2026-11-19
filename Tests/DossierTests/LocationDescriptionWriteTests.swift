import DossierCore
import Foundation
import Testing

@testable import Dossier

/// `LocationDescription.write(to:)` (§16.3, SFV-4, D-5), on temporary copies of the synthetic
/// `locations-project` bundles. The fixture directory is never written.
@Suite("LocationDescription write (§16.3)")
struct LocationDescriptionWriteTests {
  private static let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/locations-project")

  /// A copy of a fixture bundle in a temporary directory, opened.
  private func copy(_ path: String) throws -> DossierBundle {
    let root = try RenderProject.temporaryRoot()
    let name = (path as NSString).lastPathComponent
    let destination = root.appendingPathComponent(name)
    try FileManager.default.copyItem(at: Self.project.appendingPathComponent(path), to: destination)
    return try DossierBundle.open(at: destination)
  }

  @Test("A written LOCATION.md is re-read as written, and the manifest still validates")
  func roundTrip() throws {
    var bundle = try copy("locations/HARBOR-LIGHT.dossier")
    #expect(bundle.isLocation)
    let before = try #require(String(data: Data(contentsOf: bundle.url.appendingPathComponent("LOCATION.md")), encoding: .utf8))
    var description = LocationDescription(text: before)
    try description.setFrontMatter("theme", .string("FOG"))
    description.setSection(named: "Blocking", content: "The lamp keeper crosses to the rail.")
    try description.write(to: &bundle)

    let written = try String(contentsOf: bundle.url.appendingPathComponent("LOCATION.md"), encoding: .utf8)
    #expect(written == description.text)
    #expect(written != before)
    let reread = LocationDescription(text: written)
    #expect(reread.frontMatter?["theme"] == .string("FOG"))
    #expect(reread.frontMatter?["location"] == .string("HARBOR-LIGHT"))
    #expect(reread.section(named: "Blocking")?.content.contains("The lamp keeper crosses to the rail.") == true)
    #expect(reread.section(named: "Views") == LocationDescription(text: before).section(named: "Views"))

    let reopened = try DossierBundle.open(at: bundle.url)
    let listed = try #require(reopened.manifest.files.first { $0.path == "LOCATION.md" })
    #expect(listed.sizeBytes == Int64(Data(written.utf8).count))
    #expect(reopened.manifest.manifestChecksum == bundle.manifest.manifestChecksum)
    let codes = try DossierBundle.validate(at: bundle.url).findings.map(\.code)
    #expect(!codes.contains(.fileHash))
    #expect(!codes.contains(.unclassified))
    // Nothing is left behind by the temporary file.
    let names = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path)
    #expect(!names.contains { $0.hasSuffix(".tmp") })
  }

  @Test("Writing the text that is already there changes nothing")
  func sameText() throws {
    var bundle = try copy("locations/SALT-STORE.dossier")
    let manifestURL = bundle.url.appendingPathComponent("manifest.json")
    let file = try String(contentsOf: bundle.url.appendingPathComponent("LOCATION.md"), encoding: .utf8)
    try LocationDescription(text: file).write(to: &bundle)
    let first = try Data(contentsOf: manifestURL)
    try LocationDescription(text: file).write(to: &bundle)
    #expect(try Data(contentsOf: manifestURL) == first)
  }

  @Test("Zero bytes are refused, and the file is left as it was")
  func zeroBytes() throws {
    var bundle = try copy("locations/DRY-DOCK.dossier")
    let file = bundle.url.appendingPathComponent("LOCATION.md")
    let before = try Data(contentsOf: file)
    #expect(throws: DossierWriteError.zeroByteFiles(["LOCATION.md"])) {
      try LocationDescription(text: "").write(to: &bundle)
    }
    #expect(try Data(contentsOf: file) == before)
  }

  @Test("A destination that isn't a regular file is refused")
  func destinationNotRegular() throws {
    var bundle = try copy("locations/DRY-DOCK.dossier")
    let file = bundle.url.appendingPathComponent("LOCATION.md")
    let target = bundle.url.appendingPathComponent("elsewhere.md")
    try FileManager.default.moveItem(at: file, to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(throws: DossierWriteError.destinationNotInBundle("LOCATION.md")) {
      try LocationDescription(text: "x\n").write(to: &bundle)
    }
  }

  @Test("A character bundle is refused and left untouched")
  func characterBundle() throws {
    var bundle = try copy("characters/THE KEEPER.dossier")
    #expect(!bundle.isLocation)
    let manifestURL = bundle.url.appendingPathComponent("manifest.json")
    let manifest = try Data(contentsOf: manifestURL)
    #expect(throws: DescriptionError.notALocationBundle(bundle.url.path)) {
      try LocationDescription(text: "---\ntype: location\n---\n").write(to: &bundle)
    }
    #expect(try Data(contentsOf: manifestURL) == manifest)
    #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("LOCATION.md").path))
  }
}
