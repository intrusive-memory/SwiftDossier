import ArgumentParser
import Dossier
import DossierCore
import Foundation

struct ListCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "List a bundle's assets.")
  @Argument(help: "The bundle.") var bundle: String
  @Option(help: "Only this kind.") var kind: String?
  @Option(help: "Only this variant.") var variant: String?
  @Option(help: "Only this status: selected, candidate or rejected.") var status: String?
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    let target = try openBundle(bundle)
    let assets = target.assets(kind: kind.map(AssetKind.init(rawValue:)), variant: variant)
      .filter { status == nil || $0.status.rawValue == status }
    if io.json {
      io.emit(["assets": assets.map(assetJSON)])
    } else {
      for asset in assets { io.line(assetLine(asset)) }
    }
    return 0
  }
}

struct CandidatesCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "candidates", abstract: "List the files in .generations/<CHARACTER>/, which aren't in the bundle.")
  @Argument(help: "The bundle.") var bundle: String
  @Option(help: "Only this kind.") var kind: String?
  @Option(help: "Only this variant.") var variant: String?
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    let target = try openBundle(bundle)
    let found = target.candidates(kind: kind.map(AssetKind.init(rawValue:)), variant: variant)
    if io.json {
      io.emit([
        "candidates": found.map { candidate -> [String: Any] in
          [
            "name": candidate.name, "path": candidate.url.path,
            "kind": candidate.kind.map { $0.rawValue as Any } ?? NSNull(),
            "variant": candidate.variant.map { $0 as Any } ?? NSNull(),
            "sidecar": candidate.sidecar.map { $0.path as Any } ?? NSNull(),
          ]
        }
      ])
    } else {
      for candidate in found {
        let kind = candidate.kind.map(\.rawValue) ?? "-"
        let sidecar = candidate.sidecar == nil ? "" : "  (sidecar)"
        io.line("\(kind)  \(candidate.variant ?? "-")  \(candidate.name)\(sidecar)")
      }
    }
    return 0
  }
}

struct ValidateCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "validate",
    abstract: "Validate a bundle, a project's CAST.md, or one bundle as its project sees it.",
    discussion: """
      dossier validate <bundle>             the bundle alone
      dossier validate --cast CAST.md       every member's bundle, the pointers and orphans
      dossier validate <bundle> --cast CAST.md   the findings for that bundle, from the project

      A page is compared with the template this tool carries: another template, older or \
      newer, is W-STALE.

      Exits 0 when clean, 1 with warnings only, 2 with any error.
      """)
  static var failureStatus: Int32 { 2 }

  @Argument(help: "The bundle.") var bundle: String?
  @Option(help: "The CAST.md.") var cast: String?
  @OptionGroup var output: OutputOptions

  func validate() throws {
    if bundle == nil && cast == nil { throw ValidationError("give a bundle, --cast CAST.md, or both") }
  }

  /// One finding, as printed.
  private struct Line {
    let code: String
    let level: String
    let message: String
    let path: String?
  }

  /// Each member of a `CAST.md`: its name, its §7 hash, and where its `manifest:` leads, which
  /// `make acceptance` reads. Empty for a file that can't be read, which is already `E-CAST`.
  private func memberLines(cast: URL) -> [[String: Any]] {
    guard let loaded = try? Cast.load(cast) else { return [] }
    return loaded.members.map { member in
      [
        "character": member.character, "hash": member.hash,
        "manifest": loaded.manifestURL(of: member).map { $0.path as Any } ?? NSNull(),
      ]
    }
  }

  func execute(io: CommandIO) throws -> Int32 {
    let template = try DossierTemplate.current
    let report: ValidationReport
    var extra: [Line] = []
    switch (bundle, cast) {
    case (let bundle?, nil):
      report = try DossierBundle.validate(at: fileURL(bundle), template: template)
    case (nil, let cast?):
      report = try DossierBundle.validate(cast: fileURL(cast), template: template)
    case (let bundle?, let cast?):
      (report, extra) = try bundleFromProject(bundle: fileURL(bundle), cast: fileURL(cast), template: template)
    case (nil, nil):
      throw CLIFailure("usage", "give a bundle, --cast CAST.md, or both", status: 64)
    }

    let lines =
      report.findings.map {
        Line(code: $0.code.rawValue, level: $0.level.rawValue, message: $0.message, path: $0.path)
      } + extra
    let status: Int32 =
      lines.contains { $0.level == "error" } ? 2 : (lines.isEmpty ? 0 : 1)

    if io.json {
      var object: [String: Any] = [
        "status": Int(status),
        "findings": lines.map { line -> [String: Any] in
          ["code": line.code, "level": line.level, "message": line.message, "path": line.path.map { $0 as Any } ?? NSNull()]
        },
        "completeness": report.completeness.map { entry -> [String: Any] in
          [
            "bundle": entry.bundlePath, "tier": entry.report.tier.rawValue,
            "isComplete": entry.report.isComplete, "missingRequired": entry.report.missingRequired,
            "rows": entry.report.rows.map { row -> [String: Any] in
              ["id": row.id, "label": row.label, "level": row.level.rawValue, "satisfied": row.isSatisfied]
            },
          ]
        },
      ]
      if bundle == nil, let cast { object["members"] = memberLines(cast: fileURL(cast)) }
      io.emit(object)
    } else {
      for line in lines {
        io.line("\(line.level) \(line.code)\(line.path.map { " \($0)" } ?? ""): \(line.message)")
      }
      let errors = lines.filter { $0.level == "error" }.count
      io.line("\(errors) errors, \(lines.count - errors) warnings")
    }
    return status
  }

  /// §14 for one bundle with the member `CAST.md` gives it. A bundle no member points at is
  /// validated alone and reported as an orphan, as the project-wide run would.
  private func bundleFromProject(
    bundle: URL, cast castURL: URL, template: PageTemplate
  ) throws -> (ValidationReport, [Line]) {
    guard let cast = try? Cast.load(castURL) else {
      // The project run reports the unreadable CAST.md as E-CAST.
      return (try DossierBundle.validate(cast: castURL, template: template), [])
    }
    guard let member = castMember(pointingAt: bundle, in: cast) else {
      let alone = try DossierBundle.validate(at: bundle, template: template)
      let orphan = Line(
        code: Finding.Code.orphan.rawValue, level: Finding.Code.orphan.level.rawValue,
        message: "No CAST.md member points at \(bundle.lastPathComponent)", path: nil)
      return (alone, [orphan])
    }
    guard let opened = try? DossierBundle.open(at: bundle, member: member) else {
      return (try DossierBundle.validate(at: bundle, template: template), [])
    }
    return (try opened.validate(template: template), [])
  }
}

