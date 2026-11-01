import DossierCore
import Foundation
import Testing

@Suite("DossierBundle (§4, §8.1)")
struct DossierBundleTests {
  private func lead() throws -> DossierBundle {
    let cast = try Cast.load(Fixtures.project("valid/complete-lead").appendingPathComponent("CAST.md"))
    return try #require(try cast.openBundle(for: cast.members[0]))
  }

  /// `W-POINTER-nowhere` has no bundle on disk at all, which is the point of it.
  @Test("Open refuses exactly E-MANIFEST, E-VERSION and E-NOT-BUNDLE among all fixtures")
  func openOverEveryFixture() throws {
    let refused = ["E-MANIFEST", "E-VERSION", "E-NOT-BUNDLE"]
    var count = 0
    for entry in try Fixtures.conformance().fixtures {
      let url = Fixtures.bundleURL(of: entry)
      if entry.path == "warnings/W-POINTER-nowhere" {
        #expect(!FileManager.default.fileExists(atPath: url.path))
      } else if entry.codes.contains(where: refused.contains) {
        #expect(throws: DossierError.self, "\(entry.path)") { try DossierBundle.open(at: url) }
        count += 1
      } else {
        #expect(throws: Never.self, "\(entry.path)") { try DossierBundle.open(at: url) }
      }
    }
    #expect(count == 5)
  }

  @Test("Both version 1 shapes open, with no change to their retired kinds")
  func versionOne() throws {
    for (path, bundle) in [
      ("warnings/W-V1", "characters/PELL ARDEN.dossier"),
      ("warnings/W-V1-plain-directory", "characters/PELL ARDEN"),
    ] {
      let opened = try DossierBundle.open(at: Fixtures.project(path).appendingPathComponent(bundle))
      #expect(opened.manifest.manifestVersion == 1)
      #expect(opened.selectedAsset(kind: .faceSheet) != nil)
      #expect(opened.selectedAsset(kind: .face) == nil)
      #expect(opened.assets(kind: .turnaround).first?.label == "front")
      #expect(opened.stale().isEmpty)
      #expect(try opened.completeness(tier: .background) == nil)
    }
  }

  @Test("§8.1's lookup: kind, exact variant, status selected")
  func lookup() throws {
    let bundle = try lead()
    #expect(bundle.selectedAsset(kind: .portrait)?.status == .selected)
    #expect(bundle.assets(kind: .portrait).count == 3)
    #expect(bundle.selectedAsset(kind: .view, variant: "front")?.variant == "front")
    #expect(bundle.selectedAsset(kind: .view) == nil, "No variant asked for means no variant")
    #expect(bundle.selectedAsset(kind: .view, variant: "sideways") == nil)
    #expect(bundle.selectedAsset(kind: .crowdRef) == nil)
    #expect(bundle.assets(kind: .view, variant: "back").count == 1)
    #expect(bundle.assets().count == bundle.manifest.assets.count)
  }

  @Test("sampleURL, by variant and by model")
  func samples() throws {
    let bundle = try lead()
    let neutral06 = try #require(bundle.sampleURL(variant: "neutral", model: "0.6b"))
    #expect(neutral06.lastPathComponent == "sample-neutral-0.6b.m4a")
    let neutral17 = try #require(bundle.sampleURL(variant: "neutral", model: "1.7b"))
    #expect(neutral17.lastPathComponent == "sample-neutral.m4a")
    #expect(bundle.sampleURL(variant: "neutral") != nil)
    #expect(bundle.sampleURL(variant: "hushed") != nil)
    #expect(bundle.sampleURL(variant: "absent") == nil)
    #expect(FileManager.default.fileExists(atPath: neutral06.path))
  }

  @Test("identityPrompt, artStyle and pageURL")
  func accessors() throws {
    let bundle = try lead()
    #expect(bundle.identityPrompt?.hasPrefix("A tall woman") == true)
    #expect(bundle.artStyle == "flat placeholder shapes")
    #expect(bundle.pageURL?.lastPathComponent == "WREN HALLOWAY-dossier.html")
    #expect(bundle.pageURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
  }

  @Test("A bundle name with non-ASCII and # characters resolves on disk")
  func awkwardNames() throws {
    let cast = try Cast.load(Fixtures.project("valid/non-ascii-underfive").appendingPathComponent("CAST.md"))
    let bundle = try #require(try cast.openBundle(for: cast.members[0]))
    #expect(bytes(bundle.manifest.character) == bytes("IN\u{00C9}S"))
    let hash = try DossierBundle.open(
      at: Fixtures.project("valid/empty-background").appendingPathComponent("characters/BYSTANDER #2.dossier"))
    #expect(hash.manifest.character == "BYSTANDER #2")
    #expect(hash.manifest.files.isEmpty)
    #expect(hash.manifest.computedChecksum == Checksum.sha256(Data()))
  }

  @Test("§5.2's path rules, and a manifest can't lead a reader outside the bundle")
  func paths() throws {
    for good in ["CHARACTER.md", "images/a b.png", "voice/x:y.m4a"] {
      #expect(BundlePath.isValid(good), "\(good)")
    }
    for bad in ["", "/x", "C:/x", "file:///x", "a\\b", "a//b", "./a", "a/./b", "../x", "a/..", "a/"] {
      #expect(!BundlePath.isValid(bad), "\(bad)")
    }
    let bundle = try lead()
    #expect(bundle.fileURL(forPath: "../../CAST.md") == nil)
    #expect(bundle.fileURL(forPath: "CHARACTER.md") != nil)
  }

  @Test("Every path-fault fixture opens, and its bad path gives no URL")
  func pathFaultFixtures() throws {
    let entry = try #require(try Fixtures.conformance().fixtures.first { $0.path == "errors/E-PATH-escape" })
    let bundle = try DossierBundle.open(at: Fixtures.bundleURL(of: entry))
    let bad = bundle.manifest.files.map(\.path) + bundle.manifest.assets.map(\.path)
    #expect(bad.contains { !BundlePath.isValid($0) })
    for path in bad where !BundlePath.isValid(path) {
      #expect(bundle.fileURL(forPath: path) == nil)
    }
  }
}
