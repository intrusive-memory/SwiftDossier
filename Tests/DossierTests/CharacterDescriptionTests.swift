import DossierCore
import Foundation
import Testing

@testable import Dossier

/// Synthetic `CHARACTER.md` files and bundles. Invented characters only.
private enum Fixture {
  static let quirky = """
    ---
    # a comment above the first key
    type: character
    character: "THE TINKER"   # says who
    age:   '39'
    notes: |
      looks: like a key
      type: not one

    # a comment between keys
    aliases: [TINK,   "OLD T"]
    quoted: "first line
    role: not a key"
    unknownKey: {a: 1,  b: [x,   y]}
    ---

    ## Logline

    Mends what the tide brings in.

    """

  static let examples = SpecTree.examples

  static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("CharacterDescriptionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
  }

  /// A `.dossier` with an empty manifest.
  static func bundle(_ character: String = "THE TINKER", description: String? = nil, role: String? = nil) throws -> DossierBundle {
    let url = try temporaryDirectory().appendingPathComponent("\(character).dossier", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var manifest = Manifest(character: character, updatedAt: "2026-01-01T00:00:00Z")
    manifest.role = role
    try manifest.encoded().write(to: url.appendingPathComponent("manifest.json"))
    var bundle = try DossierBundle.open(at: url)
    if let description { try CharacterDescription(text: description).write(to: &bundle) }
    return bundle
  }

  /// A copy of the conformance fixture's whole project, and its bundle.
  static func completeLead() throws -> (project: URL, bundle: URL) {
    let root = try temporaryDirectory().appendingPathComponent("project")
    try FileManager.default.copyItem(at: examples.appendingPathComponent("valid/complete-lead"), to: root)
    return (root, root.appendingPathComponent("characters/WREN HALLOWAY.dossier"))
  }

  static func tree(_ root: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = walker?.nextObject() as? URL {
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        result[url.path] = try Data(contentsOf: url)
      }
    }
    return result
  }

  static func withFrontMatter(role: String? = "lead", sections: [String], tail: String = "") -> String {
    var text = "---\ntype: character\ncharacter: THE TINKER\n"
    if let role { text += "role: \(role)\n" }
    text += "---\n\n"
    for section in sections { text += "## \(section)\n\nSome text.\n\n" }
    return text + tail
  }

  static let full = [
    "Logline", "Appearance", "Personality", "Backstory", "Arc", "Relationships", "Voice & Speech", "Pronunciation",
    "Wardrobe",
  ]
}

@Suite("CharacterDescription (§9)")
struct CharacterDescriptionTests {
  // MARK: Front matter

  @Test("Text comes back byte for byte, LF and CRLF")
  func roundTrip() {
    #expect(Array(CharacterDescription(text: Fixture.quirky).text.utf8) == Array(Fixture.quirky.utf8))
    let crlf = Fixture.quirky.replacingOccurrences(of: "\n", with: "\r\n")
    #expect(Array(CharacterDescription(text: crlf).text.utf8) == Array(crlf.utf8))
    let bare = "## Logline\n\nNo front matter.\n"
    #expect(CharacterDescription(text: bare).text == bare)
    #expect(!CharacterDescription(text: bare).hasFrontMatter)
  }

  @Test("§9.1: changing a key leaves the text of every other key as written")
  func onlyThatKey() throws {
    var description = CharacterDescription(text: Fixture.quirky)
    try description.setFrontMatter("age", .string("late 40s"))
    let expected = Fixture.quirky.replacingOccurrences(of: "age:   '39'\n", with: "age: late 40s\n")
    #expect(Array(description.text.utf8) == Array(expected.utf8))
  }

  @Test("§9.1: a key's multi-line value is replaced whole, and lines inside it aren't keys")
  func multiLine() throws {
    var description = CharacterDescription(text: Fixture.quirky)
    try description.setFrontMatter("notes", .string("short"))
    let text = description.text
    #expect(text.contains("notes: short\n\n# a comment between keys\naliases: [TINK,   \"OLD T\"]\n"))
    #expect(!text.contains("looks: like a key"))

    var quoted = CharacterDescription(text: Fixture.quirky)
    try quoted.setFrontMatter("quoted", .string("one line"))
    #expect(quoted.text.contains("quoted: one line\nunknownKey: {a: 1,  b: [x,   y]}\n"))
    #expect(quoted.frontMatter?["role"] == nil)
    #expect(quoted.frontMatter?["type"]?.stringValue == "character")
  }