struct CheckCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract: "Report on CHARACTER.md: front matter, sections against the tier, footnotes, open questions.",
    discussion: """
      Read-only. The tier is the CAST.md member's role with --cast; without it, the role copied \
      into CHARACTER.md or the manifest. Open questions are reported, not judged.

      Exits 0 when clean, 1 with warnings only, 2 with any error.
      """)
  static var failureStatus: Int32 { 2 }

  @Argument(help: "The bundle.") var bundle: String
  @Option(help: "The CAST.md, which gives the tier.") var cast: String?
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    let url = fileURL(bundle)
    var found: Cast.Member?
    if let cast {
      do {
        found = castMember(pointingAt: url, in: try Cast.load(fileURL(cast)))
      } catch {
        throw CLIFailure(Finding.Code.cast.rawValue, error.localizedDescription, status: 2)
      }
    }
    var report = try DossierBundle.open(at: url, member: found).checkDescription()
    if cast != nil, found == nil {
      report.append(.init(.file, code: .orphan, "No CAST.md member points at \(url.lastPathComponent)"))
    }

    if io.json {
      io.emit(Self.json(report))
    } else {
      printReport(report, io: io)
    }
    return report.exitStatus
  }

  private static func json(_ report: DescriptionCheckReport) -> [String: Any] {
    [
      "status": Int(report.exitStatus),
      "hasFile": report.hasFile,
      "frontMatterKeys": report.frontMatterKeys,
      "tier": report.tier.map { $0.rawValue as Any } ?? NSNull(),
      "tierSource": report.tierSource.map { $0.rawValue as Any } ?? NSNull(),
      "sections": report.sections.map { row -> [String: Any] in
        ["name": row.name, "level": row.level.rawValue, "present": row.isPresent, "hasContent": row.hasContent]
      },
      "otherSections": report.otherSections,
      "footnotes": [
        "undefined": report.footnotes.undefined, "unused": report.footnotes.unused,
        "unclassified": report.footnotes.unclassified,
      ],
      "openQuestions": report.openQuestions.map { group -> [String: Any] in
        [
          "group": group.name.map { $0 as Any } ?? NSNull(), "standard": group.isStandard,
          "empty": group.isEmpty, "items": group.items,
        ]
      },
      "issues": report.issues.map { issue -> [String: Any] in
        [
          "area": issue.area.rawValue, "level": issue.level.rawValue,
          "code": issue.codeText.map { $0 as Any } ?? NSNull(), "message": issue.message,
        ]
      },
    ]
  }

  private func printReport(_ report: DescriptionCheckReport, io: CommandIO) {
    if report.hasFile, !report.sections.isEmpty {
      let source = report.tierSource.map { " (from \($0.rawValue))" } ?? ""
      io.line("tier: \(report.tier?.rawValue ?? "none")\(source)")
      let present = report.sections.filter(\.isPresent).map(\.name)
      let absent = report.sections.filter { !$0.isPresent }.map(\.name)
      io.line("sections: \(present.count) of \(report.sections.count)")
      if !absent.isEmpty { io.line("  absent: \(absent.joined(separator: ", "))") }
      if !report.otherSections.isEmpty { io.line("  other: \(report.otherSections.joined(separator: ", "))") }
      io.line("open questions:\(report.openQuestions.isEmpty ? " none" : "")")
      for group in report.openQuestions {
        io.line("  \(group.name ?? "(no group)"): \(group.items.count)")
        for item in group.items { io.line("    - \(item)") }
      }
    }
    for issue in report.issues {
      io.line("\(issue.level.rawValue)\(issue.codeText.map { " \($0)" } ?? "") [\(issue.area.rawValue)]: \(issue.message)")
    }
    let errors = report.issues.filter { $0.level == .error }.count
    io.line("\(errors) errors, \(report.issues.count - errors) warnings")
  }
}

struct RenderCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "render", abstract: "Render a bundle's page. Not available yet.")
  @Argument(help: "The bundle.") var bundle: String?
  @Option(help: "The CAST.md.") var cast: String?
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    throw CLIFailure(
      "not-available",
      "render is not available: this version carries the page template but has no renderer for it yet",
      status: 69)
  }
}

struct MigrateCommand: DossierSubcommand {
  static let configuration = CommandConfiguration(
    commandName: "migrate", abstract: "Migrate a version 1 bundle. Not available yet.")
  @Argument(help: "The bundle.") var bundle: String?
  @Option(help: "The CAST.md.") var cast: String?
  @Flag(help: "Perform the migration; a dry run otherwise.") var apply = false
  @OptionGroup var output: OutputOptions

  func execute(io: CommandIO) throws -> Int32 {
    throw CLIFailure(
      "not-available", "migrate is not available: it is phase 4 of the plan and has not been built", status: 69)
  }
}
