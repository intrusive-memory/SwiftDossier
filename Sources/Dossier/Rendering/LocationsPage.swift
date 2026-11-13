import DossierCore
import Foundation
import ImageIO

/// The LOCATIONS page template this package carries (§16.6, DF-99), copied byte for byte from the
/// pinned dossier-format revision's `template-locations/`, with the version and hash published
/// beside it. It is versioned and hashed apart from ``DossierTemplate``.
///
/// The hash is `template-locations/README.md` rule 1's, which also covers `template/dossier.css`
/// and `template/fonts.css`. It's read from `VERSION.json`, not computed; the tests compute it.
public enum LocationsTemplate {
  private struct Published: Decodable, Sendable {
    let version: String
    let sha256: String
  }

  private static let published: Result<Published, DossierError> = {
    guard let data = try? data(at: "VERSION.json"),
      let published = try? JSONDecoder().decode(Published.self, from: data)
    else { return .failure(.resourceUnreadable("template-locations/VERSION.json")) }
    return .success(published)
  }()

  /// The version the template is published with.
  ///
  /// - Throws: ``DossierCore/DossierError/resourceUnreadable(_:)`` when `VERSION.json` can't be read.
  public static var version: String { get throws { try published.get().version } }

  /// The hash the template is published with: the last line of every LOCATIONS page key.
  ///
  /// - Throws: ``DossierCore/DossierError/resourceUnreadable(_:)`` when `VERSION.json` can't be read.
  public static var sha256: String { get throws { try published.get().sha256 } }

  /// The template's identity.
  ///
  /// - Throws: ``DossierCore/DossierError/resourceUnreadable(_:)`` when `VERSION.json` can't be read.
  public static var current: PageTemplate {
    get throws { PageTemplate(version: try version, sha256: try sha256) }
  }

  /// The bundled `template-locations/` directory: its files that rule 1 hashes, and `VERSION.json`.
  /// The two files it shares with the dossier template are in ``DossierTemplate/directory``.
  ///
  /// - Throws: ``DossierCore/DossierError/resourceUnreadable(_:)`` when the bundle has no resource directory.
  public static var directory: URL {
    get throws {
      guard let root = DossierResources.bundle.resourceURL else {
        throw DossierError.resourceUnreadable("template-locations/")
      }
      return root.appendingPathComponent("template-locations", isDirectory: true)
    }
  }

  /// A template file's bytes.
  ///
  /// - Parameter path: The `/`-separated path under `template-locations/`, such as `skeleton.html`.
  /// - Throws: ``DossierCore/DossierError/resourceUnreadable(_:)`` when there's no such file.
  public static func data(at path: String) throws -> Data {
    guard let data = try? Data(contentsOf: try directory.appendingPathComponent(path)) else {
      throw DossierError.resourceUnreadable("template-locations/\(path)")
    }
    return data
  }
}

/// A built LOCATIONS page (§16.6).
public struct LocationsPage: Sendable {
  /// The page's text: one self-contained HTML file, with images as `data:` URIs and no script.
  public let html: String
  /// Names what the page was built from (``DossierCore/LocationsIndex/locationsPageKey(title:template:)``).
  public let key: String
}

/// What showing the LOCATIONS page gives (§16.6, *Showing the page*).
public struct LocationsPageResult: Sendable {
  /// The page's key.
  public let key: String
  /// `true` when `.locations-page/<key>.html` was already there and nothing was built or written.
  public let hit: Bool
  /// The stored page, or `nil` when it was built but couldn't be stored (``storeError``).
  public let pageURL: URL?
  /// The page built this time, or `nil` on a hit. A viewer shows it from memory when ``pageURL``
  /// is `nil`; it is self-contained.
  public let html: String?
  /// Why the built page couldn't be stored, or `nil`. A viewer MAY show the page anyway (§16.6).
  public let storeError: (any Error)?
}

/// A project's LOCATIONS pages, kept in `.locations-page/` in the directory holding the locations
/// index (§16.6, *The store*): §11.1's store, with `.locations-page/` for `.preview/`.
///
/// A page file is a regular file directly in `.locations-page/` named `<key>.html`, where `<key>`
/// is 64 lowercase hexadecimal characters. Nothing else in the store is a page, and nothing is
/// ever written in a bundle.
public struct LocationsPageStore: Sendable {
  private let store: PreviewStore

  /// `<index directory>/.locations-page/`.
  public var directory: URL { store.directory }