  @Test("CRLF: a replaced line keeps the file's line breaks")
  func crlfEdit() throws {
    let text = "---\r\ntype: character\r\nage: '1'\r\ncharacter: X\r\n---\r\nBody\r\n"
    var description = CharacterDescription(text: text)
    try description.setFrontMatter("age", .string("2"))
    #expect(Array(description.text.utf8) == Array("---\r\ntype: character\r\nage: '2'\r\ncharacter: X\r\n---\r\nBody\r\n".utf8))
  }

  @Test("Setting a key to the value it has keeps its text")
  func sameValue() throws {
    var description = CharacterDescription(text: Fixture.quirky)
    try description.setFrontMatter("age", .string("39"))
    try description.setFrontMatter("unknownKey", description.frontMatter?["unknownKey"])
    #expect(Array(description.text.utf8) == Array(Fixture.quirky.utf8))
  }

  @Test("A new key goes last in the block; nil removes one; no block gets one")
  func addAndRemove() throws {
    var description = CharacterDescription(text: "---\ntype: character\ncharacter: X\n---\nBody\n")
    try description.setFrontMatter("pronouns", .string("they/them"))
    #expect(description.text == "---\ntype: character\ncharacter: X\npronouns: they/them\n---\nBody\n")
    try description.setFrontMatter("pronouns", nil)
    #expect(description.text == "---\ntype: character\ncharacter: X\n---\nBody\n")
    try description.setFrontMatter("absent", nil)
    #expect(description.text == "---\ntype: character\ncharacter: X\n---\nBody\n")

    var bare = CharacterDescription(text: "Body\n")
    try bare.setFrontMatter("type", .string("character"))
    #expect(bare.text == "---\ntype: character\n---\nBody\n")
  }

  @Test("Values read back as given: §9.1's dates and bare numbers stay strings")
  func quoting() throws {
    for value in ["39", "2026-10-31", "null", "true", "~", "a: b", "line one\nline two", "\u{E9}t\u{E9}", " spaced "] {
      var description = CharacterDescription(text: "---\ntype: character\n---\n")
      try description.setFrontMatter("age", .string(value))
      #expect(description.frontMatter?["age"] == .string(value), "\(value)")
      #expect(description.frontMatter?["type"]?.stringValue == "character")
    }
    var dated = CharacterDescription(text: "---\ntype: character\n---\n")
    try dated.setFrontMatter("when", .string("2026-10-31"))
    #expect(dated.text.contains("when: '2026-10-31'\n"))
    #expect(!dated.text.contains("\u{FFFD}"))
    var long = CharacterDescription(text: "---\ntype: character\n---\n")
    let words = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
    try long.setFrontMatter("artStyle", .string(words))
    #expect(long.text.contains("artStyle: \(words)\n"), "one line, not wrapped")
  }

