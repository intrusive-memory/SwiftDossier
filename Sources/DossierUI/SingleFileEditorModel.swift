import Dossier
import DossierCore
import Foundation
import Observation

/// Which description file a ``SingleFileEditorModel`` edits.
public enum SingleFileEditorKind: Sendable, Equatable {
  /// `CHARACTER.md` (§9).
  case character
  /// `LOCATION.md` (§16.3).
  case location
}

/// The front-matter keys an editor may write, and nothing else (D-4, D-6).
///
/// A character's writable keys are the top-level front-matter keys `fields.json` takes (read from
/// the bundle through `CharacterPreviewModel.frontMatterFields`, never listed here) plus the keys in
/// ``extra``. A location's are the keys in ``extra`` for ``SingleFileEditorKind/location``. Every
/// other key (`type`, `character`, `aliases`, `draft` and its dotted keys, an unknown key) is listed
/// read-only.
enum EditableKeys {
  struct Entry: Equatable {
    let key: String
    let label: String
    let isList: Bool
  }

  /// The writable keys that `fields.json` doesn't take from front matter. This is the one place
  /// they are named.
  static let extra: [(kind: SingleFileEditorKind, entry: Entry)] = [
    // §9.1: `role` | no | tier | "A copy; `CAST.md` wins." (D-6: the editor may write it.)
    (.character, Entry(key: "role", label: "Role", isList: false)),
    // §16.3: `LOCATION.md` front matter is `type: location` and `location`: the location's name
    // (D-4: `fields.json` has no location record, so the key is named here).
    (.location, Entry(key: "location", label: "Location", isList: false)),
    // §16.3: `theme` | string | "the producing tool's name for the look the location shares".
    (.location, Entry(key: "theme", label: "Theme", isList: false)),
  ]

  /// The writable keys for a kind, in the order an editor shows them.
  static func entries(for kind: SingleFileEditorKind) -> [Entry] {
    let added = extra.filter { $0.kind == kind }.map(\.entry)
    switch kind {
    case .character:
      let (role, rest) = (added, CharacterPreviewModel.frontMatterFields)
      return role + rest.map { Entry(key: $0.key, label: $0.label, isList: $0.isList) }
    case .location:
      return added
    }
  }
}

/// One front-matter row an editor shows.
public struct EditorFieldRow: Sendable, Equatable, Identifiable {
  public var id: String { key }
  /// The front-matter key (dotted for a nested one such as `draft.generatedBy`).
  public let key: String
  public let label: String
  /// The value as the one string a person edits: a list is comma-separated.
  public let value: String
  /// Whether the value is a list, edited as comma-separated text and written back as a YAML list.
  public let isList: Bool
  /// `nil` when the row is writable, else why it isn't.
  public let readOnlyReason: String?
  public var isWritable: Bool { readOnlyReason == nil }
}

/// One `##` section an editor shows.
public struct EditorSectionRow: Sendable, Equatable, Identifiable {
  public var id: String { name }
  /// The name `setSection` is given: §9.2's name for a character, the heading for a location.
  public let name: String
  /// The section's content with leading and trailing blank lines dropped; empty when the file
  /// has no such section yet.
  public let content: String
  /// Whether the file has the section. A missing one is added on its first edit.
  public let exists: Bool
}

/// The logic of `CharacterEditor` and `LocationEditor`, with no UI (SFV-9, SFV-10).
///
/// The model holds a description built from the text it was given. Every change goes through
/// `setFrontMatter` or `setSection`; for a character `markEdited` follows, and only then is the
/// `commit` closure called with the new text. A change that throws leaves the text as it was, calls
/// nothing and records an error for that field or section. A change that changes nothing calls
/// nothing and records no error. ``reload(text:)`` rebuilds the model from text that changed outside
/// the editor.
///
/// Values are strings. A key whose value is a YAML list (`languages`, or any key whose current value
/// is a list) is shown as comma-separated text and written back as a list; a scalar stays a scalar,
/// and keeps the kind it has (a number or boolean given text that reads as one stays one). Empty
/// text removes the key.
///
/// `markEdited` takes the name `draft.generated` holds (§9.1: "section names or front-matter keys"):
/// the front-matter key for a field, §9.2's section name for a section.
///
/// Open Questions (§9.2) is edited as a section, as raw Markdown (its `###` groups and list items),
/// like any other: the editor adds no structure of its own.
///
/// No file is read or written here (SFV-1).
@MainActor
@Observable
public final class SingleFileEditorModel {
  public let kind: SingleFileEditorKind
  /// The text the model holds. The host's binding mirrors it.
  public private(set) var text: String
  /// Why the front matter can't be read, or `nil`. With a problem there are no rows.
  public private(set) var problem: String?
  /// The writable keys, then every other key read-only.
  public private(set) var fields: [EditorFieldRow] = []
  public private(set) var sections: [EditorSectionRow] = []
  /// A refused change's message, by field key.
  public private(set) var fieldErrors: [String: String] = [:]
  /// A refused change's message, by section name.
  public private(set) var sectionErrors: [String: String] = [:]

