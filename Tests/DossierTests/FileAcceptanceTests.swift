import DossierCore
import Foundation
import Testing

@testable import Dossier

/// The writes other than `refresh`, which must leave a mismatched file's entry alone.
private enum Mutator: String, CaseIterable, Sendable {
  case prompt, add, select, reject, removeOther, faceCrop
}

@Suite("A file that no longer matches its entry")
struct FileAcceptanceTests {
  private let edited = synthetic(body: fullBodyForAcceptance + "\nEdited by hand.\n")

  private func project() throws -> RenderProject {
    try RenderProject(description: synthetic(body: fullBodyForAcceptance))
  }

  private func findings(_ project: RenderProject) throws -> [Finding] {
    try project.open().validate(template: DossierTemplate.current).findings
  }

  private func paths(_ code: Finding.Code, _ project: RenderProject) throws -> [String] {
    try findings(project).filter { $0.code == code }.compactMap(\.path).sorted()
  }

  private func entry(_ path: String, _ project: RenderProject) throws -> FileEntry? {
    try project.manifest().files.first { $0.path == path }
  }

  private func file(_ path: String, _ project: RenderProject) -> URL {
    project.bundleURL.appendingPathComponent(path)
  }

  private func put(_ text: String, at path: String, _ project: RenderProject) throws {
    let url = file(path, project)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  /// A write that changes nothing but the manifest, which lists whatever isn't listed yet.
  private func touch(_ project: RenderProject, _ text: String = "A prompt.") throws {
    var bundle = try project.open()
    try bundle.setPrompt(.identity, text)
  }

  private func expectChecksumRight(_ project: RenderProject) throws {
    #expect(try paths(.checksum, project).isEmpty)
    let manifest = try project.manifest()
    #expect(manifest.manifestChecksum == manifest.computedChecksum)
    try expectManifestValidates(try project.open())
  }

  private func refusal(_ project: RenderProject) throws -> String {
    var bundle = try project.open()
    let error = #expect(throws: DossierWriteError.self) { try bundle.renderPage() }
    return try #require(error?.errorDescription)
  }

  private func mutate(_ mutator: Mutator, view: String, _ project: RenderProject) throws {
    var bundle = try project.open()
    switch mutator {
    case .prompt: try bundle.setPrompt(.identity, "Changed.")
    case .add: try project.addImage(.view, variant: "left", shade: 90, select: false)
    case .select: try bundle.select(path: view)
    case .reject: try bundle.reject(path: view)
    case .removeOther: try bundle.remove(path: view)
    case .faceCrop: try bundle.deriveFace(box: FaceBox(x: 2, y: 2, width: 8, height: 8))
    }
  }

  // MARK: The rule

  @Test("A hand edit refuses a render, survives every other write, and refresh is what accepts it", arguments: Mutator.allCases)
  private func handEditSurvives(_ mutator: Mutator) throws {
    let project = try project()
    try project.addImage(.portrait)
    let view = try project.addImage(.view, variant: "front", select: false).path
    var rendered = try project.open()
    try rendered.renderPage()

    try put(edited, at: "CHARACTER.md", project)
    let recorded = try #require(try entry("CHARACTER.md", project))
    #expect(try paths(.fileHash, project) == ["CHARACTER.md"])
    #expect(try refusal(project).contains("dossier refresh"))

    let manifest = try Data(contentsOf: project.manifestURL)
    try mutate(mutator, view: view, project)
    #expect(try Data(contentsOf: project.manifestURL) != manifest, "the write happened")
    #expect(try paths(.fileHash, project) == ["CHARACTER.md"])
    #expect(try entry("CHARACTER.md", project) == recorded)
    #expect(try Data(contentsOf: file("CHARACTER.md", project)) == Data(edited.utf8))
    #expect(try refusal(project).contains("dossier refresh"))
    try expectChecksumRight(project)

    var bundle = try project.open()
    let report = try bundle.refresh()
    #expect(report.accepted == ["CHARACTER.md"])
    #expect(try paths(.fileHash, project).isEmpty)
    let accepted = try #require(try entry("CHARACTER.md", project))
    #expect(accepted.sha256 == Checksum.sha256(Data(edited.utf8)))
    #expect(accepted.sizeBytes == Int64(edited.utf8.count))
    try expectChecksumRight(project)
    try bundle.renderPage()
    #expect(try Data(contentsOf: file("CHARACTER.md", project)) == Data(edited.utf8))
    #expect(try paths(.fileHash, project).isEmpty)
    #expect(try paths(.fileMissing, project).isEmpty)
    try expectChecksumRight(project)
  }

  @Test("A second refresh accepts nothing and doesn't change the manifest's bytes")
  func secondRefresh() throws {
    let project = try project()
    try put(edited, at: "CHARACTER.md", project)
    var bundle = try project.open()
    #expect(try bundle.refresh().accepted == ["CHARACTER.md"])
    let manifest = try Data(contentsOf: project.manifestURL)
    let tree = try project.tree()
    let second = try bundle.refresh()
    #expect(second.accepted.isEmpty && second.adopted.isEmpty)
    #expect(try Data(contentsOf: project.manifestURL) == manifest)
    #expect(try project.tree() == tree)
  }

  @Test("refresh accepts with nothing to adopt, and reports each file in byte order")
  func acceptsSeveral() throws {
    let project = try project()
    let portrait = try project.addImage(.portrait)
    try Data(try RenderImages.png(width: 18, height: 32, shade: 200)).write(to: file(portrait.path, project))
    try put(edited, at: "CHARACTER.md", project)
    var bundle = try project.open()
    let report = try bundle.refresh()
    #expect(report.accepted == ["CHARACTER.md", portrait.path])
    #expect(report.adopted.isEmpty)
    #expect(bundle.manifest == (try project.manifest()), "the value holds what was written")
  }

  // MARK: add

  @Test("A file add creates is recorded, copied or in place")
  func addRecords() throws {
    let project = try project()
    let outside = project.root.appendingPathComponent("outside.jpg")
    try Data("copied".utf8).write(to: outside)
    var bundle = try project.open()
    let copied = try bundle.add(outside, kind: .sourcePhoto)
    #expect(try entry(copied.path, project)?.sha256 == Checksum.sha256(Data("copied".utf8)))

    try put("in place", at: "source/inplace.jpg", project)
    let placed = try bundle.add(file("source/inplace.jpg", project), kind: .sourcePhoto)
    #expect(placed.path == "source/inplace.jpg")
    #expect(try entry(placed.path, project)?.sha256 == Checksum.sha256(Data("in place".utf8)))
    #expect(try paths(.fileHash, project).isEmpty)
    #expect(try paths(.unclassified, project).isEmpty)
    try expectChecksumRight(project)
  }

  @Test("add of a listed file whose bytes changed makes the asset and doesn't accept it, in place or copied")
  func addDoesNotAccept() throws {
    for inPlace in [true, false] {
      let project = try project()
      try put("first", at: "source/photo.jpg", project)
      try touch(project)
      let recorded = try #require(try entry("source/photo.jpg", project))
      try put("second", at: "source/photo.jpg", project)

      let source: URL
      if inPlace {
        source = file("source/photo.jpg", project)
      } else {
        source = project.root.appendingPathComponent("photo.jpg")
        try Data("second".utf8).write(to: source)
      }
      var bundle = try project.open()
      let asset = try bundle.add(source, kind: .sourcePhoto)
      #expect(asset.path == "source/photo.jpg")
      #expect(try entry(asset.path, project) == recorded)
      #expect(try paths(.fileHash, project) == [asset.path])
      try expectChecksumRight(project)

      #expect(try bundle.refresh().accepted == [asset.path])
      #expect(try paths(.fileHash, project).isEmpty)
    }
  }

  @Test("add of other bytes over a listed file is refused, as any overwrite is")
  func addRefusesOverwrite() throws {
    let project = try project()
    try put("first", at: "source/photo.jpg", project)
    try touch(project)
    try put("second", at: "source/photo.jpg", project)
    let source = project.root.appendingPathComponent("photo.jpg")
    try Data("third".utf8).write(to: source)
    let tree = try project.tree()
    var bundle = try project.open()
    #expect(throws: DossierWriteError.destinationExists("source/photo.jpg")) {
      try bundle.add(source, kind: .sourcePhoto)
    }
    #expect(try project.tree() == tree)
  }