  /// The store beside a locations index. Nothing is read or written until it's used.
  public init(index: LocationsIndex) {
    store = PreviewStore(
      storeDirectory: index.directory.appendingPathComponent(".locations-page", isDirectory: true))
  }

  /// `.locations-page/<key>.html` when it's there as a regular file, or `nil`. Only metadata is read.
  public func storedPage(forKey key: String) -> URL? { store.storedPage(forKey: key) }

  /// The page file in the store, whatever its key, or `nil`: what a viewer shows while a bundle an
  /// entry points at is being updated (§16.6 step 1). The one modified last, when there are two.
  public func anyStoredPage() -> URL? { store.anyStoredPage() }

  /// Stores `page` as `.locations-page/<key>.html` and only then removes everything else in the
  /// store except `.gitignore`, which is written with the one line `*` when absent. A temporary
  /// file is renamed into place; nothing is removed when the write fails.
  ///
  /// - Throws: ``PreviewStoreError/invalidKey(_:)``, and file-system errors.
  @discardableResult
  public func store(_ page: LocationsPage) throws -> URL { try store.store(key: page.key, html: page.html) }
}

extension LocationsIndex {
  /// §16.6's version: the second line of the LOCATIONS page key.
  public static let locationsPageVersion = "1"

  /// The `id` of a location's section on the LOCATIONS page (§16.7): `location-` and the first 8
  /// hexadecimal characters of the SHA-256 of the entry's `location` as UTF-8. A host scrolls to
  /// it when a location bundle is selected.
  public static func sectionID(forLocation location: String) -> String {
    "location-" + Checksum.sha256(location).prefix(8)
  }

  /// The LOCATIONS page key (§16.6): the SHA-256 of `dossier-locations-page`, the version, the
  /// hash of the index's bytes, the hash of the project's title (or nothing), one line per entry
  /// holding the hash of the `manifest.json` its pointer reaches (or nothing), and the template's
  /// hash, each line ending in LF. Only the index and the manifests are read.
  ///
  /// - Parameters:
  ///   - title: `PROJECT.md`'s title (``DossierCore/DossierProject/title``), `nil` when it has none.
  ///   - template: The current template, usually ``LocationsTemplate/current``.
  /// - Throws: When the index can't be read.
  public func locationsPageKey(title: String?, template: PageTemplate) throws -> String {
    var lines = ["dossier-locations-page", Self.locationsPageVersion, Checksum.sha256(try Data(contentsOf: url))]
    lines.append(title.flatMap { $0.isEmpty ? nil : Checksum.sha256($0) } ?? "")
    for entry in entries {
      lines.append(manifestData(of: entry).map(Checksum.sha256) ?? "")
    }
    lines.append(template.sha256)
    return Checksum.sha256(lines.map { $0 + "\n" }.joined())
  }

