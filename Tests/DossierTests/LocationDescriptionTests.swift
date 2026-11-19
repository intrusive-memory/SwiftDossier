import DossierCore
import Foundation
import Testing

@testable import Dossier

/// `LOCATION.md` read and edited as text (§16.3, SFV-4), over the synthetic `locations-project`
/// fixture copied from Escribir (D-3).
@Suite("LocationDescription (§16.3)")
struct LocationDescriptionTests {
  /// `Tests/DossierTests/Fixtures/locations-project`, read from the source tree.
  static let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/locations-project")

  private func text(of location: String) throws -> String {
    let url = Self.project.appendingPathComponent("locations/\(location).dossier/LOCATION.md")
    return try String(contentsOf: url, encoding: .utf8)
  }

  @Test("HARBOR-LIGHT: location, theme and sections")
  func harborLight() throws {
    let source = try text(of: "HARBOR-LIGHT")
    let description = LocationDescription(text: source)
    #expect(description.text == source)
    #expect(description.frontMatterProblem == nil)
    #expect(description.hasFrontMatter)
    #expect(description.frontMatter?["location"] == .string("HARBOR-LIGHT"))
    #expect(description.frontMatter?["theme"] == .string("COAST"))
    #expect(description.frontMatter?["type"] == .string("location"))
    #expect(description.sections.map(\.heading) == ["Blocking", "Views"])
    #expect(description.section(named: "Views")?.content.contains("`lamp-room`") == true)
    #expect(description.section(named: "Missing") == nil)
  }

  @Test("SALT-STORE: location, no theme, one section")
  func saltStore() throws {
    let source = try text(of: "SALT-STORE")
    let description = LocationDescription(text: source)
    #expect(description.text == source)
    #expect(description.frontMatterProblem == nil)
    #expect(description.frontMatter?["location"] == .string("SALT-STORE"))
    #expect(description.frontMatter?["theme"] == nil)
    #expect(description.sections.map(\.heading) == ["Blocking"])
  }

  @Test("Setting theme changes only the theme line")
  func setThemeChangesOneLine() throws {
    let source = try text(of: "HARBOR-LIGHT")
    var description = LocationDescription(text: source)
    try description.setFrontMatter("theme", .string("HARBOUR"))

    let before = source.split(separator: "\n", omittingEmptySubsequences: false)
    let after = description.text.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(before.count == after.count)
    let changed = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }
    #expect(changed.count == 1)
    #expect(changed.first?.element.0 == "theme: COAST")
    #expect(changed.first?.element.1 == "theme: HARBOUR")
    #expect(description.frontMatter?["theme"] == .string("HARBOUR"))
    #expect(description.frontMatter?["location"] == .string("HARBOR-LIGHT"))
  }

  @Test("Adding theme where there's none appends one line to the block")
  func addTheme() throws {
    let source = try text(of: "SALT-STORE")
    var description = LocationDescription(text: source)
    try description.setFrontMatter("theme", .string("COAST"))
    #expect(description.text == source.replacingOccurrences(
      of: "location: SALT-STORE\n", with: "location: SALT-STORE\ntheme: COAST\n"))
  }

  @Test("Setting theme to its value changes nothing")
  func noOpSet() throws {
    let source = try text(of: "HARBOR-LIGHT")
    var description = LocationDescription(text: source)
    try description.setFrontMatter("theme", .string("COAST"))
    #expect(description.text == source)
  }
}
