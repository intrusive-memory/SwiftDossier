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
  /// The walk, hidden files included, for a listed hidden file that's being accepted (§5.2).
  private let inventory: BundleInventory

  /// - Parameters:
  ///   - url: The bundle.
  ///   - excluding: Paths left out of the inventory: the page, when what's asked is the bundle without it.
  /// - Throws: ``DossierWriteError/zeroByteFiles(_:)``, which a writer must not write (§5.2).
  init(bundle url: URL, excluding: [String] = []) throws {
    inventory = BundleInventory(bundle: url, excluding: excluding)
    let visible = inventory.visible
    let empty = visible.filter { $0.size == 0 }.map(\.path)
    guard empty.isEmpty else { throw DossierWriteError.zeroByteFiles(empty) }
    files = try visible.map(Self.hashed)
    byKey = Dictionary(files.map { (BundleInventory.key($0.path), $0) }) { first, _ in first }
  }

  private static func hashed(_ file: BundleInventory.File) throws -> File {
    guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else {
      throw DossierWriteError.fileUnreadable(file.path)
    }
    return File(path: file.path, sha256: Checksum.sha256(data), sizeBytes: Int64(data.count))
  }

  /// The hash on disk of the file a manifest path names, if it's in the inventory. This is what the
  /// bytes are now, which `files` may not say: `derivedFrom` and `references` record what a tool
  /// read, so they use this, and `files` uses ``entries(recordedIn:accepting:removing:)``.
  func sha256(ofPath path: String) -> String? { byKey[BundleInventory.key(path)]?.sha256 }

  /// The checksum of what's on disk, whatever `files` says, leaving out the given paths.
  func diskChecksum(excluding paths: [String] = []) -> String {
    let left = Set(paths.map(BundleInventory.key))
    return Checksum.sorted(files.filter { !left.contains(BundleInventory.key($0.path)) }.map(\.sha256))
  }

  /// `files` as this write leaves it, sorted by the byte order of the path (§5.2).
  ///
  /// A listed file keeps its entry, whatever the disk now holds, unless the write says it changed
  /// that file: only `refresh` brings the manifest up to the disk, so a rescan leaves `E-FILE-HASH`
  /// and `E-FILE-MISSING` for it to report. A file
  /// that isn't listed yet is recorded as found, so a file another tool put here is listed, and is
  /// `W-UNCLASSIFIED` until an asset names it.
  ///
  /// SPEC-GAP: §5.2: `files` is "every regular file" but hidden ones, and a listed hidden file is
  /// checked as any other. A listed hidden file keeps its entry like the rest, so its finding stays.
  ///
  /// SPEC-GAP: §5.2: a rescan can find a name whose normalization differs from the manifest's, since
  /// a filesystem may store either. An asset's or entry's spelling is kept, because
  /// `E-ASSET-NO-FILE` compares `assets` with `files` by their bytes.
  ///
  /// - Parameters:
  ///   - manifest: Gives the recorded entries and the spellings.
  ///   - accepting: Paths this write created or replaced, or that `refresh` accepts: recorded as
  ///     they are on disk.
  ///   - removing: Paths this write removed, or that `refresh` drops: their entries go.
  /// - Throws: ``DossierWriteError`` for an accepted hidden file that's empty or can't be read.
  func entries(
    recordedIn manifest: Manifest, accepting: [String] = [], removing: [String] = []
  ) throws -> [FileEntry] {
    var spelling: [[UInt8]: String] = [:]
    for file in manifest.files { spelling[BundleInventory.key(file.path)] = file.path }
    for asset in manifest.assets { spelling[BundleInventory.key(asset.path)] = asset.path }

    let accepted = Set(accepting.map(BundleInventory.key))
    var seen = Set(removing.map(BundleInventory.key))
    var entries: [FileEntry] = []
    for entry in manifest.files {
      let key = BundleInventory.key(entry.path)
      guard seen.insert(key).inserted else { continue }
      let path = spelling[key] ?? entry.path
      if accepted.contains(key), let file = try file(ofKey: key) {
        entries.append(FileEntry(path: path, sha256: file.sha256, sizeBytes: file.sizeBytes))
      } else {
        var kept = entry
        kept.json["path"] = .string(path)
        entries.append(kept)
      }
    }
    for file in files where seen.insert(BundleInventory.key(file.path)).inserted {
      let path = spelling[BundleInventory.key(file.path)] ?? file.path
      entries.append(FileEntry(path: path, sha256: file.sha256, sizeBytes: file.sizeBytes))
    }
    return entries.sorted { $0.path.precedesInByteOrder($1.path) }
  }

  private func file(ofKey key: [UInt8]) throws -> File? {
    if let file = byKey[key] { return file }
    guard let hidden = inventory.files.first(where: { BundleInventory.key($0.path) == key }) else { return nil }
    guard hidden.size > 0 else { throw DossierWriteError.zeroByteFiles([hidden.path]) }
    return try Self.hashed(hidden)
  }

  /// The listed files whose bytes on disk aren't their entry's, in byte order of the path: what
  /// `refresh` accepts. A file that's gone isn't one, and neither is a symlink: there's nothing to
  /// record. A file that can't be read is, so that the write says why it can't be recorded.
  static func changedFiles(in manifest: Manifest, bundle url: URL) -> [String] {
    let inventory = BundleInventory(bundle: url)
    return
      manifest.files.filter { entry in
        guard let file = inventory.file(at: entry.path) else { return false }
        if let size = entry.sizeBytes, size != file.size { return true }
        guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) else { return true }
        return !Checksum.sha256(data).hasSameBytes(as: entry.sha256)
      }
      .map(\.path)
      .sorted { $0.precedesInByteOrder($1) }
  }
}

