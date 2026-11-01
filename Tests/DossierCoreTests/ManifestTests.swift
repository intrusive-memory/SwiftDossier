import DossierCore
import Foundation
import Testing

@Suite("Manifest (§5, §6)")
struct ManifestTests {
  private static func fixtureManifests() -> [URL] {
    let walker = FileManager.default.enumerator(at: Fixtures.root, includingPropertiesForKeys: nil)
    let all = (walker?.allObjects as? [URL]) ?? []
    return all.filter { $0.lastPathComponent == "manifest.json" }
  }

  private func decode(_ text: String) throws -> Manifest {
    try Manifest(data: Data(text.utf8))
  }

  private static let minimal = """
    {"manifestVersion": 2, "character": "ODA VANTERPOOL", "updatedAt": "2026-01-01T00:00:00Z",
     "files": [], "assets": [], "manifestChecksum": "x"}
    """

  @Test("Every decodable fixture manifest re-encodes to its own bytes")
  func everyFixtureReencodesByteForByte() throws {
    let urls = Self.fixtureManifests()
    var reencoded = 0
    for url in urls {
      let data = try Data(contentsOf: url)
      guard let manifest = try? Manifest(data: data) else { continue }
      #expect(manifest.encoded() == data, "\(url.path)")
      reencoded += 1
    }
    // Every manifest.json under examples/, less not-JSON, not-object and E-VERSION.
    #expect(reencoded == 102)
  }

  @Test("Unknown top-level, asset and provenance keys survive a re-encode")
  func unknownKeysSurvive() throws {
    let text = """
      {
        "zUnknown": {"b": 1.50, "a": [1e3, 12345678901234567890, null, true, []], "c": {}},
        "manifestVersion": 2,
        "character": "ODA VANTERPOOL",
        "updatedAt": "2026-01-01T00:00:00Z",
        "files": [],
        "manifestChecksum": "x",
        "assets": [{
          "path": "CHARACTER.md", "kind": "description", "status": "selected",
          "createdAt": "2026-01-01T00:00:00Z", "assetExtra": "kept",
          "provenance": {"provider": "manual", "provExtra": {"deep": [2.0]}}
        }]
      }
      """
    let encoded = try #require(String(data: try decode(text).encoded(), encoding: .utf8))
    #expect(encoded.contains("\"b\": 1.50"))
    #expect(encoded.contains("1e3"))
    #expect(encoded.contains("12345678901234567890"))
    #expect(encoded.contains("\"assetExtra\": \"kept\""))
    #expect(encoded.contains("\"provExtra\": {\n"))
    #expect(encoded.contains("2.0"))
    #expect(encoded.contains("\"c\": {}"))
    let asset = try #require(try decode(text).assets.first)
    #expect(asset.json["assetExtra"]?.stringValue == "kept")
    #expect(asset.provenance.json["provExtra"] != nil)
  }

