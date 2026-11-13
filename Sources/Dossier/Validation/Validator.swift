import DossierCore
import Foundation

extension DossierBundle {
  /// Reports on this bundle as it now stands on disk (§14). Nothing is changed.
  ///
  /// With a ``member`` the member's checks and completeness are included, as they are from
  /// ``validate(cast:template:)``. With none they can't be: a tier and a voice come from
  /// `CAST.md` (§8.2, §8.3).
  ///
  /// - Parameter template: The current template, usually ``DossierTemplate/current``. `nil` makes no template comparison (§11).
  /// - Throws: Only when a resource bundled with this package can't be read.
  public func validate(template: PageTemplate? = nil) throws -> ValidationReport {
    try Self.validate(directory: url, member: member, template: template)
  }

  /// Reports on the directory at a URL, which needn't open as a bundle (§14). Nothing is
  /// changed. No `CAST.md` is read, so the member's checks and completeness aren't included.
  ///
  /// - Parameters:
  ///   - url: The directory that should hold `manifest.json`.
  ///   - template: The current template, usually ``DossierTemplate/current``. `nil` makes no template comparison (§11).
  /// - Throws: Only when a resource bundled with this package can't be read.
  public static func validate(at url: URL, template: PageTemplate? = nil) throws -> ValidationReport {
    try validate(directory: url.standardizedFileURL, member: nil, template: template)
  }

  /// Reports on a whole project from its `CAST.md` (§3, §14): every member's bundle, the
  /// members' pointers, and orphans; and the project's locations, as ``validate(project:template:)``
  /// reports them, with `CAST.md`'s directory as the project directory. Nothing is changed.
  ///
  /// - Parameters:
  ///   - castURL: The `CAST.md` file.
  ///   - template: The current template, usually ``DossierTemplate/current``. `nil` makes no template comparison (§11).
  /// - Throws: Only when a resource bundled with this package can't be read.
  public static func validate(cast castURL: URL, template: PageTemplate? = nil) throws -> ValidationReport {
    var run = ProjectValidation(directory: castURL.deletingLastPathComponent(), castURL: castURL, template: template)
    return try run.run()
  }

  /// Reports on a whole project directory (§3, §14, §16.2): its `CAST.md`, when there is one, as
  /// ``validate(cast:template:)`` does, and its locations, found from `PROJECT.md`'s `locations`
  /// key: the index's entries, their bundles, pointers and orphans. Nothing is changed.
  ///
  /// With no `PROJECT.md`, or none naming an index, the project has no locations and nothing is
  /// reported about them (§16.2 case 1). Character discovery never reads `PROJECT.md`, so no
  /// character bundle's findings depend on it.
  ///
  /// - Parameters:
  ///   - directory: The project directory: the one holding `CAST.md`, or, with no `CAST.md`, the
  ///     one holding `PROJECT.md`.
  ///   - template: The current template, usually ``DossierTemplate/current``. `nil` makes no template comparison (§11).
  /// - Throws: Only when a resource bundled with this package can't be read.
  public static func validate(project directory: URL, template: PageTemplate? = nil) throws -> ValidationReport {
    let castURL = directory.appendingPathComponent("CAST.md")
    let hasCast = FileManager.default.fileExists(atPath: castURL.path)
    var run = ProjectValidation(directory: directory, castURL: hasCast ? castURL : nil, template: template)
    return try run.run()
  }

  private static func validate(
    directory: URL, member: Cast.Member?, template: PageTemplate?
  ) throws -> ValidationReport {
    var run = BundleValidation(
      url: directory, member: member, prefix: "", template: template,
      schemas: try SchemaEvaluator.bundledSchemas.get())
    try run.run()
    let roles = member.map(roleFindings(of:)) ?? []
    return ValidationReport(
      findings: roles + run.findings,
      completeness: run.completeness.map { [.init(bundlePath: "", report: $0)] } ?? [])
  }

  /// §14 over a bundle as a given manifest describes it, with these paths treated as absent. Field
  /// rule 5's banner: the bundle without the page. Nothing is changed.
  static func findings(
    at url: URL, describedBy manifest: Manifest, excluding: [String], member: Cast.Member?, template: PageTemplate?
  ) throws -> [Finding] {
    var run = BundleValidation(
      url: url, member: member, prefix: "", template: template, schemas: try SchemaEvaluator.bundledSchemas.get(),
      described: manifest, excluding: excluding)
    try run.run()
    return run.findings
  }

