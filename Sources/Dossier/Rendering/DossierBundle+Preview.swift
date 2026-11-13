import DossierCore
import Foundation

/// A page built for viewing only, from the bundle as it is on disk (``DossierBundle/previewPage(template:)``).
public struct PreviewPage: Sendable {
  /// The page's text: one self-contained HTML file, with images and samples as `data:` URIs.
  public let html: String
  /// Names what the page was built from (``DossierBundle/previewKey(template:)``).
  public let key: String
  /// What the page's integrity banner lists. A preview shows these instead of refusing.
  public let banner: [Finding]
}

extension DossierBundle {
  /// §11.1's version: the second line of the preview key. It changes when the rules for
  /// building a preview change, and every key changes with it.
  public static let previewVersion = "1"

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
  /// - Parameter template: The template the page is built with; its `sha256` is part of the
  ///   page's ``PreviewPage/key``, which is ``previewKey(template:)`` for the same template.
  /// - Throws: ``DossierCore/CharacterDescriptionError`` when `CHARACTER.md` is missing or isn't
  ///   UTF-8, since then there is nothing to show; template and resource errors.
  public func previewPage(template: PageTemplate) throws -> PreviewPage {
    try previewPage(try previewParts(template: template))
  }

  /// ``previewPage(template:)`` with ``DossierTemplate/current``.
  public func previewPage() throws -> PreviewPage {
    try previewPage(template: try DossierTemplate.current)
  }

  /// §11.1's key for the page ``previewPage(template:)`` would build: the SHA-256 of five
  /// LF-terminated lines, `dossier-preview`, ``previewVersion``, the SHA-256 of `manifest.json`'s
  /// bytes as stored, the member's hash (§7; empty with no member), and the template's `sha256`.
  ///
  /// It reads `manifest.json` and no other file (PV-2), so an edit that bypasses a writer, such
  /// as `CHARACTER.md` saved from a text editor, leaves the key as it was (§11.1).
  ///
  /// - Throws: File-system errors reading `manifest.json`.
  public func previewKey(template: PageTemplate) throws -> String {
    Self.previewKey(
      manifestBytes: try Data(contentsOf: url.appendingPathComponent("manifest.json")),
      member: member, template: template)
  }

  /// ``previewKey(template:)`` with ``DossierTemplate/current``.
  public func previewKey() throws -> String {
    try previewKey(template: try DossierTemplate.current)
  }

  /// Opens a bundle for ``previewPage(template:)``, with its member of the project's `CAST.md`.
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

  /// The template a preview is built with, and its key. Cheap: only `manifest.json` is read.
  struct PreviewParts {
    let template: PageTemplate
    let key: String
  }

  func previewParts(template: PageTemplate) throws -> PreviewParts {
    // §16.6: a viewer builds no preview of a location bundle; the LOCATIONS page shows it.
    guard !isLocation else { throw DossierWriteError.kindNotWritable("dossier, in a location bundle (§16.6)") }
    return PreviewParts(template: template, key: try previewKey(template: template))
  }

  func previewParts() throws -> PreviewParts {
    try previewParts(template: try DossierTemplate.current)
  }

  static func previewKey(manifestBytes: Data, member: Cast.Member?, template: PageTemplate) -> String {
    let lines = [
      "dossier-preview", previewVersion, Checksum.sha256(manifestBytes), member?.hash ?? "",
      template.sha256,
    ]
    return Checksum.sha256(lines.map { $0 + "\n" }.joined())
  }

  func previewPage(_ parts: PreviewParts) throws -> PreviewPage {
    let current = manifest
    let pages = previewPagePaths()
    let scan = try BundleScan(bundle: url, excluding: pages, allowingEmpty: true)
    let embedded = try Self.embeddedManifest(of: current, scan: scan, pages: pages)
    let banner =
      (try? Self.bannerFindings(
        of: current, at: url, pages: pages, member: member, template: parts.template)) ?? []

    let document = try Self.readDescription(in: url, excluding: pages)
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
      excluding: pages, lenient: true)
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
  static func member(pointingAt url: URL, in castURL: URL?) -> Cast.Member? {
    guard let castURL, let cast = try? Cast.load(castURL) else { return nil }
    let target = url.resolvingSymlinksInPath().standardizedFileURL.path
    return cast.members.first { member in
      cast.manifestURL(of: member)?.deletingLastPathComponent().resolvingSymlinksInPath()
        .standardizedFileURL.path == target
    }
  }
}
