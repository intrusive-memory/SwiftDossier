import CoreGraphics
import CryptoKit
import DossierCore
import Foundation
import Testing

@testable import Dossier

/// dossier-format 2.1.0's additions as a consumer reads them: location bundles, plates, the
/// display name, storyboard labels, `PROJECT.md` discovery, and the LOCATIONS page (§5.1, §16).
@Suite("Locations (§16)")
struct LocationsTests {
  private func project(_ path: String) -> URL { Conformance.root.appendingPathComponent(path) }

  /// A writable copy of a fixture project.
  private func copy(of path: String) throws -> URL {
    let root = try RenderProject.temporaryRoot().appendingPathComponent("project")
    try FileManager.default.copyItem(at: project(path), to: root)
    return root
  }

  // MARK: Reading

  @Test("A location bundle reads as one, with its record, plates in page order and labels")
  func locationBundle() throws {
    let index = try #require(DossierProject(directory: project("valid/location")).discoverLocations().index)
    #expect(index.entries.map(\.location) == ["HARBOR-LIGHT", "THE OLD QUAY"])
    #expect(index.entries[1].pointer == nil)
    #expect(index.entries[0].fields["name"]?.stringValue == "The harbor light at the end of the mole")
    let bundle = try #require(try index.openBundle(for: index.entries[0]))
    #expect(bundle.isLocation)
    #expect(bundle.dossierType == .location)
    #expect(bundle.descriptionPath == "LOCATION.md")
    #expect(bundle.displayName == nil)
    let record = try #require(bundle.manifest.location)
    #expect(record.name == "The harbor light at the end of the mole")
    #expect(record.theme == "COAST")
    #expect(record.views.map(\.variant) == ["dock", "lamp-room"])
    #expect(record.views[1].view.theme == "COAST-NIGHT")
    #expect(record.views[0].view.exterior == true)
    #expect(record.views[1].view.refs == ["room:dock"])

    #expect(bundle.plates().count == 3)
    #expect(bundle.plates(variant: "dock").count == 2)
    #expect(bundle.selectedPlates.map(\.variant) == ["dock", "lamp-room"])
    let dock = try #require(bundle.selectedPlate(variant: "dock"))
    #expect(dock.kind == .plate)
    #expect(dock.path == "images/plate-dock-f20ae08d.png")
    #expect(dock.storyboardLabel == "this location's empty set; paint the people into it")
    let lamp = try #require(bundle.selectedPlate(variant: "lamp-room"))
    #expect(lamp.provenance.references.first?.role == "plate:dock")

    let view = try #require(bundle.selectedAsset(kind: .view, variant: "storyboard-design"))
    #expect(view.isImported)
    #expect(view.path.hasSuffix(".jpg"))
    #expect(view.provenance.copiedFromSha256 == "e2c06e9f8ab6b92dda57b50e79881d9827e4c9cf4a708f9a3429aaec23aa0226")
    #expect(view.provenance.source == "storyboards/fixture/harbor-light-design.jpg")
    #expect(try bundle.completeness(tier: .lead) == nil)
    #expect(bundle.stale().isEmpty)
  }

  @Test("A character bundle is the default, and a reserved dossierType reads as one")
  func characterIsDefault() throws {
    let manifest = { (extra: String) in
      try Manifest(
        data: Data(
          #"{"manifestVersion": 2, "character": "A", "updatedAt": "2026-01-01T00:00:00Z", "files": [], "assets": [], "manifestChecksum": ""\#(extra)}"#
            .utf8))
    }
    #expect(try manifest("").dossierType == .character)
    #expect(try manifest(#", "dossierType": "character""#).dossierType == .character)
    #expect(try manifest(#", "dossierType": "prop""#).dossierType == .character)
    #expect(try manifest(#", "dossierType": "prop""#).dossierTypeText == "prop")
    #expect(try manifest(#", "dossierType": "location""#).dossierType == .location)
    #expect(AssetKind(rawValue: "plate") == .plate)
    #expect(AssetKind.plate.isImage)
  }