  fileprivate static func roleFindings(of member: Cast.Member) -> [Finding] {
    guard member.pointer != nil, member.fields.role == nil else { return [] }
    return [Finding(code: .role, message: "\(member.character) has a manifest: and no role", path: nil)]
  }
}

/// A project's checks (§3, §14, §16.2): `CAST.md`'s members, the locations index's entries, the
/// bundles they point at, and orphans. Reads the disk, and writes nothing.
private struct ProjectValidation {
  let directory: URL
  let castURL: URL?
  let template: PageTemplate?

  private var findings: [Finding] = []
  private var completeness: [ValidationReport.BundleCompleteness] = []
  /// The directories §3 and §16.2 list for orphans, relative to the project directory.
  private var scanned: [[String]] = []
  /// Every bundle an entry of either index points at, relative to the project directory, as NFC
  /// bytes. A `.dossier` directory is an orphan only when none does (§3).
  private var pointedAt: Set<[UInt8]> = []

  init(directory: URL, castURL: URL?, template: PageTemplate?) {
    self.directory = directory
    self.castURL = castURL
    self.template = template
  }

  private static func key(_ segments: [String]) -> [UInt8] {
    Array(segments.joined(separator: "/").precomposedStringWithCanonicalMapping.utf8)
  }

  /// What a bundle's manifest says it is, when it can be read; `nil` leaves the bundle to its own
  /// checks (`E-MANIFEST`, `E-VERSION`).
  private static func readType(at directory: URL) -> (type: DossierType, version: Int)? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
      let manifest = try? Manifest(data: data)
    else { return nil }
    return (manifest.dossierType, manifest.manifestVersion)
  }

  mutating func run() throws -> ValidationReport {
    let schemas = try SchemaEvaluator.bundledSchemas.get()
    if let castURL { try checkCast(castURL, schemas: schemas) }
    try checkLocations(schemas: schemas)
    findings += orphanFindings()
    return ValidationReport(findings: findings, completeness: completeness)
  }

  /// §3: `CAST.md`'s members.
  private mutating func checkCast(_ castURL: URL, schemas: SchemaEvaluator) throws {
    let cast: Cast
    do {
      cast = try Cast.load(castURL)
    } catch {
      findings.append(Finding(code: .cast, message: error.localizedDescription, path: castURL.lastPathComponent))
      return
    }
    scanned.append(["characters"])
    for member in cast.members {
      guard let pointer = member.pointer, pointer.namesManifest else { continue }
      pointedAt.insert(Self.key(Array(pointer.segments.dropLast())))
    }
    for member in cast.members {
      guard let pointer = member.pointer, let manifest = cast.manifestURL(of: member) else { continue }
      findings += DossierBundle.roleFindings(of: member)
      let bundle = manifest.deletingLastPathComponent()
      let bundleSegments = Array(pointer.segments.dropLast())
      guard Self.leadsToManifest(pointer, manifest) else {
        findings.append(
          Finding(
            code: .pointer, message: "\(member.character): manifest: leads to no manifest: \(pointer.raw)",
            path: pointer.raw))
        continue
      }
      scanned.append(Array(bundleSegments.dropLast()))
      // §16.1: the two indexes don't cross.
      if Self.readType(at: bundle)?.type == .location {
        findings.append(
          Finding(
            code: .typeMismatch, message: "\(member.character): a CAST.md member points at a location bundle",
            path: bundleSegments.joined(separator: "/")))
        continue
      }
      var run = BundleValidation(
        url: bundle, member: member, prefix: bundleSegments.joined(separator: "/") + "/",
        template: template, schemas: schemas)
      try run.run()
      findings += run.findings
      if let report = run.completeness {
        completeness.append(.init(bundlePath: bundleSegments.joined(separator: "/"), report: report))
      }
    }
  }

  /// §3: a pointer reaches a manifest, or at least its directory, which is then `E-MANIFEST`.
  private static func leadsToManifest(_ pointer: ManifestPointer, _ manifest: URL) -> Bool {
    let manager = FileManager.default
    return pointer.namesManifest
      && (manager.fileExists(atPath: manifest.path)
        || manager.fileExists(atPath: manifest.deletingLastPathComponent().path))
  }

  /// §16.2: `PROJECT.md`, the index it names, and the entries' bundles.
  private mutating func checkLocations(schemas: SchemaEvaluator) throws {
    let project = DossierProject(directory: directory)
    let index: LocationsIndex
    switch project.discoverLocations() {
    case .none:
      return
    case .projectUnreadable(let error):
      findings.append(Finding(code: .cast, message: error.localizedDescription, path: DossierProject.projectFileName))
      return
    case .indexMissing(let path):
      findings.append(
        Finding(code: .pointer, message: "PROJECT.md's locations reaches no file: \(path)", path: path))
      return
    case .indexUnreadable(let url, let error):
      findings.append(Finding(code: .cast, message: error.localizedDescription, path: relativePath(of: url)))
      return
    case .index(let found):
      index = found
    }

    // The index's directory, relative to the project directory; a valid index path never leaves it.
    let indexSegments = Array(ManifestPointer(relativePath(of: index.url)).segments.dropLast())
    func projectSegments(_ pointer: ManifestPointer) -> [String] {
      ManifestPointer((indexSegments + pointer.segments).joined(separator: "/")).segments
    }
    scanned.append(indexSegments + ["locations"])
    for entry in index.entries {
      guard let pointer = entry.pointer, pointer.namesManifest else { continue }
      pointedAt.insert(Self.key(Array(projectSegments(pointer).dropLast())))
    }
    for entry in index.entries {
      if (try? CanonicalName.canonicalize(entry.location)) == nil {
        findings.append(Finding(code: .name, message: "The entry's location is invalid: \(entry.location)", path: nil))
      }
      guard let pointer = entry.pointer, let manifest = index.manifestURL(of: entry) else { continue }
      let bundle = manifest.deletingLastPathComponent()
      let bundleSegments = Array(projectSegments(pointer).dropLast())
      guard Self.leadsToManifest(pointer, manifest) else {
        findings.append(
          Finding(
            code: .pointer, message: "\(entry.location): manifest: leads to no manifest: \(pointer.raw)",
            path: (indexSegments + [pointer.raw]).joined(separator: "/")))
        continue
      }
      scanned.append(Array(bundleSegments.dropLast()))
      // §16.1. A version 1 manifest has no `dossierType`; it's `W-V1`, as from a member (§16.2).
      if let read = Self.readType(at: bundle), read.version == 2, read.type != .location {
        findings.append(
          Finding(
            code: .typeMismatch, message: "\(entry.location): a LOCATIONS.md entry points at a character bundle",
            path: bundleSegments.joined(separator: "/")))
        continue
      }
      var run = BundleValidation(
        url: bundle, member: nil, prefix: bundleSegments.joined(separator: "/") + "/",
        template: template, schemas: schemas, indexName: entry.location)
      try run.run()
      findings += run.findings
    }
  }

  /// A file's path relative to the project directory, or its full path when it's outside.
  private func relativePath(of url: URL) -> String {
    let base = directory.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(base + "/") else { return path }
    return String(path.dropFirst(base.count + 1))
  }

  /// §3, §16.2: the only directory listings the format uses. `characters/` beside `CAST.md`, each
  /// directory holding a bundle a member points at, and, once the locations index has been read,
  /// `locations/` beside it and each directory holding a bundle an entry points at. Not
  /// recursively.
  private func orphanFindings() -> [Finding] {
    var findings: [Finding] = []
    var seen: Set<[UInt8]> = []
    for segments in scanned {
      let relative = segments.joined(separator: "/")
      guard seen.insert(Array(relative.precomposedStringWithCanonicalMapping.utf8)).inserted else { continue }
      let listed = segments.reduce(directory) { $0.appendingPathComponent($1) }
      let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
      guard
        let entries = try? FileManager.default.contentsOfDirectory(
          at: listed, includingPropertiesForKeys: keys)
      else { continue }
      let names = entries.filter { entry in
        let values = try? entry.resourceValues(forKeys: Set(keys))
        return values?.isDirectory == true && values?.isSymbolicLink != true
          && entry.lastPathComponent.hasSuffix(".dossier")
      }.map(\.lastPathComponent).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
      for name in names {
        let bundle = relative.isEmpty ? name : relative + "/" + name
        if !pointedAt.contains(Self.key(ManifestPointer(bundle).segments)) {
          findings.append(Finding(code: .orphan, message: "No index entry points at \(bundle)", path: bundle))
        }
      }
    }
    return findings
  }
}

