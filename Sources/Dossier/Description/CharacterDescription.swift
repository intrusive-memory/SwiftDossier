import DossierCore
import Foundation
import Yams

/// Every way reading or editing `CHARACTER.md` can fail. A write's own failures are
/// ``DossierWriteError``.
public enum CharacterDescriptionError: Error, Equatable, Sendable, LocalizedError {
  /// The file can't be read.
  case unreadable(String)
  /// The file isn't UTF-8 (§9).
  case notUTF8(String)
  /// The front matter doesn't parse, or isn't a mapping.
  case frontMatterUnreadable(String)
  /// The front matter can't be edited by key without changing the text of other keys.
  case frontMatterNotEditable(String)

  /// A description of the failure, for people.
  public var errorDescription: String? {
    switch self {
    case .unreadable(let path): return "Can't read \(path)"
    case .notUTF8(let path): return "\(path) isn't UTF-8"
    case .frontMatterUnreadable(let detail): return "The front matter can't be read: \(detail)"
    case .frontMatterNotEditable(let detail): return "The front matter can't be edited by key: \(detail)"
    }
  }
}

/// What ``CharacterDescription/footnoteCheck()`` found (§9.3). Labels are in byte order.
public struct FootnoteReport: Sendable, Equatable {
  /// Labels referenced with no definition (`W-FOOTNOTE`).
  public let undefined: [String]
  /// Labels defined with no reference (`W-FOOTNOTE`).
  public let unused: [String]
  /// Labels whose definition doesn't start with `Stated.`, `Inferred.` or `Author.`.
  public let unclassified: [String]
}

/// One `###` group of the Open Questions section (§9.2).
public struct OpenQuestionGroup: Sendable, Equatable {
  /// §9.2's standard groups, in its order. The format has no data file for these.
  public static let standardNames = ["Needed before Portrait / Views", "Needed for Voice", "Optional", "Deferred"]

  /// The `###` heading. `nil` for text in the section before any group.
  public let name: String?
  /// The questions: each list item, or each paragraph that isn't in a list, as written.
  public let items: [String]

  /// Whether the group has no questions.
  public var isEmpty: Bool { items.isEmpty }
  /// Whether the name is one of ``standardNames``.
  public var isStandard: Bool { name.map { name in Self.standardNames.contains { $0.hasSameBytes(as: name) } } ?? false }
}

/// `CHARACTER.md` (§9), for reading and for changing by key.
///
/// The value holds the file's text. A change to the front matter replaces the lines of that
/// one key; the text of every other key, and any comment or blank line between keys, stays as it
/// was (§9.1). A change to ``body`` leaves the front matter alone.
public struct CharacterDescription: Sendable {
  /// One `##` section (§9.2).
  public struct Section: Sendable, Equatable {
    /// The heading, without `## `.
    public let heading: String
    /// What's under it, up to the next `##`.
    public let content: String
  }

  /// The file's name in a bundle (§4).
  static let fileName = "CHARACTER.md"

  private var opening: String
  private var frontMatterYAML: String?
  private var closing: String
  /// The text after the front matter.
  public var body: String

  /// A description from the file's text. Nothing is rejected here: ``frontMatterProblem`` says
  /// what's wrong with the front matter.
  public init(text: String) {
    guard let split = FrontMatter.split(text) else {
      (opening, frontMatterYAML, closing, body) = ("", nil, "", text)
      return
    }
    let bytes = Array(text.utf8)
    let openingCount = (bytes.firstIndex(of: 0x0A) ?? -1) + 1
    let closingEnd = bytes.count - split.body.utf8.count
    opening = String(decoding: bytes[..<openingCount], as: UTF8.self)
    frontMatterYAML = split.yaml
    closing = String(decoding: bytes[(openingCount + split.yaml.utf8.count)..<closingEnd], as: UTF8.self)
    body = split.body
  }

  /// Reads a `CHARACTER.md` file.
  ///
  /// - Throws: ``CharacterDescriptionError``.
  public static func read(at url: URL) throws -> CharacterDescription {
    guard let data = try? Data(contentsOf: url) else { throw CharacterDescriptionError.unreadable(url.path) }
    guard let text = String(data: data, encoding: .utf8) else { throw CharacterDescriptionError.notUTF8(url.path) }
    return CharacterDescription(text: text)
  }

  /// Reads a bundle's `CHARACTER.md` as it now stands on disk. `nil` when the bundle has none.
  ///
  /// - Throws: ``CharacterDescriptionError``.
  public static func read(from bundle: DossierBundle) throws -> CharacterDescription? {
    let url = bundle.url.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try read(at: url)
  }

