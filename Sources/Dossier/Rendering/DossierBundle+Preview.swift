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
  /// - The `CAST.md` member is optional. With none, the record's `castMember` is `null` and the
  ///   page has no role, tier or voice prompt. ``openForPreview(at:cast:)`` takes the member from
  ///   the project's `CAST.md`, which its caller passes in.
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

  /// Opens a bundle for ``previewPage()``, with its member of the project's `CAST.md`.
  ///
  /// A project has one `CAST.md`, and the caller passes it in as `cast`; nothing looks for one.
  /// The member is the one whose `manifest:` points at this bundle (§3, *Resolving a pointer*,
  /// compared as ``DossierCore/Cast/manifestURL(of:)`` gives it). A `cast` that's `nil`, missing
  /// or unreadable, or that has no such member, gives a bundle with no member, not an error.
  ///
  /// - Throws: What ``open(at:member:)`` throws.
  public static func openForPreview(at url: URL, cast: URL?) throws -> DossierBundle {
    try open(at: url, member: Self.member(pointingAt: url, in: cast))
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
    record["castMember"] = member?.normalForm ?? .null
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

  /// The member of the `CAST.md` at `castURL` whose `manifest:` points at the bundle at `url`,
  /// or `nil`. Only that file is read.
  private static func member(pointingAt url: URL, in castURL: URL?) -> Cast.Member? {
    guard let castURL, let cast = try? Cast.load(castURL) else { return nil }
    let target = url.resolvingSymlinksInPath().standardizedFileURL.path
    return cast.members.first { member in
      cast.manifestURL(of: member)?.deletingLastPathComponent().resolvingSymlinksInPath()
        .standardizedFileURL.path == target
    }
  }
}
