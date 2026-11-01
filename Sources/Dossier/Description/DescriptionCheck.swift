import DossierCore
import Foundation
import SwiftReparto
import Yams

/// What ``DossierBundle/checkDescription()`` found in `CHARACTER.md` (§9).
///
/// It reports and decides nothing: what a tool does about an open question is that tool's call.
public struct DescriptionCheckReport: Sendable {
  /// Which part of the file an issue is about.
  public enum Area: String, Sendable, Equatable {
    /// The file as a whole.
    case file
    /// §9.1.
    case frontMatter
    /// §9.2, against the tier.
    case sections
    /// §9.3.
    case footnotes
    /// §9.2's Open Questions.
    case openQuestions
  }

  /// One thing to say about the file.
  public struct Issue: Sendable, Equatable {
    /// The part of the file.
    public let area: Area
    /// How much it matters.
    public let level: Finding.Level
    /// §14's code, or `nil` for what §14 has no code for.
    public let code: Finding.Code?
    /// For people.
    public let message: String

    /// An issue. With a code, the level is the code's.
    package init(_ area: Area, level: Finding.Level = .warning, code: Finding.Code? = nil, _ message: String) {
      self.area = area
      self.level = code?.level ?? level
      self.code = code
      self.message = message
    }
  }

  /// Where the tier came from.
  public enum TierSource: String, Sendable, Equatable {
    /// The `CAST.md` member's `role`, which is the tier (§8.3).
    case cast
    /// The copy in `CHARACTER.md`'s front matter (§9.1).
    case description
    /// The copy in the manifest (§5.1).
    case manifest
  }

  /// One of §9.2's sections, and what the tier asks of it.
  public struct SectionRow: Sendable, Equatable {
    /// The section's name.
    public let name: String
    /// What the tier asks. `.none` when there's no tier, or it asks nothing.
    public let level: CompletenessReport.Level
    /// Whether the file has it.
    public let isPresent: Bool
    /// Whether it has anything but whitespace in it.
    public let hasContent: Bool
  }

  /// Whether the bundle has the file. Without it there's nothing else to report.
  public let hasFile: Bool
  /// The front matter's keys, in file order.
  public let frontMatterKeys: [String]
  /// The tier measured against. `nil` when no source gives one.
  public let tier: CastRole?
  /// Where ``tier`` came from.
  public let tierSource: TierSource?
  /// §9.2's sections, in its order.
  public let sections: [SectionRow]
  /// The headings that aren't §9.2's, in file order.
  public let otherSections: [String]
  /// §9.3's check.
  public let footnotes: FootnoteReport
  /// §9.2's groups.
  public let openQuestions: [OpenQuestionGroup]
  /// Everything to say, by area in the file's order. Open questions themselves aren't issues.
  public private(set) var issues: [Issue]

  /// 0 clean, 1 warnings only, 2 errors, as ``ValidationReport/exitStatus``.
  public var exitStatus: Int32 {
    if issues.contains(where: { $0.level == .error }) { return 2 }
    return issues.isEmpty ? 0 : 1
  }

  /// Adds something the caller found, such as an orphan.
  package mutating func append(_ issue: Issue) { issues.append(issue) }
}

