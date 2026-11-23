import CoreGraphics
import DossierCore
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Dossier

/// `acceptStale(path:at:)` (§7, DF-100), on copies of the pinned fixtures.
@Suite("Accepting a stale asset (§7, DF-100)")
struct AcceptStaleTests {
  private static let view = "images/view-front-b31b46b8.png"
  private static let acceptedAt = Date(timeIntervalSince1970: 1_795_000_000.75)
  private static let acceptedAtText = "2026-11-18T11:06:40Z"

  /// A copy of a fixture project, and its bundle.
  private struct Copy {
    let root: URL
    let bundleURL: URL

    init(_ fixture: String, bundle: String = "characters/PELL ARDEN.dossier") throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AcceptStaleTests-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
      try FileManager.default.copyItem(at: SpecTree.examples.appendingPathComponent(fixture), to: root)
      bundleURL = root.appendingPathComponent(bundle, isDirectory: true)
    }

    func open() throws -> DossierBundle { try DossierBundle.open(at: bundleURL) }
    var manifestBytes: Data { (try? Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))) ?? Data() }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  private func stalePaths(_ bundle: DossierBundle) -> Set<String> { Set(bundle.stale().map(\.path)) }

  private func asset(_ path: String, in bundle: DossierBundle) throws -> Asset {
    try #require(bundle.manifest.assets.first { $0.path == path })
  }

  /// A PNG that isn't any fixture's, so its hash is new.
  private func png(shade: UInt8) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 18, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: CGFloat(shade) / 255, green: 0.4, blue: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 18, height: 32))
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }

  @Test("Accepting records the selection's hash, keeps the old entry, and changes no input or file")
  func acceptClearsStaleness() throws {
    let copy = try Copy("warnings/W-STALE-accepted-older-portrait")
    defer { copy.remove() }
    var bundle = try copy.open()
    #expect(stalePaths(bundle).contains(Self.view))
    let before = try asset(Self.view, in: bundle)
    let selectedPortrait = try #require(bundle.selectedAsset(kind: .portrait))
    let portraitHash = try #require(bundle.manifest.files.first { $0.path == selectedPortrait.path }?.sha256)
    let filesBefore = bundle.manifest.files

    let written = try bundle.acceptStale(path: Self.view, at: Self.acceptedAt)

    #expect(!stalePaths(bundle).contains(Self.view))
    #expect(written.accepted.count == before.accepted.count + 1)
    #expect(Array(written.accepted.prefix(before.accepted.count)) == before.accepted)
    let added = try #require(written.accepted.last)
    #expect(added.role == "portrait")
    #expect(added.sha256 == portraitHash)
    #expect(added.acceptedAt == Self.acceptedAtText)
    #expect(added.json.keys.sorted() == ["acceptedAt", "role", "sha256"])
    #expect(written.derivedFrom == before.derivedFrom)
    #expect(written.provenance == before.provenance)
    #expect(written.status == .selected)

    let reopened = try copy.open()
    #expect(try asset(Self.view, in: reopened) == written)
    #expect(reopened.manifest.files == filesBefore)
    let report = try reopened.validate()
    #expect(!report.findings.contains { $0.code == .stale && $0.path == Self.view }, "\(report.findings)")
    #expect(!report.findings.contains { $0.code == .schema }, "\(report.findings)")
  }

  @Test("A later portrait makes the accepted view stale again; accepting again clears it")
  func laterChangeReStales() throws {
    let copy = try Copy("warnings/W-STALE-accepted-older-portrait")
    defer { copy.remove() }
    var bundle = try copy.open()
    try bundle.acceptStale(path: Self.view, at: Self.acceptedAt)
    #expect(!stalePaths(bundle).contains(Self.view))

    let source = copy.root.appendingPathComponent("new-portrait.png")
    try png(shade: 200).write(to: source)
    var options = AddOptions()
    options.select = true
    let portrait = try bundle.add(source, kind: .portrait, options: options)
    #expect(portrait.status == .selected)
    #expect(stalePaths(bundle).contains(Self.view))

    // Acceptance is of a value: reselecting an accepted portrait matches its entry again.
    try bundle.select(path: "images/portrait-cfe63dbc.png")
    #expect(!stalePaths(bundle).contains(Self.view))

    try bundle.select(path: portrait.path)
    let entries = try asset(Self.view, in: bundle).accepted.count
    try bundle.acceptStale(path: Self.view, at: Self.acceptedAt)
    #expect(!stalePaths(bundle).contains(Self.view))
    #expect(try asset(Self.view, in: bundle).accepted.count == entries + 1)
  }

  @Test("A changed artStyle is accepted with the front matter's; provenance keeps the old one")
  func acceptArtStyle() throws {
    let copy = try Copy("warnings/W-STALE-accepted-art-style-changed-again")
    defer { copy.remove() }
    var bundle = try copy.open()
    let style = try #require(bundle.artStyle)
    let stale = bundle.manifest.assets.filter { asset in
      bundle.stale().contains { $0.path == asset.path }
    }
    #expect(!stale.isEmpty)
    for before in stale {
      let written = try bundle.acceptStale(path: before.path, at: Self.acceptedAt)
      #expect(written.accepted.last?.artStyle == style)
      #expect(written.accepted.last?.json.keys.sorted() == ["acceptedAt", "artStyle"])
      #expect(written.provenance == before.provenance)
      #expect(written.provenance.artStyle != style)
    }
    #expect(bundle.stale().isEmpty)
  }

  @Test("A page can't be accepted; the manifest is as it was")
  func pageRefused() throws {
    let copy = try Copy("valid/complete-lead", bundle: "characters/WREN HALLOWAY.dossier")
    defer { copy.remove() }
    var bundle = try copy.open()
    let page = try #require(bundle.manifest.assets.first { $0.kind == .dossier })
    let original = copy.manifestBytes
    #expect(throws: DossierWriteError.acceptanceNotAllowed(page.path)) {
      try bundle.acceptStale(path: page.path, at: Self.acceptedAt)
    }
    #expect(copy.manifestBytes == original)
  }

  @Test("Nothing to accept writes nothing: a current asset, a candidate, an unknown path")
  func nothingToAccept() throws {
    let copy = try Copy("valid/accepted-stale-view")
    defer { copy.remove() }
    var bundle = try copy.open()
    #expect(bundle.stale().isEmpty)
    let original = copy.manifestBytes
    let view = try bundle.acceptStale(path: Self.view, at: Self.acceptedAt)
    #expect(view == (try asset(Self.view, in: bundle)))
    try bundle.acceptStale(path: "images/portrait-f65b324c.png", at: Self.acceptedAt)
    #expect(copy.manifestBytes == original)
    #expect(throws: DossierWriteError.assetNotFound("images/none.png")) {
      try bundle.acceptStale(path: "images/none.png", at: Self.acceptedAt)
    }
  }

  @Test("A role with no selection can't be accepted, and stays stale")
  func noSelectionStaysStale() throws {
    let copy = try Copy("warnings/W-STALE-no-selection")
    defer { copy.remove() }
    var bundle = try copy.open()
    let stale = try #require(bundle.stale().first { finding in
      if case .input(_, _, nil) = finding.reason { return true }
      return false
    })
    let original = copy.manifestBytes
    try bundle.acceptStale(path: stale.path, at: Self.acceptedAt)
    #expect(copy.manifestBytes == original)
    #expect(bundle.stale().contains { $0.path == stale.path })
  }

  @Test("Accepting holds one update marker around its manifest replacement")
  func holdsMarker() throws {
    let copy = try Copy("warnings/W-STALE-accepted-older-portrait")
    defer { copy.remove() }
    var bundle = try copy.open()
    let events = Mutex<[UpdateEnvironment.Event]>([])
    var environment = UpdateEnvironment()
    environment.observe = { event in events.withLock { $0.append(event) } }
    try UpdateHolding.$environment.withValue(environment) {
      try bundle.acceptStale(path: Self.view, at: Self.acceptedAt)
    }
    let wrote = events.withLock { $0 }.filter { if case .wrote = $0 { return true } else { return false } }
    #expect(wrote.count == 1)
    #expect(events.withLock { $0 }.last.map { if case .removed = $0 { return true } else { return false } } == true)
  }
}