  @Test("add that puts back a listed missing file records what it wrote")
  func addRestores() throws {
    let project = try project()
    try put("first", at: "source/photo.jpg", project)
    try touch(project)
    try FileManager.default.removeItem(at: file("source/photo.jpg", project))
    let source = project.root.appendingPathComponent("photo.jpg")
    try Data("other".utf8).write(to: source)
    var bundle = try project.open()
    try bundle.add(source, kind: .sourcePhoto)
    #expect(try entry("source/photo.jpg", project)?.sha256 == Checksum.sha256(Data("other".utf8)))
    #expect(try paths(.fileMissing, project).isEmpty)
    #expect(try paths(.fileHash, project).isEmpty)
  }

  // MARK: The page

  @Test("A render records its page, and a second render is identical")
  func renderRecordsPage() throws {
    let project = try project()
    try project.addImage(.portrait)
    var bundle = try project.open()
    try bundle.renderPage()
    let page = try Data(contentsOf: project.pageURL)
    let name = project.pageURL.lastPathComponent
    #expect(try entry(name, project)?.sha256 == Checksum.sha256(page))
    #expect(try entry(name, project)?.sizeBytes == Int64(page.count))
    #expect(try paths(.fileHash, project).isEmpty)
    let files = try project.manifest().files

    try bundle.renderPage()
    #expect(try Data(contentsOf: project.pageURL) == page)
    #expect(try project.manifest().files == files)
    #expect(try paths(.stale, project).isEmpty)
    try expectChecksumRight(project)
  }

