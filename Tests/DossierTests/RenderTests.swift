import CoreGraphics
import CryptoKit
import DossierCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Dossier

private let fullBody = """

  ## Logline

  A tinker who mends radios.[^a]

  ## Appearance

  Short and quick.[^b]

  [^a]: Author. Invented, 2026-01-01.
  [^b]: Stated. nowhere/invented.fountain:1.
  """

@Suite("renderPage")
struct RenderTests {
  @discardableResult
  private func render(_ project: RenderProject) throws -> RenderedPage {
    var bundle = try project.open()
    return try bundle.renderPage()
  }

  private func validationCodes(_ project: RenderProject) throws -> [String] {
    try project.open().validate(template: DossierTemplate.current).findings.map(\.code.rawValue).sorted()
  }

  @Test("Two renders give the same bytes, whatever the clock says")
  func deterministic() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    try project.addImage(.portrait)
    var bundle = try project.open()
    let writer = ManifestWriter(bundle: bundle.url)
    let first = try bundle.renderPage(now: Date(timeIntervalSince1970: 1_000_000_000), writer: writer)
    let bytes = try Data(contentsOf: project.pageURL)
    let second = try bundle.renderPage(now: Date(timeIntervalSince1970: 1_900_000_000), writer: writer)
    #expect(first.asset.createdAt != second.asset.createdAt)
    #expect(try Data(contentsOf: project.pageURL) == bytes)
    #expect(try !project.page().contains("2030-") && !project.page().contains("2001-09"))
  }

  @Test("The page asset goes through the write path, with its inputs")
  func asset() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    let rendered = try render(project)
    let manifest = try project.manifest()
    let asset = try #require(manifest.assets.first { $0.kind == .dossier })
    #expect(asset == rendered.asset)
    #expect(asset.status == .selected)
    #expect(asset.path == "\(RenderProject.character)-dossier.html")
    #expect(asset.provenance.provider?.isEmpty == false)
    let inputs = Dictionary(uniqueKeysWithValues: asset.derivedFrom.map { ($0.role, $0) })
    #expect(Set(inputs.keys) == ["description", "castMember", "bundle", "template"])
    let bundle = try project.open()
    #expect(inputs["castMember"]?.sha256 == bundle.member?.hash)
    #expect(inputs["description"]?.path == "CHARACTER.md")
    #expect(inputs["template"]?.version == (try DossierTemplate.version))
    #expect(inputs["template"]?.sha256 == (try DossierTemplate.sha256))
    let record = try PageReader(text: try project.page()).record()
    #expect(inputs["bundle"]?.sha256 == record["manifest"]?.objectValue?["manifestChecksum"]?.stringValue)
    let entry = try #require(manifest.files.first { $0.path == asset.path })
    #expect(entry.sha256 == Checksum.sha256(try Data(contentsOf: project.pageURL)))
    #expect(try validationCodes(project).filter { $0.hasPrefix("E-") }.isEmpty)
    #expect(try !validationCodes(project).contains("W-STALE"))
    #expect(try !validationCodes(project).contains("W-UNCLASSIFIED"))
  }

  @Test("A re-render leaves one page, one asset and one files entry, and replaces an older path")
  func reRender() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    try render(project)
    // A page from another name, as a bundle could have.
    let old = project.bundleURL.appendingPathComponent("OLD-dossier.html")
    try Data("<!DOCTYPE html>".utf8).write(to: old)
    var manifest = try project.manifest()
    var assets = manifest.assets
    var older = try #require(assets.first { $0.kind == .dossier })
    older.path = "OLD-dossier.html"
    older.status = .candidate
    assets.append(older)
    manifest.assets = assets
    try manifest.encoded().write(to: project.manifestURL)

    try render(project)
    let after = try project.manifest()
    #expect(after.assets.filter { $0.kind == .dossier }.count == 1)
    #expect(after.files.filter { $0.path.hasSuffix(".html") }.count == 1)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    let names = try FileManager.default.contentsOfDirectory(atPath: project.bundleURL.path)
    #expect(names.sorted() == ["CHARACTER.md", "\(RenderProject.character)-dossier.html", "manifest.json"])
    #expect(try !validationCodes(project).contains("E-ASSET-NO-FILE"))
  }

  @Test("The embedded manifest: no page, its own checksum, updatedAt the latest createdAt, otherwise manifest.json")
  func embedded() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    try project.addImage(.portrait)
    // The second render's manifest has a page entry, which must make no difference.
    try render(project)
    try render(project)
    let onDisk = try project.manifest()
    let record = try PageReader(text: try project.page()).record()
    let inPage = try Manifest(data: JSONValue.object(try #require(record["manifest"]?.objectValue)).prettyEncoded())
    #expect(!inPage.assets.contains { $0.kind == .dossier })
    #expect(!inPage.files.contains { $0.path.hasSuffix("-dossier.html") })
    #expect(inPage.manifestChecksum == inPage.computedChecksum)
    #expect(inPage.updatedAt == Timestamp.string(from: RenderProject.made))
    #expect(onDisk.updatedAt != inPage.updatedAt)
    #expect(inPage.assets == onDisk.assets.filter { $0.kind != .dossier })
    #expect(inPage.files == onDisk.files.filter { !$0.path.hasSuffix("-dossier.html") })
    #expect(inPage.character == onDisk.character)
  }

  @Test("A file a tool left in the bundle counts: what the write will record, the page says")
  func unclassifiedFile() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    try FileManager.default.createDirectory(
      at: project.bundleURL.appendingPathComponent("source"), withIntermediateDirectories: true)
    try Data("a note".utf8).write(to: project.bundleURL.appendingPathComponent("source/note.txt"))
    try render(project)
    let first = try Data(contentsOf: project.pageURL)
    #expect(try !validationCodes(project).contains("W-STALE"))
    try render(project)
    #expect(try Data(contentsOf: project.pageURL) == first)
  }

  @Test("The record matches record.schema.json, through its manifest $ref, and every < is escaped")
  func recordSchema() throws {
    let body = "\n## Logline\n\nA line with </script> and <b>tags</b>.\n"
    let project = try RenderProject(description: synthetic(frontMatter: "age: 39\nscore: 1.5\nlanguages: [fr-FR, en-US]\n", body: body))
    try render(project)
    let reader = PageReader(text: try project.page())
    let text = try #require(reader.recordText)
    #expect(!text.contains("<"))
    #expect(text.contains("\\u003c/script>"))
    let evaluator = try SchemaEvaluator.pinned()
    #expect(try evaluator.validate(try JSONValue.parse(Data(text.utf8)), against: "record.schema.json").isEmpty)
    // The evaluator follows the $ref: a broken manifest in the record is a violation.
    var broken = try reader.record()
    var manifest = try #require(broken["manifest"]?.objectValue)
    manifest["files"] = nil
    broken["manifest"] = .object(manifest)
    #expect(try !evaluator.validate(.object(broken), against: "record.schema.json").isEmpty)

    let record = try reader.record()
    // §7's scalars: integers stay integers, and what §7's canonical JSON can't write stays as written.
    #expect(record["frontMatter"]?.objectValue?["age"] == .number("39"))
    #expect(record["frontMatter"]?.objectValue?["score"] == .string("1.5"))
    #expect(record["body"]?.stringValue == body)
    #expect(record["castMember"]?.objectValue?["voices"]?.objectValue?.isEmpty == true)
    // {{lang}} is the first language.
    #expect(try project.page().contains("<html lang=\"fr-FR\">"))
    #expect(try reader.element(key: "profile.age").contains(">39<"))
  }

  @Test("{{lang}} is und with no languages, and text with a placeholder's shape stays as written")
  func onePass() throws {
    let body = "\n## Logline\n\n{{tab.panels}} and {{record}}.\n"
    let project = try RenderProject(description: synthetic(frontMatter: "occupation: \"{{character}}\"\n", body: body))
    try render(project)
    let reader = PageReader(text: try project.page())
    #expect(try project.page().contains("<html lang=\"und\">"))
    #expect(try reader.element(key: "profile.logline").contains("<p>{{tab.panels}} and {{record}}.</p>"))
    #expect(try reader.element(key: "profile.occupation").contains("{{character}}"))
  }

  @Test("check_template's substance: every key in order and nothing else, seven tabs, no external reference, the meta")
  func templateSubstance() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    try project.addImage(.portrait, width: 180, height: 320)
    try render(project)
    let text = try project.page()
    let reader = PageReader(text: text)
    let tabs = try DossierTabs.bundled()
    #expect(tabs.keys.count == 60)
    #expect(reader.attributes("data-key") == tabs.keys)
    let ids = reader.attributes("id")
    #expect(ids.count == Set(ids).count)
    #expect(Set(ids).subtracting(tabs.keys) == [])
    #expect(tabs.tabs.count == 7)
    let panels = PageReader.matches(of: "<section class=\"tab-panel\" id=\"([^\"]*)\"", in: reader.markup)
    #expect(panels == tabs.tabs.map(\.key))
    #expect(reader.attributes("data-tab-link") == tabs.tabs.map(\.key))
    #expect(PageReferences.external(in: Array(text.utf8)).isEmpty)
    let version = try DossierTemplate.version
    let sha256 = try DossierTemplate.sha256
    #expect(text.contains("<meta name=\"dossier-template\" content=\"\(version) \(sha256)\">"))
    for name in ["fonts.css", "dossier.css", "dossier.js"] {
      #expect(text.contains(String(decoding: try DossierTemplate.data(at: name), as: UTF8.self)), "\(name)")
    }
    #expect(!reader.markup.contains("{{"))
    #expect(!text.contains("<script>{{"))
  }

  @Test("Every kind's copy is JPEG at its size in page-copies.json, with no metadata")
  func copySizes() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    let portrait = try project.addImage(.portrait, width: 180, height: 320)
    let face = try project.addImage(.face, width: 64, height: 64)
    let view = try project.addImage(.view, variant: "front", width: 90, height: 160)
    let expression = try project.addImage(.expression, variant: "happy", width: 40, height: 40)
    #expect(portrait.status == .selected && face.status == .selected && view.status == .selected && expression.status == .selected)
    try render(project)
    let reader = PageReader(text: try project.page())
    let settings = try PageCopySettings(data: try DossierTemplate.data(at: "page-copies.json"))
    let expected: [(key: String, kind: String)] = [
      ("portrait.image", "portrait"), ("page.face", "face"), ("views.front", "view"), ("expressions.happy", "expression"),
    ]
    for (key, kind) in expected {
      let size = try #require(settings.size(ofKind: kind))
      let image = try #require(try reader.images(inElement: key).first, "\(key)")
      let read = try #require(JPEGSegments.read(image), "\(key)")
      #expect(read.width == size.width && read.height == size.height, "\(key)")
      #expect(!read.markers.contains { (0xE1...0xEF).contains($0) || $0 == 0xFE }, "\(key): \(read.markers)")
      #expect(try reader.element(key: key).contains("width=\"\(size.width)\" height=\"\(size.height)\""), "\(key)")
    }
    #expect(settings.quality == 0.8)
  }

  @Test("Rule 5: another shape scales to cover and crops the centre")
  func coverCrop() throws {
    // Red, green, blue, side by side: a tall copy shows only the green.
    let wide = try RenderImages.encoded(width: 900, height: 100, type: .png) { context in
      for (index, color) in [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)].enumerated() {
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        context.fill(CGRect(x: index * 300, y: 0, width: 300, height: 100))
      }
    }
    let copy = try #require(PageCopy.jpeg(of: wide, size: .init(width: 36, height: 64), quality: 0.8))
    let source = try #require(CGImageSourceCreateWithData(copy as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 36 && image.height == 64)
    let rendered = try #require(
      CGContext(
        data: nil, width: 36, height: 64, bitsPerComponent: 8, bytesPerRow: 36 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    rendered.draw(image, in: CGRect(x: 0, y: 0, width: 36, height: 64))
    let pixels = try #require(rendered.data).assumingMemoryBound(to: UInt8.self)
    for x in [1, 18, 34] {
      let offset = (32 * 36 + x) * 4
      #expect(pixels[offset + 1] > 200 && pixels[offset] < 80 && pixels[offset + 2] < 80, "at \(x)")
    }
    #expect(PageCopy.jpeg(of: Data("not an image".utf8), size: .init(width: 36, height: 64), quality: 0.8) == nil)
  }

  @Test("A sample's bytes are inlined as they are, neutral first, as audio/mp4; the overlay is in percent")
  func audioAndOverlay() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    let vox = project.root.appendingPathComponent("\(RenderProject.character).vox")
    try Data("a vox".utf8).write(to: vox)
    var bundle = try project.open()
    try bundle.add(
      vox, kind: .vox,
      options: AddOptions(provenance: JSONObject(["provider": .string("manual"), "models": .array([.string("x-1.7B-y")])]), select: true))
    var samples: [String: Data] = [:]
    for (name, variant) in [("sample-wry.m4a", "wry"), ("sample-neutral.m4a", "neutral")] {
      let bytes = Data("audio of \(variant)".utf8)
      samples[variant] = bytes
      let file = project.root.appendingPathComponent(name)
      try bytes.write(to: file)
      try bundle.add(
        file, kind: .voiceSample,
        options: AddOptions(variant: variant, model: "1.7b", sampleText: "A <line>.", provenance: JSONObject(["provider": .string("manual")]), select: true))
    }
    try project.addImage(.portrait, width: 180, height: 320)
    try project.addImage(
      .face, width: 180, height: 180,
      provenance: JSONObject([
        "provider": .string("manual"),
        "box": .object(JSONObject(["x": .integer(50), "y": .integer(60), "width": .integer(80), "height": .integer(100)])),
      ]))
    try render(project)
    let reader = PageReader(text: try project.page())
    let lines = try reader.element(key: "samples.lines")
    let sources = PageReader.matches(of: "src=\"data:audio/mp4;base64,([^\"]*)\"", in: lines)
    #expect(sources == ["neutral", "wry"].map { samples[$0]!.base64EncodedString() })
    #expect(lines.contains("A &lt;line&gt;."))
    #expect(lines.contains("<span class=\"t-sampleNote\">· 1.7b</span>"))
    // §8.5's worked example: the crop is 180 × 180 at (0, 20) in 180 × 320.
    #expect(try reader.element(key: "face.portrait").contains("style=\"left:0%;top:6.25%;width:100%\""))
    #expect(try reader.element(key: "face.crop").contains("hand-set"))
    #expect(try reader.element(key: "voice.models").contains("<li>x-1.7B-y</li>"))
  }

  @Test("Field rule 2: citation order, then never cited in file order; an undefined reference stays as text")
  func footnotes() throws {
    let body = """

      ## Logline

      First.[^later] Second.[^early] No definition.[^nowhere]

      ## Appearance

      Again.[^early] Bold **name**[^later] and `[^code]` in a span, with \\[^escaped].

      [^early]: Stated. file:2.
      [^unused-z]: Author. Never cited, first.
      [^later]: Inferred. A reason.
      [^unused-a]: Author. Never cited, second.
      """
    let project = try RenderProject(description: synthetic(body: body))
    try render(project)
    let reader = PageReader(text: try project.page())
    let sources = try reader.element(key: "page.sources")
    #expect(PageReader.matches(of: "<li>([^<]*)</li>", in: sources) == [
      "Inferred. A reason.", "Stated. file:2.", "Author. Never cited, first.", "Author. Never cited, second.",
    ])
    let mark = { (number: Int) in "<sup class=\"mark\"><a href=\"#page.sources\">\(number)</a></sup>" }
    #expect(try reader.element(key: "profile.logline") .contains("First.\(mark(1)) Second.\(mark(2)) No definition.[^nowhere]"))
    let appearance = try reader.element(key: "profile.appearance")
    #expect(appearance.contains("Again.\(mark(2)) Bold <strong>name</strong>\(mark(1))"))
    #expect(appearance.contains("`[^code]` in a span, with \\[^escaped]."))
    // A definition is shown only in page.sources.
    #expect(!appearance.contains("Never cited"))
    #expect(try !reader.element(key: "profile.logline").contains("A reason"))
    // No number is ever given to a definition nothing cites.
    #expect(!reader.markup.contains(mark(3)) && !reader.markup.contains(mark(4)))
    // W-FOOTNOTE still reports both.
    let footnote = try project.open().validate().findings.filter { $0.code == .footnote }
    #expect(footnote.count == 3)
  }

  @Test("Rule 3's Markdown, and field rules 1 and 3")
  func markdown() throws {
    let body = """

      ## Logline

      A <b>tag</b> & a [link](https://example.org) and *emphasis* and **bold** and "quotes" and 'one'.

      ### A group

      - One item
      - Another[^a]

      After the list.

      ## Arc (Season 1)

      First season.[^a]

      ## Arc (Season 2)

      Second season.

      ## Canon & Guardrails

      Never at sea.[^a] Never on land.[^b]

      - An item with none.
      - An item with one.[^b][^nowhere]

      ## Backstory

      [^a]: Author. Said so, 2026-01-01.
      [^b]: Stated. file:1.
      """
    let project = try RenderProject(description: synthetic(body: body))
    try render(project)
    let reader = PageReader(text: try project.page())
    let logline = try reader.element(key: "profile.logline")
    #expect(logline.contains("<p>A &lt;b&gt;tag&lt;/b&gt; &amp; a [link](https://example.org) and <em>emphasis</em> and <strong>bold</strong> and &quot;quotes&quot; and &#x27;one&#x27;.</p>"))
    #expect(logline.contains("<h4>A group</h4><ul><li>One item</li><li>Another"))
    #expect(logline.contains("</li></ul><p>After the list.</p>"))
    let arc = try reader.element(key: "profile.arc")
    #expect(arc.contains("<p class=\"parenthetical t-facts\">(Season 1)</p><p>First season."))
    #expect(arc.contains("<p class=\"parenthetical t-facts\">(Season 2)</p><p>Second season.</p>"))
    #expect(arc.contains(">Arc<"))
    let canon = try reader.element(key: "profile.canon")
    let classes = PageReader.matches(of: "<span class=\"canon-source t-captionNote\">([^<]*)</span>", in: canon)
    #expect(classes == ["Author, Stated", "", "Stated"])
    // Only whitespace, once its definitions are gone.
    #expect(try reader.state(key: "profile.backstory") == "empty")
    #expect(try reader.element(key: "profile.backstory").contains("No backstory"))
    #expect(try reader.state(key: "profile.wardrobe") == "empty")
  }

  @Test("The defaults for label and text styles, and the empty states")
  func stylesAndStates() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    try render(project)
    let reader = PageReader(text: try project.page())
    #expect(try reader.element(key: "portrait.prompt").contains("field-label t-label"))
    #expect(try reader.element(key: "profile.logline").contains("t-lead"))
    #expect(try reader.element(key: "profile.appearance").contains("field-label t-sectionTitle"))
    // `body` is the default a field that names no textStyle gets, and hidden labels say so.
    #expect(try reader.element(key: "profile.provenance").contains("is-hidden"))
    #expect(try !reader.element(key: "profile.logline").contains("is-hidden"))
    #expect(try reader.state(key: "page.face") == "absent")
    #expect(try reader.state(key: "page.tier") == "filled")
    #expect(try reader.state(key: "portrait.image") == "empty")
    #expect(try reader.element(key: "portrait.image").contains("<span class=\"image-missing\">"))
    #expect(try reader.state(key: "views.set") == "filled")
    #expect(try reader.state(key: "views.front") == "empty")
    #expect(try reader.state(key: "samples.lines") == "empty")
    #expect(try reader.element(key: "samples.lines").contains("<div class=\"field-value t-body\">"))
  }

  @Test("Field rule 4: n/N with the page's own row counted, the rows missing by label and never the page")
  func completeness() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    try render(project)
    let reader = PageReader(text: try project.page())
    let report = try #require(try project.open().completeness())
    let required = report.rows.filter { $0.level == .required }
    #expect(required.contains { $0.id == "dossier" })
    let satisfied = required.filter(\.isSatisfied).count
    #expect(try reader.element(key: "page.completeness").contains(">\(satisfied)/\(required.count)<"))
    let missing = PageReader.matches(of: "<li>([^<]*)</li>", in: try reader.element(key: "page.missing"))
    #expect(missing == required.filter { !$0.isSatisfied }.map { PageText.escaped($0.label) })
    #expect(!missing.contains("Dossier page"))
    #expect(!missing.isEmpty)
  }

  @Test("A member with no role: completeness shows its empty text, and nothing is missing")
  func noRole() throws {
    let root = try RenderProject.temporaryRoot()
    let name = "THE ROLELESS"
    let url = root.appendingPathComponent("characters/\(name).dossier", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data(
      "---\ntype: cast\nschemaVersion: 1\ncast:\n- character: \(name)\n  voices: {}\n  manifest: characters/\(name).dossier/manifest.json\n---\n".utf8
    ).write(to: root.appendingPathComponent("CAST.md"))
    try Manifest(character: name, updatedAt: "2026-01-01T00:00:00Z").encoded().write(to: url.appendingPathComponent("manifest.json"))
    let description = root.appendingPathComponent("CHARACTER.md")
    try Data("---\ntype: character\ncharacter: \(name)\n---\n\n## Logline\n\nA line.\n".utf8).write(to: description)
    var bundle = try DossierBundle.open(at: url)
    try bundle.add(description, kind: .description, options: AddOptions(provenance: JSONObject(["provider": .string("manual")]), select: true))
    let loaded = try Cast.load(root.appendingPathComponent("CAST.md"))
    var withMember = try #require(try loaded.openBundle(for: loaded.members[0]))
    let rendered = try withMember.renderPage()
    let reader = PageReader(text: String(decoding: try Data(contentsOf: rendered.url), as: UTF8.self))
    #expect(try reader.state(key: "page.completeness") == "empty")
    #expect(try reader.element(key: "page.completeness").contains("Completeness needs a role"))
    #expect(try reader.state(key: "page.missing") == "absent")
    #expect(try reader.state(key: "page.tier") == "absent")
  }

  @Test("Field rule 5: the banner lists stale selections and errors, computed without the page")
  func banner() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    let portrait = try project.addImage(.portrait, width: 180, height: 320)
    let stale = try project.addImage(
      .view, variant: "front", width: 90, height: 160,
      derivedFrom: [DerivedInput(role: "portrait", sha256: String(repeating: "0", count: 64), path: portrait.path)])
    // A candidate is never reported, and a clean page's own inputs aren't in the banner.
    try project.addImage(
      .view, variant: "back", width: 90, height: 160, shade: 90, select: false,
      derivedFrom: [DerivedInput(role: "portrait", sha256: String(repeating: "0", count: 64), path: portrait.path)])
    let rendered = try render(project)
    #expect(rendered.banner.map(\.code) .contains(.stale))
    let reader = PageReader(text: try project.page())
    let items = PageReader.matches(of: "<li>([^<]*)</li>", in: try reader.element(key: "page.integrity"))
    #expect(items == ["W-STALE \(stale.path)"])

    // A page is stale now (its description changed), but the next render doesn't say so.
    let description = project.bundleURL.appendingPathComponent("CHARACTER.md")
    try Data(synthetic(body: fullBody + "\nMore.\n").utf8).write(to: description)
    #expect(try validationCodes(project).contains("E-FILE-HASH"))
    try render(project)
    let next = PageReader(text: try project.page())
    let listed = PageReader.matches(of: "<li>([^<]*)</li>", in: try next.element(key: "page.integrity"))
    #expect(listed == ["E-FILE-HASH CHARACTER.md", "W-STALE \(stale.path)"])
    #expect(try next.state(key: "page.integrity") == "filled")
  }

  @Test("A clean bundle's banner is absent, whatever the page being replaced says")
  func cleanBanner() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    try render(project)
    // The page being replaced is faulty in every way the validator could see.
    try Data().write(to: project.pageURL)
    var manifest = try project.manifest()
    var assets = manifest.assets
    let index = try #require(assets.firstIndex { $0.kind == .dossier })
    assets[index].derivedFrom = [DerivedInput(role: "description", sha256: String(repeating: "0", count: 64), path: "CHARACTER.md")]
    manifest.assets = assets
    try manifest.encoded().write(to: project.manifestURL)
    let rendered = try render(project)
    #expect(rendered.banner.isEmpty)
    #expect(try PageReader(text: try project.page()).state(key: "page.integrity") == "absent")
  }

  @Test("An error in the manifest's names is on the banner")
  func nameError() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    let description = project.bundleURL.appendingPathComponent("CHARACTER.md")
    let text = "---\ntype: character\ncharacter: SOMEONE ELSE\n---\n\n## Logline\n\nA line.\n"
    try Data(text.utf8).write(to: description)
    var bundle = try project.open()
    // Written through a write, so the hash of the file is right.
    try bundle.refreshManifestForTest()
    let rendered = try render(project)
    #expect(rendered.banner.map(\.code) == [.nameMismatch])
    let items = PageReader.matches(of: "<li>([^<]*)</li>", in: try PageReader(text: try project.page()).element(key: "page.integrity"))
    #expect(items.count == 1 && items[0].hasPrefix("E-NAME-MISMATCH "))
  }

  @Test("A failed manifest write leaves the previous page and manifest, and no marker")
  func failedWrite() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    try render(project)
    let before = try project.tree()
    // Changes what the page will say, so a page left behind would be seen.
    try project.addImage(.portrait, width: 180, height: 320)
    let intermediate = try project.tree()
    #expect(intermediate != before)

    var bundle = try project.open()
    let writer = ManifestWriter(bundle: bundle.url) { url in try? Data("garbage".utf8).write(to: url) }
    #expect(throws: DossierWriteError.verificationFailed) {
      try bundle.renderPage(now: Date(), writer: writer)
    }
    #expect(try project.tree() == intermediate)
    #expect(UpdateMarker.files(inBundle: project.bundleURL).isEmpty)
  }

  @Test("A first render that fails leaves no page")
  func failedFirst() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    let before = try project.tree()
    var bundle = try project.open()
    let writer = ManifestWriter(bundle: bundle.url) { url in try? Data("garbage".utf8).write(to: url) }
    #expect(throws: DossierWriteError.verificationFailed) {
      try bundle.renderPage(now: Date(), writer: writer)
    }
    #expect(try project.tree() == before)
    #expect(!FileManager.default.fileExists(atPath: project.pageURL.path))
  }

  @Test("A selected image that can't be read fails before anything changes")
  func unreadableImage() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    try render(project)
    let portrait = try project.addImage(.portrait)
    let file = project.bundleURL.appendingPathComponent(portrait.path)
    try Data("not an image".utf8).write(to: file)
    let before = try project.tree()
    var bundle = try project.open()
    #expect(throws: DossierWriteError.imageUnreadable(portrait.path)) { try bundle.renderPage() }
    #expect(try project.tree() == before)
  }

  @Test("No member, no description and bad front matter are refused")
  func refused() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    var withoutMember = try DossierBundle.open(at: project.bundleURL)
    #expect(throws: DossierWriteError.missingDerivedInput(kind: "dossier", role: "castMember")) {
      try withoutMember.renderPage()
    }

    var bundle = try project.open()
    try bundle.reject(path: "CHARACTER.md")
    let rejected = try project.tree()
    #expect(throws: DossierWriteError.missingDerivedInput(kind: "dossier", role: "description")) {
      try bundle.renderPage()
    }
    #expect(try project.tree() == rejected)

    let unreadable = try RenderProject(description: "---\n- [unclosed\n---\nBody\n")
    var other = try unreadable.open()
    #expect(throws: CharacterDescriptionError.self) { try other.renderPage() }

    let notBundle = try RenderProject(description: synthetic(body: fullBody))
    var manifest = try JSONValue.parse(try Data(contentsOf: notBundle.manifestURL)).objectValue!
    manifest["manifestVersion"] = .integer(1)
    try JSONValue.object(manifest).prettyEncoded().write(to: notBundle.manifestURL)
    var old = try notBundle.open()
    #expect(throws: DossierWriteError.versionOneManifest) { try old.renderPage() }
  }

  @Test("A render shows as one update: the marker is up for every manifest replacement, and gone after")
  func oneUpdate() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    let seen = RenderBox<[Int]>([])
    let wrote = RenderBox(0)
    var environment = UpdateEnvironment()
    environment.observe = { event in
      if case .wrote = event { wrote.withValue { $0 += 1 } }
    }
    var bundle = try project.open()
    let writer = ManifestWriter(bundle: bundle.url) { url in
      seen.withValue { $0.append(UpdateMarker.files(inBundle: url.deletingLastPathComponent()).count) }
    }
    try UpdateHolding.$environment.withValue(environment) {
      _ = try bundle.renderPage(now: Date(), writer: writer)
    }
    #expect(seen.value == [1])
    #expect(wrote.value == 1)
    #expect(UpdateMarker.files(inBundle: project.bundleURL).isEmpty)
  }

  @Test("add still takes a page, with a template")
  func addStillWorks() throws {
    let project = try RenderProject(description: synthetic(body: fullBody))
    let page = project.root.appendingPathComponent("page.html")
    try Data("<!DOCTYPE html>".utf8).write(to: page)
    var bundle = try project.open()
    let asset = try bundle.add(page, kind: .dossier, options: AddOptions(template: try DossierTemplate.current))
    #expect(asset.derivedFrom.map(\.role) == ["description", "castMember", "bundle", "template"])
  }
}

