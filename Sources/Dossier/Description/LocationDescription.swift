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
  /// A section the body doesn't have is added at the end of the body, since §16.3 gives no order.
  public mutating func setSection(named name: String, content: String) {
    body = SectionEditor.setting(name, to: content, in: body, order: nil)
  }

  // MARK: Writing

  /// Writes the text to `LOCATION.md` in a location bundle (SFV-4, D-5), as
  /// ``CharacterDescription/write(to:)`` writes `CHARACTER.md`: atomically through a temporary
  /// file, refusing zero bytes and a destination that isn't a regular file, and updating the
  /// manifest's checksums and file list, which are held under the bundle's update marker.
  ///
  /// - Parameter bundle: A location bundle, which is updated to what was written.
  /// - Throws: ``DescriptionError/notALocationBundle(_:)`` for a bundle of any other type, which
  ///   is left untouched; ``DossierWriteError`` or ``DossierCore/DossierError`` otherwise.
  public func write(to bundle: inout DossierBundle) throws {
    guard bundle.isLocation else { throw DescriptionError.notALocationBundle(bundle.url.path) }
    try DescriptionFile.write(text, as: Self.fileName, to: &bundle)
  }
}
