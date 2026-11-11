import DossierCore
import Foundation

/// A bundle's previews, kept in `<bundle>/.preview/` (§11.1, *The store*).
///
/// A preview file is a regular file directly in `.preview/` named `<key>.html`, where `<key>` is
/// a ``DossierCore/DossierBundle/previewKey(template:)``. Nothing else in `.preview/` is a
/// preview. The store writes nothing in the bundle outside `.preview/` (PV-8).
public struct PreviewStore: Sendable {
  /// `<bundle>/.preview/`.
  public let directory: URL

  /// The store of the bundle at `bundle`. Nothing is read or written until it's used.
  public init(bundle: URL) {
    directory = bundle.appendingPathComponent(".preview", isDirectory: true)
  }

  /// `.preview/<key>.html` when it's there as a regular file, or `nil`.
  ///
  /// Only the file's metadata is looked at: a hit reads and writes nothing (PV-11).
  public func storedPage(forKey key: String) -> URL? {
    guard Self.isKey(key) else { return nil }
    let file = pageURL(forKey: key)
    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
    return file
  }

  /// The preview file in the store, whatever its key, or `nil` (§11.1, *Showing a bundle*, step 1:
  /// what a viewer shows while the bundle is being updated, when no key is computed).
  ///
  /// The store normally holds one. When two writers have each left one, the one modified last is
  /// returned. Only the directory's listing and its entries' metadata are read.
  public func anyStoredPage() -> URL? {
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
    guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
    else { return nil }
    let pages = entries.compactMap { entry -> (url: URL, modified: Date)? in
      let name = entry.lastPathComponent
      guard name.hasSuffix(".html"), Self.isKey(String(name.dropLast(5))),
        let values = try? entry.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
      else { return nil }
      // Named as `storedPage(forKey:)` names it, not as the listing spells the directory.
      return (directory.appendingPathComponent(name), values.contentModificationDate ?? .distantPast)
    }
    return pages.max { $0.modified < $1.modified }?.url
  }

