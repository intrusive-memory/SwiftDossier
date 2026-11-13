import DossierCore
import Foundation
import Yams

/// What ``DossierBundle/renderPage()`` wrote.
public struct RenderedPage: Sendable {
  /// The page's asset, as written.
  public let asset: Asset
  /// The page's file.
  public let url: URL
  /// The page's size in bytes.
  public let sizeBytes: Int64
  /// What the page's integrity banner lists (field rule 5).
  public let banner: [Finding]
}

extension DossierBundle {
  /// Writes `<CHARACTER>-dossier.html` (§11): the template in `DossierTemplate`, filled from
  /// `CHARACTER.md`, the manifest, the bundle's `CAST.md` member and the selected originals by
  /// `template/README.md`'s rules, driven by `DossierTabs`, and registers it as the selected
  /// `dossier` asset. It replaces the page file and asset that were there, and any other `dossier`
  /// asset with its file (§11: the page is the bundle's only HTML file).
  ///
  /// The same inputs and template give the same bytes: the page holds no render time. The whole
  /// render shows as one update (SD-14), and when it fails the previous page and manifest are
  /// as they were.
  ///
  /// - Returns: What was written.
  /// - Throws: ``DossierWriteError``, ``DossierCore/DossierError`` or ``CharacterDescriptionError``.
  ///   A bundle with no ``DossierCore/DossierBundle/member`` is refused, as §7's `castMember` input
  ///   has nothing to hash, and so is one with no selected `description`.
  @discardableResult
  public mutating func renderPage() throws -> RenderedPage {
    try renderPage(now: Date(), writer: ManifestWriter(bundle: url))
  }

  /// ``renderPage()``, with what a test sets.
  @discardableResult
  mutating func renderPage(now: Date, writer: ManifestWriter) throws -> RenderedPage {
    // §16.6: a location bundle has no page; its project's LOCATIONS page shows it.
    guard !isLocation else { throw DossierWriteError.kindNotWritable("dossier, in a location bundle (§16.6)") }
    return try withUpdate(label: "render the page") { bundle in
      try bundle.writePage(now: now, writer: writer)
    }
  }

  private mutating func writePage(now: Date, writer: ManifestWriter) throws -> RenderedPage {
    let current = try writer.currentManifest()
    let kindName = AssetKind.dossier.rawValue
    guard let member else { throw DossierWriteError.missingDerivedInput(kind: kindName, role: "castMember") }

    let template = try DossierTemplate.current
    let pagePath = try Self.destination(
      of: .dossier, sourceName: "", sha256: "", character: current.character, options: AddOptions())
    let replaced = current.assets.filter { $0.kind == .dossier }.map(\.path)
    let pages = replaced + [pagePath]

    // §11: a page would describe bytes `files` doesn't vouch for. It refuses first, with nothing
    // written: `refresh` brings the manifest up to the disk, and an asset's missing file is restored
    // or the asset removed. The page being replaced isn't considered.
    let banner = try Self.bannerFindings(of: current, at: url, pages: pages, member: member, template: template)
    let broken = banner.filter { $0.code == .fileHash || $0.code == .fileMissing }
    guard broken.isEmpty else {
      throw DossierWriteError.renderRefusedByIntegrity(broken.map { "\($0.code.rawValue) \($0.path ?? "")" })
    }

    let scan = try BundleScan(bundle: url, excluding: pages)
    let embedded = try Self.embeddedManifest(of: current, scan: scan, pages: pages)
    let view = DossierBundle(url: url, manifest: embedded, member: member)
    guard view.selectedAsset(kind: .description) != nil else {
      throw DossierWriteError.missingDerivedInput(kind: kindName, role: "description")
    }

    let document = try Self.readDescription(in: url, excluding: pages)
    let frontMatter = try Self.frontMatterObject(of: document)
    var record = JSONObject()
    record["formatVersion"] = .integer(Int64(try DossierTabs.bundled().formatVersion))
    record["character"] = .string(current.character)
    record["castMember"] = member.normalForm
    record["frontMatter"] = .object(frontMatter)
    record["body"] = .string(document.body)
    record["manifest"] = .object(embedded.json)
    let violations = try SchemaEvaluator.bundledSchemas.get().validate(.object(record), against: "record.schema.json")
    guard violations.isEmpty else {
      throw DossierWriteError.pageRecordInvalid(violations.map { "\($0.path.isEmpty ? "/" : $0.path): \($0.message)" })
    }

    let filler = try PageFiller(
      bundle: view, record: record, findings: banner, document: document, template: template, excluding: pages)
    let bytes = Data(try filler.html().utf8)

    let swap = try PageSwap(bundle: url, pagePath: pagePath, replacing: replaced)
    try swap.place(bytes)
    let manifest: Manifest
    do {
      // SPEC-GAP: §5.1, §11: every other write stamps `generator`, and a render is a write. But the
      // embedded manifest "otherwise matches manifest.json" and the fixture pages carry the prior
      // writer's `generator`, so stamping it would change the page between a first render and a
      // second, on the same inputs. A render leaves it; the asset's provenance says who rendered.
      let others = replaced.filter { BundleInventory.key($0) != BundleInventory.key(pagePath) }
      let read = scan.diskChecksum()
      manifest = try writer.update(keepingGenerator: true, accepting: [pagePath], removing: others) { manifest, scan in
        let inputs = try DerivedInputs.resolve(
          kind: .dossier, path: pagePath, explicit: nil, references: [], template: template, member: member,
          manifest: manifest, scan: scan)
        // `bundle` is what the page's embedded checksum was read as, and the disk is what the page
        // was filled from. A difference in either is a file that changed since then, so the page
        // doesn't describe this bundle. `files` alone can't tell, as it keeps a listed file's entry.
        guard let inputs, inputs.first(where: { $0.role == "bundle" })?.sha256.hasSameBytes(as: embedded.manifestChecksum) == true,
          scan.diskChecksum(excluding: pages).hasSameBytes(as: read)
        else {
          throw DossierWriteError.bundleChangedDuringRender
        }
        var asset = Asset(
          path: pagePath, kind: .dossier, status: .selected, createdAt: Timestamp.string(from: now),
          provenance: Self.pageProvenance())
        asset.derivedFrom = inputs
        var assets = manifest.assets
        let position = assets.firstIndex { $0.kind == .dossier }
        assets.removeAll { $0.kind == .dossier }
        assets.insert(asset, at: min(position ?? assets.count, assets.count))
        manifest.assets = assets
      }
    } catch {
      swap.undo()
      throw error
    }
    swap.finish()

    self = DossierBundle(url: url, manifest: manifest, member: member)
    guard let asset = manifest.assets.first(where: { $0.hasPath(pagePath) }), let file = fileURL(forPath: pagePath) else {
      throw DossierWriteError.assetNotFound(pagePath)
    }
    return RenderedPage(asset: asset, url: file, sizeBytes: Int64(bytes.count), banner: filler.bannerFindings)
  }