  @Test("A tampered page survives another write, doesn't block a render, and the render records its own")
  func tamperedPage() throws {
    let project = try project()
    try project.addImage(.portrait)
    var bundle = try project.open()
    try bundle.renderPage()
    let page = try Data(contentsOf: project.pageURL)
    let name = project.pageURL.lastPathComponent

    try Data("<!doctype html>tampered".utf8).write(to: project.pageURL)
    try touch(project)
    #expect(try entry(name, project)?.sha256 == Checksum.sha256(page))
    #expect(try paths(.fileHash, project) == [name])

    bundle = try project.open()
    try bundle.renderPage()
    #expect(try paths(.fileHash, project).isEmpty)
    #expect(try entry(name, project)?.sha256 == Checksum.sha256(try Data(contentsOf: project.pageURL)))
  }

  @Test("refresh accepts a tampered page like any other file")
  func refreshAcceptsPage() throws {
    let project = try project()
    var bundle = try project.open()
    try bundle.renderPage()
    let name = project.pageURL.lastPathComponent
    try Data("<!doctype html>tampered".utf8).write(to: project.pageURL)
    #expect(try bundle.refresh().accepted == [name])
    #expect(try paths(.fileHash, project).isEmpty)
  }

  // MARK: CharacterDescription.write

  @Test("CharacterDescription.write records the file it wrote")
  func descriptionRecords() throws {
    let project = try project()
    var bundle = try project.open()
    try CharacterDescription(text: edited).write(to: &bundle)
    #expect(try entry("CHARACTER.md", project)?.sha256 == Checksum.sha256(Data(edited.utf8)))
    #expect(try paths(.fileHash, project).isEmpty)
    try expectChecksumRight(project)
  }

  @Test("CharacterDescription.write over a hand edit records what it wrote, which replaced the edit")
  func descriptionReplacesEdit() throws {
    let project = try project()
    try put(edited, at: "CHARACTER.md", project)
    let replacement = synthetic(body: "## Logline\n\nReplaced.\n")
    var bundle = try project.open()
    try CharacterDescription(text: replacement).write(to: &bundle)
    #expect(try Data(contentsOf: file("CHARACTER.md", project)) == Data(replacement.utf8))
    #expect(try entry("CHARACTER.md", project)?.sha256 == Checksum.sha256(Data(replacement.utf8)))
    #expect(try paths(.fileHash, project).isEmpty)
  }