  /// The bytes of the `manifest.json` an entry's pointer reaches, or `nil`.
  private func manifestData(of entry: Entry) -> Data? {
    guard let pointer = entry.pointer, pointer.namesManifest, let file = manifestURL(of: entry),
      (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    else { return nil }
    return try? Data(contentsOf: file)
  }

  /// Builds the LOCATIONS page from the index and the bundles as they are on disk (§16.6). Nothing
  /// is written. A file that's missing or can't be decoded is left out; a bundle that can't be
  /// shown, or an entry with no bundle, says so in its section.
  ///
  /// - Parameter title: `PROJECT.md`'s title, `nil` when it has none.
  /// - Throws: When a bundled resource can't be read, or the index can't be.
  public func buildLocationsPage(title: String?) throws -> LocationsPage {
    let template = try LocationsTemplate.current
    let key = try locationsPageKey(title: title, template: template)
    return LocationsPage(html: try LocationsPageBuilder(index: self, title: title, key: key, template: template).html(), key: key)
  }

  /// §16.6's *Showing the page*, steps 2 to 4: computes the key; on a hit returns the stored file
  /// and writes nothing; otherwise builds the page and stores it. A page that's built and can't be
  /// stored is in the result with its ``LocationsPageResult/storeError``; this doesn't throw for it.
  ///
  /// Step 1 is the caller's: while ``isUpdatingABundle(at:)`` is `true`, a viewer shows
  /// ``LocationsPageStore/anyStoredPage()`` and builds nothing.
  ///
  /// - Parameter title: `PROJECT.md`'s title, `nil` when it has none.
  public func showLocationsPage(title: String?) throws -> LocationsPageResult {
    if let hit = try storedLocationsPage(title: title) { return hit }
    return try rebuildLocationsPage(title: title)
  }

  /// Steps 2 and 3 alone: the stored page for the current key, or `nil` on a miss. Nothing is built
  /// or written.
  public func storedLocationsPage(title: String?) throws -> LocationsPageResult? {
    let key = try locationsPageKey(title: title, template: try LocationsTemplate.current)
    return LocationsPageStore(index: self).storedPage(forKey: key).map {
      LocationsPageResult(key: key, hit: true, pageURL: $0, html: nil, storeError: nil)
    }
  }

  /// §16.6's *Rebuild*: builds and stores the page even when `.locations-page/<key>.html` exists.
  /// Nothing is written in a bundle.
  public func rebuildLocationsPage(title: String?) throws -> LocationsPageResult {
    let page = try buildLocationsPage(title: title)
    do {
      let file = try LocationsPageStore(index: self).store(page)
      return LocationsPageResult(key: page.key, hit: false, pageURL: file, html: page.html, storeError: nil)
    } catch {
      return LocationsPageResult(key: page.key, hit: false, pageURL: nil, html: page.html, storeError: error)
    }
  }

  /// Whether a bundle an entry points at is being updated (§5.7): §16.6 step 1, when a viewer
  /// shows the stored page and goes no further.
  public func isUpdatingABundle(at now: Date = Date()) -> Bool {
    entries.contains { entry in
      guard let bundle = try? openBundle(for: entry) else { return false }
      return bundle.updateStatus(at: now).isUpdating
    }
  }
}

extension DossierProject {
  /// §16.6 for this project: the LOCATIONS page of the index `PROJECT.md` names, with its title,
  /// shown as ``DossierCore/LocationsIndex/showLocationsPage(title:)`` shows it. `nil` when the
  /// project has no readable locations index (§16.2), where there is no page (§16.7).
  public func showLocationsPage() throws -> LocationsPageResult? {
    guard let index = discoverLocations().index else { return nil }
    return try index.showLocationsPage(title: title)
  }
}

/// Fills `template-locations/` for one index (§16.6, `template-locations/README.md`).
private struct LocationsPageBuilder {
  let index: LocationsIndex
  let title: String?
  let key: String
  let template: PageTemplate

  private let fragments: [String: String]
  private let copies: LocationsPageCopies

  init(index: LocationsIndex, title: String?, key: String, template: PageTemplate) throws {
    self.index = index
    self.title = title.flatMap { $0.isEmpty ? nil : $0 }
    self.key = key
    self.template = template
    fragments = PageText.fragments(in: String(decoding: try LocationsTemplate.data(at: "fragments.html"), as: UTF8.self))
    copies = try LocationsPageCopies(data: try LocationsTemplate.data(at: "page-copies.json"))
  }

  private func fill(_ name: String, _ values: [String: String]) throws -> String {
    guard let fragment = fragments[name] else { throw DossierError.resourceUnreadable("template-locations: no fragment \(name)") }
    return try PageText.filling(fragment, values)
  }

  func html() throws -> String {
    var sections: [String] = []
    var anchors: Set<String> = []
    for entry in index.entries {
      sections.append(try section(entry, anchors: &anchors))
    }
    let count = index.entries.count
    let text = { (data: Data) in String(decoding: data, as: UTF8.self) }
    return try PageText.filling(
      text(try LocationsTemplate.data(at: "skeleton.html")),
      [
        "template.version": PageText.escaped(template.version),
        "template.sha256": PageText.escaped(template.sha256),
        "key": PageText.escaped(key),
        "title": PageText.escaped(title.map { "\($0) · Locations" } ?? "Locations"),
        "include:fonts.css": text(try DossierTemplate.data(at: "fonts.css")),
        "include:dossier.css": text(try DossierTemplate.data(at: "dossier.css")),
        "include:locations.css": text(try LocationsTemplate.data(at: "locations.css")),
        "project": try title.map { try fill("project", ["text": PageText.escaped($0)]) } ?? "",
        "count": PageText.escaped("\(count) location" + (count == 1 ? "" : "s")),
        "locations": sections.joined(separator: "\n"),
      ])
  }

