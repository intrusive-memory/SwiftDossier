import DossierCore
import Foundation
import Testing

@testable import Dossier

/// The dossier-format tree the tests read: `.dossier-format/` (the pinned tag, fetched by
/// `make fixtures`), or the directory in DOSSIER_SPEC_DIR when `make test SPEC_DIR=<path>` is used.
enum SpecTree {
  static let override: URL? = {
    guard let path = ProcessInfo.processInfo.environment["DOSSIER_SPEC_DIR"], !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }()
  static var isOverridden: Bool { override != nil }
  static let root: URL = override ?? URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".dossier-format")
  static let examples = root.appendingPathComponent("examples")

  /// An independent walk: every directory under examples/ that holds a CAST.md, relative to examples/.
  static func fixtureDirectories() -> [String] {
    let base = examples.resolvingSymlinksInPath().path
    guard let walker = FileManager.default.enumerator(atPath: base) else { return [] }
    var found: [String] = []
    for case let relative as String in walker where relative.hasSuffix("/CAST.md") {
      found.append(String(relative.dropLast("/CAST.md".count)))
    }
    return found.sorted()
  }
}

/// The pinned revision's fixtures. A missing `.dossier-format/` fails `everyFixtureIsPresent`
/// rather than skipping it (`make test` fetches them).
enum Conformance {
  struct Entry: Decodable, Sendable, CustomTestStringConvertible {
    let path: String
    let bundle: String
    let verdict: String
    let codes: [String]
    let mayAlso: [String]
    let complete: Bool?
    let missingRequired: [String]?
    /// `examples/README.md`: `at` is the time to use as `now`, and `updating` is §5.7's answer.
    let updateStatus: UpdateAssertion?

    struct UpdateAssertion: Decodable, Sendable {
      let at: String
      let updating: Bool
    }

    var testDescription: String { path }
  }

  struct Document: Decodable {
    let templateVersion: String
    let templateSha256: String
    let fixtures: [Entry]
  }

  static let root = SpecTree.examples

  static func document() throws -> Document {
    try JSONDecoder().decode(
      Document.self, from: Data(contentsOf: root.appendingPathComponent("conformance.json")))
  }

  /// Empty when the fixtures are absent, which `everyFixtureIsPresent` fails on.
  static let entries: [Entry] = (try? document().fixtures) ?? []

  static func template() throws -> PageTemplate {
    let document = try document()
    return PageTemplate(version: document.templateVersion, sha256: document.templateSha256)
  }

  static func castURL(of path: String) -> URL {
    root.appendingPathComponent(path).appendingPathComponent("CAST.md")
  }

  /// Every directory under examples/ named `update-*`, relative to it.
  static func updateFixtureDirectories() -> [String] {
    let base = root.resolvingSymlinksInPath()
    guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else {
      return []
    }
    var found: [String] = []
    for case let url as URL in walker
    where url.lastPathComponent.hasPrefix("update-")
      && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    {
      found.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1)))
    }
    return found.sorted()
  }

  /// The `update-*` fixtures with no entry asserting `updateStatus`.
  static func unasserted(updateFixtures: [String], entries: [Entry]) -> [String] {
    let asserted = Set(entries.filter { $0.updateStatus != nil }.map(\.path))
    return updateFixtures.filter { !asserted.contains($0) }
  }
}

@Suite("Conformance (conformance.json)")
struct ConformanceTests {
  @Test("conformance.json lists exactly the fixture directories in examples/")
  func everyFixtureIsPresent() throws {
    let listed = try Conformance.document().fixtures.map(\.path)
    #expect(Set(listed).count == listed.count, "a path is listed twice")
    #expect(!listed.isEmpty)
    let onDisk = SpecTree.fixtureDirectories()
    #expect(Set(listed).subtracting(onDisk).sorted().isEmpty, "listed but missing: \(Set(listed).subtracting(onDisk).sorted())")
    #expect(Set(onDisk).subtracting(listed).sorted().isEmpty, "present but unlisted: \(Set(onDisk).subtracting(listed).sorted())")
    #expect(Conformance.entries.count == listed.count)
  }

