import DossierCore
import Foundation
import Testing

@testable import Dossier
@testable import DossierUI

/// A stand-in for the host's `Binding<String>`: counts how often it is set.
@MainActor
final class BindingBox {
  var text: String
  var sets = 0
  init(_ text: String) { self.text = text }
  func set(_ new: String) {
    text = new
    sets += 1
  }
}

@MainActor
@Suite("SingleFileEditorModelTests")
struct SingleFileEditorModelTests {
  static func fixture(_ path: String) throws -> String {
    try SingleFilePreviewModelTests.fixture(path)
  }

  static func lines(_ text: String) -> [String] {
    text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
  }

  /// The lines that differ between two texts of the same line count.
  static func changed(_ a: String, _ b: String) -> [Int] {
    let (x, y) = (lines(a), lines(b))
    #expect(x.count == y.count)
    return zip(x, y).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
  }

  static let hunter = "character-hunter-shape/CHARACTER.md"

  // MARK: Character fields

  @Test func editingAgeChangesOneLineAndMarksItEdited() throws {
    let original = """
      ---
      type: character
      character: A
      age: 52
      draft:
        generatedBy: tool
        generated:
          - age
          - Appearance
      ---

      ## Appearance

      Tall.
      """
    let model = SingleFileEditorModel.character(text: original)
    let box = BindingBox(original)
    #expect(model.setField("age", to: "53", commit: box.set))
    #expect(box.sets == 1)
    // The value's line changed, and `age` left draft.generated; the body is as it was.
    #expect(box.text.hasSuffix("## Appearance\n\nTall."))
    let after = CharacterDescription(text: box.text)
    #expect(after.frontMatter?["age"] == .number("53"))
    #expect(after.frontMatter?["draft"]?.objectValue?["generated"]?.arrayValue == [.string("Appearance")])
    #expect(box.text.contains("age: 53"))
    #expect(model.text == box.text)
  }

  @Test func editingAgeInTheFixtureChangesExactlyOneLine() throws {
    let original = try Self.fixture(Self.hunter)
    let model = SingleFileEditorModel.character(text: original)
    let box = BindingBox(original)
    #expect(model.setField("age", to: "late 50s", commit: box.set))
    #expect(Self.changed(original, box.text).count == 1)
    #expect(box.text.contains("age: late 50s"))
  }

  @Test func aSectionEditMarksTheSectionEdited() {
    let original = """
      ---
      type: character
      character: A
      draft:
        generated: [Appearance, Personality]
      ---

      ## Appearance

      Tall.

      ## Personality

      Dry.
      """
    let model = SingleFileEditorModel.character(text: original)
    let box = BindingBox(original)
    #expect(model.setSection("Appearance", to: "Short.", commit: box.set))
    let after = CharacterDescription(text: box.text)
    #expect(after.frontMatter?["draft"]?.objectValue?["generated"]?.arrayValue == [.string("Personality")])
    #expect(after.section(named: "Appearance")?.content.contains("Short.") == true)
    #expect(after.section(named: "Personality")?.content.contains("Dry.") == true)
  }

  @Test func aRefusedChangeLeavesTheBindingAndReportsTheError() {
    // A flow-style mapping can't be edited by key.
    let original = "---\n{type: character, character: A, age: 5}\n---\n\n## Logline\n\nx\n"
    let model = SingleFileEditorModel.character(text: original)
    let box = BindingBox(original)
    #expect(!model.setField("age", to: "6", commit: box.set))
    #expect(box.sets == 0)
    #expect(box.text == original)
    #expect(model.fieldErrors["age"] != nil)
    #expect(model.fields.first { $0.key == "age" }?.isWritable == false)
  }

  @Test func aThrowingWriteLeavesTheBindingAndReportsTheError() {
    // Front matter that doesn't parse: nothing to edit by key.
    let original = "---\nage: [unclosed\n---\n\n## Logline\n\nx\n"
    let model = SingleFileEditorModel.character(text: original)
    let box = BindingBox(original)
    #expect(model.problem != nil)
    #expect(!model.setField("age", to: "6", commit: box.set))
    #expect(!model.setSection("Logline", to: "y", commit: box.set))
    #expect(box.sets == 0)
    #expect(model.fieldErrors["age"] != nil)
    #expect(model.sectionErrors["Logline"] != nil)
  }

  @Test func aliasesWithCommentsIsReadOnlyAndDraftIsListedReadOnly() throws {
    let original = try Self.fixture(Self.hunter)
    let model = SingleFileEditorModel.character(text: original)
    let aliases = try #require(model.fields.first { $0.key == "aliases" })
    #expect(!aliases.isWritable)
    #expect(aliases.value == "Mrs. Vell, The Surveyor, Gull")
    let box = BindingBox(original)
    #expect(!model.setField("aliases", to: "x", commit: box.set))
    #expect(box.sets == 0)
    #expect(model.fieldErrors["aliases"] != nil)
    #expect(["type", "character"].allSatisfy { key in model.fields.first { $0.key == key }?.isWritable == false })

    let drafted = SingleFileEditorModel.character(
      text: "---\ntype: character\ncharacter: A\nmystery: 1\ndraft:\n  generatedBy: tool\n  generated: [age]\n---\n")
    for key in ["draft.generatedBy", "draft.generated", "mystery"] {
      let row = try #require(drafted.fields.first { $0.key == key })
      #expect(!row.isWritable)
    }
  }