  @Test("displayName: the member's wins, the manifest's is a copy, and they may differ (W-DISPLAY-NAME)")
  func displayName() throws {
    func bundle(_ path: String, _ name: String) throws -> DossierBundle {
      let cast = try Cast.load(project(path).appendingPathComponent("CAST.md"))
      let member = try #require(cast.members.first { $0.character == name })
      return try #require(try cast.openBundle(for: member))
    }
    let differing = try bundle("warnings/W-DISPLAY-NAME", "PELL ARDEN")
    #expect(differing.manifest.displayName == "Pell")
    #expect(differing.member?.displayName == "Miss Arden")
    #expect(differing.displayName == "Miss Arden")
    let copyOnly = try bundle("valid/display-name-no-member-copy", "THE PURSER")
    #expect(copyOnly.member?.displayName == nil)
    #expect(copyOnly.displayName == copyOnly.manifest.displayName)
    #expect(copyOnly.displayName != nil)
  }

  @Test("Hosted-voice provenance: voiceId, creditsUsed and postProcess")
  func hostedVoiceProvenance() throws {
    let cast = try Cast.load(project("valid/hosted-voice-provenance").appendingPathComponent("CAST.md"))
    let bundle = try #require(try cast.openBundle(for: cast.members[0]))
    let samples = bundle.assets(kind: .voiceSample)
    #expect(!samples.isEmpty)
    for sample in samples {
      #expect(sample.provenance.voiceId != nil)
      #expect((sample.provenance.creditsUsed ?? -1) >= 0)
      let process = try #require(sample.provenance.postProcess)
      #expect(process.chain?.isEmpty == false)
      #expect(process.tool?.name != nil)
    }
  }

  @Test("Writers: a plate needs a variant and is content-named; an imported JPEG keeps its bytes")
  func writers() throws {
    let root = try copy(of: "valid/location")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let index = try #require(DossierProject(directory: root).discoverLocations().index)
    var bundle = try #require(try index.openBundle(for: index.entries[0]))
    let sources = root.appendingPathComponent("incoming")
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

    let plate = sources.appendingPathComponent("stair.png")
    try RenderImages.png(width: 320, height: 180, shade: 90).write(to: plate)
    let provenance = JSONObject([("provider", .string("vinetas"))])
    #expect(throws: DossierWriteError.self) {
      try bundle.add(plate, kind: .plate, options: AddOptions(provenance: provenance))
    }
    let added = try bundle.add(
      plate, kind: .plate,
      options: AddOptions(
        variant: "stair-from-below", provenance: provenance, select: true, storyboardLabel: "the stair, from below"))
    #expect(added.path.hasPrefix("images/plate-stair-from-below-"))
    #expect(added.path.hasSuffix(".png"))
    #expect(added.storyboardLabel == "the stair, from below")
    #expect(bundle.selectedPlates.map(\.variant) == ["dock", "lamp-room", "stair-from-below"])

    let drawing = sources.appendingPathComponent("design.jpg")
    let jpeg = try RenderImages.encoded(width: 100, height: 50, type: .jpeg) { context in
      context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
    }
    try jpeg.write(to: drawing)
    let imported = try bundle.add(
      drawing, kind: .view,
      options: AddOptions(
        variant: "storyboard-wide",
        provenance: JSONObject([("provider", .string("import")), ("copiedFrom", .string("storyboards/design.jpg"))])))
    #expect(imported.path.hasSuffix(".jpg"))
    #expect(try Data(contentsOf: bundle.url.appendingPathComponent(imported.path)) == jpeg)

