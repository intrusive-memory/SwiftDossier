import DossierCore
import Foundation

/// What ``DossierBundle/add(_:kind:options:)`` needs besides the file and its kind.
public struct AddOptions: Sendable {
  /// §8.1's variant, on `view`, `expression` and `voiceSample`.
  public var variant: String?
  /// The size a `voiceSample` was rendered with (§5.4).
  public var model: String?
  /// The words a `voiceSample` speaks (§5.4).
  public var sampleText: String?
  /// A `voiceSample`'s language, when it isn't the default (§5.4).
  public var language: String?
  /// Display text (§5.4).
  public var label: String?
  /// The `lora` object, which a `lora` asset needs (§8.4). Its `version` names the file.
  public var lora: JSONObject?
  /// The `training` object, which a `training` asset needs (§8.4).
  public var training: JSONObject?
  /// A Vinetas sidecar. Stays outside the bundle (§4). Without one, a PNG's embedded record is read.
  public var sidecar: URL?
  /// `--reference-roles`: the role of each reference, in order (SD-7).
  public var referenceRoles: [String]
  /// `--provenance`: keys merged over the sidecar's, such as `tool`, `notes`, `gateOverridden`.
  public var provenance: JSONObject?
  /// The inputs, when the current selection isn't what the file was made from (§7). `nil` works
  /// them out, as ``DossierBundle/add(_:kind:options:)`` says.
  public var derivedFrom: [DerivedInput]?
  /// The template a `dossier` was rendered with (§7).
  public var template: PageTemplate?
  /// When the file was made. Default: the sidecar's `generatedAt`, then the file's modification date.
  public var createdAt: Date?
  /// Selects the new asset in the same write, demoting the previous selection (SD-8).
  public var select: Bool

  /// Options for an ``DossierBundle/add(_:kind:options:)``.
  public init(
    variant: String? = nil, model: String? = nil, sampleText: String? = nil, language: String? = nil,
    label: String? = nil, lora: JSONObject? = nil, training: JSONObject? = nil, sidecar: URL? = nil,
    referenceRoles: [String] = [], provenance: JSONObject? = nil, derivedFrom: [DerivedInput]? = nil,
    template: PageTemplate? = nil, createdAt: Date? = nil, select: Bool = false
  ) {
    self.variant = variant
    self.model = model
    self.sampleText = sampleText
    self.language = language
    self.label = label
    self.lora = lora
    self.training = training
    self.sidecar = sidecar
    self.referenceRoles = referenceRoles
    self.provenance = provenance
    self.derivedFrom = derivedFrom
    self.template = template
    self.createdAt = createdAt
    self.select = select
  }
}

/// The keys of `prompts` (§5.5).
public enum PromptKey: String, CaseIterable, Sendable {
  /// Who the character is, visually.
  case identity
  /// The working portrait prompt.
  case portrait
  /// The noun prompts use for the character.
  case subject
}

extension DossierBundle {
  /// Copies a file into the bundle and records it as an asset (SD-5, SD-6, SD-7, SD-10).
  ///
  /// The source is read and never changed. Images under `images/` are named for their content
  /// (§4); voice files, source photos and training images keep their names; the others have
  /// the one name §4 gives them. Nothing is overwritten.
  ///
  /// A PNG image copied in loses its metadata (§1) in the bundle's copy: its embedded record is
  /// read first, every other chunk stays byte for byte, and the hash, size and `<sha8>` are the
  /// stripped bytes'. A malformed one is refused. Other formats are copied as they are. A file
  /// already in the bundle is never modified: it keeps its bytes and its name.
  ///
  /// `derivedFrom` is §7's list, from the current selection. A reference whose role is an input's
  /// role says what was actually sent, so its hash is recorded instead, and the asset reads as
  /// stale if that's no longer selected. When those bytes have left the bundle, the path is that
  /// of the role's current selection; with no selection the input is refused as missing. A `view`
  /// lists `face` when a reference was the face.
  ///
  /// - Parameters:
  ///   - source: The file to copy.
  ///   - kind: What it is.
  ///   - options: Everything else.
  /// - Returns: The asset as written.
  /// - Throws: ``DossierWriteError`` or ``DossierError``. The bundle is then as it was.
  @discardableResult
  public mutating func add(_ source: URL, kind: AssetKind, options: AddOptions = AddOptions()) throws -> Asset {
    let writer = ManifestWriter(bundle: url)
    let current = try writer.currentManifest()

    let file = source.resolvingSymlinksInPath()
    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
      throw DossierWriteError.sourceUnreadable(source.path)
    }
    guard !data.isEmpty else { throw DossierWriteError.zeroByteFiles([source.lastPathComponent]) }