  /// The whole file.
  public var text: String { opening + (frontMatterYAML ?? "") + closing + body }

  // MARK: Front matter

  /// Why the front matter can't be used, or `nil` when it can. No block at all isn't a problem
  /// here: ``hasFrontMatter`` says that.
  public var frontMatterProblem: String? {
    do {
      _ = try frontMatterMapping()
      return nil
    } catch let error as CharacterDescriptionError {
      if case .frontMatterUnreadable(let detail) = error { return detail }
      return error.localizedDescription
    } catch {
      return error.localizedDescription
    }
  }

  /// Whether the file has a front-matter block.
  public var hasFrontMatter: Bool { frontMatterYAML != nil }

  /// The front matter's keys and values, in file order. `nil` with no block, or one that can't
  /// be used.
  ///
  /// Quoted scalars are strings; a plain one is a string unless it's a YAML null, a boolean or
  /// an integer, by the same reading as §7's.
  public var frontMatter: JSONObject? {
    guard hasFrontMatter, let mapping = try? frontMatterMapping() else { return nil }
    return Self.object(of: mapping)
  }

  /// Sets a front-matter key, or removes it with `nil`. Only that key's lines change. A new key
  /// goes at the end of the block, and a file with no block gets one. Setting a key to the value
  /// it has changes nothing, so its text stays as written.
  ///
  /// Values are written so that they read back as given: `"39"` is `'39'`, and a date string is
  /// quoted, as §9.1 asks.
  ///
  /// - Throws: ``CharacterDescriptionError``. The value is then as it was.
  public mutating func setFrontMatter(_ key: String, _ value: JSONValue?) throws {
    guard let yaml = frontMatterYAML else {
      guard let value else { return }
      let lineBreak = body.contains("\r\n") ? "\r\n" : "\n"
      opening = "---" + lineBreak
      frontMatterYAML = try Self.rendered(key, value, lineBreak: lineBreak)
      closing = "---" + lineBreak
      return
    }
    let mapping = try frontMatterMapping()
    let before = Self.object(of: mapping)
    if before[key] == value.map(Self.asRead) { return }

    var lines = Self.linesKeepingBreaks(yaml)
    let lineBreak = yaml.contains("\r\n") ? "\r\n" : "\n"
    let spans = try Self.keySpans(of: mapping, lines: lines)
    let replacement = try value.map { Self.linesKeepingBreaks(try Self.rendered(key, $0, lineBreak: lineBreak)) } ?? []
    if let span = spans.first(where: { $0.key.hasSameBytes(as: key) }) {
      lines.replaceSubrange(span.lines, with: replacement)
    } else {
      lines.append(contentsOf: replacement)
    }
    let edited = lines.joined()

    // An anchor in the replaced text, say, would change another key.
    var expected = before
    expected[key] = value.map(Self.asRead)
    let after = (try? Self.mapping(of: edited)).map(Self.object(of:))
    guard let after, after == expected else {
      throw CharacterDescriptionError.frontMatterNotEditable("changing \(key) would change another key")
    }
    frontMatterYAML = edited
  }

  /// Records that a person edited a section or a front-matter key: its entry leaves
  /// `draft.generated` (§9.1). Nothing changes when it isn't there.
  ///
  /// - Parameter name: The section name or front-matter key.
  /// - Throws: ``CharacterDescriptionError``.
  public mutating func markEdited(_ name: String) throws {
    guard var draft = frontMatter?["draft"]?.objectValue, let generated = draft["generated"]?.arrayValue else { return }
    let remaining = generated.filter { $0 != .string(name) }
    guard remaining.count != generated.count else { return }
    draft["generated"] = .array(remaining)
    try setFrontMatter("draft", .object(draft))
  }

  // MARK: Body

  /// Every `##` section, in file order (§9.2).
  public var sections: [Section] {
    CharacterDocument(text: text).sections.map { Section(heading: $0.heading, content: $0.content) }
  }

  /// The first section by this name: the exact name, optionally followed by a space and a
  /// parenthetical (§9.2).
  public func section(named name: String) -> Section? {
    sections.first { CharacterDocument.heading($0.heading, matches: name) }
  }

  /// §9.3's check of the footnotes. Footnotes in code blocks and code spans aren't read.
  public func footnoteCheck() -> FootnoteReport {
    let result = Footnotes.check(body: body)
    return FootnoteReport(undefined: result.undefined, unused: result.unused, unclassified: result.unclassified)
  }

