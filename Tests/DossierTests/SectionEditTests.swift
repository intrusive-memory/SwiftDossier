import DossierCore
import Foundation
import Testing

@testable import Dossier

/// `setSection(named:content:)` and `isEditable(key:)` on both description types (SFV-5, SFV-6),
/// round-tripped over synthetic fixtures (SFV-14, SFV-15, D-3).
@Suite("Section edits and editable keys (SFV-14, SFV-15)")
struct SectionEditTests {
  static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

  /// The invented character in HUNTER's shape: commented `aliases:` items and a plain `age:`.
  static func character() throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent("character-hunter-shape/CHARACTER.md"), encoding: .utf8)
  }

  static func location(_ name: String) throws -> String {
    try String(
      contentsOf: fixtures.appendingPathComponent("locations-project/locations/\(name).dossier/LOCATION.md"),
      encoding: .utf8)
  }

  static let aliasLines = [
    "aliases:",
    "  - Mrs. Vell   # MARGO",
    "  - The Surveyor   # NARRATOR",
    "  - Gull   # DECKHAND",
  ]

  /// The lines removed from `before` and the lines inserted in `after`, in order.
  static func lineDiff(_ before: String, _ after: String) -> (removed: [String], inserted: [String]) {
    let old = before.components(separatedBy: "\n")
    let new = after.components(separatedBy: "\n")
    var removed: [String] = []
    var inserted: [String] = []
    for change in new.difference(from: old) {
      switch change {
      case .remove(_, let line, _): removed.append(line)
      case .insert(_, let line, _): inserted.append(line)
      }
    }
    return (removed.sorted(), inserted.sorted())
  }

  // MARK: SFV-14: only the changed lines differ

  @Test("CHARACTER.md: one key and one section change only their lines")
  func characterRoundTrip() throws {
    let source = try Self.character()
    var description = CharacterDescription(text: source)
    #expect(description.text == source)
    try description.setFrontMatter("age", .string("53"))
    description.setSection(named: "Appearance", content: "Tall, and greyer than last year.")

    let diff = Self.lineDiff(source, description.text)
    #expect(diff.removed == ["Tall, weathered, with a brass pencil behind one ear and salt on her boots.", "age: 52"].sorted())
    #expect(diff.inserted == ["Tall, and greyer than last year.", "age: '53'"].sorted())
    #expect(description.frontMatter?["age"] == .string("53"))
    #expect(description.section(named: "Appearance")?.content == "\nTall, and greyer than last year.\n\n")
  }

  @Test("LOCATION.md: one key and one section change only their lines")
  func locationRoundTrip() throws {
    let source = try Self.location("HARBOR-LIGHT")
    var description = LocationDescription(text: source)
    try description.setFrontMatter("theme", .string("HARBOUR"))
    description.setSection(named: "Blocking", content: "The door is on the right now.\n")

    let diff = Self.lineDiff(source, description.text)
    #expect(diff.removed == [
      "The door is on the left of the dock view; the stair rises on the right of the lamp room.", "theme: COAST",
    ].sorted())
    #expect(diff.inserted == ["The door is on the right now.", "theme: HARBOUR"].sorted())
    #expect(description.sections.map(\.heading) == ["Blocking", "Views"])
  }

  @Test("Setting a section to its own content changes nothing", arguments: ["character", "HARBOR-LIGHT", "SALT-STORE", "DRY-DOCK"])
  func ownContentIsNoOp(_ fixture: String) throws {
    let source = try fixture == "character" ? Self.character() : Self.location(fixture)
    var character = CharacterDescription(text: source)
    var location = LocationDescription(text: source)
    for section in character.sections {
      character.setSection(named: section.heading, content: section.content)
      location.setSection(named: section.heading, content: section.content)
    }
    #expect(character.text == source)
    #expect(location.text == source)
  }

  @Test("A `##` line in a code fence isn't a heading: the whole section is replaced")
  func fencedHeadingIsContent() throws {
    let source = try Self.character()
    var description = CharacterDescription(text: source)
    description.setSection(named: "Voice & Speech", content: "Quiet.")
    #expect(!description.text.contains("## not a heading"))
    #expect(description.text.contains("## Voice & Speech\n\nQuiet.\n\n## Open Questions\n"))
    #expect(description.sections.map(\.heading) == CharacterDescription(text: source).sections.map(\.heading))
  }

  @Test("The text before the first section and the last section's end stay as written")
  func preambleAndEnd() {
    let source = "Intro line\n\n## Logline\n\nOld."
    var description = CharacterDescription(text: source)
    description.setSection(named: "Logline", content: "New.\n")
    #expect(description.text == "Intro line\n\n## Logline\n\nNew.")
  }

  @Test("Empty content leaves the heading and its separation")
  func emptyContent() {
    var description = CharacterDescription(text: "## Logline\n\nOld.\n\n## Appearance\n\nTall.\n")
    description.setSection(named: "Logline", content: "")
    #expect(description.text == "## Logline\n\n## Appearance\n\nTall.\n")
    description.setSection(named: "Logline", content: "Back.")
    #expect(description.text == "## Logline\n\nBack.\n\n## Appearance\n\nTall.\n")
  }

  // MARK: CRLF

  @Test("A CRLF file keeps CRLF on every line, and only the changed lines differ")
  func crlfPreserved() throws {
    let source = try Self.character().replacingOccurrences(of: "\n", with: "\r\n")
    var description = CharacterDescription(text: source)
    try description.setFrontMatter("age", .string("53"))
    description.setSection(named: "Appearance", content: "Tall.\nGreyer.\n")
    let text = description.text

    #expect(text.utf8.count(where: { $0 == 0x0A }) == text.components(separatedBy: "\r\n").count - 1)
    let diff = Self.lineDiff(
      source.replacingOccurrences(of: "\r\n", with: "\n"), text.replacingOccurrences(of: "\r\n", with: "\n"))
    #expect(diff.removed == ["Tall, weathered, with a brass pencil behind one ear and salt on her boots.", "age: 52"].sorted())
    #expect(diff.inserted == ["Greyer.", "Tall.", "age: '53'"].sorted())
    #expect(text.contains("## Appearance\r\n\r\nTall.\r\nGreyer.\r\n\r\n## Personality\r\n"))
  }

  @Test("A CRLF section set to its own content changes nothing")
  func crlfNoOp() throws {
    let source = try Self.location("HARBOR-LIGHT").replacingOccurrences(of: "\n", with: "\r\n")
    var description = LocationDescription(text: source)
    for section in description.sections {
      description.setSection(named: section.heading, content: section.content)
    }
    #expect(description.text == source)
  }

  // MARK: Duplicate headings

  @Test("When two headings match, only the first section changes")
  func duplicateHeadingReplacesFirst() {
    let source = "## Arc\n\nFirst.\n\n## Arc (Season 2)\n\nSecond.\n\n## Arc\n\nThird.\n"
    var description = CharacterDescription(text: source)
    description.setSection(named: "Arc", content: "Changed.")
    #expect(description.text == "## Arc\n\nChanged.\n\n## Arc (Season 2)\n\nSecond.\n\n## Arc\n\nThird.\n")

    var location = LocationDescription(text: "## Views\n\nA.\n\n## Views\n\nB.\n")
    location.setSection(named: "Views", content: "C.")
    #expect(location.text == "## Views\n\nC.\n\n## Views\n\nB.\n")
  }

  @Test("A parenthetical heading matches and keeps its heading line")
  func parentheticalHeading() {
    var description = CharacterDescription(text: "## Arc (Season 1)\n\nOld.\n")
    description.setSection(named: "Arc", content: "New.")
    #expect(description.text == "## Arc (Season 1)\n\nNew.\n")
  }

  // MARK: `aliases:` comments survive

  @Test("The `aliases:` comment lines are byte-for-byte the same after edits")
  func aliasCommentsSurvive() throws {
    let source = try Self.character()
    let block = Self.aliasLines.joined(separator: "\n") + "\n"
    #expect(source.contains(block))

    var description = CharacterDescription(text: source)
    try description.setFrontMatter("age", .string("53"))
    try description.setFrontMatter("occupation", .string("Retired surveyor"))
    description.setSection(named: "Logline", content: "Retired, and measuring anyway.")
    description.setSection(named: "Arc", content: "She lets one thing go unmeasured.")
    #expect(description.text.contains(block))

    var crlf = CharacterDescription(text: source.replacingOccurrences(of: "\n", with: "\r\n"))
    try crlf.setFrontMatter("age", .string("53"))
    crlf.setSection(named: "Appearance", content: "Tall.")
    #expect(crlf.text.contains(block.replacingOccurrences(of: "\n", with: "\r\n")))
  }

  // MARK: SFV-15 / SFV-6: isEditable

  @Test("isEditable: false for the commented `aliases:`, true for the plain `age:`")
  func editableKeysOnFixture() throws {
    let description = CharacterDescription(text: try Self.character())
    #expect(!description.isEditable(key: "aliases"))
    #expect(description.isEditable(key: "age"))
    #expect(description.isEditable(key: "character"))
    #expect(description.isEditable(key: "pronouns"))
    #expect(description.isEditable(key: "notThere"))

    let location = LocationDescription(text: try Self.location("HARBOR-LIGHT"))
    #expect(location.isEditable(key: "theme"))
    #expect(location.isEditable(key: "location"))
    #expect(LocationDescription(text: try Self.location("SALT-STORE")).isEditable(key: "theme"))
  }

  @Test(
    "isEditable: comments, anchors and aliases make a key read-only",
    arguments: [
      "key: value # a comment\n",
      "key:   # a comment on the key line\n  - a\n",
      "key:\n  # a comment line inside the value\n  - a\n",
      "key: [a, b] # after a flow sequence\n",
      "key: \"quoted\" # after a quoted scalar\n",
      "key: | # after a block indicator\n  text\n",
      "key: &anchor value\n",
      "other: &shared value\nkey: *shared\n",
      "key:\n  - &item a\n  - b\n",
      "key: !!str &a value\n",
      "key: Tom's car # a quote inside a plain scalar opens nothing\n",
    ])
  func notEditable(_ yaml: String) {
    let description = CharacterDescription(text: "---\n\(yaml)tail: x\n---\n")
    #expect(description.frontMatterProblem == nil)
    #expect(!description.isEditable(key: "key"))
    #expect(description.isEditable(key: "tail"))
  }

  @Test(
    "isEditable: a `#`, `&` or `*` that isn't a comment, anchor or alias leaves a key editable",
    arguments: [
      "key: \"a # in double quotes\"\n",
      "key: 'a # in single quotes'\n",
      "key: 'it''s # still quoted'\n",
      "key: \"multi-line # quoted\n  scalar # still quoted\"\n",
      "key: a#b\n",
      "key: Tom & Jerry\n",
      "key: Tom's#1\n",
      "key: a * b\n",
      "key: |\n  # a heading in a block scalar\n  text # not a comment\n",
      "key: >-\n  folded # text\n",
      "key: ['#x', \"#y\"]\n",
    ])
  func editable(_ yaml: String) {
    let description = CharacterDescription(text: "---\n\(yaml)tail: x\n---\n")
    #expect(description.frontMatterProblem == nil)
    #expect(description.isEditable(key: "key"))
  }

  @Test("isEditable: a comment after a key belongs to no key and doesn't count")
  func trailingCommentOutsideSpan() {
    let description = CharacterDescription(text: "---\nkey: a\n# a comment between keys\ntail: x\n---\n")
    #expect(description.isEditable(key: "key"))
    #expect(description.isEditable(key: "tail"))
  }

  @Test("isEditable: no front matter, or front matter that can't be edited by key")
  func editableEdges() {
    #expect(CharacterDescription(text: "## Logline\n").isEditable(key: "age"))
    #expect(!CharacterDescription(text: "---\n{a: 1, b: 2}\n---\n").isEditable(key: "a"))
    #expect(!CharacterDescription(text: "---\n: [\n---\n").isEditable(key: "a"))
  }

  // MARK: SFV-5: inserting a missing section

  @Test("A missing CHARACTER.md section goes after the nearest earlier §9.2 section")
  func insertAfterEarlier() throws {
    let source = try Self.character()
    var description = CharacterDescription(text: source)
    #expect(description.section(named: "Arc") == nil)
    description.setSection(named: "Arc", content: "She lets one thing go unmeasured.")
    #expect(description.sections.map(\.heading) == [
      "Logline", "Appearance", "Personality", "Backstory", "Arc", "Relationships", "Voice & Speech", "Open Questions",
    ])
    #expect(description.text.contains(
      "breakwater failed.\n\n## Arc\n\nShe lets one thing go unmeasured.\n\n## Relationships\n"))
    let diff = Self.lineDiff(source, description.text)
    #expect(diff.removed.isEmpty)
    #expect(diff.inserted == ["## Arc", "She lets one thing go unmeasured.", "", ""].sorted())
  }

  @Test("A missing section with no earlier one goes before the first later one")
  func insertBeforeLater() {
    var description = CharacterDescription(text: "# MARGO\n\n## Appearance\n\nTall.\n")
    description.setSection(named: "Logline", content: "Measures.")
    #expect(description.text == "# MARGO\n\n## Logline\n\nMeasures.\n\n## Appearance\n\nTall.\n")
  }

  @Test("A missing section after the last §9.2 one present goes at the end")
  func insertAtEndAfterEarlier() throws {
    var description = CharacterDescription(text: "## Logline\n\nMeasures.\n")
    description.setSection(named: "Wardrobe", content: "Oilskins.")
    #expect(description.text == "## Logline\n\nMeasures.\n\n## Wardrobe\n\nOilskins.\n")

    var unterminated = CharacterDescription(text: "## Logline\n\nMeasures.")
    unterminated.setSection(named: "Wardrobe", content: "Oilskins.")
    #expect(unterminated.text == "## Logline\n\nMeasures.\n\n## Wardrobe\n\nOilskins.\n")
  }

  @Test("A name that isn't a §9.2 section, or a body with no sections, appends at the end")
  func insertUnknownAtEnd() {
    var description = CharacterDescription(text: "## Logline\n\nMeasures.\n\n## Wardrobe\n\nOilskins.\n")
    description.setSection(named: "Notes", content: "Extra.")
    #expect(description.text == "## Logline\n\nMeasures.\n\n## Wardrobe\n\nOilskins.\n\n## Notes\n\nExtra.\n")

    var bare = CharacterDescription(text: "---\ntype: character\n---\n")
    bare.setSection(named: "Logline", content: "Measures.")
    #expect(bare.text == "---\ntype: character\n---\n## Logline\n\nMeasures.\n")
  }

  @Test("A missing LOCATION.md section is appended at the end")
  func insertLocationAtEnd() throws {
    let source = try Self.location("SALT-STORE")
    var description = LocationDescription(text: source)
    // `Logline` comes first in §9.2's order; LOCATION.md has no order, so it still goes last.
    description.setSection(named: "Logline", content: "Salt and rope.")
    #expect(description.sections.map(\.heading) == ["Blocking", "Logline"])
    let diff = Self.lineDiff(source, description.text)
    #expect(diff.removed.isEmpty)
    #expect(description.text.hasPrefix(source))
    #expect(description.text.hasSuffix("## Logline\n\nSalt and rope.\n"))
  }

  @Test("A section inserted into a CRLF file uses CRLF")
  func insertCRLF() throws {
    let source = try Self.character().replacingOccurrences(of: "\n", with: "\r\n")
    var description = CharacterDescription(text: source)
    description.setSection(named: "Wardrobe", content: "Oilskins.\nBoots.")
    #expect(description.text.contains("\r\n## Wardrobe\r\n\r\nOilskins.\r\nBoots.\r\n\r\n## Open Questions\r\n"))
    #expect(!description.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
  }
}