    let inPlace = try bundlePath(ofFile: file)
    var stored = data
    if inPlace == nil, kind.isImage, VinetasPNG.isPNG(data) {
      guard let stripped = PNGMetadata.stripped(data) else { throw DossierWriteError.pngMalformed(source.path) }
      stored = stripped
    }
    let named = try Self.destination(
      of: kind, sourceName: file.lastPathComponent, sha256: Checksum.sha256(stored),
      character: current.character, options: options)
    let path = inPlace ?? named
    if path.hasPrefix("images/"), !VinetasPNG.isPNG(data) { throw DossierWriteError.notPNG(source.path) }
    if current.assets.contains(where: { $0.hasPath(path) }) { throw DossierWriteError.assetExists(path) }

    var folded = try FoldedProvenance(
      metadata: try Self.generatorRecord(kind: kind, data: data, sidecar: options.sidecar),
      extra: options.provenance)
    let createdAt = try Self.createdAt(of: file, options: options, folded: folded)

    let placed = try place(stored, at: path)
    do {
      var added: Asset?
      let member = member
      let manifest = try writer.update { manifest, scan in
        try folded.resolveReferences(roles: options.referenceRoles, manifest: manifest, scan: scan)
        folded.resolveLoras(manifest: manifest)
        let provenance = Provenance(json: folded.json)
        var asset = Asset(
          path: path, kind: kind, status: options.select ? .selected : .candidate, createdAt: createdAt,
          provenance: provenance)
        asset.variant = options.variant
        asset.model = options.model
        asset.sampleText = options.sampleText
        asset.language = options.language
        asset.label = options.label
        asset.lora = options.lora
        asset.training = options.training
        if let inputs = try DerivedInputs.resolve(
          kind: kind, path: path, explicit: options.derivedFrom, references: provenance.references,
          template: options.template, member: member, manifest: manifest, scan: scan)
        {
          asset.derivedFrom = inputs
        }
        var assets = manifest.assets
        if options.select { Self.demoteSelection(of: asset.selectionKey, in: &assets) }
        assets.append(asset)
        manifest.assets = assets
        added = asset
      }
      self = DossierBundle(url: url, manifest: manifest, member: member)
      return added!
    } catch {
      placed.undo()
      throw error
    }
  }

  /// Marks an asset `selected` and demotes the previous selection of its combination to
  /// `candidate` (SD-8, §5.4). Nothing is written when nothing changes.
  ///
  /// - Parameter path: The asset's bundle path.
  /// - Returns: The asset as written.
  @discardableResult
  public mutating func select(path: String) throws -> Asset {
    try setStatus(of: path, to: .selected)
  }

  /// Marks an asset `rejected`. It stays in the bundle (SD-9). A `selected` one leaves its
  /// combination with no selection; nothing is promoted in its place.
  ///
  /// - Parameter path: The asset's bundle path.
  /// - Returns: The asset as written.
  @discardableResult
  public mutating func reject(path: String) throws -> Asset {
    try setStatus(of: path, to: .rejected)
  }

  /// Sets one of `prompts`' keys (§5.5), keeping the others and any unknown key. Nothing is
  /// written when nothing changes.
  ///
  /// - Parameters:
  ///   - key: Which prompt.
  ///   - text: Its text. A `subject` outside §5.5's words fails the schema, and is refused.
  public mutating func setPrompt(_ key: PromptKey, _ text: String) throws {
    let writer = ManifestWriter(bundle: url)
    let current = try writer.currentManifest()
    if current.prompts?.json[key.rawValue]?.stringValue?.hasSameBytes(as: text) == true {
      self = DossierBundle(url: url, manifest: current, member: member)
      return
    }
    let manifest = try writer.update { manifest, _ in
      var prompts = manifest.prompts ?? Manifest.Prompts(json: JSONObject())
      prompts.json[key.rawValue] = .string(text)
      manifest.prompts = prompts
    }
    self = DossierBundle(url: url, manifest: manifest, member: member)
  }

  /// Deletes one asset and its file (SD-9). Assets derived from it stay, and read as stale (§7).
  ///
  /// The file is set aside until the manifest is written and put back if that fails, so the
  /// two can't disagree. An asset whose file is already gone is removed all the same.
  ///
  /// - Parameter path: The asset's bundle path.
  public mutating func remove(path: String) throws {
    let writer = ManifestWriter(bundle: url)
    let current = try writer.currentManifest()
    guard let asset = current.assets.first(where: { $0.hasPath(path) }) else {
      throw DossierWriteError.assetNotFound(path)
    }

    // The inventory doesn't follow a symbolic link, so only a file inside the bundle is moved.
    let file = BundlePath.isValid(asset.path) ? BundleInventory(bundle: url).file(at: asset.path) : nil
    let manager = FileManager.default
    let aside = file.map {
      $0.url.deletingLastPathComponent().appendingPathComponent(".removing-\(UUID().uuidString)")
    }
    if let file, let aside { try manager.moveItem(at: file.url, to: aside) }
    let manifest: Manifest
    do {
      manifest = try writer.update { manifest, _ in
        var assets = manifest.assets
        assets.removeAll { $0.hasPath(path) }
        manifest.assets = assets
      }
    } catch {
      if let file, let aside { try? manager.moveItem(at: aside, to: file.url) }
      throw error
    }
    // Written. A file that won't go now is hidden, so it's outside §5.2's inventory.
    if let aside { try? manager.removeItem(at: aside) }
    self = DossierBundle(url: url, manifest: manifest, member: member)
  }

  /// Deletes the whole bundle (SD-9). `CAST.md` isn't changed, so a member pointing here now
  /// has a `W-POINTER`.
  ///
  /// - Throws: ``DossierWriteError/notADossierDirectory(_:)`` for anything but a `.dossier`
  ///   directory holding a `manifest.json`.
  public func delete() throws {
    guard url.lastPathComponent.hasSuffix(".dossier"),
      FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path)
    else { throw DossierWriteError.notADossierDirectory(url.path) }
    try FileManager.default.removeItem(at: url)
  }

  private mutating func setStatus(of path: String, to status: AssetStatus) throws -> Asset {
    let writer = ManifestWriter(bundle: url)
    let current = try writer.currentManifest()
    guard let target = current.assets.first(where: { $0.hasPath(path) }) else {
      throw DossierWriteError.assetNotFound(path)
    }
    let competing = current.assets.contains {
      status == .selected && $0.status == .selected && !$0.hasPath(path) && $0.selectionKey == target.selectionKey
    }
    if target.status == status, !competing {
      self = DossierBundle(url: url, manifest: current, member: member)
      return target
    }

    var written = target
    let manifest = try writer.update { manifest, _ in
      var assets = manifest.assets
      if status == .selected { Self.demoteSelection(of: target.selectionKey, in: &assets) }
      if let index = assets.firstIndex(where: { $0.hasPath(path) }) {
        assets[index].status = status
        written = assets[index]
      }
      manifest.assets = assets
    }
    self = DossierBundle(url: url, manifest: manifest, member: member)
    return written
  }

  private static func demoteSelection(of key: [UInt8], in assets: inout [Asset]) {
    for index in assets.indices where assets[index].status == .selected && assets[index].selectionKey == key {
      assets[index].status = .candidate
    }
  }

  /// The bundle path of a file that's already in this bundle, or `nil` for one outside it.
  ///
  /// - Throws: ``DossierWriteError/fileNameNotAllowed(_:)`` for what can't be an asset's path:
  ///   `manifest.json`, or a hidden file (§5.2).
  private func bundlePath(ofFile file: URL) throws -> String? {
    func canonical(_ url: URL) -> String {
      (try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? url.path
    }
    let root = canonical(url.resolvingSymlinksInPath()) + "/"
    let path = canonical(file)
    guard path.hasPrefix(root) else { return nil }
    let relative = String(path.dropFirst(root.count))
    guard relative != "manifest.json", BundlePath.isValid(relative),
      !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") })
    else { throw DossierWriteError.fileNameNotAllowed(relative) }
    return relative
  }

  /// §4's path for a new file of a kind.
  ///
  /// SPEC-GAP: §4: `crowdRef` has no directory. It's an image, so SD-6 puts it in `images/`.
  /// §4 gives `source/` and `training/` no naming rule, and the fixtures keep a plain name there,
  /// so the file keeps its own, and a name that's taken by other bytes is refused.
  private static func destination(
    of kind: AssetKind, sourceName: String, sha256: String, character: String, options: AddOptions
  ) throws -> String {
    func usable(_ name: String) throws -> String {
      guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\") else {
        throw DossierWriteError.fileNameNotAllowed(name)
      }
      return name
    }

    switch kind {
    case .view, .expression, .voiceSample:
      break
    default:
      if let variant = options.variant {
        throw DossierWriteError.variantNotAllowed("\(kind.rawValue) has no variants, and was given \(variant)")
      }
    }
    switch kind {
    case .portrait, .face, .view, .expression, .crowdRef:
      let stem = [kind.rawValue, options.variant, String(sha256.prefix(8))].compactMap { $0 }.joined(separator: "-")
      guard let name = try? usable(stem + ".png") else {
        throw DossierWriteError.variantNotAllowed(options.variant ?? stem)
      }
      return "images/" + name
    case .vox:
      return "voice/" + (try usable(character + ".vox"))
    case .voiceSample:
      return "voice/" + (try usable(sourceName))
    case .description:
      return "CHARACTER.md"
    case .dossier:
      return try usable(character + "-dossier.html")
    case .sourcePhoto:
      return "source/" + (try usable(sourceName))
    case .training:
      return "training/" + (try usable(sourceName))
    case .lora:
      guard let version = options.lora?["version"]?.intValue else { throw DossierWriteError.loraVersionMissing }
      return "lora/" + (try usable("\(character)-v\(version).safetensors"))
    case .turnaround, .faceSheet, .expressions, .wardrobe, .palette, .unknown:
      throw DossierWriteError.kindNotWritable(kind.rawValue)
    }
  }

  /// The sidecar if there is one, or the record an image holds.
  private static func generatorRecord(kind: AssetKind, data: Data, sidecar: URL?) throws -> JSONObject? {
    let json: Data
    let name: String
    if let sidecar {
      guard let text = try? Data(contentsOf: sidecar) else {
        throw DossierWriteError.provenanceUnreadable(sidecar.lastPathComponent)
      }
      (json, name) = (text, sidecar.lastPathComponent)
    } else if kind.isImage, let text = VinetasPNG.embeddedJSON(in: data) {
      (json, name) = (text, "the PNG's vinetas chunk")
    } else {
      return nil
    }
    guard let object = (try? JSONValue.parse(json))?.objectValue else {
      throw DossierWriteError.provenanceUnreadable(name)
    }
    return object
  }

  /// §5.4: a generator's own time where known, not when the file was added.
  private static func createdAt(of file: URL, options: AddOptions, folded: FoldedProvenance) throws -> String {
    if let date = options.createdAt { return Timestamp.string(from: date) }
    if let time = folded.createdAt { return time }
    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
    return Timestamp.string(from: values?.contentModificationDate ?? Date())
  }

  /// Undoes a placement when the manifest can't be written.
  private struct Placement {
    let file: URL?
    let directory: URL?

    func undo() {
      if let file { try? FileManager.default.removeItem(at: file) }
      if let directory { try? FileManager.default.removeItem(at: directory) }
    }
  }

  /// Writes the bytes at a bundle path: to a hidden name, then renamed, so a partial file is
  /// never in the inventory. Bytes identical to what's there are left alone, which is how a
  /// file another tool put in the bundle becomes an asset (§5.6).
  private func place(_ data: Data, at path: String) throws -> Placement {
    let manager = FileManager.default
    var cursor = url
    for segment in path.split(separator: "/").dropLast() {
      cursor.appendPathComponent(String(segment))
      let attributes = try? manager.attributesOfItem(atPath: cursor.path)
      if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
        throw DossierWriteError.destinationNotInBundle(path)
      }
    }
    guard let destination = fileURL(forPath: path) else { throw DossierWriteError.fileNameNotAllowed(path) }

    if let attributes = try? manager.attributesOfItem(atPath: destination.path) {
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        (try? Data(contentsOf: destination, options: .mappedIfSafe)) == data
      else { throw DossierWriteError.destinationExists(path) }
      return Placement(file: nil, directory: nil)
    }

    let parent = destination.deletingLastPathComponent()
    let isNewDirectory = !manager.fileExists(atPath: parent.path)
    let temporary = parent.appendingPathComponent(".add-\(UUID().uuidString)")
    do {
      try manager.createDirectory(at: parent, withIntermediateDirectories: true)
      try data.write(to: temporary)
      try manager.moveItem(at: temporary, to: destination)
    } catch {
      try? manager.removeItem(at: temporary)
      if isNewDirectory { try? manager.removeItem(at: parent) }
      throw DossierWriteError.replaceFailed(error.localizedDescription)
    }
    return Placement(file: destination, directory: isNewDirectory ? parent : nil)
  }
}