  @Test("A fixture produces what conformance.json says", arguments: Conformance.entries)
  func fixture(_ entry: Conformance.Entry) throws {
    let report = try DossierBundle.validate(
      cast: Conformance.castURL(of: entry.path), template: Conformance.template())
    let reported = Set(report.findings.map(\.code.rawValue))

    let missing = Set(entry.codes).subtracting(reported)
    #expect(missing.isEmpty, "not reported: \(missing.sorted())")
    let surplus = reported.subtracting(entry.codes).subtracting(entry.mayAlso)
    let detail = report.findings.filter { surplus.contains($0.code.rawValue) }
      .map { "\($0.code.rawValue) \($0.path ?? "-"): \($0.message)" }
    #expect(surplus.isEmpty, "not allowed: \(detail)")

    let verdicts = [0: "valid", 1: "warnings", 2: "invalid"]
    #expect(verdicts[Int(report.exitStatus)] == entry.verdict)

    if let complete = entry.complete {
      let measured = report.completeness.first {
        $0.bundlePath.precomposedStringWithCanonicalMapping == entry.bundle.precomposedStringWithCanonicalMapping
      }
      let found = try #require(measured, "no completeness for \(entry.bundle)")
      #expect(found.report.isComplete == complete)
      #expect(found.report.missingRequired == entry.missingRequired?.sorted())
    }

    if let assertion = entry.updateStatus {
      let now = try #require(UpdateMarker.date(fromTimestamp: assertion.at), "updateStatus.at: \(assertion.at)")
      let bundle = try DossierBundle.open(
        at: Conformance.root.appendingPathComponent(entry.path).appendingPathComponent(entry.bundle))
      #expect(bundle.updateStatus(at: now).isUpdating == assertion.updating)
    }
  }

  // The pinned tag has these fixtures, and the assertion in `fixture` runs on them. A tree that
  // has them can't pass without asserting them.
  @Test("An update-* fixture has an updateStatus entry")
  func updateFixturesAreAsserted() throws {
    let entries = try Conformance.document().fixtures
    let unasserted = Conformance.unasserted(
      updateFixtures: Conformance.updateFixtureDirectories(), entries: entries)
    #expect(unasserted.isEmpty, "update fixtures nothing asserts: \(unasserted)")
  }

