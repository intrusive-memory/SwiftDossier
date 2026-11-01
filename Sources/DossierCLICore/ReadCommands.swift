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

  func execute(io: CommandIO) throws -> Int32 {
    let report: ValidationReport
    var extra: [Line] = []
    switch (bundle, cast) {
    case (let bundle?, nil):
      report = try DossierBundle.validate(at: fileURL(bundle))
    case (nil, let cast?):
      report = try DossierBundle.validate(cast: fileURL(cast))
    case (let bundle?, let cast?):
      (report, extra) = try bundleFromProject(bundle: fileURL(bundle), cast: fileURL(cast))
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
      io.emit([
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
      ])
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
  private func bundleFromProject(bundle: URL, cast castURL: URL) throws -> (ValidationReport, [Line]) {
    let target = bundle.resolvingSymlinksInPath()
    guard let cast = try? Cast.load(castURL) else {
      // The project run reports the unreadable CAST.md as E-CAST.
      return (try DossierBundle.validate(cast: castURL), [])
    }
    let member = cast.members.first { member in
      cast.manifestURL(of: member)?.deletingLastPathComponent().resolvingSymlinksInPath().path == target.path
    }
    guard let member else {
      let alone = try DossierBundle.validate(at: bundle)
      let orphan = Line(
        code: Finding.Code.orphan.rawValue, level: Finding.Code.orphan.level.rawValue,
        message: "No CAST.md member points at \(bundle.lastPathComponent)", path: nil)
      return (alone, [orphan])
    }
    guard let opened = try? DossierBundle.open(at: bundle, member: member) else {
      return (try DossierBundle.validate(at: bundle), [])
    }
    return (try opened.validate(), [])
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
      "render is not available: it waits on the dossier-format page template, which is not published yet",
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