/// SD-10: `derivedFrom` in §7's array shape.
private enum DerivedInputs {
  /// The inputs a kind records, or `nil` for a kind that has none and was given none.
  static func resolve(
    kind: AssetKind, path: String, explicit: [DerivedInput]?, references: [ProvenanceReference],
    template: PageTemplate?, member: Cast.Member?, manifest: Manifest, scan: BundleScan
  ) throws -> [DerivedInput]? {
    let required = requiredRoles(of: kind)
    if let explicit {
      for role in required where !explicit.contains(where: { $0.role == role }) {
        throw DossierWriteError.missingDerivedInput(kind: kind.rawValue, role: role)
      }
      return explicit
    }
    guard !required.isEmpty else { return nil }

    var roles = required
    if kind == .view, wasSent("face", references: references, manifest: manifest, scan: scan) { roles.append("face") }
    return try roles.map { role in
      switch role {
      case "castMember":
        guard let member else { throw DossierWriteError.missingDerivedInput(kind: kind.rawValue, role: role) }
        return DerivedInput(role: role, sha256: member.hash)
      case "bundle":
        // §7: over every file except the page, which here isn't an asset yet.
        let pages = manifest.assets.filter { $0.kind == .dossier }.map(\.path) + [path]
        let hashes = scan.files.filter { file in
          !pages.contains { BundleInventory.key($0) == BundleInventory.key(file.path) }
        }.map(\.sha256)
        return DerivedInput(role: role, sha256: Checksum.sorted(hashes))
      case "template":
        guard let template else { throw DossierWriteError.missingDerivedInput(kind: kind.rawValue, role: role) }
        return DerivedInput(role: role, sha256: template.sha256, version: template.version)
      default:
        return try assetInput(role, kind: kind, references: references, manifest: manifest, scan: scan)
      }
    }
  }

