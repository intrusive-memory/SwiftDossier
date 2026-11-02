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
    commandName: "render", abstract: "Write a bundle's page, or the page of every member of a CAST.md with a dossier.",
    discussion: """
      dossier render <bundle>               that bundle's page; its member comes from CAST.md
      dossier render <bundle> --cast CAST.md   the same, from that CAST.md
      dossier render --cast CAST.md         every member with a dossier, reported one by one

      A page needs its CAST.md member (§7). Without --cast, CAST.md is looked for in the \
      bundle's parent directory and then its grandparent, and nowhere else. A member that \
      doesn't point at the bundle is refused.

      The same inputs give the same bytes. A render that fails leaves the previous page and \
      manifest as they were. Exits 0, or 1 when any render fails.

      A file that doesn't match its entry refuses the render, except the page being replaced. Run \
      refresh to accept a changed file (E-FILE-HASH) or drop a missing one with no asset \
      (E-FILE-MISSING); an asset's missing file must be restored, or the asset removed.
      """)

  @Argument(help: "The bundle.") var bundle: String?
  @Option(help: "The CAST.md.") var cast: String?
  @OptionGroup var output: OutputOptions

  func validate() throws {
    if bundle == nil && cast == nil { throw ValidationError("give a bundle, --cast CAST.md, or both") }
  }

  func execute(io: CommandIO) throws -> Int32 {
    guard let bundle else {
      guard let cast else { throw CLIFailure("usage", "give a bundle, --cast CAST.md, or both", status: 64) }
      return try renderAll(cast: fileURL(cast), io: io)
    }
    let directory = fileURL(bundle)
    let castURL = try cast.map(fileURL) ?? Self.findCast(near: directory)
    let loaded = try Cast.load(castURL)
    guard let member = castMember(pointingAt: directory, in: loaded) else {
      throw CLIFailure("member-not-found", "No member of \(castURL.path) points at \(directory.path)")
    }
    var target = try DossierBundle.open(at: directory, member: member)
    let page = try target.renderPage()
    if io.json {
      io.emit(Self.object(member: member, bundle: directory, page: page))
    } else {
      io.line("Rendered \(page.url.path) (\(page.sizeBytes) bytes)")
    }
    return 0
  }

  /// SPEC-GAP: §7, §11: a page's `castMember` input needs a member and a bundle doesn't hold one.
  /// §3 only starts discovery from `CAST.md`, so nothing says how to get from a bundle to it. This
  /// looks where a project's layout puts it, the bundle's parent and then its grandparent, with no
  /// scanning, and otherwise refuses.
  static func findCast(near bundle: URL) throws -> URL {
    let parent = bundle.deletingLastPathComponent()
    for directory in [parent, parent.deletingLastPathComponent()] {
      let candidate = directory.appendingPathComponent("CAST.md")
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    throw CLIFailure(
      "cast-not-found", "No CAST.md in the bundle's parent or grandparent directory; pass --cast CAST.md")
  }

  private func renderAll(cast castURL: URL, io: CommandIO) throws -> Int32 {
    let loaded = try Cast.load(castURL)
    var reports: [[String: Any]] = []
    var failed = 0
    for member in loaded.members where member.pointer != nil {
      let directory = loaded.manifestURL(of: member)?.deletingLastPathComponent()
      do {
        guard var target = try loaded.openBundle(for: member), let directory else { continue }
        let page = try target.renderPage()
        reports.append(Self.object(member: member, bundle: directory, page: page))
        if !io.json { io.line("\(member.character): rendered \(page.url.path) (\(page.sizeBytes) bytes)") }
      } catch {
        failed += 1
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        reports.append([
          "character": member.character, "status": "failed",
          "bundle": directory.map { $0.path as Any } ?? NSNull(),
          "error": ["code": String(String(describing: error).prefix { $0 != "(" }), "message": message],
        ])
        if !io.json { io.note("\(member.character): failed: \(message)") }
      }
    }
    if io.json {
      var object: [String: Any] = ["members": reports]
      if failed > 0 {
        object["error"] = ["code": "render-failed", "message": "\(failed) of \(reports.count) renders failed"]
      }
      io.emit(object)
    } else {
      io.line("\(reports.count - failed) of \(reports.count) rendered")
    }
    return failed > 0 ? 1 : 0
  }

  private static func object(member: Cast.Member, bundle: URL, page: RenderedPage) -> [String: Any] {
    [
      "character": member.character, "status": "rendered", "bundle": bundle.path, "page": page.url.path,
      "sizeBytes": page.sizeBytes, "role": member.fields.role.map { $0.rawValue as Any } ?? NSNull(),
      "banner": page.banner.map { ["code": $0.code.rawValue, "path": $0.path.map { $0 as Any } ?? NSNull()] },
    ]
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
