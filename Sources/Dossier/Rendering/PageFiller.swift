import DossierCore
import Foundation

/// `data/fields.json` walked over one bundle, as `template/README.md` says: the page's markup.
///
/// Nothing the field list holds is named here (SD-2): tabs, fields and labels come from
/// ``DossierCore/DossierTabs``, and the values of `from` and `value` are the vocabulary
/// `fields.json` defines in its `sources` and `values`.
final class PageFiller {
  /// A value of a source: a JSON value, or `nil` for the empty one.
  private typealias Value = JSONValue?

  private let tabs: DossierTabs
  private let fragments: [String: String]
  private let copies: PageCopySettings
  private let template: PageTemplate
  private let bundle: DossierBundle
  private let record: JSONObject
  private let frontMatter: JSONObject
  private let castMember: JSONObject
  private let findings: [Finding]
  private let document: CharacterDocument
  private let footnotes: PageFootnotes
  private let inventory: BundleInventory
  /// Whether a media file that can't be read is left off the page instead of failing it. A
  /// preview (``DossierCore/DossierBundle/previewPage()``) shows the bundle as it is; a written
  /// page refuses.
  private let lenient: Bool
  private var copied: [String: String] = [:]

  /// - Parameters:
  ///   - bundle: A view of the bundle whose manifest is the embedded one.
  ///   - record: The record (§11).
  ///   - findings: What the banner may list, computed without the page.
  ///   - document: `CHARACTER.md`.
  ///   - excluding: The page's paths, which aren't read.
  ///   - lenient: Leave off an image or a sample that can't be read, rather than throw.
  init(
    bundle: DossierBundle, record: JSONObject, findings: [Finding], document: CharacterDocument,
    template: PageTemplate, excluding: [String], lenient: Bool = false
  ) throws {
    self.lenient = lenient
    tabs = try DossierTabs.bundled()
    fragments = PageText.fragments(in: String(decoding: try DossierTemplate.data(at: "fragments.html"), as: UTF8.self))
    copies = try PageCopySettings(data: try DossierTemplate.data(at: "page-copies.json"))
    self.template = template
    self.bundle = bundle
    self.record = record
    frontMatter = record["frontMatter"]?.objectValue ?? JSONObject()
    castMember = record["castMember"]?.objectValue ?? JSONObject()
    self.findings = findings
    self.document = document
    footnotes = PageFootnotes(body: document.body)
    inventory = BundleInventory(bundle: bundle.url, excluding: excluding)
  }

  // MARK: - The page

  /// The page's text.
  func html() throws -> String {
    func include(_ name: String) throws -> String { String(decoding: try DossierTemplate.data(at: name), as: UTF8.self) }
    let languages = frontMatter["languages"]?.arrayValue?.compactMap(Self.plain) ?? []
    let recordText = JSONValue.object(record).canonicalEncoded().replacingOccurrences(of: "<", with: "\\u003c")
    return try PageText.filling(
      try include("skeleton.html"),
      [
        "lang": PageText.escaped(languages.first ?? "und"),
        "character": PageText.escaped(record["character"]?.stringValue ?? ""),
        "template.version": PageText.escaped(template.version),
        "template.sha256": PageText.escaped(template.sha256),
        "include:fonts.css": try include("fonts.css"),
        "include:dossier.css": try include("dossier.css"),
        "include:dossier.js": try include("dossier.js"),
        "page.before": try tabs.pageBefore.map(stamp).joined(),
        "tab.links": try tabs.tabs.map { tab in
          try fragment("tabLink", ["key": tab.key, "label": PageText.escaped(tab.label)])
        }.joined(),
        "tab.panels": try tabs.tabs.map { tab in
          try fragment("tab", ["key": tab.key, "label": PageText.escaped(tab.label), "fields": try stampGroups(tab.fields)])
        }.joined(separator: "\n"),
        "page.after": try tabs.pageAfter.map(stamp).joined(),
        "record": recordText,
      ])
  }

  private func fragment(_ name: String, _ values: [String: String]) throws -> String {
    guard let text = fragments[name] else { throw DossierError.resourceUnreadable("template/fragments.html: \(name)") }
    return try PageText.filling(text, values)
  }

  private func malformed(_ what: String) -> DossierError { .resourceUnreadable("fields.json: \(what)") }

  // MARK: - Stamping