  @Test("Structured values, numbers, booleans and null")
  func structured() throws {
    var description = CharacterDescription(text: "---\ntype: character\n---\n")
    let draft = try JSONValue.parse(Data(#"{"generatedBy":"x","sources":["a","b"],"generated":[]}"#.utf8))
    try description.setFrontMatter("draft", draft)
    try description.setFrontMatter("count", .number("3"))
    try description.setFrontMatter("ratio", .number("1.5"))
    try description.setFrontMatter("flag", .bool(true))
    try description.setFrontMatter("nothing", .null)
    let read = try #require(description.frontMatter)
    #expect(read["draft"] == draft)
    #expect(read["count"]?.intValue == 3)
    #expect(read["ratio"]?.stringValue == "1.5")
    #expect(read["flag"]?.boolValue == true)
    #expect(read["nothing"] == .null)
  }

  @Test("What can't be edited by key is refused, and the value is unchanged")
  func refusals() throws {
    let flow = "---\n{type: character, character: X}\n---\n"
    var description = CharacterDescription(text: flow)
    #expect(throws: CharacterDescriptionError.self) { try description.setFrontMatter("type", .string("other")) }
    #expect(description.text == flow)

    let anchored = "---\nfirst: &shared one\nsecond: *shared\n---\n"
    var aliased = CharacterDescription(text: anchored)
    #expect(throws: CharacterDescriptionError.self) { try aliased.setFrontMatter("first", .string("two")) }
    #expect(aliased.text == anchored)

    let broken = "---\na: [unclosed\n---\n"
    var unreadable = CharacterDescription(text: broken)
    #expect(unreadable.frontMatterProblem != nil)
    #expect(unreadable.frontMatter == nil)
    #expect(throws: CharacterDescriptionError.self) { try unreadable.setFrontMatter("a", .string("b")) }

    #expect(CharacterDescription(text: "---\n- a\n---\n").frontMatterProblem != nil)
  }

  @Test("§9.1: markEdited removes the entry from draft.generated, and nothing else moves")
  func markEdited() throws {
    let text = """
      ---
      type: character   # kept
      draft:
        generatedBy: invented
        generatedAt: '2026-10-31'
        generated:
        - Logline
        - age
      ---

      """
    var description = CharacterDescription(text: text)
    try description.markEdited("Wardrobe")
    #expect(description.text == text)
    try description.markEdited("Logline")
    let draft = try #require(description.frontMatter?["draft"]?.objectValue)
    #expect(draft["generated"] == .array([.string("age")]))
    #expect(draft["generatedBy"]?.stringValue == "invented")
    #expect(draft["generatedAt"]?.stringValue == "2026-10-31")
    #expect(description.text.contains("type: character   # kept\n"))
    #expect(description.text.contains("generatedAt: '2026-10-31'"))
  }

  // MARK: Body

  @Test("§9.2: sections match by name, with an optional parenthetical; body edits leave the front matter")
  func sections() {
    var description = CharacterDescription(text: Fixture.quirky)
    description.body += "\n## Arc (Season 1)\n\nFrom here to there.\n"
    #expect(description.section(named: "Arc")?.heading == "Arc (Season 1)")
    #expect(description.section(named: "Arc")?.content.contains("From here") == true)
    #expect(description.section(named: "Season") == nil)
    #expect(description.text.hasPrefix("---\n# a comment above the first key\n"))
  }

  @Test("§9.3: undefined, unused and unclassified")
  func footnotes() {
    let body = """
      A[^a] B[^b] C[^c] D[^d] E[^e] F[^f]

      [^a]: Stated. file:12.
      [^c]: Inferred. Because.
      [^d]: Author. 2026-01-01.
      [^e]: Claimed. By nobody.
      [^f]: Stated, no full stop
      [^g]: Stated. Never used.

      """
    let report = CharacterDescription(text: body).footnoteCheck()
    #expect(report.undefined == ["b"])
    #expect(report.unused == ["g"])
    #expect(report.unclassified == ["e", "f"])
  }

  // SPEC-GAP: §9.3 (recon N8): the text doesn't say a footnote in code isn't one. Markdown's rule.
  @Test("§9.3 SPEC-GAP: footnotes in code spans and fenced blocks aren't footnotes")
  func footnotesInCode() {
    let body = """
      A real one[^a], and `[^span]` and ``[^double]`` and an escape \\[^escaped].

      ```
      [^fenced]
      [^fenced-def]: Stated. In a fence.
      ```

      ~~~
      [^tilde]
      ~~~

      [^a]: Stated. file:1.

      """
    let report = CharacterDescription(text: body).footnoteCheck()
    #expect(report == FootnoteReport(undefined: [], unused: [], unclassified: []))
    #expect(CharacterDescription(text: "`[^a]`\n\n[^a]: Stated. x\n").footnoteCheck().unused == ["a"])
  }

  @Test("§9.2: open questions, by group, in file order")
  func openQuestions() throws {
    let text = """
      ## Logline

      ### Not a group here

      ## Open Questions

      ### Needed before Portrait / Views

      - How tall?
        Roughly.
      * Which hand?

      ### Needed for Voice

      ### Optional

      1. First
      2) Second

      A paragraph.

      ### Pet names (invented)

      ```
      ### not a group
      - not a marker
      ```

      ### Deferred

      - Later.

      [^a]: Stated. A definition.
          With a continuation.
      [^b]: Author. Another.

      """
    let groups = CharacterDescription(text: text).openQuestions
    #expect(groups.map(\.name) == [
      "Needed before Portrait / Views", "Needed for Voice", "Optional", "Pet names (invented)", "Deferred",
    ])
    #expect(groups[0].items == ["How tall?\nRoughly.", "Which hand?"])
    #expect(groups[1].isEmpty)
    #expect(groups[2].items == ["First", "Second", "A paragraph."])
    #expect(groups[3].items == ["```\n### not a group\n- not a marker\n```"])
    #expect(groups[4].items == ["Later."], "footnote definitions at the end of the file aren't questions")
    #expect(groups.map(\.isStandard) == [true, true, true, false, true])
  }