  /// §11: no entry for the page, the checksum over the remaining files, and `updatedAt` the latest
  /// `createdAt` of its assets. `files` is the rescan the write will record (SD-5), so this
  /// matches the `manifest.json` the render leaves.
  static func embeddedManifest(of current: Manifest, scan: BundleScan, pages: [String]) throws -> Manifest {
    var embedded = current
    embedded.assets = current.assets.filter { $0.kind != .dossier }
    embedded.files = try scan.entries(recordedIn: embedded, removing: pages)
    embedded.manifestChecksum = embedded.computedChecksum
    if let latest = latestCreatedAt(of: embedded.assets) { embedded.updatedAt = latest }
    return embedded
  }

  /// The latest `createdAt`, as written. Compared as instants where both read as timestamps, as
  /// a timestamp may have an offset.
  private static func latestCreatedAt(of assets: [Asset]) -> String? {
    assets.compactMap(\.createdAt).reduce(nil) { latest, next in
      guard let latest else { return next }
      if let first = Timestamp.normalized(latest), let second = Timestamp.normalized(next) {
        return first.precedesInByteOrder(second) ? next : latest
      }
      return latest.precedesInByteOrder(next) ? next : latest
    }
  }

  /// Field rule 5: §14 over the bundle without the page. This reads `manifest.json` as it stands,
  /// with its entries for the page gone. A checksum that was right stays right; a wrong one stays
  /// wrong, which is `E-CHECKSUM`.
  ///
  /// A render refuses `E-FILE-HASH` and `E-FILE-MISSING` (§11), so neither reaches a banner.
  static func bannerFindings(
    of current: Manifest, at url: URL, pages: [String], member: Cast.Member?, template: PageTemplate
  ) throws -> [Finding] {
    let isPage: (String) -> Bool = { path in pages.contains { BundleInventory.key($0) == BundleInventory.key(path) } }
    var described = current
    let wasRight = current.manifestChecksum.hasSameBytes(as: current.computedChecksum)
    described.assets = current.assets.filter { $0.kind != .dossier }
    described.files = current.files.filter { !isPage($0.path) }
    if wasRight { described.manifestChecksum = described.computedChecksum }
    return try findings(at: url, describedBy: described, excluding: pages, member: member, template: template)
  }

  /// `CHARACTER.md` (§9), which must be UTF-8.
  static func readDescription(in url: URL, excluding: [String]) throws -> CharacterDocument {
    let name = CharacterDescription.fileName
    guard let file = BundleInventory(bundle: url, excluding: excluding).file(at: name),
      let data = try? Data(contentsOf: file.url)
    else { throw CharacterDescriptionError.unreadable(name) }
    guard let text = String(data: data, encoding: .utf8) else { throw CharacterDescriptionError.notUTF8(name) }
    return CharacterDocument(text: text)
  }