  private func section(_ entry: LocationsIndex.Entry, anchors: inout Set<String>) throws -> String {
    let anchor = LocationsIndex.sectionID(forLocation: entry.location)
    let id = anchors.insert(anchor).inserted ? try fill("id", ["id": anchor]) : ""
    var heading = entry.location
    let content: String
    if entry.pointer == nil {
      content = try fill("missing", ["text": PageText.escaped("No bundle yet.")])
    } else if let bundle = showableBundle(entry) {
      if let name = bundle.manifest.location?.name, !name.isEmpty { heading = name }
      content = try self.content(of: bundle)
    } else {
      content = try fill("missing", ["text": PageText.escaped("This location's bundle can't be shown.")])
    }
    return try fill(
      "location",
      [
        "id": id, "name": PageText.escaped(entry.location), "heading": PageText.escaped(heading),
        "content": content,
      ])
  }

  /// §16.6: the pointer reaches a `manifest.json` that is a JSON object with `manifestVersion` 2
  /// and `dossierType` `location`, in a `.dossier` directory.
  private func showableBundle(_ entry: LocationsIndex.Entry) -> DossierBundle? {
    guard let pointer = entry.pointer, pointer.namesManifest, let manifest = index.manifestURL(of: entry) else {
      return nil
    }
    let directory = manifest.deletingLastPathComponent()
    guard directory.lastPathComponent.hasSuffix(".dossier"), let bundle = try? DossierBundle.open(at: directory),
      bundle.manifest.manifestVersion == 2, bundle.isLocation
    else { return nil }
    return bundle
  }

  private func content(of bundle: DossierBundle) throws -> String {
    var out = ""
    // A LOCATION.md that is missing or isn't UTF-8 is left out (§16.6).
    if let data = try? Data(contentsOf: bundle.url.appendingPathComponent("LOCATION.md")),
      let text = String(data: data, encoding: .utf8)
    {
      let body = FrontMatter.split(text)?.body ?? text
      let footnotes = PageFootnotes(body: body)
      let markdown = LocationMarkdown(
        footnotes: footnotes, mark: { try fill("mark", ["number": String($0)]) },
        markSeparator: { try fill("markSeparator", [:]) })
      let markup = try markdown.markup(ofBody: body)
      if !markup.isEmpty { out += try fill("description", ["markup": markup]) }
      let items = try footnotes.sources.map { try fill("sourceItem", ["text": PageText.escaped($0)]) }.joined()
      if !items.isEmpty { out += try fill("sources", ["items": items]) }
    }

    var plates: [String] = []
    for plate in bundle.selectedPlates {
      guard let variant = plate.variant, let file = bundle.fileURL(forPath: plate.path),
        let data = try? Data(contentsOf: file), let copy = copies.plate(of: data)
      else { continue }
      plates.append(try imageItem(label: variant, copy: copy))
    }
    if !plates.isEmpty { out += try fill("plates", ["items": plates.joined()]) }

    var views: [String] = []
    let selected = bundle.manifest.assets.filter { $0.kind == .view && $0.status == .selected && $0.variant != nil }
    for view in selected.sorted(by: { ($0.variant ?? "").precedesInByteOrder($1.variant ?? "") }) {
      guard let variant = view.variant, let file = bundle.fileURL(forPath: view.path),
        let data = try? Data(contentsOf: file), let copy = copies.view(of: data)
      else { continue }
      views.append(try imageItem(label: variant, copy: copy))
    }
    if !views.isEmpty { out += try fill("views", ["items": views.joined()]) }
    return out
  }

  private func imageItem(label: String, copy: LocationsPageCopies.Copy) throws -> String {
    let img = try fill(
      "img",
      [
        "label": PageText.escaped(label), "src": "data:image/jpeg;base64," + copy.jpeg.base64EncodedString(),
        "width": String(copy.width), "height": String(copy.height),
      ])
    return try fill("imageItem", ["img": img, "label": PageText.escaped(label)])
  }
}

/// `template-locations/page-copies.json` and rule 4: a plate scaled to cover its size and cropped
/// at the centre, a view scaled to the largest size inside its box, keeping its shape; JPEG.
private struct LocationsPageCopies {
  struct Copy {
    let jpeg: Data
    let width: Int
    let height: Int
  }

  private let quality: Double
  private let plateSize: PageCopySettings.Size
  private let viewBox: PageCopySettings.Size

