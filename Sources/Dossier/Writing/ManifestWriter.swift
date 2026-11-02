import DossierCore
import Foundation

/// §1's timestamps: RFC 3339, UTC, `Z`, whole seconds.
enum Timestamp {
  static func string(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
  }

  /// The same instant in §1's form, or `nil` when the text isn't an RFC 3339 timestamp.
  /// Fractions of a second are dropped, as §1 has whole seconds.
  static func normalized(_ text: String) -> String? {
    for options: ISO8601DateFormatter.Options in [
      [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
    ] {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = options
      if let date = formatter.date(from: text) { return string(from: date) }
    }
    return nil
  }
}

extension Asset {
  /// §5.4's combination, of which at most one asset is `selected`.
  var selectionKey: [UInt8] {
    var key = [kind.rawValue, variant ?? ""]
    if kind == .voiceSample { key.append(model ?? "") }
    return Array(key.joined(separator: "\0").utf8)
  }

  /// Whether this asset's path is the given one. Compared as NFC, as a path and a name on
  /// disk are (`BundleInventory`).
  func hasPath(_ path: String) -> Bool { BundleInventory.key(self.path) == BundleInventory.key(path) }
}

/// §5.2's inventory of the disk, hashed.
struct BundleScan {
  struct File {
    let path: String
    let sha256: String
    let sizeBytes: Int64
  }

  /// §5.2's inventory, in the disk's spelling.
  let files: [File]
  private let byKey: [[UInt8]: File]

  /// - Parameters:
  ///   - url: The bundle.
  ///   - excluding: Paths left out of the inventory: the page, when what's asked is the bundle without it.
  /// - Throws: ``DossierWriteError/zeroByteFiles(_:)``, which a writer must not write (§5.2).
  init(bundle url: URL, excluding: [String] = []) throws {
    let visible = BundleInventory(bundle: url, excluding: excluding).visible
    let empty = visible.filter { $0.size == 0 }.map(\.path)
    guard empty.isEmpty else { throw DossierWriteError.zeroByteFiles(empty) }
    files = try visible.map { file in
      guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else {
        throw DossierWriteError.fileUnreadable(file.path)
      }
      return File(path: file.path, sha256: Checksum.sha256(data), sizeBytes: Int64(data.count))
    }
    byKey = Dictionary(files.map { (BundleInventory.key($0.path), $0) }) { first, _ in first }
  }

  /// The hash of the file a manifest path names, if it's in the inventory.
  func sha256(ofPath path: String) -> String? { byKey[BundleInventory.key(path)]?.sha256 }

  /// `files`, sorted by the byte order of the path (§5.2).
  ///
  /// SPEC-GAP: §5.2: a rescan can find a name whose normalization differs from the
  /// manifest's, since a filesystem may store either. An asset's or entry's spelling is
  /// kept, because `E-ASSET-NO-FILE` compares `assets` with `files` by their bytes.
  func entries(spelledAs manifest: Manifest) -> [FileEntry] {
    var spelling: [[UInt8]: String] = [:]
    for file in manifest.files { spelling[BundleInventory.key(file.path)] = file.path }
    for asset in manifest.assets { spelling[BundleInventory.key(asset.path)] = asset.path }
    return
      files
      .map { FileEntry(path: spelling[BundleInventory.key($0.path)] ?? $0.path, sha256: $0.sha256, sizeBytes: $0.sizeBytes) }
      .sorted { $0.path.precedesInByteOrder($1.path) }
  }
}

/// SD-5's sequence, the one way `manifest.json` changes: rescan, recompute, write a temporary
/// file in the bundle, replace, re-read and compare (§5.6). A failure leaves the prior
/// manifest in place.
struct ManifestWriter {
  static let generatorName = "SwiftDossier"

  let bundle: URL
  /// Called between the replace and the re-read. A test's way to make the two differ.
  var afterReplace: (@Sendable (URL) -> Void)?

  init(bundle: URL, afterReplace: (@Sendable (URL) -> Void)? = nil) {
    self.bundle = bundle
    self.afterReplace = afterReplace
  }

  private var manifestURL: URL { bundle.appendingPathComponent("manifest.json") }