  @Test("CharacterDescription.write puts back a missing description and records it")
  func descriptionRestores() throws {
    let project = try project()
    try FileManager.default.removeItem(at: file("CHARACTER.md", project))
    var bundle = try project.open()
    try CharacterDescription(text: edited).write(to: &bundle)
    #expect(try paths(.fileMissing, project).isEmpty)
    #expect(try paths(.fileHash, project).isEmpty)
  }

  // MARK: Missing files

  @Test("A listed, asset-less missing file stays E-FILE-MISSING across a write, and refresh doesn't clear it")
  func missingWithoutAsset() throws {
    let project = try project()
    try put("note", at: "notes/loose.txt", project)
    try touch(project)
    let recorded = try #require(try entry("notes/loose.txt", project))
    try FileManager.default.removeItem(at: file("notes/loose.txt", project))
    #expect(try paths(.fileMissing, project) == ["notes/loose.txt"])
    #expect(try refusal(project).contains("restored"))

    try touch(project, "Changed.")
    #expect(try entry("notes/loose.txt", project) == recorded)
    #expect(try paths(.fileMissing, project) == ["notes/loose.txt"])
    try expectChecksumRight(project)

    var bundle = try project.open()
    let manifest = try Data(contentsOf: project.manifestURL)
    #expect(try bundle.refresh().accepted.isEmpty)
    #expect(try Data(contentsOf: project.manifestURL) == manifest)
    #expect(try paths(.fileMissing, project) == ["notes/loose.txt"])

    // A refresh that writes for another reason keeps it too.
    try put(edited, at: "CHARACTER.md", project)
    #expect(try bundle.refresh().accepted == ["CHARACTER.md"])
    #expect(try entry("notes/loose.txt", project) == recorded)
    #expect(try paths(.fileMissing, project) == ["notes/loose.txt"])
    try expectChecksumRight(project)

    try put("note", at: "notes/loose.txt", project)
    #expect(try paths(.fileMissing, project).isEmpty)
    #expect(try paths(.fileHash, project).isEmpty)
  }

  @Test("An asset's missing file refuses every write, refresh included, and remove is the way out")
  func missingWithAsset() throws {
    let project = try project()
    let portrait = try project.addImage(.portrait)
    try FileManager.default.removeItem(at: file(portrait.path, project))
    try put(edited, at: "CHARACTER.md", project)
    let tree = try project.tree()
    var bundle = try project.open()

    #expect(throws: DossierWriteError.assetFilesMissing([portrait.path])) { try bundle.setPrompt(.identity, "No.") }
    #expect(throws: DossierWriteError.assetFilesMissing([portrait.path])) { try bundle.refresh() }
    #expect(try project.tree() == tree)
    #expect(try paths(.fileMissing, project) == [portrait.path])
    #expect(try paths(.fileHash, project) == ["CHARACTER.md"])

    try bundle.remove(path: portrait.path)
    #expect(try entry(portrait.path, project) == nil)
    #expect(try paths(.fileMissing, project).isEmpty)
    #expect(try paths(.fileHash, project) == ["CHARACTER.md"], "remove accepts nothing else")
    try expectChecksumRight(project)
  }

  @Test("A refresh with nothing to write doesn't refuse an asset's missing file")
  func missingWithAssetNoWrite() throws {
    let project = try project()
    let portrait = try project.addImage(.portrait)
    try FileManager.default.removeItem(at: file(portrait.path, project))
    var bundle = try project.open()
    #expect(try bundle.refresh().accepted.isEmpty)
    #expect(try paths(.fileMissing, project) == [portrait.path])
  }