extension SchemaEvaluator {
  /// The pinned schemas, loaded once.
  static let bundledSchemas = Result<SchemaEvaluator, any Error> { try SchemaEvaluator.pinned() }
}

/// One bundle's checks. Reads the disk, and writes nothing.
private struct BundleValidation {
  private static let pageSizeLimit = 10_000_000

  let url: URL
  let member: Cast.Member?
  /// What a finding's path starts with.
  let prefix: String
  let template: PageTemplate?
  let schemas: SchemaEvaluator

  private(set) var findings: [Finding] = []
  private(set) var completeness: CompletenessReport?

  /// The manifest to check, in place of `manifest.json`.
  private let described: Manifest?
  /// Paths to treat as absent.
  private let excluding: [String]
  /// The `LOCATIONS.md` entry's `location`, when the bundle was reached from the index (§16.1).
  private let indexName: String?

  init(
    url: URL, member: Cast.Member?, prefix: String, template: PageTemplate?, schemas: SchemaEvaluator,
    described: Manifest? = nil, excluding: [String] = [], indexName: String? = nil
  ) {
    self.url = url
    self.member = member
    self.prefix = prefix
    self.template = template
    self.schemas = schemas
    self.described = described
    self.excluding = excluding
    self.indexName = indexName
  }

  private mutating func add(_ code: Finding.Code, _ message: String, path: String? = nil) {
    findings.append(Finding(code: code, message: message, path: path.map { prefix + $0 }))
  }