extension DossierBundle {
  /// Reads `CHARACTER.md` as it stands on disk and reports its front matter, its sections against
  /// the tier, its footnotes and its open questions (§9). Read-only.
  ///
  /// A problem with a key §9.1 requires, or with the file itself, is an error. §9.1's other types,
  /// missing or misplaced sections and bad footnotes are warnings, as §14 has `W-INCOMPLETE` and
  /// `W-FOOTNOTE`.
  ///
  /// SPEC-GAP: §8.3, §9.1, §14: §14 has no code for a missing `CHARACTER.md` or a required key,
  /// and a bundle can validate without either. Here they're errors with no code, because this
  /// reports on that file and §9.1 marks the keys required.
  ///
  /// SPEC-GAP: §8.3: a tier comes only from `CAST.md`, but §5's `dossier check <bundle>` names no
  /// `CAST.md`. Opened with no member, the copies stand in, as §9.1's "`CAST.md` wins" implies,
  /// and ``DescriptionCheckReport/tierSource`` says so. A member with no `role` has no tier.
  ///
  /// - Returns: The report. An unreadable file is an issue in it, not a throw.
  /// - Throws: ``DossierCore/DossierError`` when `tiers.json` can't be read.
  public func checkDescription() throws -> DescriptionCheckReport {
    let description: CharacterDescription?
    do {
      description = try CharacterDescription.read(from: self)
    } catch {
      return Self.emptyCheck(hasFile: true, message: error.localizedDescription)
    }
    guard let description else {
      return Self.emptyCheck(hasFile: false, message: "The bundle has no CHARACTER.md")
    }

    var issues = checkFrontMatter(of: description)
    let (tier, source) = checkTier(of: description, issues: &issues)
    let (rows, others) = try checkSections(of: description, tier: tier, issues: &issues)

    let footnotes = description.footnoteCheck()
    for label in footnotes.undefined {
      issues.append(.init(.footnotes, code: .footnote, "[^\(label)] has no definition"))
    }
    for label in footnotes.unused {
      issues.append(.init(.footnotes, code: .footnote, "[^\(label)] is never referenced"))
    }
    for label in footnotes.unclassified {
      issues.append(.init(.footnotes, "[^\(label)]'s definition doesn't start with Stated., Inferred. or Author."))
    }

    let questions = description.openQuestions
    if questions.contains(where: { $0.name == nil }) {
      issues.append(.init(.openQuestions, "Open Questions has text outside any ### group"))
    }

    return DescriptionCheckReport(
      hasFile: true, frontMatterKeys: description.frontMatter?.keys ?? [], tier: tier, tierSource: source,
      sections: rows, otherSections: others, footnotes: footnotes, openQuestions: questions, issues: issues)
  }

  private static func emptyCheck(hasFile: Bool, message: String) -> DescriptionCheckReport {
    DescriptionCheckReport(
      hasFile: hasFile, frontMatterKeys: [], tier: nil, tierSource: nil, sections: [], otherSections: [],
      footnotes: FootnoteReport(undefined: [], unused: [], unclassified: []), openQuestions: [],
      issues: [.init(.file, level: .error, message)])
  }

  /// §9.1's table.
  ///
  /// SPEC-GAP: §9.1: `age` is typed string, and its own example is a bare `39`. Any scalar passes
  /// as a string key. `languages`' BCP 47 syntax isn't checked, since no list of what's valid is
  /// given.
  private func checkFrontMatter(of description: CharacterDescription) -> [DescriptionCheckReport.Issue] {
    typealias Issue = DescriptionCheckReport.Issue
    guard description.hasFrontMatter else {
      return [.init(.frontMatter, level: .error, "CHARACTER.md has no front matter")]
    }
    guard description.frontMatterProblem == nil, let mapping = try? description.frontMatterMapping() else {
      return [.init(.frontMatter, level: .error, description.frontMatterProblem ?? "The front matter can't be read")]
    }
    var issues: [Issue] = []

    func text(_ node: Node?) -> String? {
      guard case .scalar(let scalar)? = node else { return nil }
      if scalar.style == .plain, MemberHash.isNullText(scalar.string) { return nil }
      return scalar.string
    }
    func isStringArray(_ node: Node) -> Bool {
      guard case .sequence(let sequence) = node else { return false }
      return sequence.allSatisfy { text($0) != nil }
    }

    if let type = text(mapping["type"]) {
      if !type.hasSameBytes(as: "character") {
        issues.append(.init(.frontMatter, level: .error, "type is \(type), and must be character"))
      }
    } else {
      issues.append(.init(.frontMatter, level: .error, "type is required, and must be character"))
    }
    if let character = text(mapping["character"]) {
      let normal = character.precomposedStringWithCanonicalMapping
      if !normal.hasSameBytes(as: manifest.character.precomposedStringWithCanonicalMapping) {
        issues.append(
          .init(.frontMatter, code: .nameMismatch, "CHARACTER.md says \(character) and the bundle is \(manifest.character)"))
      }
    } else {
      issues.append(.init(.frontMatter, level: .error, "character is required, and must be a string"))
    }

    for key in ["age", "pronouns", "occupation", "artStyle", "sampleLine", "role"] {
      if let node = mapping[key], text(node) == nil {
        issues.append(.init(.frontMatter, "\(key) must be a string"))
      }
    }
    for key in ["aliases", "languages"] {
      if let node = mapping[key], !isStringArray(node) {
        issues.append(.init(.frontMatter, "\(key) must be an array of strings"))
      }
    }
    if let node = mapping["draft"] {
      if case .mapping(let draft) = node {
        for key in ["sources", "generated"] {
          if let value = draft[key], !isStringArray(value) {
            issues.append(.init(.frontMatter, "draft.\(key) must be an array of strings"))
          }
        }
        for key in ["generatedAt", "reviewedAt"] {
          if case .scalar(let scalar)? = draft[key], scalar.style == .plain, Self.isDate(scalar.string) {
            issues.append(.init(.frontMatter, "draft.\(key) is a date, and dates are quoted strings"))
          }
        }
      } else {
        issues.append(.init(.frontMatter, "draft must be an object"))
      }
    }
    return issues
  }

