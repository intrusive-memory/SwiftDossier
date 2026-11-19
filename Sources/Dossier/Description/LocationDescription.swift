import DossierCore
import Foundation

/// `LOCATION.md` (§16.3), for reading and for changing by key.
///
/// The same shape as ``CharacterDescription``, and the same lossless front-matter write: a change
/// replaces the lines of that one key, and the text of every other key, and any comment or blank
/// line between keys, stays as it was. Sections are read through `CharacterDocument`, as
/// `DossierBundle` and the validator read `LOCATION.md`.
public struct LocationDescription: Sendable {
  /// One `##` section (§16.3).
  public struct Section: Sendable, Equatable {
    /// The heading, without `## `.
    public let heading: String
    /// What's under it, up to the next `##`.
    public let content: String
  }

  /// The file's name in a location bundle (§16.3).
  static let fileName = "LOCATION.md"

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

  /// The whole file.
  public var text: String { editor.text }

  // MARK: Front matter

  /// Why the front matter can't be used, or `nil` when it can. No block at all isn't a problem
  /// here: ``hasFrontMatter`` says that.
  public var frontMatterProblem: String? { editor.problem }

  /// Whether the file has a front-matter block.
  public var hasFrontMatter: Bool { editor.hasFrontMatter }

  /// The front matter's keys and values, in file order. `nil` with no block, or one that can't
  /// be used. Values read as ``CharacterDescription/frontMatter`` reads them.
  public var frontMatter: JSONObject? { editor.object }

  /// Sets a front-matter key, or removes it with `nil`, by the same rule as
  /// ``CharacterDescription/setFrontMatter(_:_:)``: only that key's lines change.
  ///
  /// - Throws: ``CharacterDescriptionError``, whose cases are the shared writer's. The value is
  ///   then as it was.
  public mutating func setFrontMatter(_ key: String, _ value: JSONValue?) throws {
    try editor.set(key, value)
  }

  // MARK: Body

  /// Every `##` section, in file order (§16.3).
  public var sections: [Section] {
    CharacterDocument(text: text).sections.map { Section(heading: $0.heading, content: $0.content) }
  }

  /// The first section by this name: the exact name, optionally followed by a space and a
  /// parenthetical.
  public func section(named name: String) -> Section? {
    sections.first { CharacterDocument.heading($0.heading, matches: name) }
  }
}
