import DossierCore
import Foundation
import Testing

@testable import Dossier

private let body = """

  ## Logline

  A tinker who mends radios.[^a]

  ## Appearance

  Short and quick.[^b]

  [^a]: Author. Invented, 2026-01-01.
  [^b]: Stated. nowhere/invented.fountain:1.
  """

@Suite("previewPage")
struct PreviewTests {
  @Test("A preview writes nothing into the bundle")
  func writesNothing() throws {
    let project = try RenderProject(description: synthetic(body: body))
    try project.addImage(.portrait)
    let before = try project.tree()
    let page = try DossierBundle.openForPreview(at: project.bundleURL, cast: project.cast).previewPage()
    #expect(try project.tree() == before)
    #expect(page.html.contains("A tinker who mends radios."))
  }

  @Test("A clean bundle previews as the page a render writes")
  func matchesRender() throws {
    let project = try RenderProject(description: synthetic(body: body))
    try project.addImage(.portrait)
    let preview = try project.open().previewPage()
    var bundle = try project.open()
    try bundle.renderPage()
    #expect(try project.page() == preview.html)
  }

  @Test("A page already in the bundle is ignored, current or not")
  func ignoresCommittedPage() throws {
    let project = try RenderProject(description: synthetic(body: body))
    var bundle = try project.open()
    try bundle.renderPage()
    let committed = try project.page()
    let description = project.bundleURL.appendingPathComponent("CHARACTER.md")
    try Data(synthetic(body: "\n## Logline\n\nA tinker who now sells radios.\n").utf8).write(to: description)

    let preview = try project.open().previewPage()
    #expect(preview.html.contains("A tinker who now sells radios."))
    #expect(!preview.html.contains("A tinker who mends radios."))
    #expect(try project.page() == committed)
  }

  @Test("An image that changed since the manifest refuses a render and still previews")
  func changedImage() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let portrait = try project.addImage(.portrait)
    try RenderImages.png(width: 18, height: 32, shade: 200)
      .write(to: project.bundleURL.appendingPathComponent(portrait.path))