  /// The Open Questions section's groups, in file order (§9.2). Empty when there's no such section.
  ///
  /// A producing tool decides what a group's state means; this only reads it.
  ///
  /// SPEC-GAP: §9.2: "empty" isn't defined, and §9.3 puts footnote definitions at the end of the
  /// file, which is inside this section when it comes last. A definition and its indented
  /// continuation lines aren't a question; any other text is, so a `None.` makes a group non-empty.
  public var openQuestions: [OpenQuestionGroup] {
    var groups: [(name: String?, items: [String])] = []
    var fence = CodeFence()
    var inDefinition = false
    var inItem = false
    for section in sections where CharacterDocument.heading(section.heading, matches: "Open Questions") {
      for rawLine in section.content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
        let line = String(rawLine)
        let isCode = fence.isCode(line)
        if !isCode, line.hasPrefix("### ") {
          groups.append((line.dropFirst(4).trimmingCharacters(in: .whitespaces), []))
          (inDefinition, inItem) = (false, false)
          continue
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !isCode, Footnotes.isDefinition(line) {
          (inDefinition, inItem) = (true, false)
          continue
        }
        if trimmed.isEmpty {
          continue
        }
        if !isCode, inDefinition, line.hasPrefix("    ") || line.hasPrefix("\t") {
          continue
        }
        inDefinition = false
        if groups.isEmpty { groups.append((nil, [])) }
        let last = groups.count - 1
        if !isCode, let item = Self.listItemText(line) {
          groups[last].items.append(item)
          inItem = true
        } else if inItem, isCode || line.first == " " || line.first == "\t" {
          groups[last].items[groups[last].items.count - 1] += "\n" + trimmed
        } else {
          groups[last].items.append(trimmed)
          inItem = isCode
        }
      }
    }
    return groups.map { OpenQuestionGroup(name: $0.name, items: $0.items) }
  }

  // MARK: Write

  /// Writes this text as the bundle's `CHARACTER.md` and records it (SD-5), so `files` and
  /// `manifestChecksum` stay correct. A failure puts back the file that was there.
  ///
  /// Nothing is written when the file already holds this text and is listed. That includes a file
  /// edited by hand to this text: this call changed nothing, so it stays `E-FILE-HASH` until
  /// `refresh` accepts it. A file edited to something else is replaced, and what replaced it is
  /// recorded, so reading an edited file, changing it and writing it takes the edit in with it.
  ///
  /// A selected description's hash changes, so what was derived from it reads as stale (§7).
  ///
  /// SPEC-GAP: §5.6: no rule adopts `CHARACTER.md`, and an asset needs a `provenance` only its
  /// producer knows. A file no asset lists stays `W-UNCLASSIFIED` until ``DossierBundle/add(_:kind:options:)``
  /// records it, which accepts the file already in place.
  ///
  /// - Parameter bundle: The bundle, which is updated to what was written.
  /// - Throws: ``DossierWriteError`` or ``DossierCore/DossierError``.
  public func write(to bundle: inout DossierBundle) throws {
    let writer = ManifestWriter(bundle: bundle.url)
    let current = try writer.currentManifest()

    let manager = FileManager.default
    let destination = bundle.url.appendingPathComponent(Self.fileName)
    let bytes = Data(text.utf8)
    guard !bytes.isEmpty else { throw DossierWriteError.zeroByteFiles([Self.fileName]) }

    var prior: Data?
    if let attributes = try? manager.attributesOfItem(atPath: destination.path) {
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw DossierWriteError.destinationNotInBundle(Self.fileName)
      }
      guard let data = try? Data(contentsOf: destination) else {
        throw DossierWriteError.fileUnreadable(Self.fileName)
      }
      prior = data
    }

    // The same text, unlisted, still needs a rescan to list it.
    let isSameText = prior == bytes
    let isListed = current.files.contains { $0.path == Self.fileName }
    if isSameText, isListed { return }

