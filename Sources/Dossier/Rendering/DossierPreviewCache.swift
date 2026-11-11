import DossierCore
import Foundation

/// Preview pages (``DossierCore/DossierBundle/previewPage()``) kept on disk, outside the bundles
/// they show, so a viewer can load one as a file and never writes into a project.
///
/// A page is filed under its ``DossierCore/DossierBundle/previewKey(template:)`` (§11.1), which
/// changes when `manifest.json`, the `CAST.md` member or the template does. An edit made through a
/// writer (a new image, a changed `CHARACTER.md`) changes `manifest.json`, so it's a miss that
/// builds the page again; an edit that bypasses a writer is not seen. Each bundle keeps only its
/// latest page.
///
/// Every page is self-contained (images and samples are `data:` URIs), so a web view needs read
/// access to this directory only, not to the project.
public struct DossierPreviewCache: Sendable {
  /// Where the pages are kept.
  public let directory: URL

  /// The default directory: `Dossier Previews` in the user's Caches directory, which a sandboxed
  /// app gets inside its own container.
  public static var defaultDirectory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dossier Previews", isDirectory: true)
  }

  /// A cache in `directory`, which is made when a page is first written.
  public init(directory: URL = DossierPreviewCache.defaultDirectory) {
    self.directory = directory
  }

  /// The preview page of the bundle at `url`, built and written here if it isn't already.
  ///
  /// The bundle is opened with ``DossierCore/DossierBundle/openForPreview(at:cast:)``, so the page
  /// has its member of the project's `CAST.md` at `cast`, when there is one. Reads `manifest.json` for the key; reads the rest of the
  /// bundle and builds the page only on a miss. Call it off the main thread.
  ///
  /// - Returns: The page's file.
  /// - Throws: What ``DossierCore/DossierBundle/openForPreview(at:cast:)`` and
  ///   ``DossierCore/DossierBundle/previewPage()`` throw, and file-system errors writing the page.
  public func pageURL(forBundleAt url: URL, cast: URL?) throws -> URL {
    try pageURL(for: try DossierBundle.openForPreview(at: url, cast: cast))
  }

  /// The preview page of `bundle`, built and written here if it isn't already.
  public func pageURL(for bundle: DossierBundle) throws -> URL {
    let parts = try bundle.previewParts()
    let folder = folder(for: bundle.url)
    let file = folder.appendingPathComponent(parts.key + ".html")
    if FileManager.default.fileExists(atPath: file.path) { return file }

    let page = try bundle.previewPage(parts)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(page.html.utf8).write(to: file, options: .atomic)
    removeOthers(in: folder, keeping: file.lastPathComponent)
    return file
  }

  /// Removes every page.
  public func removeAll() throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }

  /// One folder for each bundle, named by a hash of its path.
  private func folder(for bundleURL: URL) -> URL {
    let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
    return directory.appendingPathComponent(String(Checksum.sha256(path).prefix(32)), isDirectory: true)
  }

  private func removeOthers(in folder: URL, keeping name: String) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
    for other in names where other != name {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(other))
    }
  }
}