  @Test("remove of the mismatched asset itself takes its entry; another file's mismatch stays")
  func removeMismatched() throws {
    let project = try project()
    let portrait = try project.addImage(.portrait)
    try Data("changed".utf8).write(to: file(portrait.path, project))
    try put(edited, at: "CHARACTER.md", project)
    var bundle = try project.open()
    try bundle.remove(path: portrait.path)
    #expect(try entry(portrait.path, project) == nil)
    #expect(!FileManager.default.fileExists(atPath: file(portrait.path, project).path))
    #expect(try paths(.fileHash, project) == ["CHARACTER.md"])
    try expectChecksumRight(project)
  }

  @Test("A zero-byte listed file refuses a write and refresh: there's nothing a writer may record")
  func zeroByte() throws {
    let project = try project()
    try put(edited, at: "CHARACTER.md", project)
    try Data().write(to: file("CHARACTER.md", project))
    var bundle = try project.open()
    #expect(throws: DossierWriteError.zeroByteFiles(["CHARACTER.md"])) { try bundle.setPrompt(.identity, "No.") }
    #expect(throws: DossierWriteError.zeroByteFiles(["CHARACTER.md"])) { try bundle.refresh() }
  }

  // MARK: What's taken from a mismatched file

  @Test("A face from a changed portrait records the bytes it cropped: stale until refresh accepts them")
  func faceFromChangedPortrait() throws {
    let project = try project()
    let portrait = try project.addImage(.portrait)
    let earlier = try project.addImage(.view, variant: "front")
    let changed = try RenderImages.png(width: 18, height: 32, shade: 200)
    try changed.write(to: file(portrait.path, project))
    let recorded = try #require(try entry(portrait.path, project))

    var bundle = try project.open()
    let face = try bundle.deriveFace(box: FaceBox(x: 2, y: 2, width: 8, height: 8)).asset
    #expect(face.derivedFrom.first?.sha256 == Checksum.sha256(changed))
    #expect(try entry(portrait.path, project) == recorded)
    #expect(try paths(.fileHash, project) == [portrait.path])
    #expect(try paths(.stale, project) == [face.path], "the view was made from what's recorded")

    #expect(try bundle.refresh().accepted == [portrait.path])
    #expect(try paths(.fileHash, project).isEmpty)
    #expect(try paths(.stale, project) == [earlier.path], "what's accepted is what the face was made from")
    try expectChecksumRight(project)
  }

  @Test("An image derived with a reference records what was sent, against a mismatched file")
  func referencesFromChangedFile() throws {
    let project = try project()
    let portrait = try project.addImage(.portrait)
    let changed = try RenderImages.png(width: 18, height: 32, shade: 200)
    let old = try #require(try entry(portrait.path, project)).sha256
    let new = Checksum.sha256(changed)
    try changed.write(to: file(portrait.path, project))

    var bundle = try project.open()
    func add(sent: String, variant: String, shade: UInt8) throws -> Asset {
      let source = project.root.appendingPathComponent("\(variant).png")
      try RenderImages.png(width: 18, height: 32, shade: shade).write(to: source)
      let reference = JSONObject([("sha256", .string(sent))])
      return try bundle.add(
        source, kind: .view,
        options: AddOptions(
          variant: variant, referenceRoles: ["portrait"],
          provenance: JSONObject([("references", .array([.object(reference)]))]), select: true))
    }
    let fromNew = try add(sent: new, variant: "front", shade: 70)
    let fromOld = try add(sent: old, variant: "left", shade: 80)
    #expect(fromNew.derivedFrom.first?.sha256 == new)
    #expect(fromNew.provenance.references.first?.path == portrait.path)
    #expect(fromOld.derivedFrom.first?.sha256 == old)
    #expect(fromOld.provenance.references.first?.path == portrait.path, "the role's selection")
    #expect(try paths(.stale, project) == [fromNew.path])

    #expect(try bundle.refresh().accepted == [portrait.path])
    #expect(try paths(.stale, project) == [fromOld.path])
  }