  @Test("The check above finds an update-* fixture with no updateStatus")
  func updateFixtureCheckBites() throws {
    let plain = try JSONDecoder().decode(
      Conformance.Entry.self,
      from: Data(#"{"path": "valid/update-a", "bundle": "b", "verdict": "valid", "codes": [], "mayAlso": []}"#.utf8))
    #expect(plain.updateStatus == nil)
    #expect(Conformance.unasserted(updateFixtures: ["valid/update-a"], entries: [plain]) == ["valid/update-a"])
    let asserted = try JSONDecoder().decode(
      Conformance.Entry.self,
      from: Data(
        #"{"path": "valid/update-a", "bundle": "b", "verdict": "valid", "codes": [], "mayAlso": [], "updateStatus": {"at": "2026-10-19T17:00:00Z", "updating": true}}"#
          .utf8))
    #expect(Conformance.unasserted(updateFixtures: ["valid/update-a"], entries: [asserted]).isEmpty)
  }

  @Test("§14: a validator changes nothing")
  func readsOnly() throws {
    let project = Conformance.root.appendingPathComponent("warnings/W-STALE")
    func snapshot() throws -> [String] {
      let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
      let walker = try #require(FileManager.default.enumerator(at: project, includingPropertiesForKeys: keys))
      return try walker.compactMap { $0 as? URL }.map { url in
        let values = try url.resourceValues(forKeys: Set(keys))
        return "\(url.path) \(values.fileSize ?? -1) \(String(describing: values.contentModificationDate))"
      }.sorted()
    }
    let before = try snapshot()
    _ = try DossierBundle.validate(cast: project.appendingPathComponent("CAST.md"), template: Conformance.template())
    #expect(try snapshot() == before)
  }
}

@Suite("Validator entry points")
struct ValidatorEntryPointTests {
  private func bundle(_ project: String, _ name: String) -> URL {
    Conformance.root.appendingPathComponent(project).appendingPathComponent("characters").appendingPathComponent(name)
  }

  @Test("§14: every code has its level, and the exit status follows")
  func levelsAndExitStatus() {
    for code in Finding.Code.allCases {
      #expect(code.level == (code.rawValue.hasPrefix("E-") ? .error : .warning))
    }
    #expect(Finding.Code.allCases.count == 31)
    let warning = Finding(code: .role, message: "", path: nil)
    let error = Finding(code: .path, message: "", path: nil)
    #expect(ValidationReport(findings: [], completeness: []).exitStatus == 0)
    #expect(ValidationReport(findings: [warning], completeness: []).exitStatus == 1)
    #expect(ValidationReport(findings: [warning, error], completeness: []).exitStatus == 2)
  }

  @Test("A directory with no CAST.md has no tier, so no W-INCOMPLETE or completeness")
  func noCast() throws {
    let report = try DossierBundle.validate(
      at: bundle("warnings/W-INCOMPLETE", "WREN HALLOWAY.dossier"), template: Conformance.template())
    #expect(!report.findings.contains { $0.code == .incomplete })
    #expect(report.completeness.isEmpty)
  }

  @Test("A directory that doesn't open as a bundle is still reported on")
  func unopenable() throws {
    let codes = { (project: String, name: String) in
      try DossierBundle.validate(at: bundle(project, name)).findings.map(\.code)
    }
    #expect(try codes("errors/E-MANIFEST-missing", "PELL ARDEN.dossier") == [.manifest])
    #expect(try codes("errors/E-VERSION", "PELL ARDEN.dossier") == [.version])
    #expect(try codes("errors/E-NOT-BUNDLE", "PELL ARDEN") == [.notBundle])
  }

  @Test("An opened bundle's member is measured, as from a cast")
  func openedWithMember() throws {
    let cast = try Cast.load(Conformance.castURL(of: "warnings/W-INCOMPLETE"))
    let opened = try #require(try cast.openBundle(for: cast.members[0]))
    let report = try opened.validate(template: Conformance.template())
    #expect(report.findings.contains { $0.code == .incomplete })
    #expect(report.completeness.first?.bundlePath == "")
  }

  @Test("§5.2: a symlink isn't a file, and isn't followed")
  func symlink() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    let directory = root.appendingPathComponent("NOBODY.dossier")
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("outside.txt")
    try Data("outside\n".utf8).write(to: outside)
    try manager.createSymbolicLink(
      at: directory.appendingPathComponent("linked.txt"), withDestinationURL: outside)
    let hash = Checksum.sha256(Data("outside\n".utf8))
    let manifest = """
      {"manifestVersion": 2, "character": "NOBODY", "updatedAt": "2026-10-31T12:00:00Z",
       "files": [{"path": "linked.txt", "sha256": "\(hash)", "sizeBytes": 8}], "assets": [],
       "manifestChecksum": "\(Checksum.sorted([hash]))"}
      """
    try Data(manifest.utf8).write(to: directory.appendingPathComponent("manifest.json"))
    let codes = try DossierBundle.validate(at: directory).findings.map(\.code)
    #expect(codes == [.fileMissing])
  }
}

@Suite("Page references (§11)")
struct PageReferencesTests {
  private func external(_ html: String) -> [String] {
    PageReferences.external(in: Array(html.utf8)).map(\.value)
  }

  @Test("Comments, text and scripts aren't searched")
  func notSearched() {
    #expect(external(#"<!-- <img src="x.png"> --><p>url(x.png) src="x.png"</p>"#) == [])
    #expect(external(#"<script src=""> fetch("x"); var s = '<img src="x.png">'; </script>"#) == [])
    #expect(external(#"<title><img src="x.png"></title><textarea><img src="y.png"></textarea>"#) == [])
    #expect(external(##"<!doctype html><?pi src="x"?><img src="#a">"##) == [])
  }

  @Test("Every listed attribute, on any element, in any case")
  func attributes() {
    #expect(external(#"<IMG SRC="a.png">"#) == ["a.png"])
    #expect(external(#"<video poster=a.png>"#) == ["a.png"])
    #expect(external(#"<object data='a'>"#) == ["a"])
    #expect(external(#"<form action="a"><button formaction="b">"#) == ["a", "b"])
    #expect(external(#"<td background="a">"#) == ["a"])
    #expect(external(#"<use xlink:href="a.svg">"#) == ["a.svg"])
    #expect(external(#"<div data-src="a" title="b">"#) == [])
  }