    var bundle = try project.open()
    #expect(throws: DossierWriteError.self) { try bundle.renderPage() }
    let preview = try project.open().previewPage()
    #expect(preview.banner.contains { $0.code == .fileHash })
    #expect(preview.html.contains("data:image/jpeg;base64,"))
  }

  @Test("A missing image is left off the page")
  func missingImage() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let portrait = try project.addImage(.portrait)
    try FileManager.default.removeItem(at: project.bundleURL.appendingPathComponent(portrait.path))

    let preview = try project.open().previewPage()
    #expect(preview.banner.contains { $0.code == .fileMissing })
    #expect(!preview.html.contains("data:image/jpeg;base64,"))
    #expect(preview.html.contains("A tinker who mends radios."))
  }

  @Test("A zero-byte image is on the banner as E-ZERO-BYTE, and the page still builds")
  func zeroByteImage() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let portrait = try project.addImage(.portrait)
    try Data().write(to: project.bundleURL.appendingPathComponent(portrait.path))

    let preview = try project.open().previewPage()
    #expect(preview.banner.contains { $0.code == .zeroByte })
    #expect(preview.html.contains("A tinker who mends radios."))
  }

  @Test("A stray HTML file in the bundle's root is absent from the embedded manifest")
  func strayHTMLNotEmbedded() throws {
    let project = try RenderProject(description: synthetic(body: body))
    try project.addImage(.portrait)
    try Data("<p>notes</p>".utf8).write(to: project.bundleURL.appendingPathComponent("notes.html"))

    let preview = try project.open().previewPage()
    let record = try PageReader(text: preview.html).record()
    guard case .object(let manifest)? = record["manifest"] else {
      Issue.record("the record has no manifest")
      return
    }
    let text = String(describing: manifest)
    #expect(!text.contains("notes.html"))
    #expect(text.contains("images/"))
    #expect(!preview.html.contains("<p>notes</p>"))
  }

  @Test("Front matter that is a YAML list still builds, with the body shown")
  func listFrontMatter() throws {
    let project = try RenderProject(description: "---\n- one\n- two\n---\n" + body)
    let page = try project.open().previewPage()
    #expect(page.html.contains("A tinker who mends radios."))
    let record = try PageReader(text: page.html).record()
    guard case .object(let front)? = record["frontMatter"] else {
      Issue.record("frontMatter is not an object")
      return
    }
    #expect(front.isEmpty)
  }

  @Test("No CAST.md passed, a missing one, or one with no member previews with no member")
  func noMember() throws {
    let project = try RenderProject(description: synthetic(body: body))

    let unpassed = try DossierBundle.openForPreview(at: project.bundleURL, cast: nil)
    #expect(unpassed.member == nil)
    #expect(try unpassed.previewPage().html.contains("A tinker who mends radios."))

    let missing = project.root.appendingPathComponent("NO-SUCH-CAST.md")
    #expect(try DossierBundle.openForPreview(at: project.bundleURL, cast: missing).member == nil)

    let unreadable = project.root.appendingPathComponent("BROKEN-CAST.md")
    try Data("---\ncast: [\n---\n".utf8).write(to: unreadable)
    #expect(try DossierBundle.openForPreview(at: project.bundleURL, cast: unreadable).member == nil)

    let other = project.root.appendingPathComponent("OTHER-CAST.md")
    try Data(
      """
      ---
      type: cast
      schemaVersion: 1
      cast:
      - character: SOMEONE ELSE
        manifest: characters/SOMEONE ELSE.dossier/manifest.json
      ---
      """.utf8
    ).write(to: other)
    let unmatched = try DossierBundle.openForPreview(at: project.bundleURL, cast: other)
    #expect(unmatched.member == nil)
    #expect(try unmatched.previewPage().html.contains("A tinker who mends radios."))
  }

  @Test("With the project's CAST.md passed, the member is the one pointing at the bundle")
  func findsMember() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let bundle = try DossierBundle.openForPreview(at: project.bundleURL, cast: project.cast)
    #expect(bundle.member?.character == RenderProject.character)
  }

  @Test("A CAST.md in the bundle's parent or grandparent is not read when none is passed")
  func noSearch() throws {
    let project = try RenderProject(description: synthetic(body: body))
    // The grandparent (the project root) already holds a CAST.md pointing at the bundle; put
    // one in the parent (`characters/`) too, pointing at it from there.
    let parent = project.bundleURL.deletingLastPathComponent().appendingPathComponent("CAST.md")
    try Data(
      """
      ---
      type: cast
      schemaVersion: 1
      cast:
      - character: \(RenderProject.character)
        role: lead
        manifest: \(RenderProject.character).dossier/manifest.json
      ---
      """.utf8
    ).write(to: parent)
    #expect(try DossierBundle.openForPreview(at: project.bundleURL, cast: parent).member != nil)
    #expect(try DossierBundle.openForPreview(at: project.bundleURL, cast: project.cast).member != nil)

    #expect(try DossierBundle.openForPreview(at: project.bundleURL, cast: nil).member == nil)
  }

  @Test("With no member, the record's castMember is JSON null")
  func nullCastMember() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let page = try DossierBundle.openForPreview(at: project.bundleURL, cast: nil).previewPage()
    let record = try PageReader(text: page.html).record()
    guard case .null? = record["castMember"] else {
      Issue.record("castMember is \(String(describing: record["castMember"])), not null")
      return
    }
  }

  @Test("No CHARACTER.md is an error: there is nothing to show")
  func noDescription() throws {
    let project = try RenderProject(description: synthetic(body: body))
    try FileManager.default.removeItem(at: project.bundleURL.appendingPathComponent("CHARACTER.md"))
    #expect(throws: CharacterDescriptionError.self) { try project.open().previewPage() }
  }
}
