import DossierCore
import Foundation
import Testing

@testable import Dossier

private let body = """

  ## Logline

  A tinker who mends radios.[^a]

  [^a]: Author. Invented, 2026-01-01.
  """

/// The update markers in the bundle's root: hidden names that are `.update-*.json`.
private func markerNames(in bundle: URL) -> [String] {
  ((try? FileManager.default.contentsOfDirectory(atPath: bundle.path)) ?? [])
    .filter { $0.hasPrefix(".update-") && $0.hasSuffix(".json") }.sorted()
}

private func modificationDate(_ file: URL) throws -> Date {
  try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
}

@Suite("rebuild (§11.1, PV-12 to PV-15)")
struct RebuildTests {
  private func project() throws -> (RenderProject, Asset) {
    let project = try RenderProject(description: synthetic(body: body))
    let image = try project.addImage(.portrait)
    return (project, image)
  }

  @Test("An unchanged bundle keeps its key, <key>.html is rewritten, manifest.json is untouched (item 12)")
  func unchanged() async throws {
    let (project, _) = try project()
    var bundle = try project.open()
    let template = try DossierTemplate.current
    let shown = try bundle.showPreview(template: template)
    let file = try #require(shown.pageURL)
    let past = Date(timeIntervalSinceNow: -86_400)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
    let manifestBefore = try Data(contentsOf: project.manifestURL)

    let result = try await bundle.rebuild(cast: project.cast, template: template)

    #expect(result.refreshError == nil)
    #expect(result.preview.key == shown.key)
    #expect(!result.preview.hit)
    #expect(result.preview.pageURL == file)
    #expect(result.preview.html != nil)
    #expect(result.preview.storeError == nil)
    #expect(try modificationDate(file) > past)
    #expect(try Data(contentsOf: project.manifestURL) == manifestBefore)
  }

  @Test("After an image is edited by hand, the manifest is refreshed, the key changes and the old preview goes (item 13)")
  func editedImage() async throws {
    let (project, image) = try project()
    var bundle = try project.open()
    let template = try DossierTemplate.current
    let shown = try bundle.showPreview(template: template)
    let oldFile = try #require(shown.pageURL)
    let manifestBefore = try Data(contentsOf: project.manifestURL)
    try RenderImages.png(width: 18, height: 32, shade: 200)
      .write(to: project.bundleURL.appendingPathComponent(image.path))

    let result = try await bundle.rebuild(cast: project.cast, template: template)

    #expect(result.refreshError == nil)
    #expect(try Data(contentsOf: project.manifestURL) != manifestBefore)
    #expect(result.preview.key != shown.key)
    #expect(result.preview.key == (try bundle.previewKey(template: template)))
    #expect(!FileManager.default.fileExists(atPath: oldFile.path))
    let file = try #require(result.preview.pageURL)
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test("With an asset's file deleted, the refusal is reported and a page is built on the unchanged manifest (item 14)")
  func missingAssetFile() async throws {
    let (project, image) = try project()
    var bundle = try project.open()
    let template = try DossierTemplate.current
    let key = try bundle.previewKey(template: template)
    let manifestBefore = try Data(contentsOf: project.manifestURL)
    try FileManager.default.removeItem(at: project.bundleURL.appendingPathComponent(image.path))

    let result = try await bundle.rebuild(cast: project.cast, template: template)

    let error = try #require(result.refreshError as? DossierWriteError)
    #expect(error == .assetFilesMissing([image.path]))
    #expect(result.preview.key == key)
    #expect(result.preview.html != nil)
    let file = try #require(result.preview.pageURL)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(try Data(contentsOf: project.manifestURL) == manifestBefore)
  }

  @Test("One update marker is held across the rebuild, and none remains after")
  func markerHeld() async throws {
    let (project, image) = try project()
    try RenderImages.png(width: 18, height: 32, shade: 120)
      .write(to: project.bundleURL.appendingPathComponent(image.path))
    var bundle = try project.open()
    let bundleURL = project.bundleURL
    var seen: [String]?

    let result = try await bundle.rebuild(cast: project.cast, template: try DossierTemplate.current) { _ in
      seen = markerNames(in: bundleURL)
    }

    #expect(result.refreshError == nil)
    #expect(seen?.count == 1)
    #expect(markerNames(in: bundleURL).isEmpty)
  }

  @Test("With CHARACTER.md missing, rebuild throws and leaves no marker")
  func missingDescription() async throws {
    let (project, _) = try project()
    var bundle = try project.open()
    let description = try #require(bundle.assets(kind: .description).first)
    try FileManager.default.removeItem(at: project.bundleURL.appendingPathComponent(description.path))

    await #expect(throws: CharacterDescriptionError.self) {
      try await bundle.rebuild(cast: project.cast, template: try DossierTemplate.current)
    }
    #expect(markerNames(in: project.bundleURL).isEmpty)
  }
}
