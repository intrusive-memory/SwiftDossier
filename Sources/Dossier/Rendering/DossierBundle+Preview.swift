import DossierCore
import Foundation

/// A page built for viewing only, from the bundle as it is on disk (``DossierBundle/previewPage()``).
public struct PreviewPage: Sendable {
  /// The page's text: one self-contained HTML file, with images and samples as `data:` URIs.
  public let html: String
  /// Names what the page was built from (``DossierBundle/previewKey()``).
  public let key: String
  /// What the page's integrity banner lists. A preview shows these instead of refusing.
  public let banner: [Finding]
}

extension DossierBundle {
  /// Bumped when the preview's own rules change, so a cached page built by older rules is
  /// rebuilt. The template's identity is part of the key already.
  static let previewRules = "1"

  /// The page, built from the bundle as it is now. Nothing is written.
  ///
  /// It is ``renderPage()``'s page with three differences, all of which let a viewer show a
  /// bundle a render would refuse:
  ///
  /// - Any page already in the bundle is ignored, current or not, and left where it is.
  /// - A file that doesn't match its `files` entry, or a listed file that's missing, is shown in
  ///   the banner rather than refusing. An image or sample that can't be read is left off.
  /// - The `CAST.md` member is optional. With none, the page has no role, tier or voice prompt;
  ///   ``openForPreview(at:)`` finds the member where a project's layout puts it.
  ///
  /// The selected `description` asset isn't required either: `CHARACTER.md` on disk is what's shown.
  ///
  /// - Throws: ``DossierCore/CharacterDescriptionError`` when `CHARACTER.md` is missing or isn't
  ///   UTF-8, since then there is nothing to show; template and resource errors.
  public func previewPage() throws -> PreviewPage {
    let parts = try previewParts()
    return try previewPage(parts)
  }

  /// A name for what ``previewPage()`` would build now: a hash of every file in the bundle but
  /// the page, the `CAST.md` member, the template and the preview's rules. Any change to them
  /// changes it, so a page cached under it is never shown out of date.
  ///
  /// It reads and hashes every file, as a render does, and builds nothing.
  public func previewKey() throws -> String {
    try previewParts().key
  }

  /// Opens a bundle for ``previewPage()``, with the `CAST.md` member when one can be found.
  ///
  /// `CAST.md` is looked for in the bundle's parent directory and then its grandparent, as
  /// `dossier render` does, and the member is the one whose `manifest:` points at this bundle. A
  /// `CAST.md` that's missing or unreadable, or that has no such member, gives a bundle with no
  /// member, not an error.
  ///
  /// - Throws: What ``open(at:member:)`` throws.
  public static func openForPreview(at url: URL) throws -> DossierBundle {
    try open(at: url, member: Self.previewMember(of: url))
  }

  // MARK: - Internals

  struct PreviewParts {
    let scan: BundleScan
    let pages: [String]
    let template: PageTemplate
    let key: String
  }

  func previewParts() throws -> PreviewParts {
    let template = try DossierTemplate.current
    let pages = previewPagePaths()
    let scan = try BundleScan(bundle: url, excluding: pages, allowingEmpty: true)
    let key = Checksum.sha256(
      [
        "dossier-preview", Self.previewRules, template.version, template.sha256,
        scan.diskChecksum(), member?.canonicalJSON ?? "",
      ].joined(separator: "\n"))
    return PreviewParts(scan: scan, pages: pages, template: template, key: key)
  }

  func previewPage(_ parts: PreviewParts) throws -> PreviewPage {
    let current = manifest
    let embedded = try Self.embeddedManifest(of: current, scan: parts.scan, pages: parts.pages)
    let banner =
      (try? Self.bannerFindings(
        of: current, at: url, pages: parts.pages, member: member, template: parts.template)) ?? []

    let document = try Self.readDescription(in: url, excluding: parts.pages)
    var record = JSONObject()
    record["formatVersion"] = .integer(Int64(try DossierTabs.bundled().formatVersion))
    record["character"] = .string(current.character)
    record["castMember"] = member?.normalForm ?? .object(JSONObject())
    // A front matter that can't be read still leaves the body to show.
    record["frontMatter"] = .object((try? Self.frontMatterObject(of: document)) ?? JSONObject())
    record["body"] = .string(document.body)
    record["manifest"] = .object(embedded.json)

    let view = DossierBundle(url: url, manifest: embedded, member: member)
    let filler = try PageFiller(
      bundle: view, record: record, findings: banner, document: document, template: parts.template,
      excluding: parts.pages, lenient: true)
    return PreviewPage(html: try filler.html(), key: parts.key, banner: filler.bannerFindings)
  }

  /// Every page the bundle holds, which a preview neither reads nor shows: the `dossier` assets,
  /// and any HTML file at the bundle's top level (§11: the page is the bundle's only HTML file),
  /// registered or not.
  func previewPagePaths() -> [String] {
    let registered = manifest.assets.filter { $0.kind == .dossier }.map(\.path)
    let loose = BundleInventory(bundle: url).visible.map(\.path).filter { path in
      !path.contains("/") && ["html", "htm"].contains((path as NSString).pathExtension.lowercased())
    }
    var seen: Set<[UInt8]> = []
    return (registered + loose).filter { seen.insert(BundleInventory.key($0)).inserted }
  }

  private static func previewMember(of url: URL) -> Cast.Member? {
    let target = url.resolvingSymlinksInPath().standardizedFileURL.path
    let parent = url.deletingLastPathComponent()
    for directory in [parent, parent.deletingLastPathComponent()] {
      let candidate = directory.appendingPathComponent("CAST.md")
      guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
      guard let cast = try? Cast.load(candidate) else { return nil }
      return cast.members.first { member in
        cast.manifestURL(of: member)?.deletingLastPathComponent().resolvingSymlinksInPath()
          .standardizedFileURL.path == target
      }
    }
    return nil
  }
}