  /// `YYYY-MM-DD`.
  private static func isDate(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard bytes.count == 10 else { return false }
    return bytes.indices.allSatisfy { index in
      index == 4 || index == 7 ? bytes[index] == 0x2D : (0x30...0x39).contains(bytes[index])
    }
  }

  private func checkTier(
    of description: CharacterDescription, issues: inout [DescriptionCheckReport.Issue]
  ) -> (CastRole?, DescriptionCheckReport.TierSource?) {
    let copy = description.frontMatter?["role"]?.stringValue
    if let copy, CastRole(rawValue: copy) == nil {
      issues.append(.init(.frontMatter, "role is \(copy), which isn't a tier"))
    }
    if let member {
      guard let role = member.fields.role else {
        issues.append(.init(.sections, code: .role, "\(member.character) has no role, so sections can't be measured"))
        return (nil, nil)
      }
      if let copy, !copy.hasSameBytes(as: role.rawValue) {
        issues.append(.init(.frontMatter, "role is \(copy) here and \(role.rawValue) in CAST.md, which wins"))
      }
      return (role, .cast)
    }
    if let role = copy.flatMap(CastRole.init(rawValue:)) { return (role, .description) }
    if let role = manifest.role.flatMap(CastRole.init(rawValue:)) { return (role, .manifest) }
    issues.append(.init(.sections, "No role anywhere, so sections can't be measured against a tier"))
    return (nil, nil)
  }

  /// SPEC-GAP: §9.2: headings it doesn't list aren't addressed. They're allowed and listed, and
  /// don't affect the order. A section may repeat, as a parenthetical invites (`## Arc (Season 2)`).
  private func checkSections(
    of description: CharacterDescription, tier: CastRole?, issues: inout [DescriptionCheckReport.Issue]
  ) throws -> ([DescriptionCheckReport.SectionRow], [String]) {
    typealias Level = CompletenessReport.Level
    let levels = try tier?.descriptionLevels()
    func level(of name: String) -> (level: Level, row: String?) {
      guard let levels else { return (.none, nil) }
      if levels.full != .none, CharacterDocument.fullSections.contains(name) { return (levels.full, "description.full") }
      if levels.short != .none, CharacterDocument.shortSections.contains(name) { return (levels.short, "description.short") }
      return (.none, nil)
    }

    let found = description.sections
    func matching(_ name: String) -> [CharacterDescription.Section] {
      found.filter { CharacterDocument.heading($0.heading, matches: name) }
    }

    var rows: [DescriptionCheckReport.SectionRow] = []
    for name in CharacterDocument.allSections {
      let sections = matching(name)
      let asked = level(of: name)
      let hasContent = sections.contains { !$0.content.allSatisfy(\.isWhitespace) }
      rows.append(.init(name: name, level: asked.level, isPresent: !sections.isEmpty, hasContent: hasContent))
      if sections.isEmpty, asked.level == .required, let row = asked.row {
        issues.append(.init(.sections, code: .incomplete, "\(row): no \(name) section"))
      }
      if name == "Pronunciation", levels?.pronunciation == .required, !sections.isEmpty, !hasContent {
        issues.append(.init(.sections, code: .incomplete, "pronunciation: the Pronunciation section is empty"))
      }
    }

    var others: [String] = []
    var highest = -1
    for section in found {
      let rank = CharacterDocument.allSections.firstIndex { CharacterDocument.heading(section.heading, matches: $0) }
      guard let rank else {
        others.append(section.heading)
        continue
      }
      if rank < highest {
        issues.append(.init(.sections, "\(section.heading) is after \(CharacterDocument.allSections[highest])"))
      }
      highest = max(highest, rank)
    }
    return (rows, others)
  }
}