    try FileManager.default.removeItem(at: sources)
    let report = try DossierBundle.validate(cast: root.appendingPathComponent("CAST.md"), template: try DossierTemplate.current)
    #expect(report.findings.isEmpty, "\(report.findings)")
  }

  // MARK: Discovery (§16.2)

  @Test("PROJECT.md's five outcomes", arguments: [
    ("valid/locations-no-key", "none"), ("valid/locations-no-project", "none"),
    ("errors/E-CAST-project-yaml", "project"), ("errors/E-CAST-project-locations-type", "project"),
    ("errors/E-CAST-project-locations-absolute", "project"), ("errors/E-CAST-project-locations-outside", "project"),
    ("warnings/W-POINTER-locations-missing", "missing"), ("warnings/W-POINTER-locations-directory", "missing"),
    ("errors/E-CAST-locations-yaml", "index"), ("errors/E-CAST-locations-type", "index"),
    ("errors/E-CAST-locations-no-location", "index"), ("valid/locations-index-elsewhere", "found"),
  ])
  func discovery(path: String, outcome: String) {
    let found: String
    switch DossierProject(directory: project(path)).discoverLocations() {
    case .none: found = "none"
    case .projectUnreadable: found = "project"
    case .indexMissing: found = "missing"
    case .indexUnreadable: found = "index"
    case .index: found = "found"
    }
    #expect(found == outcome)
  }

  @Test("A valid index path neither starts with / nor leaves the project directory")
  func indexPaths() {
    #expect(DossierProject.indexSegments("LOCATIONS.md") == ["LOCATIONS.md"])
    #expect(DossierProject.indexSegments("./world/../PLACES.md") == ["PLACES.md"])
    #expect(DossierProject.indexSegments("") == nil)
    #expect(DossierProject.indexSegments("/LOCATIONS.md") == nil)
    #expect(DossierProject.indexSegments("../LOCATIONS.md") == nil)
    #expect(DossierProject.indexSegments("a/..") == nil)
  }

  @Test("The index can be elsewhere: its entries resolve against its own directory")
  func indexElsewhere() throws {
    let root = project("valid/locations-index-elsewhere")
    let index = try #require(DossierProject(directory: root).discoverLocations().index)
    #expect(index.url.lastPathComponent == "PLACES.md")
    let manifest = try #require(index.manifestURL(of: index.entries[0]))
    #expect(manifest.path.hasSuffix("world/locations/HARBOR-LIGHT.dossier/manifest.json"))
  }

  @Test("validate(project:) needs no CAST.md")
  func projectWithoutCast() throws {
    let root = try copy(of: "warnings/W-ORPHAN-location")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    try FileManager.default.removeItem(at: root.appendingPathComponent("CAST.md"))
    let report = try DossierBundle.validate(project: root, template: try DossierTemplate.current)
    #expect(report.findings.map(\.code) == [.orphan])
    #expect(report.findings.first?.path == "locations/DRY-DOCK.dossier")
  }

  @Test("A location bundle validated alone is held to §16's rules")
  func locationAlone() throws {
    let bundle = project("valid/location").appendingPathComponent("locations/HARBOR-LIGHT.dossier")
    #expect(try DossierBundle.validate(at: bundle).findings.isEmpty)
    let misnamed = project("errors/E-NAME-MISMATCH-location").appendingPathComponent("locations/HARBOR-LIGHT.dossier")
    #expect(try DossierBundle.validate(at: misnamed).findings.map(\.code) == [.nameMismatch])
  }

  @Test("A location bundle has no page and no preview of its own (§16.6)")
  func noPageOfItsOwn() throws {
    let root = try copy(of: "valid/location")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    var bundle = try DossierBundle.open(at: root.appendingPathComponent("locations/HARBOR-LIGHT.dossier"))
    let before = try RenderTree.files(under: bundle.url)
    #expect(throws: DossierWriteError.self) { try bundle.renderPage() }
    #expect(throws: DossierWriteError.self) { try bundle.showPreview() }
    #expect(try RenderTree.files(under: bundle.url) == before)
  }

  @Test("View families: storyboard, storyboard-<slug>, look-<slug>")
  func viewFamilies() {
    for variant in ["storyboard", "storyboard-ink-stained", "look-evening", "look-clockwork-body", "look-a1"] {
      #expect(ViewVariant.isInFamily(variant), "\(variant)")
    }
    for variant in ["look", "look-", "storyboard-", "look-Evening", "look--a", "look-a-", "brass-armor", "storyboards"] {
      #expect(!ViewVariant.isInFamily(variant), "\(variant)")
    }
  }

  // MARK: The LOCATIONS page (§16.6)

  @Test("The LOCATIONS template's rule 1 hash is the one VERSION.json and conformance.json publish")
  func templateHash() throws {
    let locations = try LocationsTemplate.directory
    let template = try DossierTemplate.directory
    var files: [(path: String, url: URL)] = [
      ("template/dossier.css", template.appendingPathComponent("dossier.css")),
      ("template/fonts.css", template.appendingPathComponent("fonts.css")),
    ]
    for name in try FileManager.default.subpathsOfDirectory(atPath: locations.path)
    where name != "VERSION.json" && !name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
      var isDirectory: ObjCBool = false
      let url = locations.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
      files.append(("template-locations/" + name, url))
    }
    var hasher = SHA256()
    for file in files.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
      hasher.update(data: Data(file.path.utf8))
      hasher.update(data: Data([0]))
      hasher.update(data: try Data(contentsOf: file.url))
    }
    let computed = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    #expect(computed == (try LocationsTemplate.sha256))
    if !SpecTree.isOverridden {
      let document = try Conformance.document()
      #expect(document.locationsTemplateSha256 == (try LocationsTemplate.sha256))
      #expect(document.locationsTemplateVersion == (try LocationsTemplate.version))
    }
  }

  @Test("§16.6's worked example: the key, the section id, and a hit that writes nothing")
  func workedExample() throws {
    let root = project("valid/locations-page-current")
    let before = try RenderTree.files(under: root)
    let projectFile = DossierProject(directory: root)
    #expect(projectFile.title == "The Fixture Coast")
    let result = try #require(try projectFile.showLocationsPage())
    #expect(result.key == "95898bc7b519d3d5437542fe6d66f8666c7738cb22d1c49ad3d0bd49914c85a6")
    #expect(result.hit)
    #expect(result.html == nil)
    #expect(result.pageURL?.lastPathComponent == result.key + ".html")
    #expect(LocationsIndex.sectionID(forLocation: "HARBOR-LIGHT") == "location-64a891cc")
    #expect(try RenderTree.files(under: root) == before)
  }

  /// The page without the payload of each image `data:` URI, and the payloads' sizes.
  private func withoutPayloads(_ page: Data) throws -> (rest: Data, sizes: [String]) {
    let marker = Data("data:image/jpeg;base64,".utf8)
    var rest = Data()
    var sizes: [String] = []
    var position = page.startIndex
    while let found = page.range(of: marker, in: position..<page.endIndex) {
      rest.append(page[position..<found.upperBound])
      var end = found.upperBound
      while end < page.endIndex, page[end] != UInt8(ascii: "\"") { end += 1 }
      let payload = try #require(Data(base64Encoded: page[found.upperBound..<end]))
      let read = try #require(JPEGSegments.read(payload))
      sizes.append("\(read.width)x\(read.height)")
      position = end
    }
    rest.append(page[position..<page.endIndex])
    return (rest, sizes)
  }

  @Test("An out-of-date store: the page is built, stored, and is the stored example apart from image payloads")
  func outOfDate() throws {
    let root = try copy(of: "valid/locations-page-out-of-date")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let result = try #require(try DossierProject(directory: root).showLocationsPage())
    #expect(!result.hit)
    #expect(result.storeError == nil)
    let store = root.appendingPathComponent(".locations-page")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: store.path).sorted() == [".gitignore", result.key + ".html"])
    #expect(try Data(contentsOf: store.appendingPathComponent(".gitignore")) == Data("*\n".utf8))

    let built = try Data(contentsOf: try #require(result.pageURL))
    let expected = try Data(
      contentsOf: project("valid/locations-page-current").appendingPathComponent(".locations-page/\(result.key).html"))
    let (expectedRest, expectedSizes) = try withoutPayloads(expected)
    let (rest, sizes) = try withoutPayloads(built)
    #expect(sizes == expectedSizes)
    #expect(sizes == ["1280x720", "1280x720", "1280x640", "1280x720"])
    if rest != expectedRest {
      let offset = zip(rest, expectedRest).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(rest.count, expectedRest.count)
      let around = expectedRest.dropFirst(max(0, offset - 40)).prefix(120)
      Issue.record("differs at offset \(offset) of the payload-free page: \(String(decoding: around, as: UTF8.self))")
    }
    #expect(!String(decoding: built, as: UTF8.self).contains("<script"))
    #expect(PageReferences.external(in: Array(built)).isEmpty)

    // A second show is a hit, and the same inputs build the same bytes (DF-45).
    let again = try #require(try DossierProject(directory: root).showLocationsPage())
    #expect(again.hit)
    let index = try #require(DossierProject(directory: root).discoverLocations().index)
    #expect(try index.buildLocationsPage(title: "The Fixture Coast").html == String(decoding: built, as: UTF8.self))
  }

  @Test("Rebuild stores even on a hit, and writes nothing in a bundle")
  func rebuild() throws {
    let root = try copy(of: "valid/locations-page-current")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let bundles = try RenderTree.files(under: root.appendingPathComponent("locations"))
    let index = try #require(DossierProject(directory: root).discoverLocations().index)
    let result = try index.rebuildLocationsPage(title: DossierProject(directory: root).title)
    #expect(!result.hit)
    #expect(try RenderTree.files(under: root.appendingPathComponent("locations")) == bundles)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".locations-page").path).sorted()
        == [".gitignore", result.key + ".html"])
    #expect(!index.isUpdatingABundle())
  }

  @Test("An entry that can't be shown, and one with no bundle, say so; a manifest edit changes the key")
  func missingSections() throws {
    let root = try copy(of: "valid/location")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let index = try #require(DossierProject(directory: root).discoverLocations().index)
    let key = try index.locationsPageKey(title: nil, template: try LocationsTemplate.current)
    let manifest = root.appendingPathComponent("locations/HARBOR-LIGHT.dossier/manifest.json")
    try (try Data(contentsOf: manifest) + Data(" ".utf8)).write(to: manifest)
    #expect(try index.locationsPageKey(title: nil, template: try LocationsTemplate.current) != key)
    #expect(try index.locationsPageKey(title: "A title", template: try LocationsTemplate.current) != key)

    try Data("not json".utf8).write(to: manifest)
    let html = try index.buildLocationsPage(title: nil).html
    #expect(html.contains("This location&#x27;s bundle can&#x27;t be shown."))
    #expect(html.contains("No bundle yet."))
    #expect(html.contains("<title>Locations</title>"))
    #expect(html.contains("2 locations"))
  }

  @Test("LOCATION.md's Markdown: # dropped, ## as h4, tables, code spans that bold doesn't cross")
  func markdown() throws {
    let root = try copy(of: "valid/location")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let description = root.appendingPathComponent("locations/HARBOR-LIGHT.dossier/LOCATION.md")
    try Data(
      """
      ---
      type: location
      location: HARBOR-LIGHT
      ---
      # Title
      A **bold `co**de` here** and `<a>` and ``x``.[^n]
      ## Part
      | A | B |
      |:-|-:|
      | `x` | **y** | extra
      | only
      after

      [^n]: Stated. A note.
      """.utf8
    ).write(to: description)
    let html = try #require(DossierProject(directory: root).discoverLocations().index).buildLocationsPage(title: nil).html
    let start = try #require(html.range(of: "<div class=\"location-description field-value t-body\">")).upperBound
    let end = try #require(html.range(of: "</div>", range: start..<html.endIndex)).lowerBound
    #expect(
      String(html[start..<end])
        == "<p>A **bold <code>co**de</code> here** and <code>&lt;a&gt;</code> and `<code>x</code>`.<sup class=\"mark\">1</sup></p>"
        + "<h4>Part</h4><table><thead><tr><th>A</th><th>B</th></tr></thead><tbody>"
        + "<tr><td><code>x</code></td><td><strong>y</strong></td></tr><tr><td>only</td><td></td></tr></tbody></table>"
        + "<p>after</p>")
    #expect(html.contains("<li>Stated. A note.</li>"))
  }
}