  private func stampGroups(_ fields: [DossierTabs.Field]) throws -> String {
    var out = ""
    var index = 0
    while index < fields.count {
      let group = fields[index].group
      var end = index + 1
      while let group, end < fields.count, fields[end].group == group { end += 1 }
      let stamped = try fields[index..<end].map(stamp).joined()
      if let group {
        out += try fragment("group", ["group": group, "fields": stamped])
      } else {
        out += stamped
      }
      index = end
    }
    return out
  }

  private func stamp(_ field: DossierTabs.Field) throws -> String {
    let empty = field.emptyText.map(PageText.escaped) ?? ""
    var values: [String: String] = [
      "key": field.key, "kind": field.kind, "label": PageText.escaped(field.label),
      // The README's defaults, which `DossierTabs` leaves absent.
      "labelStyle": field.labelStyle ?? "label",
      "labelHidden": field.labelVisible ? "" : " is-hidden",
      "textStyle": field.textStyle ?? "body",
    ]
    func state(_ value: String?) -> String {
      if value != nil { return "filled" }
      return field.emptyText == nil ? "absent" : "empty"
    }
    switch field.kind {
    case "image":
      var image = try imageTag(label: field.label, source: field.source)
      var caption = ""
      if image != nil {
        if let overlay = field.overlay { image? += try overlayMarkup(overlay, imageSource: field.source) }
        if let spec = field.caption, let asset = try sourceAsset(field.source),
          let text = try joined(spec, asset: asset)
        {
          caption = try fragment("caption", ["text": PageText.escaped(text)])
        }
      }
      values["state"] = state(image)
      values["value"] = try image ?? missingImage(emptyText: field.emptyText)
      values["caption"] = caption
      return try fragment("image", values)
    case "imageSet":
      values["state"] = "filled"
      values["items"] = try field.items.map(stamp).joined()
      return try fragment("imageSet", values)
    case "audio":
      let rows = try audioRows(field)
      values["state"] = state(rows)
      values["value"] = try rows ?? (field.emptyText == nil ? "" : fragment("audioEmpty", ["text": empty]))
      return try fragment("audio", values)
    case "text", "longText", "list":
      let value = try fieldValue(field)
      values["state"] = state(value)
      values["value"] = value ?? empty
      return try fragment("field", values)
    default:
      throw malformed("\(field.key) has the kind \(field.kind)")
    }
  }

  private func stamp(_ item: DossierTabs.Item) throws -> String {
    let image = try imageTag(label: item.label, source: item.source)
    let state = image != nil ? "filled" : (item.emptyText == nil ? "absent" : "empty")
    return try fragment(
      "imageItem",
      [
        "key": item.key, "label": PageText.escaped(item.label), "state": state,
        "value": try image ?? missingImage(emptyText: item.emptyText),
        "note": try item.note.map { try fragment("itemNote", ["text": PageText.escaped($0)]) } ?? "",
      ])
  }

  private func missingImage(emptyText: String?) throws -> String {
    guard let emptyText else { return "" }
    return try fragment("imageMissing", ["text": PageText.escaped(emptyText)])
  }

  /// The `{{value}}` of a text, long-text or list field, or `nil` with no value.
  private func fieldValue(_ field: DossierTabs.Field) throws -> String? {
    let isSection = field.source["from"]?.stringValue == "section"
    switch field.kind {
    case "longText":
      if isSection { return try sectionMarkup(field.source) }
      return Self.plain(try raw(field.source) ?? .null).map { "<p>\(PageText.escaped($0))</p>" }
    case "list":
      let items: String?
      if isSection {
        items = try canonMarkup(field.source)
      } else {
        items = try listItems(try raw(field.source)).map { list in
          try list.map { try fragment("listItem", ["text": PageText.escaped($0)]) }.joined()
        }
      }
      return try items.map { try fragment("list", ["items": $0]) }
    default:
      guard let text = Self.plain(try raw(field.source) ?? .null) else { return nil }
      let wrap = field.wrap ?? []
      return PageText.escaped((wrap.first ?? "") + text + (wrap.dropFirst().first ?? ""))
    }
  }

  /// "A list value is a list's items": a single value is one item.
  private func listItems(_ value: Value) throws -> [String]? {
    guard let value else { return nil }
    let items = (value.arrayValue ?? [value]).compactMap(Self.plain)
    return items.isEmpty ? nil : items
  }

  // MARK: - Sections

  private var markdown: PageMarkdown {
    PageMarkdown(
      footnotes: footnotes,
      mark: { [unowned self] number in try self.fragment("mark", ["number": String(number)]) },
      markSeparator: { [unowned self] in try self.fragment("markSeparator", [:]) })
  }

  private func matching(_ section: String) -> [(heading: String, content: String)] {
    document.sections.filter { CharacterDocument.heading($0.heading, matches: section) }
  }