  @Test("Encoder writes §5's form: sorted, 2-space, final newline, no \\/")
  func encoderForm() throws {
    let text = #"{"manifestVersion":2,"b/c":"x\/y","a":"é\n\u0001\"","character":"Z"}"#
    let encoded = try String(decoding: decode(text).encoded(), as: UTF8.self)
    #expect(
      encoded == """
        {
          "a": "é\\n\\u0001\\"",
          "b/c": "x/y",
          "character": "Z",
          "manifestVersion": 2
        }

        """)
  }

  @Test("A string's normalization is kept, and NFC and NFD keys stay distinct")
  func normalizationIsNotTouched() throws {
    let nfd = "JOSE\u{0301}"
    let nfc = "JOS\u{00C9}"
    let text = #"{"manifestVersion":2,"character":"\#(nfd)","\#(nfc)":1,"\#(nfd)":2}"#
    let manifest = try decode(text)
    #expect(bytes(manifest.character) == bytes(nfd))
    #expect(manifest.json[nfc]?.intValue == 1)
    #expect(manifest.json[nfd]?.intValue == 2)
    let again = try Manifest(data: manifest.encoded())
    #expect(bytes(again.character) == bytes(nfd))
    #expect(again.json.keys.count == 4)
  }

  @Test("Strict JSON: what isn't JSON or an object is refused")
  func refusals() throws {
    for text in ["{", "[]x", "{\"a\":01}", "{\"a\":1,}", "nul", "{\"a\":\"\\ud800\"}", "\u{FEFF}{}"] {
      #expect(throws: DossierError.self, "\(text)") { try decode(text) }
    }
    #expect(throws: DossierError.manifestNotObject) { try decode("[]") }
  }

  @Test("§5.1: only versions 1 and 2 are read")
  func versions() throws {
    #expect(throws: DossierError.unknownVersion("3")) { try decode(#"{"manifestVersion":3}"#) }
    #expect(throws: DossierError.unknownVersion("\"2\"")) { try decode(#"{"manifestVersion":"2"}"#) }
    #expect(throws: DossierError.unknownVersion("2.0")) { try decode(#"{"manifestVersion":2.0}"#) }
    #expect(throws: DossierError.unknownVersion(nil)) { try decode(#"{}"#) }
    #expect(try decode(#"{"manifestVersion":1}"#).manifestVersion == 1)
  }

  @Test("A schema-invalid manifest decodes, and reads as empty where it's wrong")
  func lenientRead() throws {
    let manifest = try decode(#"{"manifestVersion":2,"character":5,"files":"x","assets":[1,{"kind":"star"}]}"#)
    #expect(manifest.character == "")
    #expect(manifest.files.isEmpty)
    #expect(manifest.assets.count == 1)
    #expect(manifest.assets[0].kind == .unknown("star"))
    // Nothing is lost on the way back out.
    #expect(String(decoding: manifest.encoded(), as: UTF8.self).contains("\"files\": \"x\""))
  }

  @Test("A package writer can mutate and re-encode, keeping unknown keys")
  func mutationThroughPackageAPI() throws {
    var manifest = try decode(
      #"{"manifestVersion":2,"zKeep":1.50,"character":"ODA","updatedAt":"t","files":[],"manifestChecksum":"x","assets":[{"path":"a.png","kind":"portrait","status":"selected","extra":true,"provenance":{"provider":"manual","p":1}}]}"#
    )
    var assets = manifest.assets
    assets[0].status = .candidate
    assets[0].variant = "front"
    var provenance = assets[0].provenance
    provenance.json["notes"] = .string("n")
    assets[0].provenance = provenance
    assets[0].derivedFrom = [DerivedInput(role: "portrait", sha256: "h", path: "p.png")]
    manifest.assets = assets
    manifest.files = [FileEntry(path: "a.png", sha256: String(repeating: "a", count: 64), sizeBytes: 3)]
    manifest.manifestChecksum = manifest.computedChecksum
    manifest.updatedAt = "t2"

    let again = try Manifest(data: manifest.encoded())
    #expect(again.assets[0].status == .candidate)
    #expect(again.assets[0].json["extra"]?.boolValue == true)
    #expect(again.assets[0].provenance.json["p"]?.intValue == 1)
    #expect(again.assets[0].provenance.notes == "n")
    #expect(again.assets[0].derivedFrom[0].path == "p.png")
    #expect(again.files[0].sizeBytes == 3)
    #expect(again.manifestChecksum == Checksum.sorted([String(repeating: "a", count: 64)]))
    #expect(String(decoding: again.encoded(), as: UTF8.self).contains("\"zKeep\": 1.50"))
  }

  @Test("A new manifest has the checksum of no files")
  func newManifest() throws {
    let manifest = Manifest(character: "ODA", updatedAt: "2026-01-01T00:00:00Z")
    #expect(manifest.manifestVersion == 2)
    #expect(manifest.manifestChecksum == Checksum.sha256(Data()))
    #expect(try Manifest(data: manifest.encoded()) == manifest)
  }

  @Test("Provenance reads §6's keys, and version 1's shapes don't crash it")
  func provenanceKeys() throws {
    let manifest = try decode(
      #"""
      {"manifestVersion":2,"assets":[
       {"kind":"face","provenance":{"provider":"personaje","tool":{"name":"t","version":"1"},
        "seed":7,"guidance":3.5,"negativeApplied":false,"models":["a","b"],
        "box":{"x":50,"y":60,"width":80,"height":100},
        "references":[{"sha256":"s","path":"p","role":"portrait"}]}},
       {"kind":"turnaround","provenance":{"tool":"fixture","references":["a.png"]},"derivedFrom":"x.png"}
      ]}
      """#)
    let face = manifest.assets[0].provenance
    #expect(face.tool?.name == "t")
    #expect(face.seed == 7)
    #expect(face.guidance == 3.5)
    #expect(face.negativeApplied == false)
    #expect(face.models == ["a", "b"])
    #expect(face.box?.height == 100)
    #expect(face.references.first?.role == "portrait")
    let old = manifest.assets[1]
    #expect(old.kind.isRetired)
    #expect(old.provenance.tool == nil)
    #expect(old.provenance.references.isEmpty)
    #expect(old.derivedFrom.isEmpty)
  }
}