  mutating func run() throws {
    guard let manifest = described ?? readManifest() else { return }
    let isV1 = manifest.manifestVersion == 1
    let bundle = DossierBundle(url: url, manifest: manifest, member: member)
    let inventory = BundleInventory(bundle: url, excluding: excluding)

    if isV1 {
      add(.v1, "A version 1 manifest; migrate it", path: "manifest.json")
    } else if !url.lastPathComponent.hasSuffix(".dossier") {
      add(.notBundle, "A version 2 manifest in a directory without .dossier", path: "manifest.json")
    }
    try checkSchema(manifest)
    checkNames(bundle)
    checkManifestPaths(manifest)
    checkFiles(manifest, inventory)
    checkAssets(manifest)
    checkInventory(manifest, inventory)
    checkShapes(manifest, inventory)
    checkFootnotes(bundle)
    checkVoice(bundle)
    checkDisplayName(bundle)
    // Appendix A: staleness, completeness and what differs on the page are version 2's.
    if !isV1 {
      try checkVariants(manifest)
      checkStaleness(bundle)
      checkPage(manifest, inventory)
      try checkCompleteness(bundle)
    }
  }

  /// §14: with no manifest, or an unknown version, no other check of the bundle is possible.
  private mutating func readManifest() -> Manifest? {
    guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")) else {
      add(.manifest, "No readable manifest.json", path: "manifest.json")
      return nil
    }
    do {
      return try Manifest(data: data)
    } catch DossierError.unknownVersion(let version) {
      // SPEC-GAP: §5.1, §14: an unknown version's rules aren't known, so nothing else is
      // checked, `E-SCHEMA` included: no schema is the one it should meet.
      add(.version, "Unknown manifestVersion: \(version ?? "absent")", path: "manifest.json")
    } catch {
      add(.manifest, error.localizedDescription, path: "manifest.json")
    }
    return nil
  }

  private mutating func checkSchema(_ manifest: Manifest) throws {
    let name = manifest.manifestVersion == 1 ? "manifest-v1.schema.json" : "manifest-v2.schema.json"
    for violation in try schemas.validate(.object(manifest.json), against: name) {
      add(.schema, "\(violation.path.isEmpty ? "/" : violation.path): \(violation.message)", path: "manifest.json")
    }
  }

  /// §2, §3.
  private mutating func checkNames(_ bundle: DossierBundle) {
    let written = bundle.manifest.json["character"]?.stringValue
    if let written, !CanonicalName.isCanonical(written) {
      add(.name, "The manifest's character isn't canonical: \(written)", path: "manifest.json")
    }
    if let member, (try? CanonicalName.canonicalize(member.character)) == nil {
      add(.name, "The member's character is invalid: \(member.character)", path: nil)
    }

    func normal(_ text: String) -> [UInt8] { Array(text.precomposedStringWithCanonicalMapping.utf8) }
    let directory = url.lastPathComponent
    let directoryName = directory.hasSuffix(".dossier") ? String(directory.dropLast(".dossier".count)) : directory
    // A version 1 bundle may have no extension (Appendix A); a v2 one has E-NOT-BUNDLE for that.
    let reference = normal(written ?? directoryName)
    if normal(directoryName) != reference {
      add(.nameMismatch, "The directory is \(directoryName) and the manifest says \(written ?? "nothing")")
    }
    if let member, normal(member.character) != reference {
      add(.nameMismatch, "The member is \(member.character) and the bundle is \(written ?? directoryName)")
    }
    if let indexName, normal(indexName) != reference {
      add(.nameMismatch, "The LOCATIONS.md entry is \(indexName) and the bundle is \(written ?? directoryName)")
    }
    // §9.1, §16.3: a description with no front-matter `character` (`location`) has nothing to compare.
    let key = bundle.isLocation ? "location" : "character"
    if let described = bundle.description?.frontMatterText(key), normal(described) != reference {
      add(
        .nameMismatch, "\(bundle.descriptionPath) says \(described) and the bundle is \(written ?? directoryName)",
        path: bundle.descriptionPath)
    }
  }

  /// §5.2's bundle paths: `files`, `assets`, `derivedFrom`, `provenance.references`.
  ///
  /// SPEC-GAP: Appendix A: version 1's `derivedFrom` and `references` have other shapes, and
  /// its sidecars recorded absolute paths, so on version 1 only `files` and `assets` are held
  /// to these rules. `provenance.loras[].path` isn't in §5.2's list and isn't checked.
  private mutating func checkManifestPaths(_ manifest: Manifest) {
    var recorded: [(place: String, path: String?)] = []
    recorded += manifest.files.map { ("files", $0.json["path"]?.stringValue) }
    for asset in manifest.assets {
      recorded.append(("assets", asset.json["path"]?.stringValue))
      guard manifest.manifestVersion == 2 else { continue }
      recorded += asset.derivedFrom.map { ("derivedFrom", $0.path) }
      recorded += asset.provenance.references.map { ("provenance.references", $0.path) }
    }
    for entry in recorded {
      guard let path = entry.path, !BundlePath.isValid(path) else { continue }
      add(.path, "\(entry.place) has the path \"\(path)\"", path: "manifest.json")
    }
  }

  /// `E-FILE-MISSING`, `E-FILE-HASH`, `E-CHECKSUM`.
  ///
  /// §5.2: a listed hidden file is checked as normal. A symlink or `manifest.json` isn't in the
  /// inventory, so an entry for one is `E-FILE-MISSING`.
  private mutating func checkFiles(_ manifest: Manifest, _ inventory: BundleInventory) {
    for entry in manifest.files {
      guard let path = entry.json["path"]?.stringValue, BundlePath.isValid(path) else { continue }
      guard let file = inventory.file(at: path) else {
        add(.fileMissing, "A files entry has no file", path: path)
        continue
      }
      if let size = entry.sizeBytes, size != file.size {
        add(.fileHash, "The entry says \(size) bytes and the file has \(file.size)", path: path)
        continue
      }
      guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else {
        add(.fileHash, "The file can't be read", path: path)
        continue
      }
      if !Checksum.sha256(data).hasSameBytes(as: entry.sha256) {
        add(.fileHash, "The file's hash isn't the entry's", path: path)
      }
    }
    if let recorded = manifest.json["manifestChecksum"]?.stringValue,
      !recorded.hasSameBytes(as: manifest.computedChecksum)
    {
      add(.checksum, "manifestChecksum is \(recorded); files gives \(manifest.computedChecksum)", path: "manifest.json")
    }
  }

  /// `E-ASSET-NO-FILE`, `E-ASSET-DUPLICATE`, `E-MULTI-SELECTED`, `E-KIND-RETIRED`.
  private mutating func checkAssets(_ manifest: Manifest) {
    let isV2 = manifest.manifestVersion == 2
    let listed = Set(manifest.files.map { Array($0.path.utf8) })
    var seenPaths: Set<[UInt8]> = []
    var selections: Set<[UInt8]> = []
    for asset in manifest.assets {
      if let path = asset.json["path"]?.stringValue {
        if !listed.contains(Array(path.utf8)) { add(.assetNoFile, "An asset with no files entry", path: path) }
        if !seenPaths.insert(Array(path.utf8)).inserted { add(.assetDuplicate, "Two assets with this path", path: path) }
      }
      guard isV2 else { continue }
      if asset.kind.isRetired {
        add(.kindRetired, "The retired kind \(asset.kind.rawValue)", path: asset.path)
      }
      // Appendix A: `E-MULTI-SELECTED` is version 2's.
      if asset.status == .selected {
        if !selections.insert(asset.selectionKey).inserted {
          let name = [asset.kind.rawValue, asset.variant, asset.kind == .voiceSample ? asset.model : nil]
            .compactMap { $0 }.joined(separator: " ")
          add(.multiSelected, "More than one selected \(name)", path: asset.path)
        }
      }
    }
  }

  /// `W-VARIANT`, against the variants `tiers.json` lists and, for a view, its families (§8.1,
  /// DF-85). A plate has no standard set (§16.4).
  private mutating func checkVariants(_ manifest: Manifest) throws {
    for kind in [AssetKind.view, .expression] {
      guard let standard = try kind.standardVariants() else {
        throw DossierError.resourceUnreadable("tiers.json lists no variants for \(kind.rawValue)")
      }
      for asset in manifest.assets where asset.kind == kind {
        guard let variant = asset.variant, !standard.contains(where: { $0.hasSameBytes(as: variant) }) else {
          continue
        }
        if kind == .view, ViewVariant.isInFamily(variant) { continue }
        let outside = kind == .view ? "the standard set and its families" : "the standard set"
        add(.variant, "The \(kind.rawValue) variant \(variant) is outside \(outside)", path: asset.path)
      }
    }
  }

  /// §5.2's walk: `E-ZERO-BYTE`, `W-UNCLASSIFIED`, `W-SIDECAR`.
  private mutating func checkInventory(_ manifest: Manifest, _ inventory: BundleInventory) {
    func normal(_ text: String) -> [UInt8] { Array(text.precomposedStringWithCanonicalMapping.utf8) }
    let classified = Set(manifest.assets.map { normal($0.path) })
    for file in inventory.visible {
      if file.size == 0 { add(.zeroByte, "A zero-byte file", path: file.path) }
      if !classified.contains(normal(file.path)), file.path != "voice/samples.yaml" {
        add(.unclassified, "A file with no asset entry", path: file.path)
      }
      if file.path.hasPrefix("images/"), file.path.lowercased().hasSuffix(".json") {
        add(.sidecar, "A sidecar in images/", path: file.path)
      }
    }
  }

  /// §8.1. A missing file is only `E-FILE-MISSING`, so it isn't read here. An imported face, view,
  /// expression or plate isn't checked (DF-86); an imported portrait is.
  private mutating func checkShapes(_ manifest: Manifest, _ inventory: BundleInventory) {
    // §16.4: a view in a location bundle is always imported (`E-SCHEMA` otherwise), so never W-SHAPE.
    let isLocation = manifest.dossierType == .location
    for asset in manifest.assets where asset.status == .selected && !asset.isImported {
      if isLocation, asset.kind == .view { continue }
      guard let target = ImageShape.target(of: asset.kind), BundlePath.isValid(asset.path),
        let file = inventory.file(at: asset.path)
      else { continue }
      guard let size = ImageShape.dimensions(of: file.url) else {
        add(.shape, "No readable dimensions", path: asset.path)
        continue
      }
      if ImageShape.isOutsideTolerance(width: size.width, height: size.height, target: target) {
        add(
          .shape, "\(size.width)×\(size.height) for a \(asset.kind.rawValue), which should be \(target.width):\(target.height)",
          path: asset.path)
      }
    }
  }

  /// §9.3, and §16.3 for `LOCATION.md`.
  private mutating func checkFootnotes(_ bundle: DossierBundle) {
    guard let body = bundle.description?.body else { return }
    let result = Footnotes.check(body: body)
    let path = bundle.descriptionPath
    for label in result.undefined { add(.footnote, "[^\(label)] has no definition", path: path) }
    for label in result.unused { add(.footnote, "[^\(label)] is never referenced", path: path) }
  }

  /// §5.1, DF-88: the member's `displayName` wins, and the manifest's is a copy. Only when both are
  /// present can they differ. A location has none (§16.3).
  private mutating func checkDisplayName(_ bundle: DossierBundle) {
    guard !bundle.isLocation, let member, let wins = member.displayName, let copy = bundle.manifest.displayName,
      !wins.hasSameBytes(as: copy)
    else { return }
    add(.displayName, "The manifest's displayName is \(copy); the member's is \(wins)", path: "manifest.json")
  }

  /// §8.2. The member is read in §7's normal form, so a legacy `voiceDescription`, a single
  /// string and a mixed-case provider read as what they mean.
  private mutating func checkVoice(_ bundle: DossierBundle) {
    guard let member, let pointer = member.pointer, let vox = bundle.selectedAsset(kind: .vox) else { return }
    let normal = member.normalForm.objectValue
    let entries = normal?["voices"]?.objectValue?["voxalta"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let target = (pointer.segments.dropLast() + [vox.path]).joined(separator: "/")
    if !entries.contains(where: { ManifestPointer($0).points(at: target) }) {
      add(.voiceElsewhere, "voices.voxalta doesn't name the selected vox", path: vox.path)
    }
    // SPEC-GAP: §8.2: with no prompt on one side there's nothing to differ from, so it isn't
    // reported. A member with none is the `voicePrompt` row's concern (§8.3).
    if let prompt = normal?["voicePrompt"]?.stringValue, let voxPrompt = vox.provenance.voicePrompt,
      !prompt.hasSameBytes(as: voxPrompt)
    {
      add(.voicePrompt, "voicePrompt differs from the vox's", path: vox.path)
    }
  }

  private mutating func checkStaleness(_ bundle: DossierBundle) {
    for stale in bundle.stale(template: template) {
      let message: String
      switch stale.reason {
      case .input(let role, _, let current):
        message = current == nil ? "Its \(role) input has no current selection" : "Its \(role) input changed"
      case .artStyle(_, let current):
        message = "Made under another art style than \(current ?? "none")"
      case .pageTemplate(let recorded, let current):
        message = "Made with template \(recorded); the current one is \(current)"
      case .voice(let provider, let voiceId, let current):
        message =
          current == nil
          ? "Its voice input names \(provider), and the member's voices has no \(provider) key"
          : "The member's voices.\(provider) no longer names its voice \(voiceId)"
      }
      add(.stale, message, path: stale.path)
    }
  }

  /// §11.
  ///
  /// SPEC-GAP: §11: an HTML file not registered as `kind: dossier` is only `W-UNCLASSIFIED`, as
  /// no rule makes it the page. A page of any `status` is checked, since the path is fixed.
  private mutating func checkPage(_ manifest: Manifest, _ inventory: BundleInventory) {
    for asset in manifest.assets where asset.kind == .dossier {
      guard BundlePath.isValid(asset.path), let file = inventory.file(at: asset.path) else { continue }
      if file.size > Self.pageSizeLimit {
        add(.pageSize, "\(file.size) bytes, over \(Self.pageSizeLimit)", path: asset.path)
      }
      guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else { continue }
      for external in PageReferences.external(in: Array(data)) {
        add(
          .pageExternal, "<\(external.element)> \(external.source) references \(external.value)", path: asset.path)
      }
    }
  }

  /// §8.3. Every missing row is its own finding, named by its ID.
  private mutating func checkCompleteness(_ bundle: DossierBundle) throws {
    completeness = try bundle.completeness()
    guard let completeness else { return }
    for row in completeness.missingRequired {
      add(.incomplete, "Missing the required row \(row) for \(completeness.tier.rawValue)", path: nil)
    }
  }
}

/// §8.1's view families (DF-85): `storyboard`, `storyboard-<slug>` and `look-<slug>`.
enum ViewVariant {
  /// Whether a variant is in a family. `look` alone isn't.
  static func isInFamily(_ variant: String) -> Bool {
    if variant == "storyboard" { return true }
    for family in ["storyboard-", "look-"] where variant.hasPrefix(family) {
      return isSlug(String(variant.dropFirst(family.count)))
    }
    return false
  }

  /// A slug: lowercase ASCII letters and digits in runs joined by single hyphens (§8.1).
  static func isSlug(_ text: String) -> Bool {
    let runs = text.utf8.split(separator: UInt8(ascii: "-"), omittingEmptySubsequences: false)
    return runs.allSatisfy { run in
      !run.isEmpty && run.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) }
    }
  }
}
