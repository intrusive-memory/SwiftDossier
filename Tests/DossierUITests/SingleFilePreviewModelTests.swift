import Foundation
import Testing

@testable import DossierUI

@Suite("SingleFilePreviewModelTests")
struct SingleFilePreviewModelTests {
  static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("DossierTests/Fixtures", isDirectory: true)

  static func fixture(_ path: String) throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent(path), encoding: .utf8)
  }

  @Test func characterShowsNameRoleAliasesAndFieldsInFieldsJSONOrder() throws {
    let model = CharacterPreviewModel(text: try Self.fixture("character-hunter-shape/CHARACTER.md"))
    #expect(model.problem == nil)
    #expect(model.name == "MARGO VELL")
    #expect(model.role == "lead")
    #expect(model.aliases == ["Mrs. Vell", "The Surveyor", "Gull"])
    #expect(model.fields.map(\.key) == ["age", "pronouns", "occupation"])
    #expect(model.fields.map(\.label) == ["Age", "Pronouns", "Occupation"])
    #expect(model.fields.map(\.value) == ["52", "she/her", "Harbour surveyor"])
  }

  @Test func fieldOrderFollowsFieldsJSONNotTheFile() {
    let text = """
      ---
      type: character
      character: A
      artStyle: ink
      sampleLine: Hello
      languages: [English, Welsh]
      occupation: Cook
      draft:
        generatedBy: x
      age: 40
      ---
      """
    let model = CharacterPreviewModel(text: text)
    #expect(model.fields.map(\.key) == ["age", "occupation", "languages", "sampleLine", "artStyle"])
    #expect(model.fields.first { $0.key == "languages" }?.value == "English, Welsh")
    #expect(!model.fields.contains { $0.key.hasPrefix("draft") })
  }

  @Test func sectionsAreInSection92OrderThenOpenQuestions() {
    let text = """
      ---
      type: character
      character: A
      ---

      ## Personality

      p

      ## Zeta Notes

      z

      ## Logline

      l

      ## Open Questions

      ### Optional

      - Why?

      ### Deferred
      """
    let model = CharacterPreviewModel(text: text)
    #expect(model.sections.map(\.heading) == ["Logline", "Personality", "Zeta Notes"])
    #expect(model.openQuestions.map(\.name) == ["Optional"])
    #expect(model.openQuestions.first?.items == ["Why?"])
  }

  @Test func theFixtureHasItsSectionsInOrder() throws {
    let model = CharacterPreviewModel(text: try Self.fixture("character-hunter-shape/CHARACTER.md"))
    #expect(
      model.sections.map(\.heading) == ["Logline", "Appearance", "Personality", "Backstory", "Relationships", "Voice & Speech"])
    #expect(model.openQuestions.first?.items == ["Does she still keep her father's theodolite?"])
  }

  @Test func unreadableFrontMatterShowsTheProblemAndTheBody() {
    let text = "---\ntype: character\ncharacter: [unclosed\n---\n\n## Logline\n\nStill here.\n"
    let model = CharacterPreviewModel(text: text)
    #expect(model.problem != nil)
    #expect(model.body.contains("Still here."))
    #expect(model.name == nil)
    #expect(model.fields.isEmpty)
    #expect(model.sections.isEmpty)
  }

  @Test func locationShowsNameThemeAndSectionsInFileOrder() throws {
    let model = LocationPreviewModel(text: try Self.fixture("locations-project/locations/HARBOR-LIGHT.dossier/LOCATION.md"))
    #expect(model.problem == nil)
    #expect(model.name == "HARBOR-LIGHT")
    #expect(model.theme == "COAST")
    #expect(model.sections.map(\.heading) == ["Blocking", "Views"])
    let salt = LocationPreviewModel(text: try Self.fixture("locations-project/locations/SALT-STORE.dossier/LOCATION.md"))
    #expect(salt.name == "SALT-STORE")
  }

  @Test func locationWithBadFrontMatterShowsTheProblem() {
    let model = LocationPreviewModel(text: "---\nlocation: [oops\n---\n\n## Blocking\n\nx\n")
    #expect(model.problem != nil)
    #expect(model.body.contains("Blocking"))
    #expect(model.sections.isEmpty)
  }

  @Test func viewsExposeLabelsAndSymbols() {
    #expect(CharacterPreview.identity == .characterPreview)
    #expect(LocationPreview.identity.systemImage == "mappin.and.ellipse")
    #expect(SingleFileViewIdentity.characterEditor.label == "Character")
    #expect(SingleFileViewIdentity.locationEditor.label == "Location")
    #expect(SingleFileContext(fileURL: URL(fileURLWithPath: "/a/CHARACTER.md")).displayName == "CHARACTER.md")
  }

  @Test func aViewsTableBecomesATable() throws {
    let html = LocationPreviewModel(text: try Self.fixture("locations-project/locations/HARBOR-LIGHT.dossier/LOCATION.md")).html
    #expect(html.contains("<table>"))
    #expect(html.contains("<th>View</th>"))
    #expect(html.contains("<code>dock</code>"))
    #expect(!html.contains("<script"))
    #expect(!html.contains("<img"))
  }

  @Test func aListBecomesAList() {
    let text = "---\ntype: character\ncharacter: A\n---\n\n## Relationships\n\n- **B**: friend\n- C: foe\n"
    let html = CharacterPreviewModel(text: text).html
    #expect(html.contains("<ul><li><strong>B</strong>: friend</li><li>C: foe</li></ul>"))
  }

  @Test func frontMatterTextIsEscaped() {
    let text = "---\ntype: character\ncharacter: '<script>alert(1)</script>'\noccupation: 'a & <b>'\n---\n\n## Logline\n\n<script>x</script>\n"
    let html = CharacterPreviewModel(text: text).html
    #expect(!html.contains("<script>alert"))
    #expect(!html.contains("<script>x"))
    #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    #expect(html.contains("a &amp; &lt;b&gt;"))
  }

  @Test func theProblemPathRendersTheBodyAsMarkdown() {
    let html = CharacterPreviewModel(text: "---\ncharacter: [unclosed\n---\n\n- one\n- two\n").html
    #expect(html.contains("class=\"problem\""))
    #expect(html.contains("<ul><li>one</li><li>two</li></ul>"))
  }
}