  @Test func aWritableKeyWithACommentShowsThePlainTextNote() throws {
    let original = "---\ntype: character\ncharacter: A\nage: 52  # per the script\n---\n"
    let model = SingleFileEditorModel.character(text: original)
    let age = try #require(model.fields.first { $0.key == "age" })
    #expect(!age.isWritable)
    #expect(age.readOnlyReason?.contains("plain-text") == true)
  }

  @Test func roleIsWritable() throws {
    let original = try Self.fixture(Self.hunter)
    let model = SingleFileEditorModel.character(text: original)
    #expect(model.fields.first { $0.key == "role" }?.isWritable == true)
    let box = BindingBox(original)
    #expect(model.setField("role", to: "supporting", commit: box.set))
    #expect(Self.changed(original, box.text).count == 1)
    #expect(CharacterDescription(text: box.text).frontMatter?["role"] == .string("supporting"))
  }

  @Test func writableKeysAreFieldsJSONPlusRoleAndNothingElse() {
    let model = SingleFileEditorModel.character(text: "---\ntype: character\ncharacter: A\n---\n")
    let writable = model.fields.filter(\.isWritable).map(\.key)
    #expect(writable == ["role", "age", "pronouns", "occupation", "languages", "sampleLine", "artStyle"])
    let location = SingleFileEditorModel.location(text: "---\ntype: location\nlocation: A\n---\n")
    #expect(location.fields.filter(\.isWritable).map(\.key) == ["location", "theme"])
  }

  @Test func aLanguagesListRoundTrips() throws {
    let original = "---\ntype: character\ncharacter: A\nlanguages:\n  - English\n  - Welsh\nage: 5\n---\n"
    let model = SingleFileEditorModel.character(text: original)
    let row = try #require(model.fields.first { $0.key == "languages" })
    #expect(row.isList)
    #expect(row.value == "English, Welsh")
    // Unchanged text is a no-op.
    let box = BindingBox(original)
    #expect(!model.setField("languages", to: "English, Welsh", commit: box.set))
    #expect(box.sets == 0)
    #expect(model.setField("languages", to: "English, Welsh,  Cornish", commit: box.set))
    let after = CharacterDescription(text: box.text)
    #expect(after.frontMatter?["languages"] == .array([.string("English"), .string("Welsh"), .string("Cornish")]))
    #expect(after.frontMatter?["age"] == .number("5"))
    #expect(model.fields.first { $0.key == "languages" }?.value == "English, Welsh, Cornish")
    // A list key the file lacks is written as a list too.
    let bare = SingleFileEditorModel.character(text: "---\ntype: character\ncharacter: A\n---\n")
    let box2 = BindingBox("")
    #expect(bare.setField("languages", to: "en, cy", commit: box2.set))
    #expect(CharacterDescription(text: box2.text).frontMatter?["languages"] == .array([.string("en"), .string("cy")]))
  }

  @Test func aNoOpEditDoesNotTouchTheBinding() throws {
    let original = try Self.fixture(Self.hunter)
    let model = SingleFileEditorModel.character(text: original)
    let box = BindingBox(original)
    #expect(!model.setField("age", to: "52", commit: box.set))
    #expect(!model.setField("occupation", to: "  Harbour surveyor ", commit: box.set))
    #expect(!model.setField("sampleLine", to: "", commit: box.set))
    let own = try #require(model.sections.first { $0.name == "Logline" })
    #expect(!model.setSection("Logline", to: own.content, commit: box.set))
    #expect(!model.setSection("Wardrobe", to: "", commit: box.set))
    #expect(box.sets == 0)
    #expect(model.fieldErrors.isEmpty && model.sectionErrors.isEmpty)
  }

  // MARK: Sections