/// SD-5's sequence, the one way `manifest.json` changes: rescan, recompute, write a temporary
/// file in the bundle, replace, re-read and compare (§5.6). A failure leaves the prior
/// manifest in place.
///
/// The rescan records what's new and keeps what's listed: only a file this write itself changed,
/// or `refresh`, changes or drops an entry (SD-5, SD-11).
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
  ///   - accepting: The paths this write created or replaced, whose entries now say what's on disk.
  ///     Anything else already listed keeps its entry. Only `refresh` names a file it didn't write.
  ///   - removing: The paths this write removed, or that `refresh` drops, whose entries go. Anything
  ///     else listed that's missing keeps its entry, and stays `E-FILE-MISSING`.
  ///   - change: Changes `assets`, and anything else but `files`, `manifestChecksum`, `updatedAt`
  ///     and `generator`, which this sets. It gets the disk as hashed for this write.
  /// - Returns: The manifest written.
  @discardableResult
  func update(
    keepingGenerator: Bool = false, accepting: [String] = [], removing: [String] = [],
    _ change: (inout Manifest, BundleScan) throws -> Void
  ) throws -> Manifest {
    var manifest = try currentManifest()
    guard let prior = try? Data(contentsOf: manifestURL) else {
      throw DossierError.manifestMissing(path: manifestURL.path)
    }
    let scan = try BundleScan(bundle: bundle)
    try change(&manifest, scan)

    manifest.files = try scan.entries(recordedIn: manifest, accepting: accepting, removing: removing)
    manifest.manifestChecksum = manifest.computedChecksum
    manifest.updatedAt = Timestamp.string(from: Date())
    if !keepingGenerator { manifest.generator = Manifest.Generator(name: Self.generatorName, version: nil) }
    try checkSchema(manifest)
    try checkIntegrity(manifest, scan: scan)

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
  /// SPEC-GAP: §5.6: an asset whose file is gone has nothing a write could record. A writer's only
  /// stated duty is the schema; this one refuses instead, and `remove` is how such an asset leaves,
  /// for the moment. The disk decides this, not `files`, which keeps a missing file's entry.
  private func checkIntegrity(_ manifest: Manifest, scan: BundleScan) throws {
    let listed = Set(manifest.files.map { Array($0.path.utf8) })
    let missing = manifest.assets.map(\.path).filter { path in
      !listed.contains(Array(path.utf8)) || scan.sha256(ofPath: path) == nil
    }
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
