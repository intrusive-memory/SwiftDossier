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
  private func cache() throws -> DossierPreviewCache {
    DossierPreviewCache(directory: try RenderProject.temporaryRoot().appendingPathComponent("cache"))
  }

  @Test("A preview writes nothing into the bundle")
  func writesNothing() throws {
    let project = try RenderProject(description: synthetic(body: body))
    try project.addImage(.portrait)
    let before = try project.tree()
    let page = try DossierBundle.openForPreview(at: project.bundleURL).previewPage()
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

  @Test("No CAST.md member still previews")
  func noMember() throws {
    let project = try RenderProject(description: synthetic(body: body))
    try FileManager.default.removeItem(at: project.cast)
    let bundle = try DossierBundle.openForPreview(at: project.bundleURL)
    #expect(bundle.member == nil)
    #expect(try bundle.previewPage().html.contains("A tinker who mends radios."))
  }

  @Test("The member is found from CAST.md beside the characters directory")
  func findsMember() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let bundle = try DossierBundle.openForPreview(at: project.bundleURL)
    #expect(bundle.member?.character == RenderProject.character)
  }

  @Test("No CHARACTER.md is an error: there is nothing to show")
  func noDescription() throws {
    let project = try RenderProject(description: synthetic(body: body))
    try FileManager.default.removeItem(at: project.bundleURL.appendingPathComponent("CHARACTER.md"))
    #expect(throws: CharacterDescriptionError.self) { try project.open().previewPage() }
  }

  @Test("The key follows the files, and nothing else")
  func key() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let first = try project.open().previewKey()
    #expect(try project.open().previewKey() == first)
    try project.addImage(.portrait)
    #expect(try project.open().previewKey() != first)
  }

  @Test("The cache builds a page once, rebuilds it after an edit, and keeps only the latest")
  func cacheLifecycle() throws {
    let project = try RenderProject(description: synthetic(body: body))
    let cache = try cache()
    let first = try cache.pageURL(forBundleAt: project.bundleURL)
    #expect(first.path.hasPrefix(cache.directory.path))
    let made = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date

    #expect(try cache.pageURL(forBundleAt: project.bundleURL) == first)
    #expect(try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date == made)

    try project.addImage(.portrait)
    let second = try cache.pageURL(forBundleAt: project.bundleURL)
    #expect(second != first)
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(try String(contentsOf: second, encoding: .utf8).contains("data:image/jpeg;base64,"))
  }
}
