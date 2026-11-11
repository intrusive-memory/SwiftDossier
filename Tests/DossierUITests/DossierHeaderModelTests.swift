import Dossier
import DossierCore
import Foundation
import SwiftReparto
import Testing

@testable import DossierUI

/// The dossier-format tree: `.dossier-format/` (the pinned tag, fetched by `make fixtures`), or
/// the directory in DOSSIER_SPEC_DIR when `make test SPEC_DIR=<path>` is used.
enum SpecTree {
  static let override: URL? = {
    guard let path = ProcessInfo.processInfo.environment["DOSSIER_SPEC_DIR"], !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }()
  static let root: URL = override ?? URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".dossier-format")
  static let examples = root.appendingPathComponent("examples")
}

/// A project in a temporary directory: the synthetic `Fixtures/header-cast/CAST.md` beside three
/// of dossier-format's `examples/valid/` bundles. Synthetic data only (SD-4).
struct HeaderProject {
  /// Each example case, and the bundle it holds.
  static let bundles = [
    ("empty-background", "BYSTANDER #2.dossier"),
    ("complete-lead", "WREN HALLOWAY.dossier"),
    ("hand-edited-member", "THE FERRYMAN.dossier"),
  ]
  static let castSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/header-cast/CAST.md")

  let root: URL
  var castURL: URL { root.appendingPathComponent("CAST.md") }

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DossierHeaderModelTests-\(UUID().uuidString)", isDirectory: true)
    let characters = root.appendingPathComponent("characters", isDirectory: true)
    try FileManager.default.createDirectory(at: characters, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: Self.castSource, to: castURL)
    for (example, bundle) in Self.bundles {
      let source = SpecTree.examples.appendingPathComponent("valid/\(example)/characters/\(bundle)")
      try FileManager.default.copyItem(at: source, to: characters.appendingPathComponent(bundle))
    }
  }

  func bundleURL(_ character: String) -> URL {
    root.appendingPathComponent("characters/\(character).dossier", isDirectory: true)
  }

  /// The model the viewer would make: the bundle opened through `CAST.md`, or, when it can't be
  /// opened, the member found by name.
  func model(_ character: String, project: DossierProjectContext = DossierProjectContext()) throws
    -> DossierHeaderModel
  {
    let url = bundleURL(character)
    let bundle = try? DossierBundle.openForPreview(at: url, cast: castURL)
    let listed = try Cast.load(castURL).members.first { $0.character == character }?.fields
    let member = bundle?.member?.fields ?? listed
    return DossierHeaderModel(
      project: project, bundleURL: url, bundle: bundle, member: member,
      update: UpdateStatus.read(bundle: url, at: Date()), rebuild: DossierRebuildAction(perform: {}))
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite
struct DossierHeaderModelTests {
  // MARK: The synthetic CAST.md

  @Test func theFixtureHasFourMembers() throws {
    let project = try HeaderProject()
    defer { project.remove() }
    let members = try Cast.load(project.castURL).members
    #expect(members.map(\.character) == ["BYSTANDER #2", "LANTERN", "WREN HALLOWAY", "THE FERRYMAN"])
    #expect(members.last?.fields.displayName == "The Ferryman")
  }

  // MARK: Role precedence (DH-2)

  @Test func theMembersRoleWinsOverTheManifests() throws {
    let project = try HeaderProject()
    defer { project.remove() }
    let bundle = try DossierBundle.openForPreview(at: project.bundleURL("BYSTANDER #2"), cast: project.castURL)
    #expect(bundle.manifest.role == "background")
    #expect(try project.model("BYSTANDER #2").role == "Guest Star")
  }

  @Test func aManifestOnlyRoleShowsItsDisplayName() throws {
    let project = try HeaderProject()
    defer { project.remove() }
    let model = try project.model("WREN HALLOWAY")
    #expect(model.character == "WREN HALLOWAY")
    #expect(model.role == "Lead")
  }

  @Test func noRoleInEitherPlaceIsNil() {
    #expect(DossierHeaderModel.role(member: nil, manifest: nil) == nil)
  }

  @Test func theMembersRoleIsUsedWithNoManifestRole() {
    #expect(DossierHeaderModel.role(member: .supporting, manifest: nil) == "Supporting")
  }

  /// N-7: "Guest Star" isn't `"guest".capitalized`.
  @Test func aManifestOnlyGuestIsGuestStar() {
    #expect(DossierHeaderModel.role(member: nil, manifest: "guest") == "Guest Star")
  }

  @Test(arguments: CastRole.allCases)
  func everyManifestRoleMapsThroughCastRole(_ role: CastRole) {
    #expect(DossierHeaderModel.role(member: nil, manifest: role.rawValue) == role.displayName)
  }

  @Test func aManifestRoleThatIsntACastRoleIsNil() {
    #expect(DossierHeaderModel.role(member: nil, manifest: "Lead") == nil)
    #expect(DossierHeaderModel.role(member: nil, manifest: "extra") == nil)
  }

  // MARK: Display name (DH-2)

  @Test func theDisplayNameIsPreferred() throws {
    let project = try HeaderProject()
    defer { project.remove() }
    let model = try project.model("THE FERRYMAN")
    #expect(model.character == "THE FERRYMAN")
    #expect(model.displayName == "The Ferryman")
    #expect(model.role == "Background")
  }

  @Test func aMemberWithNoDisplayNameHasNone() throws {
    let project = try HeaderProject()
    defer { project.remove() }
    #expect(try project.model("WREN HALLOWAY").displayName == nil)
  }

  @Test(arguments: ["", " ", "   ", "\t", " \n "])
  func anEmptyOrWhitespaceDisplayNameIsIgnored(_ value: String) {
    #expect(DossierHeaderModel.displayName(value) == nil)
    let member = CastMember(character: "WREN HALLOWAY", displayName: value)
    let model = DossierHeaderModel(
      bundleURL: URL(fileURLWithPath: "/tmp/WREN HALLOWAY.dossier", isDirectory: true), bundle: nil,
      member: member, update: UpdateStatus.read(bundle: URL(fileURLWithPath: "/nonexistent"), at: Date()),
      rebuild: DossierRebuildAction(perform: {}))
    #expect(model.displayName == nil)
    #expect(model.character == "WREN HALLOWAY")
  }

  @Test func aDisplayNameWithTextIsKeptAsWritten() {
    #expect(DossierHeaderModel.displayName(" Wren ") == " Wren ")
  }

  // MARK: A bundle that can't be opened (DH-11)

  @Test func anUnopenableBundleShowsItsStem() throws {
    let project = try HeaderProject()
    defer { project.remove() }
    #expect(throws: (any Error).self) {
      try DossierBundle.openForPreview(at: project.bundleURL("LANTERN"), cast: project.castURL)
    }
    let model = try project.model("LANTERN")
    #expect(model.character == "LANTERN")
    #expect(model.role == nil)
    #expect(model.displayName == nil)
    #expect(model.update.isUpdating == false)
  }

  @Test func theStemDropsTheExtension() {
    let url = URL(fileURLWithPath: "/tmp/characters/BYSTANDER #2.dossier", isDirectory: true)
    #expect(DossierHeaderModel.stem(of: url) == "BYSTANDER #2")
  }

  // MARK: Project context (DH-1)

  @Test func theProjectContextIsCarried() throws {
    let project = try HeaderProject()
    defer { project.remove() }
    let context = DossierProjectContext(title: "The Lighthouse Keepers", bundlePath: "characters/WREN HALLOWAY.dossier")
    let model = try project.model("WREN HALLOWAY", project: context)
    #expect(model.project == context)
    #expect(DossierProjectContext() == DossierProjectContext(title: nil, bundlePath: nil))
  }
}