  /// The manifest as it now stands on disk, not as some value of ``DossierBundle`` last saw it,
  /// and held to what a writer will write over.
  func currentManifest() throws -> Manifest {
    guard let data = try? Data(contentsOf: manifestURL) else {
      throw DossierError.manifestMissing(path: manifestURL.path)
    }
    let manifest = try Manifest(data: data)
    guard manifest.manifestVersion == 2 else { throw DossierWriteError.versionOneManifest }
    // First, because `assets` and `files` read past an element that isn't an object, and a
    // re-encode would drop what the schema would have caught.
    try checkSchema(manifest)
    return manifest
  }

  /// Applies a change and writes the result.
  ///
  /// - Parameters:
  ///   - keepingGenerator: Leaves `generator` as it is, which only a render asks for.
  ///   - change: Changes `assets`, and anything else but `files`, `manifestChecksum`, `updatedAt`
  ///     and `generator`, which this sets. It gets the disk as hashed for this write.
  /// - Returns: The manifest written.
  @discardableResult
  func update(keepingGenerator: Bool = false, _ change: (inout Manifest, BundleScan) throws -> Void) throws -> Manifest {
    var manifest = try currentManifest()
    guard let prior = try? Data(contentsOf: manifestURL) else {
      throw DossierError.manifestMissing(path: manifestURL.path)
    }
    let scan = try BundleScan(bundle: bundle)
    try change(&manifest, scan)

    manifest.files = scan.entries(spelledAs: manifest)
    manifest.manifestChecksum = manifest.computedChecksum
    manifest.updatedAt = Timestamp.string(from: Date())
    if !keepingGenerator { manifest.generator = Manifest.Generator(name: Self.generatorName, version: nil) }
    try checkSchema(manifest)
    try checkIntegrity(manifest)

    let bytes = manifest.encoded()
    try replace(with: bytes)
    afterReplace?(manifestURL)
    let reread = try? Data(contentsOf: manifestURL)
    guard reread == bytes, let parsed = reread.flatMap({ try? Manifest(data: $0) }), parsed == manifest else {
      try? replace(with: prior)
      throw DossierWriteError.verificationFailed
    }
    return manifest
  }

  /// SD-3, by the schema files.
  private func checkSchema(_ manifest: Manifest) throws {
    let violations = try SchemaEvaluator.bundledSchemas.get()
      .validate(.object(manifest.json), against: "manifest-v2.schema.json")
    guard violations.isEmpty else {
      throw DossierWriteError.schemaViolations(
        violations.map { "\($0.path.isEmpty ? "/" : $0.path): \($0.message)" })
    }
  }

  /// §14's errors the schema can't see, which only this write could otherwise record.
  ///
  /// SPEC-GAP: §5.6: a rescan would turn a missing file's `E-FILE-MISSING` into
  /// `E-ASSET-NO-FILE` without a word. A writer's only stated duty is the schema; this one
  /// refuses instead, and `remove` is how such an asset leaves.
  private func checkIntegrity(_ manifest: Manifest) throws {
    let listed = Set(manifest.files.map { Array($0.path.utf8) })
    let missing = manifest.assets.map(\.path).filter { !listed.contains(Array($0.utf8)) }
    guard missing.isEmpty else { throw DossierWriteError.assetFilesMissing(missing) }

    var paths: Set<[UInt8]> = []
    var selections: Set<[UInt8]> = []
    for asset in manifest.assets {
      guard paths.insert(Array(asset.path.utf8)).inserted else { throw DossierWriteError.duplicateAsset(asset.path) }
      if asset.status == .selected, !selections.insert(asset.selectionKey).inserted {
        throw DossierWriteError.multipleSelected(asset.path)
      }
    }
  }

  /// Writes a temporary file in the bundle and renames it over `manifest.json`. A leading `.`
  /// keeps it out of §5.2's inventory if the process dies first.
  private func replace(with bytes: Data) throws {
    let temporary = bundle.appendingPathComponent(".manifest-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    do {
      try bytes.write(to: temporary)
      let handle = try FileHandle(forWritingTo: temporary)
      defer { try? handle.close() }
      try handle.synchronize()
    } catch {
      throw DossierWriteError.replaceFailed(error.localizedDescription)
    }
    guard rename(temporary.path, manifestURL.path) == 0 else {
      throw DossierWriteError.replaceFailed(String(cString: strerror(errno)))
    }
  }
}
