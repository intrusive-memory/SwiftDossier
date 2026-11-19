import DossierCore
import Foundation
import Yams

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

  private var editor: FrontMatterEditor
  /// The text after the front matter.
  public var body: String {
    get { editor.body }
    set { editor.body = newValue }
  }

  /// A description from the file's text. Nothing is rejected here: ``frontMatterProblem`` says
  /// what's wrong with the front matter.
  public init(text: String) {
    editor = FrontMatterEditor(text: text)
  }

  /// Reads a `CHARACTER.md` file.
  ///
  /// - Throws: ``DescriptionError``.
  public static func read(at url: URL) throws -> CharacterDescription {
    guard let data = try? Data(contentsOf: url) else { throw DescriptionError.unreadable(url.path) }
    guard let text = String(data: data, encoding: .utf8) else { throw DescriptionError.notUTF8(url.path) }
    return CharacterDescription(text: text)
  }

  /// Reads a bundle's `CHARACTER.md` as it now stands on disk. `nil` when the bundle has none.
  ///
  /// - Throws: ``DescriptionError``.
  public static func read(from bundle: DossierBundle) throws -> CharacterDescription? {
    let url = bundle.url.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try read(at: url)
  }

  /// The whole file.
  public var text: String { editor.text }

  // MARK: Front matter

  /// Why the front matter can't be used, or `nil` when it can. No block at all isn't a problem
  /// here: ``hasFrontMatter`` says that.
  public var frontMatterProblem: String? { editor.problem }

  /// Whether the file has a front-matter block.
  public var hasFrontMatter: Bool { editor.hasFrontMatter }

  /// The front matter's keys and values, in file order. `nil` with no block, or one that can't
  /// be used.
  ///
  /// Quoted scalars are strings; a plain one is a string unless it's a YAML null, a boolean or
  /// an integer, by the same reading as §7's.
  public var frontMatter: JSONObject? { editor.object }

  /// Sets a front-matter key, or removes it with `nil`. Only that key's lines change. A new key
  /// goes at the end of the block, and a file with no block gets one. Setting a key to the value
  /// it has changes nothing, so its text stays as written.
  ///
  /// Values are written so that they read back as given: `"39"` is `'39'`, and a date string is
  /// quoted, as §9.1 asks.
  ///
  /// - Throws: ``DescriptionError``. The value is then as it was.
  public mutating func setFrontMatter(_ key: String, _ value: JSONValue?) throws {
    try editor.set(key, value)
  }

  /// Whether ``setFrontMatter(_:_:)`` can change this key without losing text (SFV-6): `false` when
  /// the key's lines (its key line and its value's lines) hold a YAML `#` comment, an anchor
  /// (`&name`) or an alias (`*name`), since setting the key replaces those lines. A `#` inside a
  /// quoted or block scalar isn't a comment. An editor shows such a key read-only.
  ///
  /// `true` for a key the front matter doesn't have, or a file with no front matter: setting it
  /// adds lines and replaces none. `false` when the front matter can't be edited by key at all.
  public func isEditable(key: String) -> Bool {
    editor.isEditable(key)
  }

  /// Records that a person edited a section or a front-matter key: its entry leaves
  /// `draft.generated` (§9.1). Nothing changes when it isn't there.
  ///
  /// - Parameter name: The section name or front-matter key.
  /// - Throws: ``DescriptionError``.
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

  /// Gives the first section named `name` this content, or adds the section when the body has
  /// none (SFV-5). Every other byte of the text stays as it was: the front matter, the text before
  /// the first `##`, every other section, and the line breaks (LF or CRLF) the file uses.
  ///
  /// The name matches as ``section(named:)`` matches it, and when more than one heading matches,
  /// only the first section changes. Its heading line stays as written.
  ///
  /// `content` is the text under the heading. Its line breaks are written as the file's, and its
  /// leading and trailing blank lines are dropped: the blank lines that were just under the heading
  /// and just above the next one stay, so the section's separation from its neighbours is kept.
  /// Setting a section to its own ``Section/content`` therefore changes nothing. Empty content
  /// leaves the heading with only its separating blank lines. A line in `content` that starts
  /// `## ` outside a code fence becomes a heading of its own.
  ///
  /// A section the body doesn't have is added in §9.2's order: after the nearest earlier §9.2 section
  /// the body has, else before the first later one, else at the end of the body. A name that isn't
  /// one of §9.2's sections is added at the end.
  public mutating func setSection(named name: String, content: String) {
    body = SectionEditor.setting(name, to: content, in: body, order: CharacterDocument.allSections)
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
    try DescriptionFile.write(text, as: Self.fileName, to: &bundle)
  }

  // MARK: Front matter text

  /// The front matter as a parsed node, for ``DossierBundle/checkDescription()``.
  ///
  /// An empty block is an empty mapping.
  func frontMatterMapping() throws -> Node.Mapping {
    try editor.mapping()
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