  /// Field rule 3: every matching heading, in body order, its parenthetical above its body.
  private func sectionMarkup(_ source: JSONObject) throws -> String? {
    guard let section = source["section"]?.stringValue else { throw malformed("a section source names no section") }
    let matched = matching(section)
    guard matched.contains(where: { PageMarkdown.hasText($0.content) }) else { return nil }
    var out = ""
    for (heading, content) in matched {
      if !heading.hasSameBytes(as: section) {
        let parenthetical = String(heading.dropFirst(section.count)).trimmingCharacters(in: .whitespaces)
        out += try fragment("parenthetical", ["text": PageText.escaped(parenthetical)])
      }
      out += try markdown.markup(PageMarkdown.blocks(of: content))
    }
    return out
  }

  /// Field rule 1.
  private func canonMarkup(_ source: JSONObject) throws -> String? {
    guard let section = source["section"]?.stringValue else { throw malformed("a section source names no section") }
    var out = ""
    for (_, content) in matching(section) {
      for item in try markdown.canonItems(PageMarkdown.blocks(of: content)) {
        out += try fragment("canonItem", ["text": item.text, "source": PageText.escaped(item.source)])
      }
    }
    return out.isEmpty ? nil : out
  }

  // MARK: - Values

  /// What a text, list or plain long-text field holds.
  private func raw(_ source: JSONObject) throws -> Value {
    guard let from = source["from"]?.stringValue else { throw malformed("a source has no from") }
    switch from {
    case "record": return Self.present(record[try key(of: source)])
    case "frontMatter": return Self.present(frontValue(try key(of: source)))
    case "castMember": return Self.present(castMember[try key(of: source)])
    case "asset":
      guard let asset = try sourceAsset(source) else { return nil }
      guard let name = source["value"]?.stringValue else { throw malformed("an asset source has no value") }
      return Self.present(try assetValue(asset, name))
    case "join":
      return try joined(source, asset: nil).map(JSONValue.string)
    case "provenance":
      return try provenanceLine(source).map(JSONValue.string)
    case "tiers":
      return try tierValue(source)
    case "findings":
      return bannerItems(source).map { .array($0.map(JSONValue.string)) }
    case "footnotes":
      return footnotes.sources.isEmpty ? nil : .array(footnotes.sources.map(JSONValue.string))
    default:
      throw malformed("the source \(from)")
    }
  }

  private func key(of source: JSONObject) throws -> String {
    guard let key = source["key"]?.stringValue else { throw malformed("a source has no key") }
    return key
  }

  private static func present(_ value: JSONValue?) -> Value {
    guard let value, value != .null else { return nil }
    return value
  }

  /// A value as text: lists joined by `, `, and empty as `nil`.
  private static func plain(_ value: JSONValue) -> String? {
    switch value {
    case .null: return nil
    case .string(let text): return text.isEmpty ? nil : text
    case .number(let literal): return literal
    case .bool(let flag): return flag ? "true" : "false"
    case .array(let items):
      let parts = items.compactMap(plain)
      return parts.isEmpty ? nil : parts.joined(separator: ", ")
    case .object: return nil
    }
  }

  private func frontValue(_ dotted: String) -> JSONValue? {
    var value: JSONValue? = .object(frontMatter)
    for key in dotted.split(separator: ".", omittingEmptySubsequences: false) {
      value = value?.objectValue?[String(key)]
    }
    return value
  }

  private func sourceAsset(_ source: JSONObject) throws -> Asset? {
    guard let kind = source["kind"]?.stringValue else { throw malformed("an asset source has no kind") }
    return bundle.selectedAsset(kind: AssetKind(rawValue: kind), variant: source["variant"]?.stringValue)
  }

  private func assetValue(_ asset: Asset, _ name: String) throws -> JSONValue? {
    let provenancePrefix = "provenance."
    if name.hasPrefix(provenancePrefix) {
      return asset.provenance.json[String(name.dropFirst(provenancePrefix.count))]
    }
    switch name {
    case "path": return .string(asset.path)
    case "file": return .string(Self.lastSegment(asset.path))
    case "date": return asset.createdAt.map { .string(String($0.prefix(10))) }
    case "variant": return asset.variant.map(JSONValue.string)
    case "model": return asset.model.map(JSONValue.string)
    case "sampleText": return asset.sampleText.map(JSONValue.string)
    default: throw malformed("the value \(name)")
    }
  }

  private static func lastSegment(_ path: String) -> String {
    String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
  }