  @Test func characterSectionsAreSection92InOrderIncludingMissingOnes() throws {
    let original = try Self.fixture(Self.hunter)
    let model = SingleFileEditorModel.character(text: original)
    #expect(
      model.sections.map(\.name) == [
        "Logline", "Appearance", "Personality", "Backstory", "Arc", "Relationships", "Voice & Speech",
        "Pronunciation", "Wardrobe", "Canon & Guardrails", "Open Questions",
      ])
    #expect(model.sections.first { $0.name == "Arc" }?.exists == false)
    #expect(model.sections.first { $0.name == "Backstory" }?.exists == true)
    let box = BindingBox(original)
    #expect(model.setSection("Arc", to: "She stops measuring.", commit: box.set))
    let after = CharacterDescription(text: box.text)
    let headings = after.sections.map(\.heading)
    #expect(headings.firstIndex(of: "Arc") == (headings.firstIndex(of: "Backstory") ?? 0) + 1)
    #expect(model.sections.first { $0.name == "Arc" }?.exists == true)
  }

  @Test func openQuestionsIsEditableAsASection() throws {
    let original = try Self.fixture(Self.hunter)
    let model = SingleFileEditorModel.character(text: original)
    let row = try #require(model.sections.first { $0.name == "Open Questions" })
    #expect(row.content.contains("### Optional"))
    let box = BindingBox(original)
    #expect(model.setSection("Open Questions", to: row.content + "\n- Another?", commit: box.set))
    #expect(CharacterDescription(text: box.text).openQuestions.flatMap(\.items).contains("Another?"))
  }

  @Test func aHeadingLineInContentIsRefused() throws {
    let original = try Self.fixture(Self.hunter)
    let model = SingleFileEditorModel.character(text: original)
    let box = BindingBox(original)
    #expect(!model.setSection("Logline", to: "ok\n\n## Sneaky\n\nmore", commit: box.set))
    #expect(box.sets == 0)
    #expect(model.sectionErrors["Logline"]?.contains("## ") == true)
    // In a code fence it is just text.
    #expect(model.setSection("Logline", to: "```\n## shown\n```", commit: box.set))
    #expect(box.sets == 1)
    #expect(CharacterDescription(text: box.text).sections.map(\.heading).contains("shown") == false)
  }

  @Test func locationThemeAndBlockingChangeOnlyThoseLines() throws {
    let original = try Self.fixture("locations-project/locations/HARBOR-LIGHT.dossier/LOCATION.md")
    let model = SingleFileEditorModel.location(text: original)
    let box = BindingBox(original)
    #expect(model.setField("theme", to: "STORM", commit: box.set))
    #expect(Self.changed(original, box.text).count == 1)
    #expect(box.text.contains("theme: STORM"))
    let afterTheme = box.text
    #expect(model.setSection("Blocking", to: "The door is on the right.", commit: box.set))
    #expect(Self.changed(afterTheme, box.text).count == 1)
    #expect(box.text.contains("The door is on the right."))
    #expect(!box.text.contains("The door is on the left"))
    #expect(box.text.contains("| `dock` | Exterior"))
  }

  @Test func addingAMissingViewsSectionAppends() throws {
    let original = "---\ntype: location\nlocation: A\n---\n\n## Blocking\n\nDoor left.\n"
    let model = SingleFileEditorModel.location(text: original)
    #expect(model.sections.map(\.name) == ["Blocking", "Views"])
    #expect(model.sections.first { $0.name == "Views" }?.exists == false)
    let box = BindingBox(original)
    #expect(model.setSection("Views", to: "| View | Kind |\n|---|---|\n| `a` | Exterior |", commit: box.set))
    #expect(box.text.hasPrefix(original))
    #expect(box.text.hasSuffix("| `a` | Exterior |\n"))
    #expect(box.text.contains("\n## Views\n"))
    #expect(LocationDescription(text: box.text).sections.map(\.heading) == ["Blocking", "Views"])
  }

  @Test func locationOffersTheFilesSectionsPlusBlockingAndViews() throws {
    let model = SingleFileEditorModel.location(
      text: try Self.fixture("locations-project/locations/SALT-STORE.dossier/LOCATION.md"))
    let names = model.sections.map(\.name)
    #expect(names.contains("Blocking") && names.contains("Views"))
    #expect(names.filter { $0 == "Blocking" }.count == 1)
  }

  // MARK: Outside changes

  @Test func anOutsideTextChangeIsPickedUp() throws {
    let original = try Self.fixture(Self.hunter)
    let model = SingleFileEditorModel.character(text: original)
    let box = BindingBox(original)
    #expect(!model.setSection("Logline", to: "## no", commit: box.set))
    #expect(model.sectionErrors["Logline"] != nil)
    let outside = original.replacingOccurrences(of: "age: 52", with: "age: 99")
      .replacingOccurrences(of: "A harbour surveyor", with: "A different surveyor")
    model.reload(text: outside)
    #expect(model.fields.first { $0.key == "age" }?.value == "99")
    #expect(model.sections.first { $0.name == "Logline" }?.content.hasPrefix("A different surveyor") == true)
    #expect(model.sectionErrors.isEmpty)
    // The next edit builds on the outside text, not a stale copy.
    #expect(model.setField("pronouns", to: "they/them", commit: box.set))
    #expect(box.text.contains("age: 99"))
    #expect(box.text.contains("pronouns: they/them"))
  }

  @Test func noFileIsReadOrWrittenByTheEditors() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Sources/DossierUI")
    for name in ["SingleFileEditorModel.swift", "SingleFileEditors.swift"] {
      let source = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
      #expect(!source.contains("contentsOf") && !source.contains("FileManager") && !source.contains("write(to"))
    }
  }
}