  /// - Throws: ``DossierCore/DossierError/resourceUnreadable(_:)`` when the file isn't this shape.
  init(data: Data) throws {
    let name = "template-locations/page-copies.json"
    guard let root = (try? JSONValue.parse(data))?.objectValue, root["format"]?.stringValue == "jpeg",
      let quality = root["quality"]?.doubleValue, (0...100).contains(quality),
      let sizes = root["sizes"]?.objectValue
    else { throw DossierError.resourceUnreadable(name) }
    func size(_ key: String, fit: String) throws -> PageCopySettings.Size {
      guard let object = sizes[key]?.objectValue, object["fit"]?.stringValue == fit,
        let width = object["width"]?.intValue, let height = object["height"]?.intValue, width > 0, height > 0
      else { throw DossierError.resourceUnreadable(name) }
      return PageCopySettings.Size(width: Int(width), height: Int(height))
    }
    self.quality = quality / 100
    plateSize = try size("plate", fit: "cover")
    viewBox = try size("view", fit: "inside")
  }

  func plate(of data: Data) -> Copy? {
    PageCopy.jpeg(of: data, size: plateSize, quality: quality).map {
      Copy(jpeg: $0, width: plateSize.width, height: plateSize.height)
    }
  }

  /// Rule 4: the scale is the smaller of the box's width ÷ width and height ÷ height, and each
  /// side is rounded half up, and is at least 1. Drawn at that size, the cover scale is the same
  /// scale, so nothing is cropped beyond the rounding.
  func view(of data: Data) -> Copy? {
    guard let size = LocationsPageCopies.pixelSize(of: data) else { return nil }
    let scale = min(Double(viewBox.width) / Double(size.width), Double(viewBox.height) / Double(size.height))
    let width = max(1, Int((Double(size.width) * scale + 0.5).rounded(.down)))
    let height = max(1, Int((Double(size.height) * scale + 0.5).rounded(.down)))
    let target = PageCopySettings.Size(width: width, height: height)
    return PageCopy.jpeg(of: data, size: target, quality: quality).map { Copy(jpeg: $0, width: width, height: height) }
  }

  private static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options),
      let image = CGImageSourceCreateImageAtIndex(source, 0, options), image.width > 0, image.height > 0
    else { return nil }
    return (image.width, image.height)
  }
}

/// `template-locations/README.md` rules 2 and 3: `LOCATION.md`'s body as the dossier template's
/// Markdown (rule 3 there), with `#` lines dropped, `##` read as `###`, tables, and code spans.
/// Marks aren't links.
private struct LocationMarkdown {
  let footnotes: PageFootnotes
  let mark: (Int) throws -> String
  let markSeparator: () throws -> String

  private enum Piece {
    case text(String)
    case code(String)
  }