    let target = bundle.url
    try UpdateHolding.holding(bundle: target, label: "write \(Self.fileName)") {
      if !isSameText { try Self.replace(destination, with: bytes) }
      do {
        let manifest = try writer.update(accepting: isSameText ? [] : [Self.fileName]) { _, _ in }
        bundle = DossierBundle(url: bundle.url, manifest: manifest, member: bundle.member)
      } catch {
        if !isSameText {
          if let prior {
            try? Self.replace(destination, with: prior)
          } else {
            try? manager.removeItem(at: destination)
          }
        }
        throw error
      }
    }
  }

  /// A temporary file in the same directory, renamed over the target. A leading `.` keeps it out
  /// of §5.2's inventory if the process dies first.
  private static func replace(_ destination: URL, with bytes: Data) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".character-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    do {
      try bytes.write(to: temporary)
    } catch {
      throw DossierWriteError.replaceFailed(error.localizedDescription)
    }
    guard rename(temporary.path, destination.path) == 0 else {
      throw DossierWriteError.replaceFailed(String(cString: strerror(errno)))
    }
  }

  // MARK: Front matter text

  /// The front matter as a parsed node, for ``DossierBundle/checkDescription()``.
  ///
  /// An empty block is an empty mapping.
  func frontMatterMapping() throws -> Node.Mapping {
    try Self.mapping(of: frontMatterYAML ?? "")
  }

  private static func mapping(of yaml: String) throws -> Node.Mapping {
    let root: Node?
    do {
      root = try Yams.compose(yaml: yaml)
    } catch {
      throw CharacterDescriptionError.frontMatterUnreadable(String(describing: error))
    }
    guard let root else { return Node.Mapping([]) }
    guard case .mapping(let mapping) = root else {
      throw CharacterDescriptionError.frontMatterUnreadable("it isn't a mapping")
    }
    return mapping
  }

  private static func object(of mapping: Node.Mapping) -> JSONObject {
    MemberHash.generalValue(.mapping(mapping)).objectValue ?? JSONObject()
  }

  /// The lines each top-level key occupies, from its key to its value's last line. Comments and
  /// blank lines after that belong to no key and stay.
  ///
  /// The parser finds the keys, so a line in a multi-line scalar can't be taken for one.
  private static func keySpans(
    of mapping: Node.Mapping, lines: [String]
  ) throws -> [(key: String, lines: Range<Int>)] {
    guard mapping.style != .flow else {
      throw CharacterDescriptionError.frontMatterNotEditable("the block is a flow mapping")
    }
    var starts: [(key: String, line: Int)] = []
    for (key, _) in mapping {
      guard let mark = key.mark, mark.column == 1, let name = key.string else {
        throw CharacterDescriptionError.frontMatterNotEditable("a top-level key isn't at the start of its line")
      }
      starts.append((name, mark.line - 1))
    }
    return starts.enumerated().map { index, start in
      var end = index + 1 < starts.count ? starts[index + 1].line : lines.count
      while end > start.line + 1 {
        let line = lines[end - 1]
        guard line.hasPrefix("#") || line.allSatisfy(\.isWhitespace) else { break }
        end -= 1
      }
      return (start.key, start.line..<end)
    }
  }

  /// `key: value`, ending in a line break.
  private static func rendered(_ key: String, _ value: JSONValue, lineBreak: String) throws -> String {
    let yaml: String
    do {
      yaml = try Yams.serialize(
        node: .mapping(Node.Mapping([(node(for: .string(key)), node(for: value))])), width: -1, allowUnicode: true)
    } catch {
      throw CharacterDescriptionError.frontMatterNotEditable(String(describing: error))
    }
    return lineBreak == "\n" ? yaml : yaml.replacingOccurrences(of: "\n", with: lineBreak)
  }

  private static func node(for value: JSONValue) -> Node {
    switch value {
    case .null: return Node("null", Tag(.null))
    case .bool(let flag): return Node(flag ? "true" : "false", Tag(.bool))
    case .number(let literal): return Node(literal, Tag(Int64(literal) == nil ? .float : .int))
    // Yams quotes a string that would otherwise read as something else.
    case .string(let text): return .scalar(text.represented())
    case .array(let items): return .sequence(Node.Sequence(items.map(node(for:))))
    case .object(let object):
      return .mapping(Node.Mapping(object.entries.map { (node(for: .string($0.key)), node(for: $0.value)) }))
    }
  }

  /// A value as ``frontMatter`` would read it back: a plain number that isn't an integer is text.
  private static func asRead(_ value: JSONValue) -> JSONValue {
    switch value {
    case .number(let literal): return Int64(literal) == nil ? .string(literal) : value
    case .array(let items): return .array(items.map(asRead))
    case .object(let object):
      var result = JSONObject()
      for entry in object.entries { result[entry.key] = asRead(entry.value) }
      return .object(result)
    default: return value
    }
  }

  private static func linesKeepingBreaks(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for character in text {
      current.append(character)
      if character == "\n" || character == "\r\n" {
        lines.append(current)
        current = ""
      }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
  }

  /// A list item's text, without its marker. `nil` when the line isn't one.
  private static func listItemText(_ line: String) -> String? {
    let trimmed = line.drop { $0 == " " }
    guard line.count - trimmed.count <= 3 else { return nil }
    if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
      return trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }
    let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
    let rest = trimmed.dropFirst(digits.count)
    if !digits.isEmpty, let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " {
      return rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }
}
