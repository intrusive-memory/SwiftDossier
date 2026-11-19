import DossierCore
import Foundation
import Testing

@testable import Dossier

/// SFV-14 and SFV-15 on a real project's character file, `characters/HUNTER.dossier/CHARACTER.md`.
///
/// Runs only when `DOSSIER_ACCEPTANCE_PROJECT` names a project checkout, which `make acceptance`
/// does. xcodebuild forwards an environment variable to the xctest process only with a
/// `TEST_RUNNER_` prefix, so the Makefile's `test` target is run as
/// `TEST_RUNNER_DOSSIER_ACCEPTANCE_PROJECT=<path> make test TEST_FILTER=...`.
///
/// The file is copied to a temporary directory and only the copy is read. The project is never
/// written. The suite asserts structure and holds no content of the file.
@Suite(
  "Real project round trip (SFV-14, SFV-15)",
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["DOSSIER_ACCEPTANCE_PROJECT"] != nil))
struct RealProjectRoundTripTests {
  static func copiedSource() throws -> (text: String, directory: URL) {
    let project = try #require(ProcessInfo.processInfo.environment["DOSSIER_ACCEPTANCE_PROJECT"])
    let original = URL(fileURLWithPath: project).appendingPathComponent("characters/HUNTER.dossier/CHARACTER.md")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let copy = directory.appendingPathComponent("CHARACTER.md")
    try FileManager.default.copyItem(at: original, to: copy)
    return (try String(contentsOf: copy, encoding: .utf8), directory)
  }

  /// The `aliases:` line and every line after it that is indented, which is its items and comments.
  static func aliasBlock(_ text: String) -> [String] {
    let lines = text.components(separatedBy: "\n")
    guard let start = lines.firstIndex(of: "aliases:") else { return [] }
    var block = ["aliases:"]
    for line in lines[(start + 1)...] {
      guard let first = line.first, first == " " || first == "\t" else { break }
      block.append(line)
    }
    return block
  }

  @Test("One key and one section change only their lines; the aliases are byte-identical")
  func roundTrip() throws {
    let (source, directory) = try Self.copiedSource()
    defer { try? FileManager.default.removeItem(at: directory) }

    var description = CharacterDescription(text: source)
    #expect(description.text == source)
    let before = Self.aliasBlock(source)
    #expect(before.count > 1)

    let marker = "Acceptance round trip marker."
    let oldSection = try #require(description.section(named: "Logline"))
    try description.setFrontMatter("age", .string("acceptance-age"))
    description.setSection(named: "Logline", content: "\n\(marker)\n\n")

    #expect(Self.aliasBlock(description.text) == before)
    #expect(description.frontMatter?["age"] == .string("acceptance-age"))
    #expect(description.section(named: "Logline")?.content.contains(marker) == true)

    let diff = SectionEditTests.lineDiff(source, description.text)
    let oldLines = oldSection.content.components(separatedBy: "\n").filter { !$0.isEmpty }
    // Only the age line, the Logline body and nothing else came out.
    #expect(diff.removed.filter { !$0.hasPrefix("age:") }.allSatisfy { oldLines.contains($0) })
    #expect(diff.removed.filter { $0.hasPrefix("age:") }.count == 1)
    #expect(diff.inserted.filter { !$0.hasPrefix("age:") } == [marker])
    #expect(diff.inserted.filter { $0.hasPrefix("age:") }.count == 1)
    #expect(Set(diff.removed).isDisjoint(with: Set(before)))
    #expect(Set(diff.inserted).isDisjoint(with: Set(before)))

    // The headings and the other sections are as they were.
    let reread = CharacterDescription(text: description.text)
    #expect(reread.sections.map(\.heading) == CharacterDescription(text: source).sections.map(\.heading))
  }

  @Test("isEditable: false for the commented aliases, true for age")
  func editableKeys() throws {
    let (source, directory) = try Self.copiedSource()
    defer { try? FileManager.default.removeItem(at: directory) }
    let description = CharacterDescription(text: source)
    #expect(!description.isEditable(key: "aliases"))
    #expect(description.isEditable(key: "age"))
  }
}