  /// The body as markup: runs of lines as blocks, and each table where it starts.
  func markup(ofBody body: String) throws -> String {
    let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    var out = ""
    var run: [String] = []
    func flush() throws {
      if !run.isEmpty { out += try markup(PageMarkdown.blocks(of: run.joined(separator: "\n"))) }
      run = []
    }
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if Self.isTableRow(line), index + 1 < lines.count, Self.isDelimiterRow(lines[index + 1]) {
        try flush()
        let header = Self.cells(of: line)
        var rows: [[String]] = []
        var end = index + 2
        while end < lines.count, Self.isTableRow(lines[end]) {
          let cells = Array(Self.cells(of: lines[end]).prefix(header.count))
          rows.append(cells + Array(repeating: "", count: header.count - cells.count))
          end += 1
        }
        out += "<table><thead><tr>" + (try header.map { "<th>\(try inline(cell: $0))</th>" }.joined())
          + "</tr></thead><tbody>"
          + (try rows.map { row in "<tr>" + (try row.map { "<td>\(try inline(cell: $0))</td>" }.joined()) + "</tr>" }
            .joined())
          + "</tbody></table>"
        index = end
        continue
      }
      if line.hasPrefix("# ") {
        run.append("")  // The section's heading already names the location.
      } else if line.hasPrefix("## ") {
        run.append("### " + line.dropFirst(3))
      } else {
        run.append(line)
      }
      index += 1
    }
    try flush()
    return out
  }

  /// A line whose first non-space character is `|`.
  private static func isTableRow(_ line: String) -> Bool {
    line.drop { $0 == " " || $0 == "\t" }.first == "|"
  }

  /// A row every cell of which matches `:?-+:?`.
  private static func isDelimiterRow(_ line: String) -> Bool {
    guard isTableRow(line) else { return false }
    return cells(of: line).allSatisfy { cell in
      var body = Substring(cell)
      if body.first == ":" { body = body.dropFirst() }
      if body.last == ":" { body = body.dropLast() }
      return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }
  }

  /// The line trimmed, its first `|` and any last `|` removed, split at each `|`, each cell trimmed.
  private static func cells(of line: String) -> [String] {
    var text = line.trimmingCharacters(in: .whitespaces).dropFirst()
    if text.hasSuffix("|") { text = text.dropLast() }
    return text.split(separator: "|", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }

  private func inline(cell: String) throws -> String {
    try inline([PageMarkdown.Line(text: cell, isCode: false)])
  }

  private func markup(_ blocks: [PageMarkdown.Block]) throws -> String {
    var out = ""
    var inList = false
    for block in blocks {
      var isItem = false
      if case .item = block { isItem = true }
      if isItem, !inList { out += "<ul>" }
      if !isItem, inList { out += "</ul>" }
      inList = isItem
      switch block {
      case .heading(let lines): out += "<h4>\(try inline(lines))</h4>"
      case .item(let lines, let quote):
        out += "<li>\(try inline(lines))\(try quote.map { "<blockquote>\(try inline($0))</blockquote>" } ?? "")</li>"
      case .paragraph(let lines): out += "<p>\(try inline(lines))</p>"
      case .quote(let lines): out += "<blockquote>\(try inline(lines))</blockquote>"
      }
    }
    if inList { out += "</ul>" }
    return out
  }

  /// A line cut at its code spans: a run of text between two backticks on one line, with at least
  /// one character and no backtick between them. A backtick that opens none is text.
  private static func pieces(of line: String) -> [Piece] {
    let characters = Array(line)
    var pieces: [Piece] = []
    var text = ""
    var index = 0
    while index < characters.count {
      if characters[index] == "`", let close = characters[(index + 1)...].firstIndex(of: "`"), close > index + 1 {
        if !text.isEmpty { pieces.append(.text(text)) }
        text = ""
        pieces.append(.code(String(characters[(index + 1)..<close])))
        index = close + 1
      } else {
        text.append(characters[index])
        index += 1
      }
    }
    if !text.isEmpty { pieces.append(.text(text)) }
    return pieces
  }

  /// Rule 2's inline markup: escape, then code spans, then bold, then emphasis, then marks. A code
  /// span's text takes no other markup, and `**` and `*` don't span it: each run of text between
  /// code spans is paired on its own, and may span a line break in its block.
  private func inline(_ lines: [PageMarkdown.Line]) throws -> String {
    var runs: [[Int32]] = [[]]
    var codes: [String] = []
    func appendText(_ text: String) {
      for byte in text.utf8 {
        var escaped: [UInt8] = []
        PageText.appendEscaped(byte, to: &escaped)
        runs[runs.count - 1].append(contentsOf: escaped.map(Int32.init))
      }
    }
    for (position, line) in lines.enumerated() {
      if position > 0 { runs[runs.count - 1].append(0x0A) }
      guard !line.isCode else {
        appendText(line.text)
        continue
      }
      for piece in Self.pieces(of: line.text) {
        switch piece {
        case .code(let text):
          codes.append(PageText.escaped(text))
          runs.append([])
        case .text(let text):
          for segment in Footnotes.segments(ofLine: text) {
            switch segment {
            case .text(let plain):
              appendText(plain)
            case .reference(let label, let written):
              if let number = footnotes.number(of: label) {
                runs[runs.count - 1].append(Int32(-number))
              } else {
                appendText(written)
              }
            }
          }
        }
      }
    }

    var out: [UInt8] = []
    for (position, run) in runs.enumerated() {
      if position > 0 { out.append(contentsOf: "<code>\(codes[position - 1])</code>".utf8) }
      var tokens = PageMarkdown.applying(delimiter: 2, opening: "<strong>", closing: "</strong>", to: run)
      tokens = PageMarkdown.applying(delimiter: 1, opening: "<em>", closing: "</em>", to: tokens)
      var previous: Int32 = 0
      for token in tokens {
        if token >= 0 {
          out.append(UInt8(token))
        } else {
          if previous < 0 { out.append(contentsOf: try markSeparator().utf8) }
          out.append(contentsOf: try mark(Int(-token)).utf8)
        }
        previous = token
      }
    }
    return String(decoding: out, as: UTF8.self)
  }
}