  @Test("§9.2: no section is no groups; text before a group has no name; a repeated section joins")
  func openQuestionEdges() {
    #expect(CharacterDescription(text: "## Logline\n\nText.\n").openQuestions.isEmpty)
    let groups = CharacterDescription(text: "## Open Questions\n\nLoose.\n\n### Optional\n\n- A\n\n## Open Questions (Later)\n\n### Deferred\n").openQuestions
    #expect(groups.map(\.name) == [nil, "Optional", "Deferred"])
    #expect(groups[0].items == ["Loose."])
    #expect(!groups[0].isStandard)
  }

  // MARK: Write

  @Test("SD-5: a write updates files and manifestChecksum, and validates clean of hash errors")
  func writeKeepsManifestCorrect() throws {
    let (_, url) = try Fixture.completeLead()
    var bundle = try DossierBundle.open(at: url)
    var description = try #require(try CharacterDescription.read(from: bundle))
    try description.setFrontMatter("occupation", .string("Harbour pilot"))
    try description.write(to: &bundle)

    let data = try Data(contentsOf: url.appendingPathComponent("CHARACTER.md"))
    let entry = try #require(bundle.manifest.files.first { $0.path == "CHARACTER.md" })
    #expect(entry.sha256 == Checksum.sha256(data))
    #expect(entry.sizeBytes == Int64(data.count))
    #expect(bundle.manifest.manifestChecksum == bundle.manifest.computedChecksum)
    #expect(try DossierBundle.open(at: url).manifest == bundle.manifest)
    #expect(bundle.artStyle == "flat placeholder shapes", "the value's description was refreshed")

    let codes = try DossierBundle.validate(at: url).findings.map(\.code)
    #expect(!codes.contains(.fileHash) && !codes.contains(.checksum) && !codes.contains(.schema))
    #expect(!codes.contains(.unclassified))

    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("occupation: Harbour pilot\n"))
    #expect(text.contains("unknownKeyIsPreserved: 'yes'\n"))
    #expect(text.contains("  generatedAt: '2026-10-31'\n"))
  }

  @Test("A write that changes nothing writes nothing")
  func writeNothing() throws {
    let (_, url) = try Fixture.completeLead()
    var bundle = try DossierBundle.open(at: url)
    let before = try Fixture.tree(url)
    try #require(try CharacterDescription.read(from: bundle)).write(to: &bundle)
    #expect(try Fixture.tree(url) == before)
  }

  @Test("Writing what a hand edit already put in the file still corrects its entry")
  func writeSameTextStaleEntry() throws {
    var bundle = try Fixture.bundle(description: "---\ntype: character\ncharacter: THE TINKER\n---\nFirst\n")
    let edited = "---\ntype: character\ncharacter: THE TINKER\n---\nEdited\n"
    let file = bundle.url.appendingPathComponent("CHARACTER.md")
    try Data(edited.utf8).write(to: file)
    try CharacterDescription(text: edited).write(to: &bundle)
    #expect(bundle.manifest.files.first { $0.path == "CHARACTER.md" }?.sha256 == Checksum.sha256(Data(edited.utf8)))
    #expect(!(try DossierBundle.validate(at: bundle.url).findings.map(\.code).contains(.fileHash)))
  }

  @Test("A new file is unclassified until add records it, which accepts the file in place")
  func writeNewThenAdd() throws {
    var bundle = try Fixture.bundle(description: "---\ntype: character\ncharacter: THE TINKER\n---\n")
    #expect(bundle.manifest.files.map(\.path) == ["CHARACTER.md"])
    #expect(try DossierBundle.validate(at: bundle.url).findings.map(\.code).contains(.unclassified))

    let file = bundle.url.appendingPathComponent("CHARACTER.md")
    try bundle.add(file, kind: .description, options: AddOptions(provenance: ["provider": .string("invented")].jsonObject, select: true))
    #expect(bundle.selectedAsset(kind: .description)?.path == "CHARACTER.md")
    #expect(!(try DossierBundle.validate(at: bundle.url).findings.map(\.code).contains(.unclassified)))
  }

  @Test("A failed manifest write puts the file back")
  func rollback() throws {
    let original = "---\ntype: character\ncharacter: THE TINKER\n---\nFirst\n"
    var bundle = try Fixture.bundle(description: original)
    let manifest = try Data(contentsOf: bundle.url.appendingPathComponent("manifest.json"))
    try Data().write(to: bundle.url.appendingPathComponent("empty.txt"))
    #expect(throws: DossierWriteError.self) {
      try CharacterDescription(text: original + "Second\n").write(to: &bundle)
    }
    #expect(try Data(contentsOf: bundle.url.appendingPathComponent("CHARACTER.md")) == Data(original.utf8))
    #expect(try Data(contentsOf: bundle.url.appendingPathComponent("manifest.json")) == manifest)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".") }.isEmpty)

    // No file before: none after.
    var fresh = try Fixture.bundle()
    try Data().write(to: fresh.url.appendingPathComponent("empty.txt"))
    #expect(throws: DossierWriteError.self) { try CharacterDescription(text: "x\n").write(to: &fresh) }
    #expect(!FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("CHARACTER.md").path))
  }

  @Test("Refused: version 1, an empty file, a symbolic link")
  func writeRefusals() throws {
    let v1Root = Fixture.examples.appendingPathComponent("warnings")
    let v1Name = try #require(try FileManager.default.contentsOfDirectory(atPath: v1Root.path).first { $0.hasPrefix("W-V1") })
    let characters = v1Root.appendingPathComponent(v1Name).appendingPathComponent("characters")
    let directory = try #require(try FileManager.default.contentsOfDirectory(atPath: characters.path).first)
    let copy = try Fixture.temporaryDirectory().appendingPathComponent(directory)
    try FileManager.default.copyItem(at: characters.appendingPathComponent(directory), to: copy)
    var v1 = try DossierBundle.open(at: copy)
    let before = try Fixture.tree(copy)
    #expect(throws: DossierWriteError.versionOneManifest) { try CharacterDescription(text: "x\n").write(to: &v1) }
    #expect(try Fixture.tree(copy) == before)

    var bundle = try Fixture.bundle()
    #expect(throws: DossierWriteError.zeroByteFiles(["CHARACTER.md"])) { try CharacterDescription(text: "").write(to: &bundle) }

    let outside = try Fixture.temporaryDirectory().appendingPathComponent("outside.md")
    try Data("outside\n".utf8).write(to: outside)
    let link = bundle.url.appendingPathComponent("CHARACTER.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(throws: DossierWriteError.destinationNotInBundle("CHARACTER.md")) {
      try CharacterDescription(text: "x\n").write(to: &bundle)
    }
    #expect(try Data(contentsOf: outside) == Data("outside\n".utf8))
  }

  @Test("read: nil with no file; invalid UTF-8 is refused")
  func read() throws {
    let bundle = try Fixture.bundle()
    #expect(try CharacterDescription.read(from: bundle) == nil)
    let file = bundle.url.appendingPathComponent("CHARACTER.md")
    try Data([0xFF, 0xFE, 0x00]).write(to: file)
    #expect(throws: CharacterDescriptionError.notUTF8(file.path)) { try CharacterDescription.read(at: file) }
  }

  // MARK: Check

  @Test("The conformance fixture is clean, and check writes nothing")
  func checkClean() throws {
    let (project, url) = try Fixture.completeLead()
    let before = try Fixture.tree(project)
    let report = try DossierBundle.open(at: url).checkDescription()
    #expect(report.issues == [], "\(report.issues)")
    #expect(report.exitStatus == 0)
    #expect(report.hasFile)
    #expect(report.tier == .lead)
    #expect(report.tierSource == .description)
    #expect(report.sections.count == 11)
    #expect(report.sections.allSatisfy { $0.isPresent })
    #expect(report.openQuestions.map(\.name) == ["Needed before Portrait / Views", "Optional"])
    #expect(report.openQuestions[0].isEmpty)
    #expect(report.openQuestions[1].items == ["What the station's call sign is."])
    #expect(report.frontMatterKeys.contains("unknownKeyIsPreserved"))
    #expect(try Fixture.tree(project) == before)
  }

  @Test("Sections are measured against tiers.json: full, short, none")
  func checkTiers() throws {
    let short = ["Logline", "Appearance", "Voice & Speech"]

    let lead = try Fixture.bundle(description: Fixture.withFrontMatter(role: "lead", sections: short)).checkDescription()
    #expect(lead.exitStatus == 1)
    let missing = lead.issues.filter { $0.code == .incomplete }.map(\.message)
    #expect(missing.count == 6)
    #expect(missing.allSatisfy { $0.hasPrefix("description.full: ") })
    #expect(lead.sections.first { $0.name == "Wardrobe" }?.level == .required)
    #expect(lead.sections.first { $0.name == "Open Questions" }?.level == CompletenessReport.Level.none)

    let costar = try Fixture.bundle(description: Fixture.withFrontMatter(role: "costar", sections: short)).checkDescription()
    #expect(costar.issues == [], "\(costar.issues)")
    #expect(costar.exitStatus == 0)

    let bareCostar = try Fixture.bundle(description: Fixture.withFrontMatter(role: "underfive", sections: ["Logline"])).checkDescription()
    #expect(bareCostar.issues.map(\.message).sorted() == [
      "description.short: no Appearance section", "description.short: no Voice & Speech section",
    ])

    let background = try Fixture.bundle(description: Fixture.withFrontMatter(role: "background", sections: [])).checkDescription()
    #expect(background.exitStatus == 0)
    #expect(background.sections.allSatisfy { $0.level == CompletenessReport.Level.none })
  }

  @Test("Pronunciation must have text only where the tier's row requires it")
  func checkPronunciation() throws {
    let text = Fixture.withFrontMatter(role: "lead", sections: Fixture.full)
      .replacingOccurrences(of: "## Pronunciation\n\nSome text.\n", with: "## Pronunciation\n\n")
    let lead = try Fixture.bundle(description: text).checkDescription()
    #expect(lead.issues.map(\.message) == ["pronunciation: the Pronunciation section is empty"])
    let guest = try Fixture.bundle(description: text.replacingOccurrences(of: "role: lead", with: "role: guest")).checkDescription()
    #expect(guest.issues == [], "the guest tier only recommends it")
  }

  @Test("The tier: the member wins; copies stand in without one; none is a warning")
  func checkTierSource() throws {
    let text = Fixture.withFrontMatter(role: "costar", sections: ["Logline", "Appearance", "Voice & Speech"])
    let plain = try Fixture.bundle(description: text)

    let castText = "---\ntype: cast\nschemaVersion: 1\ncast:\n- character: THE TINKER\n  role: lead\n"
      + "- character: THE NOBODY\n---\n"
    let castURL = try Fixture.temporaryDirectory().appendingPathComponent("CAST.md")
    try Data(castText.utf8).write(to: castURL)
    let cast = try Cast.load(castURL)
    let lead = try #require(cast.members.first { $0.character == "THE TINKER" })
    let report = try DossierBundle.open(at: plain.url, member: lead).checkDescription()
    #expect(report.tier == .lead)
    #expect(report.tierSource == .cast)
    #expect(report.issues.contains { $0.message.contains("CAST.md, which wins") })
    #expect(report.issues.contains { $0.code == .incomplete })

    let nobody = try #require(cast.members.first { $0.character == "THE NOBODY" })
    let noRole = try DossierBundle.open(at: plain.url, member: nobody).checkDescription()
    #expect(noRole.tier == nil, "§8.3: a copy doesn't supply a member's tier")
    #expect(noRole.issues.contains { $0.code == .role })

    let copied = try Fixture.bundle(description: Fixture.withFrontMatter(role: nil, sections: []), role: "background").checkDescription()
    #expect(copied.tierSource == .manifest)
    #expect(copied.tier == .background)

    let none = try Fixture.bundle(description: Fixture.withFrontMatter(role: nil, sections: [])).checkDescription()
    #expect(none.tier == nil)
    #expect(none.exitStatus == 1)

    let unknown = try Fixture.bundle(description: Fixture.withFrontMatter(role: "extra", sections: [])).checkDescription()
    #expect(unknown.issues.contains { $0.message.contains("isn't a tier") })
  }

  @Test("§9.1: errors for the file and the required keys")
  func checkErrors() throws {
    let noFile = try Fixture.bundle().checkDescription()
    #expect(!noFile.hasFile)
    #expect(noFile.exitStatus == 2)

    let unusable = try Fixture.bundle()
    try Data([0xFF, 0xFE]).write(to: unusable.url.appendingPathComponent("CHARACTER.md"))
    #expect(try unusable.checkDescription().exitStatus == 2)

    for (text, needle) in [
      ("## Logline\n", "no front matter"),
      ("---\na: [unclosed\n---\n", ""),
      ("---\ncharacter: THE TINKER\n---\n", "type is required"),
      ("---\ntype: person\ncharacter: THE TINKER\n---\n", "type is person"),
      ("---\ntype: character\n---\n", "character is required"),
    ] {
      let report = try Fixture.bundle(description: text).checkDescription()
      #expect(report.exitStatus == 2, "\(text)")
      #expect(report.issues.contains { $0.level == .error && (needle.isEmpty || $0.message.contains(needle)) }, "\(text)")
    }

    let mismatch = try Fixture.bundle(description: "---\ntype: character\ncharacter: THE MENDER\n---\n").checkDescription()
    #expect(mismatch.issues.contains { $0.code == .nameMismatch })
    #expect(mismatch.exitStatus == 2)
  }

  @Test("§9.1: wrong types are warnings; a bare age and unknown keys aren't")
  func checkTypes() throws {
    let text = """
      ---
      type: character
      character: THE TINKER
      role: background
      age: 39
      aliases: ONE
      languages:
      - {a: b}
      pronouns: [a]
      unknown: [anything]
      draft:
        generatedAt: 2026-10-31
        reviewedAt: '2026-10-31'
        sources: one
      ---

      """
    let messages = try Fixture.bundle(description: text).checkDescription().issues.map(\.message)
    #expect(messages.contains("aliases must be an array of strings"))
    #expect(messages.contains("languages must be an array of strings"))
    #expect(messages.contains("pronouns must be a string"))
    #expect(messages.contains("draft.sources must be an array of strings"))
    #expect(messages.contains("draft.generatedAt is a date, and dates are quoted strings"))
    #expect(messages.count == 5, "\(messages)")

    let draftScalar = "---\ntype: character\ncharacter: THE TINKER\nrole: background\ndraft: soon\n---\n"
    #expect(try Fixture.bundle(description: draftScalar).checkDescription().issues.map(\.message) == ["draft must be an object"])
  }

  @Test("Footnotes, loose questions and misplaced sections are warnings, and open questions aren't")
  func checkWarnings() throws {
    let text = Fixture.withFrontMatter(
      role: "background", sections: ["Appearance", "Logline", "Arc (Season 1)", "Arc (Season 2)", "Notes"],
      tail: "## Open Questions\n\nLoose.[^u]\n\n### Needed before Portrait / Views\n\n- A real question.\n\n[^x]: Claimed. y\n")
    let report = try Fixture.bundle(description: text).checkDescription()
    let messages = report.issues.map(\.message)
    #expect(messages.contains("Logline is after Appearance"))
    #expect(!messages.contains { $0.hasPrefix("Arc") }, "a section may repeat")
    #expect(report.otherSections == ["Notes"])
    #expect(report.issues.filter { $0.code == .footnote }.count == 2)
    #expect(messages.contains("[^x]'s definition doesn't start with Stated., Inferred. or Author."))
    #expect(messages.contains("Open Questions has text outside any ### group"))
    #expect(report.exitStatus == 1)

    let question = Fixture.withFrontMatter(
      role: "background", sections: [], tail: "## Open Questions\n\n### Needed before Portrait / Views\n\n- Height?\n")
    let open = try Fixture.bundle(description: question).checkDescription()
    #expect(open.issues == [], "an open question is reported, not judged")
    #expect(open.exitStatus == 0)
    #expect(open.openQuestions.first?.items == ["Height?"])
  }

  @Test("The validator's W-FOOTNOTE and check's agree")
  func validatorAgrees() throws {
    let text = "---\ntype: character\ncharacter: THE TINKER\nrole: background\n---\n\nA[^a].\n\n[^b]: Stated. x\n"
    let bundle = try Fixture.bundle(description: text)
    let fromValidator = try DossierBundle.validate(at: bundle.url).findings.filter { $0.code == .footnote }.map(\.message)
    let fromCheck = try bundle.checkDescription().issues.filter { $0.code == .footnote }.map(\.message)
    #expect(fromValidator == fromCheck)
    #expect(fromCheck.count == 2)
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  /// A dictionary as a provenance object.
  fileprivate var jsonObject: JSONObject {
    var object = JSONObject()
    for (key, value) in self { object[key] = value }
    return object
  }
}