/// A value hooks can set.
final class RenderBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  func withValue(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
  var value: Value { lock.withLock { stored } }
}

extension DossierBundle {
  /// A write that only rescans, to record a file changed by hand.
  mutating func refreshManifestForTest() throws {
    let manifest = try ManifestWriter(bundle: url).update { _, _ in }
    self = DossierBundle(url: url, manifest: manifest, member: member)
  }
}

/// `make test`'s version of `scripts/compare-pages.py`: each fixture page as filled, against a
/// render of a copy. Image payloads differ by encoder (DF-45), so they compare by count and size.
@Suite("Fixture pages")
struct ConformancePageTests {
  /// Deliberately faulty or out of date, or with content added after it was filled.
  private static func isAsFilled(_ entry: Conformance.Entry) -> Bool {
    let altered = [
      "valid/page-allowed-references", "valid/page-at-size-limit", "warnings/W-STALE-template",
      "warnings/W-STALE-input-member",
    ]
    return !altered.contains(entry.path) && !entry.codes.contains { $0.hasPrefix("W-PAGE-") }
  }

  /// Every fixture holding a page.
  private static let withPages: [Conformance.Entry] = Conformance.entries.filter { pageName(of: $0) != nil }

  private static func pageName(of entry: Conformance.Entry) -> String? {
    let bundle = Conformance.root.appendingPathComponent(entry.path).appendingPathComponent(entry.bundle)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: bundle.path)) ?? []
    return names.first { $0.hasSuffix("-dossier.html") }
  }

  /// A copy of the fixture's project, its bundle opened through `CAST.md`, and the page's name.
  private func copy(of entry: Conformance.Entry) throws -> (root: URL, bundle: DossierBundle, page: URL) {
    let root = try RenderProject.temporaryRoot().appendingPathComponent("project")
    try FileManager.default.copyItem(at: Conformance.root.appendingPathComponent(entry.path), to: root)
    let cast = try Cast.load(root.appendingPathComponent("CAST.md"))
    let member = try #require(
      cast.members.first { cast.manifestURL(of: $0)?.deletingLastPathComponent().lastPathComponent == URL(fileURLWithPath: entry.bundle).lastPathComponent })
    let bundle = try #require(try cast.openBundle(for: member))
    return (root, bundle, bundle.url.appendingPathComponent(try #require(Self.pageName(of: entry))))
  }

  /// The bytes without the payload of each image `data:` URI, and the payloads' sizes.
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

  @Test("The fixture list has pages, and the comparison has something to compare")
  func hasPages() {
    #expect(Self.withPages.filter(Self.isAsFilled).count >= 8)
  }

  @Test("A page as filled is what the renderer gives, apart from image payloads", arguments: withPages.filter(isAsFilled))
  func comparison(_ entry: Conformance.Entry) throws {
    var (root, bundle, page) = try copy(of: entry)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let expected = try Data(contentsOf: page)
    try bundle.renderPage()
    let (expectedRest, expectedSizes) = try withoutPayloads(expected)
    let (rest, sizes) = try withoutPayloads(try Data(contentsOf: page))
    #expect(sizes == expectedSizes)
    if rest != expectedRest {
      let offset = zip(rest, expectedRest).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(rest.count, expectedRest.count)
      let around = expectedRest.dropFirst(max(0, offset - 40)).prefix(120)
      Issue.record("differs at offset \(offset) of the payload-free page: \(String(decoding: around, as: UTF8.self))")
    }
  }

  @Test("A render adds nothing to what validate reports, and a second render gives the same bytes", arguments: withPages)
  func validateAndRepeat(_ entry: Conformance.Entry) throws {
    var (root, bundle, page) = try copy(of: entry)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let cast = root.appendingPathComponent("CAST.md")
    let template = try DossierTemplate.current
    let before = Set(try DossierBundle.validate(cast: cast, template: template).findings.map(\.code.rawValue))
    try bundle.renderPage()
    let first = try Data(contentsOf: page)
    let after = Set(try DossierBundle.validate(cast: cast, template: template).findings.map(\.code.rawValue))
    #expect(after.subtracting(before).isEmpty, "new: \(after.subtracting(before).sorted())")
    #expect(!after.contains("W-STALE") || before.contains("W-STALE"))
    try bundle.renderPage()
    #expect(try Data(contentsOf: page) == first)
  }

  @Test("The record of every render matches record.schema.json", arguments: withPages)
  func recordSchema(_ entry: Conformance.Entry) throws {
    var (root, bundle, page) = try copy(of: entry)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    try bundle.renderPage()
    let text = try #require(PageReader(text: String(decoding: try Data(contentsOf: page), as: UTF8.self)).recordText)
    #expect(!text.contains("<"))
    #expect(try SchemaEvaluator.pinned().validate(try JSONValue.parse(Data(text.utf8)), against: "record.schema.json").isEmpty)
  }

  @Test("Rendering reads the fixtures and doesn't change them")
  func fixturesUntouched() throws {
    let entry = try #require(Self.withPages.first)
    let source = Conformance.root.appendingPathComponent(entry.path)
    let before = try RenderTree.files(under: source)
    var (root, bundle, _) = try copy(of: entry)
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    try bundle.renderPage()
    #expect(try RenderTree.files(under: source) == before)
    #expect(try RenderTree.files(under: root) != before)
  }
}