  /// One part of a join, a caption, a note or a provenance line, or `nil` when it's empty.
  private func part(_ part: JSONObject, asset: Asset?) throws -> String? {
    if let literal = part["literal"]?.stringValue { return literal }
    let value: JSONValue?
    if let shown = part["whenPresent"]?.stringValue {
      guard let asset, let name = part["value"]?.stringValue else { throw malformed("a whenPresent part has no value") }
      return Self.present(try assetValue(asset, name)) != nil ? shown : part["whenAbsent"]?.stringValue
    } else if let role = part["derivedFrom"]?.stringValue {
      let input = asset?.derivedFrom.first { $0.role.hasSameBytes(as: role) }
      value = input?.path.map { .string(Self.lastSegment($0)) }
    } else if let dotted = part["frontMatter"]?.stringValue {
      value = frontValue(dotted)
    } else if part["from"]?.stringValue == "frontMatter" {
      value = frontValue(try key(of: part))
    } else if let name = part["value"]?.stringValue {
      value = try asset.flatMap { try assetValue($0, name) }
    } else {
      throw malformed("a part with nothing to read")
    }
    guard let value, let text = Self.plain(value) else { return nil }
    return (part["prefix"]?.stringValue ?? "") + text
  }

  private func joined(_ spec: JSONObject, asset: Asset?) throws -> String? {
    try joined(parts: spec, separator: spec["separator"]?.stringValue ?? "", asset: asset)
  }

  private func joined(parts spec: JSONObject, separator: String, asset: Asset?) throws -> String? {
    guard let parts = spec["parts"]?.arrayValue else { throw malformed("no parts") }
    let found = try parts.compactMap { value -> String? in
      guard let object = value.objectValue else { throw malformed("a part isn't an object") }
      return try part(object, asset: asset)
    }
    return found.isEmpty ? nil : found.joined(separator: separator)
  }

  /// `sources.provenance`: each selected asset of the kinds, in manifest order, on one line.
  private func provenanceLine(_ source: JSONObject) throws -> String? {
    guard let kinds = source["kinds"]?.arrayValue?.compactMap(\.stringValue) else { throw malformed("a provenance source has no kinds") }
    let lines = try bundle.manifest.assets.compactMap { asset -> String? in
      guard asset.status == .selected, kinds.contains(where: { $0.hasSameBytes(as: asset.kind.rawValue) }) else { return nil }
      return try joined(parts: source, separator: " · ", asset: asset)
    }
    return lines.isEmpty ? nil : lines.joined(separator: "; ")
  }

  /// Field rules 4 and 6. The `dossier` row is this page, which the embedded manifest leaves out.
  private func tierValue(_ source: JSONObject) throws -> Value {
    guard let report = try bundle.completeness() else { return nil }
    let required = report.rows.filter { $0.level == .required }
    let pageRow = "dossier"
    switch source["show"]?.stringValue {
    case "count":
      let satisfied = required.filter { $0.isSatisfied || $0.id == pageRow }.count
      return .string("\(satisfied)/\(required.count)")
    case "missing":
      let missing = required.filter { !$0.isSatisfied && $0.id != pageRow }.map(\.label)
      return missing.isEmpty ? nil : .array(missing.map(JSONValue.string))
    default:
      throw malformed("a tiers source shows \(source["show"]?.stringValue ?? "nothing")")
    }
  }