  @Test("What's allowed: empty, a fragment, data: in any case, an <a>'s web and mail links")
  func allowed() {
    #expect(external(#"<img src=""><img src="  #x"><img src=" DATA:image/png;base64,AA">"#) == [])
    #expect(external(#"<a href="https://x.invalid/a"><a href="HTTP://x.invalid"><a href="mailto:a@x.invalid">"#) == [])
    #expect(external(#"<a href="ftp://x.invalid">"#) == ["ftp://x.invalid"])
    #expect(external(#"<a href="b.html">"#) == ["b.html"])
    #expect(external(#"<link href="https://x.invalid/s.css">"#) == ["https://x.invalid/s.css"])
    #expect(external(#"<a src="https://x.invalid">"#) == ["https://x.invalid"])
  }

  @Test("A srcset splits as HTML splits it")
  func srcset() {
    #expect(PageReferences.srcsetCandidates("data:image/png;base64,AA,BB 1x, data:image/png,CC 2x") == [
      "data:image/png;base64,AA,BB", "data:image/png,CC",
    ])
    #expect(PageReferences.srcsetCandidates("a.png, b.png") == ["a.png", "b.png"])
    #expect(PageReferences.srcsetCandidates("a.png 1x,b.png 2x") == ["a.png", "b.png"])
    #expect(external(#"<img srcset="data:image/png;base64,AA,BB 1x, b.png 2x">"#) == ["b.png"])
  }

  @Test("url() and @import, in <style> and style=, read as CSS")
  func css() {
    #expect(external(#"<style>a { background: url(x.png) }</style>"#) == ["x.png"])
    #expect(external(#"<style>@import "x.css";</style>"#) == ["x.css"])
    #expect(external(#"<style>@IMPORT URL('x.css');</style>"#) == ["x.css"])
    #expect(external(#"<p style="background: url( 'x.png' )">"#) == ["x.png"])
    #expect(external(#"<style>/* url(x.png) */ a { content: "url(y.png)" }</style>"#) == [])
    #expect(external(#"<style>a { background: url("data:image/svg+xml,url(z)") }</style>"#) == [])
    #expect(external(#"<style>a { background: url(#f) } b { background: myurl(x) }</style>"#) == [])
    #expect(external(#"<style>a { background: u\72l(x.png) }</style>"#) == ["x.png"])
  }

  @Test("Character references are read, as HTML reads them")
  func characterReferences() {
    #expect(external(#"<img src="&#100;ata:x">"#) == [])
    #expect(external(#"<img src="&#x2e;&#x2F;a.png">"#) == ["./a.png"])
    #expect(external(#"<p style="background: url&lpar;x.png&rpar;">"#) == ["x.png"])
    #expect(external(#"<a href="https&colon;//x.invalid">"#) == [])
  }

  @Test("Attributes parse as HTML: first wins, and a tag the file ends in never existed")
  func tokenizer() {
    #expect(external(##"<img src="#a" src="b.png">"##) == [])
    #expect(external(#"<img alt="a>b" src="c.png">"#) == ["c.png"])
    #expect(external(#"<img src="a.png"#) == [])
  }
}

@Suite("Footnotes (§9.3)")
struct FootnotesTests {
  @Test("A reference needs a definition, and a definition a reference")
  func bothWays() {
    let result = Footnotes.check(body: "A[^a] B[^b]\n\n[^a]: Stated. x\n[^c]: Author. y\n")
    #expect(result.undefined == ["b"])
    #expect(result.unused == ["c"])
  }

  @Test("A definition's text can hold a reference")
  func nested() {
    let result = Footnotes.check(body: "A[^a]\n\n[^a]: Inferred. See[^b]\n[^b]: Stated. x\n")
    #expect(result.undefined.isEmpty)
    #expect(result.unused.isEmpty)
  }

  @Test("Code isn't read, and neither is an escape")
  func code() {
    let body = "`[^a]` and ``[^b]`` and \\[^c]\n\n```\n[^d]\n```\n"
    #expect(Footnotes.check(body: body).undefined.isEmpty)
  }
}