  /// `record.frontMatter`. A file with no front matter has an empty one.
  ///
  /// SPEC-GAP: §11, rule 9: how front matter becomes JSON isn't said, and §7's canonical JSON has
  /// no floats or dates. §7's reading of a plain scalar is used, as for a member: null, boolean,
  /// integer, otherwise a string as written.
  static func frontMatterObject(of document: CharacterDocument) throws -> JSONObject {
    guard let yaml = document.frontMatterYAML else { return JSONObject() }
    let root: Node?
    do {
      root = try Yams.compose(yaml: yaml)
    } catch {
      throw CharacterDescriptionError.frontMatterUnreadable(String(describing: error))
    }
    guard let root else { return JSONObject() }
    guard case .mapping = root, let object = MemberHash.generalValue(root).objectValue else {
      throw CharacterDescriptionError.frontMatterUnreadable("it isn't a mapping")
    }
    return object
  }

  /// SPEC-GAP: §6: `provider` is required and no value is given for this tool. It's `dossier`, as
  /// for a face crop. There's no time or version here, so nothing in it changes between renders.
  private static func pageProvenance() -> Provenance {
    var tool = JSONObject()
    tool["name"] = .string("dossier")
    var provenance = JSONObject()
    provenance["provider"] = .string("dossier")
    provenance["tool"] = .object(tool)
    return Provenance(json: provenance)
  }
}

/// Putting a page in place so a failed write can be undone: everything it displaces stays under
/// a hidden name, outside §5.2's inventory, until the manifest has been replaced.
private struct PageSwap {
  private let destination: URL
  private let temporary: URL
  private let previous: URL
  private var hadPrevious = false
  private var others: [(file: URL, aside: URL)] = []

  /// - Throws: ``DossierWriteError/destinationExists(_:)`` when something that isn't a regular
  ///   file is at the page's path, and ``DossierWriteError/destinationNotInBundle(_:)``.
  init(bundle: URL, pagePath: String, replacing replaced: [String]) throws {
    let manager = FileManager.default
    destination = bundle.appendingPathComponent(pagePath)
    let unique = UUID().uuidString
    temporary = bundle.appendingPathComponent(".render-\(unique).tmp")
    previous = bundle.appendingPathComponent(".render-\(unique).previous")
    if let attributes = try? manager.attributesOfItem(atPath: destination.path) {
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw DossierWriteError.destinationExists(pagePath)
      }
      hadPrevious = true
    }
    let inventory = BundleInventory(bundle: bundle)
    for (index, path) in replaced.enumerated() where BundleInventory.key(path) != BundleInventory.key(pagePath) {
      guard let file = inventory.file(at: path) else { continue }
      let aside = ".render-\(unique)-\(index).aside"
      others.append((file.url, file.url.deletingLastPathComponent().appendingPathComponent(aside)))
    }
  }

  /// Writes the bytes to a temporary name, then renames them over the page, keeping a link to
  /// the bytes they replace.
  func place(_ bytes: Data) throws {
    let manager = FileManager.default
    do {
      try bytes.write(to: temporary)
      let handle = try FileHandle(forWritingTo: temporary)
      defer { try? handle.close() }
      try handle.synchronize()
      if hadPrevious {
        // A link is instant and the bytes stay put. A file system with none gets a copy.
        if (try? manager.linkItem(at: destination, to: previous)) == nil {
          try manager.copyItem(at: destination, to: previous)
        }
      }
      for other in others { try manager.moveItem(at: other.file, to: other.aside) }
    } catch {
      undo()
      throw DossierWriteError.replaceFailed(error.localizedDescription)
    }
    guard rename(temporary.path, destination.path) == 0 else {
      let detail = String(cString: strerror(errno))
      undo()
      throw DossierWriteError.replaceFailed(detail)
    }
  }

  /// Puts back what was there.
  func undo() {
    let manager = FileManager.default
    try? manager.removeItem(at: temporary)
    if hadPrevious, manager.fileExists(atPath: previous.path) {
      if rename(previous.path, destination.path) != 0 { try? manager.removeItem(at: previous) }
    } else if !hadPrevious {
      try? manager.removeItem(at: destination)
    }
    for other in others where manager.fileExists(atPath: other.aside.path) {
      try? manager.moveItem(at: other.aside, to: other.file)
    }
  }

  /// The write succeeded: what was displaced goes.
  func finish() {
    let manager = FileManager.default
    try? manager.removeItem(at: previous)
    for other in others { try? manager.removeItem(at: other.aside) }
  }
}