  /// Field rule 5's findings: `fields.json` says which levels and codes. Sorted by what's shown, as
  /// the rule gives no order.
  private func banner(_ source: JSONObject) -> [(finding: Finding, text: String)] {
    let levels = source["levels"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let codes = source["codes"]?.arrayValue?.compactMap(\.stringValue) ?? []
    return findings.filter { levels.contains($0.level.rawValue) || codes.contains($0.code.rawValue) }
      .map { ($0, "\($0.code.rawValue) \($0.path ?? $0.message)") }
      .sorted { $0.text.precedesInByteOrder($1.text) }
  }

  /// Per error, and per `W-STALE` on a selected asset, the code, then what it names.
  private func bannerItems(_ source: JSONObject) -> [String]? {
    let items = banner(source).map(\.text)
    return items.isEmpty ? nil : items
  }

  /// What the page's banner lists.
  var bannerFindings: [Finding] {
    (tabs.pageBefore + tabs.pageAfter).filter { $0.source["from"]?.stringValue == "findings" }
      .flatMap { banner($0.source).map(\.finding) }
  }

  // MARK: - Media

  private func imageTag(label: String, source: JSONObject) throws -> String? {
    guard let asset = try sourceAsset(source) else { return nil }
    guard let kind = source["kind"]?.stringValue, let size = copies.size(ofKind: kind) else {
      throw DossierError.resourceUnreadable("template/page-copies.json: no size for \(asset.kind.rawValue)")
    }
    let src: String
    do {
      src = try pageCopy(of: asset, size: size)
    } catch DossierWriteError.imageUnreadable where lenient {
      return nil
    }
    return try fragment(
      "img",
      [
        "label": PageText.escaped(label), "src": src, "width": String(size.width),
        "height": String(size.height),
      ])
  }

  /// A page copy as a `data:` URI. Made once for each file: the portrait and the face are shown
  /// several times.
  private func pageCopy(of asset: Asset, size: PageCopySettings.Size) throws -> String {
    let key = "\(asset.path)\0\(size.width)x\(size.height)"
    if let found = copied[key] { return found }
    guard let file = inventory.file(at: asset.path), let data = try? Data(contentsOf: file.url, options: .mappedIfSafe),
      let copy = PageCopy.jpeg(of: data, size: size, quality: copies.quality)
    else { throw DossierWriteError.imageUnreadable(asset.path) }
    let uri = "data:image/jpeg;base64," + copy.base64EncodedString()
    copied[key] = uri
    return uri
  }

  /// §8.5's crop as percentages of the source image (the `overlay` fragment). Rule 5: they're exact
  /// only for an image of the target shape.
  private func overlayMarkup(_ overlay: JSONObject, imageSource: JSONObject) throws -> String {
    guard let source = overlay["source"]?.objectValue, let name = source["value"]?.stringValue else {
      throw malformed("an overlay has no source")
    }
    guard let face = try sourceAsset(source), let box = try assetValue(face, name)?.objectValue,
      let x = box["x"]?.doubleValue, let y = box["y"]?.doubleValue, let width = box["width"]?.doubleValue,
      let height = box["height"]?.doubleValue,
      let portrait = try sourceAsset(imageSource), let file = inventory.file(at: portrait.path),
      let size = ImageShape.dimensions(of: file.url)
    else { return "" }
    let crop = FaceCrop.rect(
      box: FaceBox(x: x, y: y, width: width, height: height), imageWidth: Int(size.width), imageHeight: Int(size.height))
    let imageWidth = Double(size.width)
    let imageHeight = Double(size.height)
    return try fragment(
      "overlay",
      [
        "left": Self.percent(100 * Double(crop.left) / imageWidth),
        "top": Self.percent(100 * Double(crop.top) / imageHeight),
        "size": Self.percent(100 * Double(crop.side) / imageWidth),
      ])
  }

  /// A plain decimal with no trailing zeros, at most 4 places.
  private static func percent(_ value: Double) -> String {
    var text = String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
  }

  private func audioRows(_ field: DossierTabs.Field) throws -> String? {
    guard let kind = field.source["kind"]?.stringValue, let row = field.row else { throw malformed("\(field.key) has no rows") }
    let selected = bundle.manifest.assets.filter { $0.status == .selected && $0.kind.rawValue.hasSameBytes(as: kind) }
    // The field's `order`: the neutral variant first, then the others, each in the manifest's order.
    let neutral = "neutral"
    let ordered =
      selected.filter { $0.variant?.hasSameBytes(as: neutral) ?? false }
      + selected.filter { !($0.variant?.hasSameBytes(as: neutral) ?? false) }
    guard !ordered.isEmpty else { return nil }
    guard let audio = row["audio"]?.stringValue, let title = row["title"]?.stringValue,
      let text = row["text"]?.stringValue, let note = row["note"]?.objectValue
    else { throw malformed("\(field.key)'s row") }
    let rows = try ordered.compactMap { asset -> String? in
      guard let path = try assetValue(asset, audio)?.stringValue, let file = inventory.file(at: path),
        let data = try? Data(contentsOf: file.url, options: .mappedIfSafe)
      else {
        if lenient { return nil }
        throw DossierWriteError.fileUnreadable(asset.path)
      }
      return try fragment(
        "audioRow",
        [
          "title": PageText.escaped(try assetValue(asset, title).flatMap(Self.plain) ?? ""),
          "note": PageText.escaped("· " + (try joined(note, asset: asset) ?? "")),
          "text": PageText.escaped(try assetValue(asset, text).flatMap(Self.plain) ?? ""),
          "src": "data:\(PageCopy.audioMIMEType(ofPath: path));base64," + data.base64EncodedString(),
        ])
    }
    return rows.isEmpty ? nil : rows.joined()
  }
}