  /// The note on a writable key that can't be edited without losing a comment or anchor.
  static let plainTextNote =
    "This key has a comment or anchor, so editing it here would lose text. Edit it in the host's plain-text mode."

  private var character: CharacterDescription?
  private var location: LocationDescription?

  public init(kind: SingleFileEditorKind, text: String) {
    self.kind = kind
    self.text = text
    rebuild(from: text)
  }

  public static func character(text: String) -> SingleFileEditorModel { .init(kind: .character, text: text) }
  public static func location(text: String) -> SingleFileEditorModel { .init(kind: .location, text: text) }

  /// Rebuilds the model from the host's current text, dropping errors. Does nothing when the text is
  /// what the model already holds.
  public func reload(text new: String) {
    guard new != text else { return }
    text = new
    fieldErrors = [:]
    sectionErrors = [:]
    rebuild(from: new)
  }

  // MARK: Editing

  /// Sets a front-matter key from the string a person typed.
  ///
  /// - Returns: `true` when the text changed and `commit` was called.
  @discardableResult
  public func setField(_ key: String, to input: String, commit: (String) -> Void) -> Bool {
    fieldErrors[key] = nil
    guard let row = fields.first(where: { $0.key == key }) else {
      fieldErrors[key] = "\(key) isn't a field this editor knows."
      return false
    }
    guard row.isWritable else {
      fieldErrors[key] = row.readOnlyReason
      return false
    }
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == row.value { return false }
    let current = frontMatter?[key]
    let new: JSONValue?
    if row.isList {
      let items = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
      new = items.isEmpty ? nil : .array(items.map { .string($0) })
    } else if trimmed.isEmpty {
      new = nil
    } else {
      switch current {
      case .number? where Int64(trimmed) != nil: new = .number(trimmed)
      case .bool? where trimmed == "true" || trimmed == "false": new = .bool(trimmed == "true")
      default: new = .string(trimmed)
      }
    }
    return apply(report: { self.fieldErrors[key] = $0 }, commit: commit) { [kind] in
      switch kind {
      case .character:
        var edited = CharacterDescription(text: self.text)
        try edited.setFrontMatter(key, new)
        try edited.markEdited(key)
        return edited.text
      case .location:
        var edited = LocationDescription(text: self.text)
        try edited.setFrontMatter(key, new)
        return edited.text
      }
    }
  }

  /// Gives a section this content. A line starting `## ` outside a code fence is refused: it would
  /// start a new section.
  ///
  /// - Returns: `true` when the text changed and `commit` was called.
  @discardableResult
  public func setSection(_ name: String, to content: String, commit: (String) -> Void) -> Bool {
    sectionErrors[name] = nil
    guard problem == nil else {
      sectionErrors[name] = problem
      return false
    }
    if Self.hasHeadingLine(content) {
      sectionErrors[name] =
        "A line starting with \"## \" would start a new section. Remove it, or indent it, or put it in a code block."
      return false
    }
    // Empty content for a section the file lacks would only add a bare heading.
    if content.allSatisfy(\.isWhitespace), sections.first(where: { $0.name == name })?.exists != true { return false }
    return apply(report: { self.sectionErrors[name] = $0 }, commit: commit) { [kind] in
      switch kind {
      case .character:
        var edited = CharacterDescription(text: self.text)
        edited.setSection(named: name, content: content)
        guard edited.text != self.text else { return self.text }
        try edited.markEdited(name)
        return edited.text
      case .location:
        var edited = LocationDescription(text: self.text)
        edited.setSection(named: name, content: content)
        return edited.text
      }
    }
  }

  /// Runs an edit; commits and rebuilds when it changed the text, reports its error otherwise.
  private func apply(report: (String) -> Void, commit: (String) -> Void, _ edit: () throws -> String) -> Bool {
    do {
      let edited = try edit()
      guard edited != text else { return false }
      text = edited
      rebuild(from: edited)
      commit(edited)
      return true
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
      report(message)
      return false
    }
  }