  /// §7's table, the inputs a kind MUST include.
  private static func requiredRoles(of kind: AssetKind) -> [String] {
    switch kind {
    case .face, .view: return ["portrait"]
    case .expression: return ["face", "portrait"]
    case .voiceSample: return ["vox"]
    case .dossier: return ["description", "castMember", "bundle", "template"]
    default: return []
    }
  }

  private static func selected(_ role: String, in manifest: Manifest) -> Asset? {
    manifest.assets.first { $0.kind == AssetKind(rawValue: role) && $0.status == .selected }
  }

  /// §7: a `view` lists `face` "when it was sent": a reference with that role, or with the
  /// selected face's hash.
  private static func wasSent(
    _ role: String, references: [ProvenanceReference], manifest: Manifest, scan: BundleScan
  ) -> Bool {
    let current = selected(role, in: manifest).flatMap { scan.sha256(ofPath: $0.path) }
    return references.contains { reference in
      reference.role == role || (current != nil && reference.sha256 == current)
    }
  }

  /// An input with a role in the bundle: what was sent for that role if a reference says, else
  /// the selection. Bytes sent that have left the bundle keep their hash, with the path of what
  /// holds the role now, so a selected asset reads as stale (§7).
  private static func assetInput(
    _ role: String, kind: AssetKind, references: [ProvenanceReference], manifest: Manifest, scan: BundleScan
  ) throws -> DerivedInput {
    let current = selected(role, in: manifest)
    if let sent = references.first(where: { $0.role == role })?.sha256 {
      let candidates = (current.map { [$0] } ?? []) + manifest.assets.filter { $0.kind == AssetKind(rawValue: role) }
      let holder = candidates.first { scan.sha256(ofPath: $0.path)?.hasSameBytes(as: sent) ?? false } ?? current
      guard let holder else { throw DossierWriteError.missingDerivedInput(kind: kind.rawValue, role: role) }
      return DerivedInput(role: role, sha256: sent, path: holder.path)
    }
    guard let current, let sha256 = scan.sha256(ofPath: current.path) else {
      throw DossierWriteError.missingDerivedInput(kind: kind.rawValue, role: role)
    }
    return DerivedInput(role: role, sha256: sha256, path: current.path)
  }
}