  /// Stores `page` as `.preview/<key>.html` and removes everything else in `.preview/` except
  /// `.gitignore` (§11.1, *Storing*; PV-9, PV-10).
  ///
  /// `.preview/` is made if it isn't there, and `.preview/.gitignore` is written with the one
  /// line `*` if it's absent. The page goes to `<key>.html.<uuid>.tmp`, which is then renamed to
  /// `<key>.html`. Only after the rename succeeds is anything removed, so a failed write leaves
  /// the last preview where it was.
  ///
  /// - Returns: The page's file.
  /// - Throws: ``PreviewStoreError/invalidKey(_:)``; file-system errors making `.preview/`,
  ///   writing `.gitignore` or the page, or renaming it. Nothing is removed when it throws.
  @discardableResult
  public func store(_ page: PreviewPage) throws -> URL {
    guard Self.isKey(page.key) else { throw PreviewStoreError.invalidKey(page.key) }
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let gitignore = directory.appendingPathComponent(Self.gitignoreName)
    if !manager.fileExists(atPath: gitignore.path) {
      try Data("*\n".utf8).write(to: gitignore)
    }

    let file = pageURL(forKey: page.key)
    let temporary = directory.appendingPathComponent("\(page.key).html.\(UUID().uuidString).tmp")
    do {
      try Data(page.html.utf8).write(to: temporary)
      // rename(2) replaces an existing `<key>.html` in one step.
      guard rename(temporary.path, file.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      // Only this write's own file; the last preview stays.
      try? manager.removeItem(at: temporary)
      throw error
    }

    let keep: Set<String> = [file.lastPathComponent, Self.gitignoreName]
    for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where !keep.contains(name) {
      try? manager.removeItem(at: directory.appendingPathComponent(name))
    }
    return file
  }

  // MARK: - Internals

  static let gitignoreName = ".gitignore"

  private func pageURL(forKey key: String) -> URL {
    directory.appendingPathComponent(key + ".html")
  }

  /// 64 lowercase hexadecimal characters (§11.1).
  static func isKey(_ key: String) -> Bool {
    key.utf8.count == 64 && key.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }
}

/// Why ``PreviewStore/store(_:)`` refused a page.
public enum PreviewStoreError: Error, Equatable {
  /// The page's key isn't 64 lowercase hexadecimal characters, so it can't name a preview file.
  case invalidKey(String)
}

/// What ``DossierCore/DossierBundle/showPreview(template:)`` shows.
public struct PreviewResult: Sendable {
  /// The page's key (§11.1).
  public let key: String
  /// `true` when `.preview/<key>.html` was already there and nothing was built or written.
  public let hit: Bool
  /// The stored page, or `nil` when it was built but couldn't be stored (``storeError``).
  public let pageURL: URL?
  /// The page built this time, or `nil` on a hit. A viewer shows it from memory when
  /// ``pageURL`` is `nil`; it is self-contained (PV-7, PV-23).
  public let html: String?
  /// What the page's integrity banner lists, or `nil` on a hit, when no page was built: the
  /// stored page carries its own banner.
  public let banner: [Finding]?
  /// Why the built page couldn't be stored (a read-only volume, no permission), or `nil` (PV-23).
  public let storeError: (any Error)?
}

extension DossierBundle {
  /// §11.1's *Showing a bundle*, steps 2 to 4: computes the key; on a hit returns
  /// `.preview/<key>.html` and writes nothing; otherwise builds the page and stores it with
  /// ``PreviewStore/store(_:)``.
  ///
  /// When the page is built but can't be stored, this doesn't throw: the result has the HTML and
  /// a ``PreviewResult/storeError`` (PV-23).
  ///
  /// - Throws: What ``previewKey(template:)`` and ``previewPage(template:)`` throw, such as
  ///   ``DossierCore/CharacterDescriptionError`` with no `CHARACTER.md`. Nothing in the store is
  ///   removed when it throws.
  public func showPreview(template: PageTemplate) throws -> PreviewResult {
    let parts = try previewParts(template: template)
    let store = PreviewStore(bundle: url)
    if let hit = storedPreview(parts, in: store) { return hit }
    return try buildAndStorePreview(parts, in: store)
  }

  /// ``showPreview(template:)`` with ``DossierTemplate/current``.
  public func showPreview() throws -> PreviewResult {
    try showPreview(template: try DossierTemplate.current)
  }

  /// §11.1's *Showing a bundle*, steps 2 and 3 alone: computes the key and returns the hit, or
  /// `nil` on a miss. Nothing is built or written, so a viewer can call it where it can't build,
  /// such as on the main actor, and build only on a miss (PV-15).
  ///
  /// - Throws: What ``previewKey(template:)`` throws.
  public func storedPreview(template: PageTemplate) throws -> PreviewResult? {
    storedPreview(try previewParts(template: template), in: PreviewStore(bundle: url))
  }

  /// ``storedPreview(template:)`` with ``DossierTemplate/current``.
  public func storedPreview() throws -> PreviewResult? {
    try storedPreview(template: try DossierTemplate.current)
  }

  func storedPreview(_ parts: PreviewParts, in store: PreviewStore) -> PreviewResult? {
    store.storedPage(forKey: parts.key).map { file in
      PreviewResult(key: parts.key, hit: true, pageURL: file, html: nil, banner: nil, storeError: nil)
    }
  }

  /// Builds the page for `parts` and stores it, whether or not `.preview/<key>.html` is already
  /// there. A failure to store is in the result's ``PreviewResult/storeError``, not thrown (PV-23).
  ///
  /// - Throws: What ``previewPage(template:)`` throws.
  func buildAndStorePreview(_ parts: PreviewParts, in store: PreviewStore) throws -> PreviewResult {
    let page = try previewPage(parts)
    do {
      let file = try store.store(page)
      return PreviewResult(
        key: page.key, hit: false, pageURL: file, html: page.html, banner: page.banner, storeError: nil)
    } catch {
      return PreviewResult(
        key: page.key, hit: false, pageURL: nil, html: page.html, banner: page.banner, storeError: error)
    }
  }
}