  /// Whether content has a line that `setSection` would read as a `##` heading.
  static func hasHeadingLine(_ content: String) -> Bool {
    var fence = CodeFence()
    for line in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      if !fence.isCode(line), line.hasPrefix("## ") { return true }
    }
    return false
  }

  // MARK: Rebuilding

  private var frontMatter: JSONObject? { character?.frontMatter ?? location?.frontMatter }

  private func rebuild(from text: String) {
    switch kind {
    case .character:
      character = CharacterDescription(text: text)
      location = nil
      problem = character?.frontMatterProblem
    case .location:
      location = LocationDescription(text: text)
      character = nil
      problem = location?.frontMatterProblem
    }
    guard problem == nil else {
      fields = []
      sections = []
      return
    }
    fields = buildFields()
    sections = buildSections()
  }

  private func isEditable(_ key: String) -> Bool {
    character?.isEditable(key: key) ?? location?.isEditable(key: key) ?? false
  }

  private func buildFields() -> [EditorFieldRow] {
    let matter = frontMatter
    var rows: [EditorFieldRow] = []
    var shown = Set<String>()
    for entry in EditableKeys.entries(for: kind) {
      shown.insert(entry.key)
      let value = matter?[entry.key]
      let isList = entry.isList || value?.arrayValue != nil
      var reason: String?
      if let value, Self.editText(value, isList: isList) == nil {
        reason = "This value isn't text, so it's shown read-only."
      } else if !isEditable(entry.key) {
        reason = Self.plainTextNote
      }
      rows.append(
        EditorFieldRow(
          key: entry.key, label: entry.label, value: value.flatMap { Self.editText($0, isList: isList) } ?? "",
          isList: isList, readOnlyReason: reason))
    }
    for item in matter?.entries ?? [] where !shown.contains(item.key) {
      for (key, value) in Self.flatten(item.key, item.value) {
        rows.append(
          EditorFieldRow(key: key, label: key, value: value, isList: false, readOnlyReason: "Not editable here."))
      }
    }
    return rows
  }

  private func buildSections() -> [EditorSectionRow] {
    let existing = character?.sections.map { ($0.heading, $0.content) } ?? location?.sections.map { ($0.heading, $0.content) } ?? []
    func found(_ name: String) -> String? {
      existing.first { CharacterDocument.heading($0.0, matches: name) }.map { Self.trimmedBlankLines($0.1) }
    }
    switch kind {
    case .character:
      return CharacterDocument.allSections.map { name in
        EditorSectionRow(name: name, content: found(name) ?? "", exists: found(name) != nil)
      }
    case .location:
      var rows: [EditorSectionRow] = []
      var seen = Set<String>()
      for (heading, content) in existing where seen.insert(heading).inserted {
        // A duplicate heading's later copy can't be reached by name, so it isn't a row.
        rows.append(EditorSectionRow(name: heading, content: Self.trimmedBlankLines(content), exists: true))
      }
      for name in ["Blocking", "Views"] where !rows.contains(where: { CharacterDocument.heading($0.name, matches: name) }) {
        rows.append(EditorSectionRow(name: name, content: "", exists: false))
      }
      return rows
    }
  }

  // MARK: Values

  /// A value as the string a person edits, or `nil` when it isn't text (an object, a list of
  /// non-text, or a list where a scalar is expected).
  static func editText(_ value: JSONValue, isList: Bool) -> String? {
    switch value {
    case .null: return ""
    case .bool(let flag): return isList ? nil : (flag ? "true" : "false")
    case .number(let literal): return isList ? nil : literal
    case .string(let string): return isList ? nil : string.trimmingCharacters(in: .whitespacesAndNewlines)
    case .object: return nil
    case .array(let items):
      guard isList else { return nil }
      var parts: [String] = []
      for item in items {
        guard let part = editText(item, isList: false), !part.contains(",") else { return nil }
        parts.append(part)
      }
      return parts.joined(separator: ", ")
    }
  }

  /// A read-only key's rows: one for a scalar or list, one per leaf of an object (`draft.generated`).
  private static func flatten(_ key: String, _ value: JSONValue) -> [(String, String)] {
    switch value {
    case .object(let object):
      if object.isEmpty { return [(key, "")] }
      return object.entries.flatMap { flatten("\(key).\($0.key)", $0.value) }
    case .array(let items):
      return [(key, items.map { editText($0, isList: false) ?? "…" }.joined(separator: ", "))]
    default:
      return [(key, editText(value, isList: false) ?? "")]
    }
  }

  private static func trimmedBlankLines(_ content: String) -> String {
    var lines = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
    while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
    return lines.joined(separator: "\n")
  }
}