  @Test("A page added by hand over a mismatch is stale until refresh, then not: every input is of the bytes read")
  func addedPageBundleInput() throws {
    let project = try project()
    try project.addImage(.portrait)
    try put(edited, at: "CHARACTER.md", project)
    let source = project.root.appendingPathComponent("page.html")
    try Data("<!doctype html><title>A page</title>".utf8).write(to: source)
    var bundle = try project.open()
    let page = try bundle.add(
      source, kind: .dossier, options: AddOptions(template: try DossierTemplate.current, select: true))
    #expect(try paths(.stale, project).contains(page.path))
    #expect(try bundle.refresh().accepted == ["CHARACTER.md"])
    #expect(!(try paths(.stale, project).contains(page.path)))
  }

  // MARK: refresh's adoption

  @Test("A listed vox that changed is both accepted and adopted")
  func acceptedAndAdopted() throws {
    let project = try project()
    let vox = "voice/\(RenderProject.character).vox"
    try put("first", at: vox, project)
    try touch(project)
    try put("second", at: vox, project)
    var bundle = try project.open()
    let report = try bundle.refresh()
    #expect(report.accepted == [vox])
    #expect(report.adopted.map(\.path) == [vox])
    #expect(try paths(.fileHash, project).isEmpty)
  }

  @Test("A new file adopted isn't accepted, and a sample derives from a changed vox as accepted in the same write")
  func adoptedSampleOfChangedVox() throws {
    let project = try project()
    let source = project.root.appendingPathComponent("made.vox")
    try Data("first".utf8).write(to: source)
    let models = JSONObject([("models", .array([.string("Qwen3-TTS-12Hz-1.7B-Base-bf16")]))])
    var bundle = try project.open()
    let vox = try bundle.add(source, kind: .vox, options: AddOptions(provenance: models, select: true))
    try put("second", at: vox.path, project)
    try put("a sample", at: "voice/sample-neutral.m4a", project)
    try put("- {variant: neutral, text: Hello there.}\n", at: "voice/samples.yaml", project)

    let report = try bundle.refresh()
    #expect(report.accepted == [vox.path])
    #expect(report.adopted.map(\.path) == ["voice/sample-neutral.m4a"])
    #expect(report.adopted.first?.derivedFrom.first?.sha256 == Checksum.sha256(Data("second".utf8)))
    #expect(try paths(.fileHash, project).isEmpty)
    #expect(try paths(.stale, project).isEmpty)
    try expectChecksumRight(project)
  }

  // MARK: Hidden files

  @Test("§5.2: a listed hidden file keeps its entry across a write, its finding stays, and refresh accepts it")
  func listedHidden() throws {
    let project = try project()
    let path = ".hidden.txt"
    try put("first", at: path, project)
    var manifest = try project.manifest()
    var files = manifest.files
    files.append(FileEntry(path: path, sha256: Checksum.sha256(Data("first".utf8)), sizeBytes: 5))
    files.sort { $0.path.precedesInByteOrder($1.path) }
    manifest.files = files
    manifest.manifestChecksum = manifest.computedChecksum
    try manifest.encoded().write(to: project.manifestURL)

    var bundle = try project.open()
    try bundle.renderPage()
    #expect(try entry(path, project) != nil)
    #expect(try paths(.stale, project).isEmpty, "the page's bundle input counts it, as stale() does")

    try put("second", at: path, project)
    try touch(project)
    #expect(try entry(path, project)?.sha256 == Checksum.sha256(Data("first".utf8)))
    #expect(try paths(.fileHash, project) == [path])

    #expect(try bundle.refresh().accepted == [path])
    #expect(try entry(path, project)?.sha256 == Checksum.sha256(Data("second".utf8)))
    #expect(try paths(.fileHash, project).isEmpty)
    try expectChecksumRight(project)
  }

  // MARK: Create

  @Test("create records no file, and its bundle has nothing to accept")
  func create() throws {
    let root = try RenderProject.temporaryRoot()
    var bundle = try DossierBundle.create(character: "THE GLAZIER", role: "lead", in: root).bundle
    #expect(bundle.manifest.files.isEmpty)
    #expect(try bundle.refresh().accepted.isEmpty)
  }
}

private let fullBodyForAcceptance = "## Logline\n\nA line.\n"
