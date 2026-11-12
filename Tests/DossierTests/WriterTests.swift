import CoreGraphics
import DossierCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Dossier

/// Synthetic files and bundles, in temporary directories. Invented characters only.
private enum Synthetic {
  static let character = "THE TINKER"
  static let absoluteSource = "/Volumes/nowhere/invented/reference-one.png"

  static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("WriterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
  }

  /// A `.dossier` with an empty manifest, in `<root>/characters/`.
  static func bundle(in root: URL, character: String = character) throws -> DossierBundle {
    let url = root.appendingPathComponent("characters/\(character).dossier", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let manifest = Manifest(character: character, updatedAt: "2026-01-01T00:00:00Z")
    try manifest.encoded().write(to: url.appendingPathComponent("manifest.json"))
    return try DossierBundle.open(at: url)
  }

  /// A real PNG, so ImageIO reads its dimensions for `W-SHAPE`. `shade` varies its bytes.
  static func png(width: Int = 18, height: Int = 32, shade: UInt8 = 40) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: CGFloat(shade) / 255, green: 0.2, blue: 0.3, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }

  /// `png` with a record embedded as Vinetas does: an uncompressed `iTXt` before `IEND`.
  static func embedding(_ json: String, in png: Data) -> Data {
    var payload = Data("vinetas".utf8)
    payload.append(contentsOf: [0, 0, 0, 0, 0])
    payload.append(Data(json.utf8))
    var output = png.prefix(png.count - 12)
    output.append(chunk("iTXt", payload))
    output.append(png.suffix(12))
    return Data(output)
  }

  /// A whole PNG chunk: length, type, payload, CRC.
  static func chunk(_ type: String, _ payload: Data) -> Data {
    let body = Data(type.utf8) + payload
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in body {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = crc & 1 != 0 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }
    crc ^= 0xFFFF_FFFF
    func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    return bigEndian(UInt32(payload.count)) + body + bigEndian(crc)
  }

  /// `png` with whole chunks put right after `IHDR`, which is always its first 33 bytes.
  static func inserting(_ chunks: [Data], in png: Data) -> Data {
    png.prefix(33) + chunks.reduce(Data(), +) + png.dropFirst(33)
  }

  /// A PNG's chunks as whole byte runs, with their types, in file order.
  static func chunks(of png: Data) -> [(type: String, bytes: Data)] {
    let bytes = [UInt8](png)
    var found: [(type: String, bytes: Data)] = []
    var offset = 8
    while offset + 12 <= bytes.count {
      let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
      let end = offset + 12 + length
      found.append((String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self), Data(bytes[offset..<end])))
      offset = end
    }
    return found
  }

  /// A file already in the bundle, put there by another tool.
  @discardableResult
  static func fileInBundle(_ path: String, _ data: Data, _ bundle: DossierBundle) throws -> URL {
    let url = bundle.url.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
  }

  /// A file outside any bundle.
  @discardableResult
  static func file(_ name: String, _ data: Data, in root: URL) throws -> URL {
    let url = root.appendingPathComponent("outside/\(name)")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
  }

  /// A record in the shape `ImageOutput.PanelMetadata` writes at Vinetas v0.26.0.
  static func sidecar(references: [(source: String, sha256: String)] = [], lora: String? = nil) -> String {
    let items = references.map { reference in
      """
      {"source": "\(reference.source)", "sha256": "\(reference.sha256)", "originalWidth": 18, \
      "originalHeight": 32, "effectiveWidth": 36, "effectiveHeight": 64}
      """
    }.joined(separator: ",")
    let loras = lora.map { #""loras": [{"path": "\#($0)", "scale": 0.8}],"# } ?? ""
    return """
      {"prompt": "a tinker, already composed, with a brass loupe", "model": "invented-4b",
       "seed": 18446744073709551615, "steps": 4, "guidance": 3.50, "width": 18, "height": 32,
       "durationSeconds": 12.25, \(loras) "generatedAt": "2026-03-04T05:06:07Z",
       "mode": "imageToImage", "engine": "invented", "style": "woodcut",
       "composedPrompt": "woodcut, a tinker", "negative": "blur", "negativeApplied": false,
       "character": "the-tinker",
       "bundle": {"panelPrompt": "a tinker", "width": 18, "height": 32, "referenceCount": 1},
       "glosa": {"notation": "0.1", "digest": "abc", "shot": {"x-unknown": [1, 2.50]}},
       "references": [\(items)]}
      """
  }

  static func object(_ json: String) throws -> JSONObject {
    try #require(try JSONValue.parse(Data(json.utf8)).objectValue)
  }

  /// Every byte under a directory, as text.
  static func allBytes(under root: URL, except excluded: (URL) -> Bool = { _ in false }) throws -> Data {
    let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    var out = Data()
    for case let url as URL in walker where !excluded(url) {
      if let data = try? Data(contentsOf: url) { out.append(data) }
    }
    return out
  }
}

/// SD-3 and SD-5 on what's now on disk: the §5 byte form, `manifest-v2`, and §14 with no finding.
private func expectClean(_ bundle: DossierBundle, sourceLocation: SourceLocation = #_sourceLocation) throws {
  let data = try Data(contentsOf: bundle.url.appendingPathComponent("manifest.json"))
  let manifest = try Manifest(data: data)
  #expect(manifest.encoded() == data, sourceLocation: sourceLocation)
  #expect(manifest == bundle.manifest, sourceLocation: sourceLocation)
  #expect(data.last == 0x0A, sourceLocation: sourceLocation)
  #expect(!String(decoding: data, as: UTF8.self).contains("\\/"), sourceLocation: sourceLocation)
  let violations = try SchemaEvaluator.pinned().validate(.object(manifest.json), against: "manifest-v2.schema.json")
  #expect(violations.isEmpty, "\(violations)", sourceLocation: sourceLocation)
  #expect(manifest.manifestChecksum == Checksum.sorted(manifest.files.map(\.sha256)), sourceLocation: sourceLocation)
  #expect(manifest.updatedAt != "2026-01-01T00:00:00Z", sourceLocation: sourceLocation)
  #expect(manifest.generator?.name == "SwiftDossier", sourceLocation: sourceLocation)
  let report = try DossierBundle.validate(at: bundle.url)
  let detail = report.findings.map { "\($0.code.rawValue) \($0.path ?? "-"): \($0.message)" }
  #expect(report.exitStatus == 0, "\(detail)", sourceLocation: sourceLocation)
  let hidden = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".") }
  #expect(hidden.isEmpty, "\(hidden)", sourceLocation: sourceLocation)
}

private func expectWriteError(
  _ expected: DossierWriteError, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void
) {
  do {
    try body()
    Issue.record("expected \(expected)", sourceLocation: sourceLocation)
  } catch {
    #expect(error as? DossierWriteError == expected, sourceLocation: sourceLocation)
  }
}

/// Adds a selected portrait; returns its path and hash.
private func addPortrait(
  to bundle: inout DossierBundle, root: URL, shade: UInt8 = 40
) throws -> (path: String, sha256: String) {
  let data = try Synthetic.png(shade: shade)
  let source = try Synthetic.file("portrait-\(shade).png", data, in: root)
  let asset = try bundle.add(source, kind: .portrait, options: AddOptions(select: true))
  return (asset.path, Checksum.sha256(try Data(contentsOf: bundle.url.appendingPathComponent(asset.path))))
}

@Suite("Writers (SD-5 to SD-10)")
struct WriterTests {
  // MARK: add: naming and copying

  @Test("SD-6: an image is named for its content, and its source is copied, not touched")
  func addCopiesAndNames() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let data = try Synthetic.png()
    let source = try Synthetic.file("a free-form name.png", data, in: root)
    let before = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date

    let asset = try bundle.add(source, kind: .portrait)

    let stored = try #require(PNGMetadata.stripped(data))
    let sha256 = Checksum.sha256(stored)
    #expect(asset.path == "images/portrait-\(sha256.prefix(8)).png")
    #expect(asset.status == .candidate)
    #expect(asset.provenance.provider == "import")
    #expect(try Data(contentsOf: bundle.url.appendingPathComponent(asset.path)) == stored)
    #expect(try Data(contentsOf: source) == data)
    #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date == before)
    #expect(bundle.manifest.files.count == 1)
    #expect(bundle.manifest.files[0].path == asset.path)
    #expect(bundle.manifest.files[0].sha256 == sha256)
    #expect(bundle.manifest.files[0].sizeBytes == Int64(stored.count))
    try expectClean(bundle)
  }

  @Test("SD-6, §4: each kind's file goes where §4 says")
  func addDestinations() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let portrait = try addPortrait(to: &bundle, root: root)
    let bytes = Data("invented bytes".utf8)

    let vox = try bundle.add(
      Synthetic.file("anything.vox", bytes, in: root), kind: .vox, options: AddOptions(select: true))
    #expect(vox.path == "voice/THE TINKER.vox")

    let sample = try bundle.add(
      Synthetic.file("sample-neutral-0.6b.m4a", bytes + Data([1]), in: root), kind: .voiceSample,
      options: AddOptions(variant: "neutral", model: "0.6b", sampleText: "Hold still."))
    #expect(sample.path == "voice/sample-neutral-0.6b.m4a")

    let lora = try bundle.add(
      Synthetic.file("adapter.safetensors", bytes + Data([2]), in: root), kind: .lora,
      options: AddOptions(lora: Synthetic.object(#"{"triggerWord": "tnkr", "version": 3}"#)))
    #expect(lora.path == "lora/THE TINKER-v3.safetensors")

    let training = try bundle.add(
      Synthetic.file("t-01.png", Synthetic.png(shade: 1), in: root), kind: .training,
      options: AddOptions(training: Synthetic.object(#"{"caption": "a tinker", "isSynthetic": true}"#)))
    #expect(training.path == "training/t-01.png")

    let photo = try bundle.add(Synthetic.file("photo.jpg", bytes + Data([3]), in: root), kind: .sourcePhoto)
    #expect(photo.path == "source/photo.jpg")

    let crowd = try bundle.add(Synthetic.file("c.png", Synthetic.png(shade: 2), in: root), kind: .crowdRef)
    #expect(crowd.path.hasPrefix("images/crowdRef-"))

    let description = try bundle.add(
      Synthetic.file("notes.md", Data("# THE TINKER\n".utf8), in: root), kind: .description,
      options: AddOptions(select: true))
    #expect(description.path == "CHARACTER.md")

    _ = portrait
    try expectClean(bundle)
  }

  @Test("§5.6: a file another tool put at the path, with these bytes, becomes the asset")
  func addAdoptsIdenticalFile() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let bytes = Data("voice".utf8)
    let voice = bundle.url.appendingPathComponent("voice")
    try FileManager.default.createDirectory(at: voice, withIntermediateDirectories: true)
    try bytes.write(to: voice.appendingPathComponent("THE TINKER.vox"))

    expectWriteError(.destinationExists("voice/THE TINKER.vox")) {
      try bundle.add(Synthetic.file("other.vox", Data("other".utf8), in: root), kind: .vox)
    }
    #expect(try Data(contentsOf: voice.appendingPathComponent("THE TINKER.vox")) == bytes)

    try bundle.add(Synthetic.file("same.vox", bytes, in: root), kind: .vox)
    try expectClean(bundle)
  }

  @Test("§5.2, §4, §8.1: what add refuses, with the bundle as it was")
  func addRefusals() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let before = try Data(contentsOf: bundle.url.appendingPathComponent("manifest.json"))
    let image = try Synthetic.file("image.png", Synthetic.png(), in: root)

    let empty = try Synthetic.file("empty.png", Data(), in: root)
    expectWriteError(.zeroByteFiles(["empty.png"])) { try bundle.add(empty, kind: .portrait) }
    let text = try Synthetic.file("text.png", Data("not a png".utf8), in: root)
    expectWriteError(.notPNG(text.path)) { try bundle.add(text, kind: .portrait) }
    expectWriteError(.kindNotWritable("turnaround")) { try bundle.add(image, kind: .turnaround) }
    expectWriteError(.kindNotWritable("invented")) { try bundle.add(image, kind: .unknown("invented")) }
    expectWriteError(.variantNotAllowed("portrait has no variants, and was given happy")) {
      try bundle.add(image, kind: .portrait, options: AddOptions(variant: "happy"))
    }
    expectWriteError(.variantNotAllowed("../../x")) {
      try bundle.add(image, kind: .expression, options: AddOptions(variant: "../../x"))
    }
    let hidden = try Synthetic.file(".hidden.m4a", Data("x".utf8), in: root)
    expectWriteError(.fileNameNotAllowed(".hidden.m4a")) {
      try bundle.add(hidden, kind: .voiceSample, options: AddOptions(variant: "neutral"))
    }
    expectWriteError(.loraVersionMissing) { try bundle.add(image, kind: .lora) }
    let absent = root.appendingPathComponent("absent.png")
    expectWriteError(.sourceUnreadable(absent.path)) { try bundle.add(absent, kind: .portrait) }

    #expect(try Data(contentsOf: bundle.url.appendingPathComponent("manifest.json")) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.url.path) == ["manifest.json"])

    try bundle.add(image, kind: .portrait)
    let path = bundle.manifest.assets[0].path
    expectWriteError(.assetExists(path)) { try bundle.add(image, kind: .portrait) }
  }

  @Test("A directory in the bundle that's a symbolic link isn't written through")
  func addRefusesSymlinkedDirectory() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let elsewhere = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: bundle.url.appendingPathComponent("images"), withDestinationURL: elsewhere)
    let data = try Synthetic.png()
    let source = try Synthetic.file("image.png", data, in: root)

    let stored = try #require(PNGMetadata.stripped(data))
    expectWriteError(.destinationNotInBundle("images/portrait-\(Checksum.sha256(stored).prefix(8)).png")) {
      try bundle.add(source, kind: .portrait)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
  }

  // MARK: add: metadata (§1, §4, SD-6)

  @Test("SD-6: a PNG copied in loses its metadata chunks, and only those, byte for byte")
  func addStripsMetadata() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let kept = [
      Synthetic.chunk("iCCP", Data("profile\0\0invented".utf8)),
      Synthetic.chunk("gAMA", Data([0, 0, 0xB1, 0x8F])),
      Synthetic.chunk("sRGB", Data([0])),
    ]
    let absolute = "/Volumes/nowhere/invented/metadata.png"
    let metadata = [
      Synthetic.chunk("tEXt", Data("Comment\0\(absolute)".utf8)),
      Synthetic.chunk("zTXt", Data("Comment\0\0\(absolute)".utf8)),
      Synthetic.chunk("iTXt", Data("XML\0\0\0\0\0\(absolute)".utf8)),
      Synthetic.chunk("eXIf", Data("MM\(absolute)".utf8)),
      Synthetic.chunk("tIME", Data([0x07, 0xEA, 11, 1, 12, 0, 0])),
    ]
    let plain = try #require(PNGMetadata.stripped(try Synthetic.png()))
    let data = Synthetic.embedding(
      Synthetic.sidecar(references: [(absolute, String(repeating: "b", count: 64))]),
      in: Synthetic.inserting(kept + metadata, in: plain))
    let source = try Synthetic.file("meta.png", data, in: root)

    let asset = try bundle.add(source, kind: .portrait)

    // Read first, so the record reached the manifest.
    #expect(asset.provenance.provider == "vinetas")
    #expect(asset.provenance.model == "invented-4b")

    let stored = try Data(contentsOf: bundle.url.appendingPathComponent(asset.path))
    let storedChunks = Synthetic.chunks(of: stored)
    let expected = Synthetic.chunks(of: data).filter { !["tEXt", "zTXt", "iTXt", "eXIf", "tIME"].contains($0.type) }
    #expect(storedChunks.map(\.type) == expected.map(\.type))
    #expect(storedChunks.map(\.bytes) == expected.map(\.bytes))
    #expect(storedChunks.map(\.type).contains("iCCP") && storedChunks.map(\.type).contains("IDAT"))
    #expect(stored.prefix(8) == data.prefix(8))

    // The hash, size and name are the stripped bytes'.
    let sha256 = Checksum.sha256(stored)
    #expect(asset.path == "images/portrait-\(sha256.prefix(8)).png")
    let entry = try #require(bundle.manifest.files.first { $0.path == asset.path })
    #expect(entry.sha256 == sha256)
    #expect(entry.sizeBytes == Int64(stored.count))

    #expect(try Data(contentsOf: source) == data)
    #expect(try Synthetic.allBytes(under: bundle.url).range(of: Data(absolute.utf8)) == nil)
    try expectClean(bundle)
  }

  @Test("SD-6: a PNG with no metadata keeps its hash")
  func addLeavesPlainPNG() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let plain = try #require(PNGMetadata.stripped(try Synthetic.png()))
    let asset = try bundle.add(Synthetic.file("plain.png", plain, in: root), kind: .portrait)
    #expect(asset.path == "images/portrait-\(Checksum.sha256(plain).prefix(8)).png")
    #expect(try Data(contentsOf: bundle.url.appendingPathComponent(asset.path)) == plain)
    #expect(bundle.manifest.files[0].sha256 == Checksum.sha256(plain))
  }

  @Test("SD-6: a malformed PNG is refused and nothing is copied")
  func addRefusesMalformedPNG() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let good = try Synthetic.png()
    var overrun = good
    overrun[11] = 0xFF  // IHDR's length.
    let cases: [(String, Data)] = [
      ("signature.png", good.prefix(8)),
      ("truncated.png", good.prefix(good.count - 6)),
      ("no-end.png", good.prefix(good.count - 12)),
      ("trailing.png", good + Data("/Volumes/nowhere".utf8)),
      ("overrun.png", overrun),
      ("no-header.png", good.prefix(8) + good.suffix(12)),
    ]
    for (name, data) in cases {
      let source = try Synthetic.file(name, data, in: root)
      expectWriteError(.pngMalformed(source.path)) { try bundle.add(source, kind: .portrait) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.url.path) == ["manifest.json"])
  }

  @Test("SD-6: an image that isn't a PNG is copied as it is; a PNG in source/ is stripped")
  func addOutsideImages() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("Exif /Volumes/nowhere".utf8)
    let photo = try bundle.add(Synthetic.file("photo.jpg", jpeg, in: root), kind: .sourcePhoto)
    #expect(photo.path == "source/photo.jpg")
    #expect(try Data(contentsOf: bundle.url.appendingPathComponent(photo.path)) == jpeg)
    let train = try bundle.add(
      Synthetic.file("t.jpg", jpeg, in: root), kind: .training,
      options: AddOptions(training: Synthetic.object(#"{"caption": "a tinker", "isSynthetic": true}"#)))
    #expect(try Data(contentsOf: bundle.url.appendingPathComponent(train.path)) == jpeg)

    let tagged = Synthetic.embedding(Synthetic.sidecar(), in: try Synthetic.png())
    let png = try bundle.add(Synthetic.file("photo.png", tagged, in: root), kind: .sourcePhoto)
    #expect(png.path == "source/photo.png")
    #expect(try Data(contentsOf: bundle.url.appendingPathComponent(png.path)) == PNGMetadata.stripped(tagged))
    #expect(png.provenance.provider == "vinetas")
  }

  @Test("SD-6: a file already in the bundle keeps its bytes and its name")
  func addInPlace() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let data = Synthetic.embedding(
      Synthetic.sidecar(references: [(Synthetic.absoluteSource, String(repeating: "b", count: 64))]),
      in: try Synthetic.png())
    let file = try Synthetic.fileInBundle("images/a free-form name.png", data, bundle)

    let asset = try bundle.add(file, kind: .portrait)

    #expect(asset.path == "images/a free-form name.png")
    #expect(asset.provenance.model == "invented-4b")
    #expect(try Data(contentsOf: file) == data)
    #expect(bundle.manifest.files.map(\.path) == [asset.path])
    #expect(bundle.manifest.files[0].sha256 == Checksum.sha256(data))

    // Reached through a link that leads to it, it's still that file.
    let link = root.appendingPathComponent("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    expectWriteError(.assetExists(asset.path)) { try bundle.add(link, kind: .portrait) }

    // What can't be an asset's path is refused.
    let hidden = try Synthetic.fileInBundle(".hidden.png", try Synthetic.png(), bundle)
    expectWriteError(.fileNameNotAllowed(".hidden.png")) { try bundle.add(hidden, kind: .portrait) }
    expectWriteError(.fileNameNotAllowed("manifest.json")) {
      try bundle.add(bundle.url.appendingPathComponent("manifest.json"), kind: .description)
    }
  }

  // MARK: §5.2, §9.1, Appendix A: what the validator does

  /// Writes a `files` entry into the manifest, keeping `manifestChecksum` right.
  private func listFile(_ path: String, sha256: String, sizeBytes: Int64, in bundle: DossierBundle) throws {
    let url = bundle.url.appendingPathComponent("manifest.json")
    var manifest = try Manifest(data: try Data(contentsOf: url))
    var files = manifest.files
    files.append(FileEntry(path: path, sha256: sha256, sizeBytes: sizeBytes))
    files.sort { $0.path.precedesInByteOrder($1.path) }
    manifest.files = files
    manifest.json["manifestChecksum"] = .string(Checksum.sorted(files.map(\.sha256)))
    try manifest.encoded().write(to: url)
  }

  @Test("§5.2: a files entry for a symlink or manifest.json is E-FILE-MISSING")
  func listedNonFiles() throws {
    let root = try Synthetic.temporaryDirectory()
    let hash = String(repeating: "a", count: 64)

    let linked = try Synthetic.bundle(in: root)
    let target = try Synthetic.file("target.txt", Data("target".utf8), in: root)
    try FileManager.default.createSymbolicLink(at: linked.url.appendingPathComponent("link.txt"), withDestinationURL: target)
    try listFile("link.txt", sha256: Checksum.sha256(Data("target".utf8)), sizeBytes: 6, in: linked)
    #expect(try DossierBundle.validate(at: linked.url).findings.map(\.code) == [.fileMissing])

    let other = try Synthetic.temporaryDirectory()
    let listed = try Synthetic.bundle(in: other)
    try listFile("manifest.json", sha256: hash, sizeBytes: 1, in: listed)
    #expect(try DossierBundle.validate(at: listed.url).findings.map(\.code) == [.fileMissing])
  }

  @Test("§5.2: a listed hidden file is checked as normal")
  func listedHiddenFile() throws {
    let root = try Synthetic.temporaryDirectory()
    let bundle = try Synthetic.bundle(in: root)
    let data = Data("hidden".utf8)
    let file = try Synthetic.fileInBundle(".hidden.txt", data, bundle)
    try listFile(".hidden.txt", sha256: Checksum.sha256(data), sizeBytes: Int64(data.count), in: bundle)
    #expect(try DossierBundle.validate(at: bundle.url).findings.isEmpty)

    try Data("HIDDEN".utf8).write(to: file)
    #expect(try DossierBundle.validate(at: bundle.url).findings.map(\.code) == [.fileHash])
  }

  @Test("§5.2: a manifest path compares with the name on disk as NFC, case-sensitively")
  func listedNormalization() throws {
    let root = try Synthetic.temporaryDirectory()
    let bundle = try Synthetic.bundle(in: root)
    let data = Data("note".utf8)
    let decomposed = "Ine\u{301}s.txt"
    try Synthetic.fileInBundle(decomposed, data, bundle)
    try listFile("In\u{E9}s.txt", sha256: Checksum.sha256(data), sizeBytes: 4, in: bundle)
    #expect(!(try DossierBundle.validate(at: bundle.url).findings.map(\.code).contains(.fileMissing)))

    let other = try Synthetic.temporaryDirectory()
    let cased = try Synthetic.bundle(in: other)
    try Synthetic.fileInBundle("note.txt", data, cased)
    try listFile("NOTE.txt", sha256: Checksum.sha256(data), sizeBytes: 4, in: cased)
    #expect(try DossierBundle.validate(at: cased.url).findings.map(\.code).contains(.fileMissing))
  }

  @Test("Appendix A: two selected in a version 1 manifest is only W-V1")
  func versionOneTwoSelected() throws {
    let root = try Synthetic.temporaryDirectory()
    let copy = root.appendingPathComponent("PELL ARDEN.dossier")
    try FileManager.default.copyItem(
      at: SpecTree.examples.appendingPathComponent("warnings/W-V1/characters/PELL ARDEN.dossier"), to: copy)
    let url = copy.appendingPathComponent("manifest.json")
    var manifest = try #require(try JSONValue.parse(Data(contentsOf: url)).objectValue)
    let assets = try #require(manifest["assets"]?.arrayValue).map { value -> JSONValue in
      guard var asset = value.objectValue, asset["path"]?.stringValue == "images/face.png" else { return value }
      asset["kind"] = .string("portrait")
      return .object(asset)
    }
    manifest["assets"] = .array(assets)
    try Data(JSONValue.object(manifest).canonicalEncoded().utf8).write(to: url)

    let codes = Set(try DossierBundle.validate(at: copy).findings.map(\.code))
    // The rest are what conformance.json allows W-V1 itself.
    #expect(codes.subtracting([.shape, .sidecar, .unclassified]) == [.v1])
  }

  @Test("§9.1: no character key in CHARACTER.md isn't E-NAME-MISMATCH")
  func noCharacterKey() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    try bundle.add(
      Synthetic.file("c.md", Data("---\ntype: character\n---\n# Text\n".utf8), in: root), kind: .description)
    #expect(!(try DossierBundle.validate(at: bundle.url).findings.map(\.code).contains(.nameMismatch)))
  }

  // MARK: add: provenance

  @Test("SD-7: a sidecar is folded in, source goes, and everything else stays as it says")
  func sidecarFold() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let portrait = try addPortrait(to: &bundle, root: root)
    let unmatched = String(repeating: "a", count: 64)
    let sidecar = try Synthetic.file(
      "panel.json",
      Data(
        Synthetic.sidecar(references: [
          (Synthetic.absoluteSource, portrait.sha256), ("/Volumes/nowhere/invented/two.png", unmatched),
        ]).utf8), in: root)
    let source = try Synthetic.file("panel.png", Synthetic.png(shade: 9), in: root)

    let asset = try bundle.add(
      source, kind: .view,
      options: AddOptions(
        variant: "front", sidecar: sidecar, referenceRoles: ["portrait", "pose"],
        provenance: Synthetic.object(
          #"{"tool": {"name": "invented-cli", "version": "1.0"}, "notes": "kept", "gateOverridden": "review"}"#)))

    let provenance = asset.provenance
    #expect(asset.createdAt == "2026-03-04T05:06:07Z")
    #expect(provenance.json["generatedAt"] == nil)
    #expect(provenance.provider == "vinetas")
    #expect(provenance.prompt == "a tinker, already composed, with a brass loupe")
    #expect(provenance.composedPrompt == "woodcut, a tinker")
    #expect(provenance.model == "invented-4b")
    #expect(provenance.json["seed"] == .number("18446744073709551615"))
    #expect(provenance.json["guidance"] == .number("3.50"))
    #expect(provenance.steps == 4)
    #expect(provenance.width == 18)
    #expect(provenance.height == 32)
    #expect(provenance.durationSeconds == 12.25)
    #expect(provenance.mode == "imageToImage")
    #expect(provenance.engine == "invented")
    #expect(provenance.style == "woodcut")
    #expect(provenance.negative == "blur")
    #expect(provenance.negativeApplied == false)
    #expect(provenance.tool?.name == "invented-cli")
    #expect(provenance.notes == "kept")
    #expect(provenance.gateOverridden == "review")

    // §6: keys with no entry there are preserved, with their literals.
    #expect(provenance.json["character"] == .string("the-tinker"))
    #expect(provenance.json["bundle"]?.objectValue?["referenceCount"] == .number("1"))
    let shot = provenance.json["glosa"]?.objectValue?["shot"]?.objectValue
    #expect(shot?["x-unknown"] == .array([.number("1"), .number("2.50")]))

    let references = provenance.references
    #expect(references.count == 2)
    #expect(references[0].sha256 == portrait.sha256)
    #expect(references[0].path == portrait.path)
    #expect(references[0].role == "portrait")
    #expect(references[0].json["effectiveWidth"] == .number("36"))
    #expect(references[0].json["source"] == nil)
    #expect(references[1].sha256 == unmatched)
    #expect(references[1].path == nil)
    #expect(references[1].role == "pose")

    // Nothing the writer put in the bundle holds the sidecar's source, and no sidecar came along.
    let written = String(decoding: try Synthetic.allBytes(under: bundle.url), as: UTF8.self)
    #expect(!written.contains(Synthetic.absoluteSource))
    #expect(!written.contains("/Volumes/nowhere"))
    #expect(!written.contains("\"source\""))
    #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("images/panel.json").path))
    try expectClean(bundle)
  }

  @Test("SD-7, V-03: a PNG's embedded record is read, and a sidecar is preferred to it")
  func embeddedRecord() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let data = Synthetic.embedding(
      Synthetic.sidecar(references: [(Synthetic.absoluteSource, String(repeating: "b", count: 64))]),
      in: try Synthetic.png())
    let source = try Synthetic.file("embedded.png", data, in: root)

    let asset = try bundle.add(source, kind: .portrait)

    #expect(asset.provenance.provider == "vinetas")
    #expect(asset.provenance.model == "invented-4b")
    #expect(asset.createdAt == "2026-03-04T05:06:07Z")
    #expect(asset.provenance.references.first?.json["source"] == nil)
    // SD-6: the source is as it was, and the record's absolute path is in no byte of the bundle.
    #expect(try Data(contentsOf: source) == data)
    #expect(try Synthetic.allBytes(under: bundle.url).range(of: Data(Synthetic.absoluteSource.utf8)) == nil)
    #expect(try Data(contentsOf: bundle.url.appendingPathComponent(asset.path)) == PNGMetadata.stripped(data))
    try expectClean(bundle)

    let sidecar = try Synthetic.file("other.json", Data(#"{"model": "from-the-sidecar"}"#.utf8), in: root)
    let other = try bundle.add(
      Synthetic.file("embedded-2.png", Synthetic.embedding(Synthetic.sidecar(), in: try Synthetic.png(shade: 8)), in: root),
      kind: .portrait, options: AddOptions(sidecar: sidecar))
    #expect(other.provenance.model == "from-the-sidecar")
    #expect(other.provenance.prompt == nil)
  }

  @Test("§5.4: with no generator's time, createdAt is the given date, then the file's")
  func createdAt() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let source = try Synthetic.file("a.png", Synthetic.png(), in: root)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: source.path)
    #expect(try bundle.add(source, kind: .portrait).createdAt == "2001-09-09T01:46:40Z")

    let later = try Synthetic.file("b.png", Synthetic.png(shade: 3), in: root)
    let asset = try bundle.add(
      later, kind: .portrait, options: AddOptions(createdAt: Date(timeIntervalSince1970: 2_000_000_000.75)))
    #expect(asset.createdAt == "2033-05-18T03:33:20Z")
  }

  @Test("§1: a generatedAt with a fraction or an offset is written in whole seconds and UTC")
  func generatedAtForms() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let cases = [("2026-03-04T05:06:07.900Z", "2026-03-04T05:06:07Z"), ("2026-03-04T05:06:07+02:00", "2026-03-04T03:06:07Z")]
    for (index, (written, expected)) in cases.enumerated() {
      let sidecar = try Synthetic.file("s\(index).json", Data(#"{"generatedAt": "\#(written)"}"#.utf8), in: root)
      let image = try Synthetic.file("p\(index).png", Synthetic.png(shade: UInt8(index)), in: root)
      let asset = try bundle.add(image, kind: .portrait, options: AddOptions(sidecar: sidecar))
      #expect(asset.createdAt == expected)
    }
    let bad = try Synthetic.file("bad.json", Data(#"{"generatedAt": "yesterday"}"#.utf8), in: root)
    let image = try Synthetic.file("p.png", Synthetic.png(shade: 200), in: root)
    expectWriteError(.timestampUnreadable(#""yesterday""#)) {
      try bundle.add(image, kind: .portrait, options: AddOptions(sidecar: bad))
    }
  }

  @Test("SD-7: unusable provenance is refused, not guessed at")
  func provenanceRefusals() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let image = try Synthetic.file("p.png", Synthetic.png(), in: root)

    expectWriteError(.referenceRolesMismatch(roles: 1, references: 0)) {
      try bundle.add(image, kind: .portrait, options: AddOptions(referenceRoles: ["portrait"]))
    }
    let notJSON = try Synthetic.file("bad.json", Data("[1]".utf8), in: root)
    expectWriteError(.provenanceUnreadable("bad.json")) {
      try bundle.add(image, kind: .portrait, options: AddOptions(sidecar: notJSON))
    }
    let pathStrings = try Synthetic.file("v1.json", Data(#"{"references": ["a.png"]}"#.utf8), in: root)
    expectWriteError(.provenanceMalformed("a reference isn't an object")) {
      try bundle.add(image, kind: .portrait, options: AddOptions(sidecar: pathStrings))
    }
    // A reference given through --provenance is held to the same rule: no source, no absolute path.
    let direct = try Synthetic.object(
      #"{"references": [{"sha256": "\#(String(repeating: "c", count: 64))", "source": "\#(Synthetic.absoluteSource)"}]}"#)
    let kept = try bundle.add(image, kind: .portrait, options: AddOptions(provenance: direct))
    #expect(kept.provenance.references.first?.json["source"] == nil)

    let other = try Synthetic.file("q.png", Synthetic.png(shade: 5), in: root)
    let absolute = try Synthetic.object(
      #"{"references": [{"sha256": "\#(String(repeating: "c", count: 64))", "path": "/x/y.png"}]}"#)
    #expect(throws: DossierWriteError.self) {
      try bundle.add(other, kind: .portrait, options: AddOptions(provenance: absolute))
    }
    #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("images/\(other.lastPathComponent)").path))
  }

  @Test("§1, §6: a LoRA's absolute path isn't written")
  func loraPaths() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let adapter = try bundle.add(
      Synthetic.file("a.safetensors", Data("adapter".utf8), in: root), kind: .lora,
      options: AddOptions(lora: Synthetic.object(#"{"triggerWord": "tnkr", "version": 1}"#)))

    func added(_ path: String, shade: UInt8) throws -> String? {
      let sidecar = try Synthetic.file(
        "l\(shade).json", Data(Synthetic.sidecar(lora: path).utf8), in: root)
      let image = try Synthetic.file("l\(shade).png", Synthetic.png(shade: shade), in: root)
      let asset = try bundle.add(image, kind: .portrait, options: AddOptions(sidecar: sidecar))
      return asset.provenance.json["loras"]?.arrayValue?.first?.objectValue?["path"]?.stringValue
    }

    #expect(try added("/Volumes/nowhere/lora/THE TINKER-v1.safetensors", shade: 1) == adapter.path)
    #expect(try added("/Volumes/nowhere/lora/shared.safetensors", shade: 2) == "shared.safetensors")
    #expect(try added("~/lora/shared.safetensors", shade: 3) == "shared.safetensors")
    #expect(try added("lora/THE TINKER-v1.safetensors", shade: 4) == adapter.path)
    let manifest = String(decoding: try Data(contentsOf: bundle.url.appendingPathComponent("manifest.json")), as: UTF8.self)
    #expect(!manifest.contains("/Volumes/nowhere"))
    try expectClean(bundle)
  }

  // MARK: add: derivedFrom

  @Test("SD-10: face, view, expression and voiceSample record §7's inputs")
  func derivedInputs() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let portrait = try addPortrait(to: &bundle, root: root)
    let faceData = try Synthetic.png(width: 16, height: 16)
    let face = try bundle.add(
      Synthetic.file("f.png", faceData, in: root), kind: .face, options: AddOptions(select: true))
    let faceHash = Checksum.sha256(try Data(contentsOf: bundle.url.appendingPathComponent(face.path)))
    #expect(face.derivedFrom.map(\.role) == ["portrait"])
    #expect(face.derivedFrom[0].path == portrait.path)
    #expect(face.derivedFrom[0].sha256 == portrait.sha256)

    let expression = try bundle.add(
      Synthetic.file("e.png", Synthetic.png(width: 16, height: 16, shade: 7), in: root), kind: .expression,
      options: AddOptions(variant: "happy", select: true))
    #expect(expression.derivedFrom.map(\.role) == ["face", "portrait"])
    #expect(expression.derivedFrom[0].sha256 == faceHash)
    #expect(expression.path.hasPrefix("images/expression-happy-"))

    // §7: a view lists its face only when it was sent.
    let plain = try bundle.add(
      Synthetic.file("v1.png", Synthetic.png(shade: 11), in: root), kind: .view,
      options: AddOptions(variant: "front", select: true))
    #expect(plain.derivedFrom.map(\.role) == ["portrait"])
    #expect(plain.path.hasPrefix("images/view-front-"))

    let sidecar = try Synthetic.file(
      "v.json", Data(Synthetic.sidecar(references: [("x", faceHash)]).utf8), in: root)
    let withFace = try bundle.add(
      Synthetic.file("v2.png", Synthetic.png(shade: 12), in: root), kind: .view,
      options: AddOptions(variant: "profile", sidecar: sidecar, select: true))
    #expect(withFace.derivedFrom.map(\.role) == ["portrait", "face"])

    let vox = try bundle.add(
      Synthetic.file("t.vox", Data("voice".utf8), in: root), kind: .vox, options: AddOptions(select: true))
    let sample = try bundle.add(
      Synthetic.file("sample-neutral.m4a", Data("line".utf8), in: root), kind: .voiceSample,
      options: AddOptions(variant: "neutral", model: "1.7b", sampleText: "Hold still.", select: true))
    #expect(sample.derivedFrom.map(\.role) == ["vox"])
    #expect(sample.derivedFrom[0].path == vox.path)
    try expectClean(bundle)
    #expect(bundle.stale().isEmpty)
  }

  @Test("SD-10: a page records description, castMember, bundle and template, and isn't stale")
  func derivedPage() throws {
    let root = try Synthetic.temporaryDirectory()
    try Data(
      """
      ---
      type: cast
      cast:
        - character: THE TINKER
          role: background
          manifest: characters/THE TINKER.dossier/manifest.json
      ---
      """.utf8
    ).write(to: root.appendingPathComponent("CAST.md"))
    _ = try Synthetic.bundle(in: root)
    let cast = try Cast.load(root.appendingPathComponent("CAST.md"))
    let onlyMember = try #require(cast.members.first)
    var bundle = try #require(try cast.openBundle(for: onlyMember))

    let page = try Synthetic.file("page.html", Data("<!doctype html><p>A page.</p>\n".utf8), in: root)
    expectWriteError(.missingDerivedInput(kind: "dossier", role: "description")) {
      try bundle.add(page, kind: .dossier)
    }
    let description = try bundle.add(
      Synthetic.file("c.md", Data("# THE TINKER\n".utf8), in: root), kind: .description,
      options: AddOptions(select: true))
    expectWriteError(.missingDerivedInput(kind: "dossier", role: "template")) {
      try bundle.add(page, kind: .dossier)
    }

    let template = PageTemplate(version: "0.0.1", sha256: String(repeating: "d", count: 64))
    let asset = try bundle.add(page, kind: .dossier, options: AddOptions(template: template, select: true))

    #expect(asset.path == "THE TINKER-dossier.html")
    #expect(asset.derivedFrom.map(\.role) == ["description", "castMember", "bundle", "template"])
    #expect(asset.derivedFrom[0].path == description.path)
    #expect(asset.derivedFrom[1].sha256 == bundle.member?.hash)
    #expect(asset.derivedFrom[2].sha256 == bundle.bundleChecksum)
    #expect(asset.derivedFrom[3].version == "0.0.1")
    #expect(bundle.stale(template: template).isEmpty)
    #expect(!bundle.pageURL!.path.isEmpty)
  }

  @Test("§7: what was sent is what's recorded, so the wrong selection reads as stale")
  func derivedFromWhatWasSent() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let first = try addPortrait(to: &bundle, root: root, shade: 20)
    let second = try addPortrait(to: &bundle, root: root, shade: 21)
    #expect(bundle.selectedAsset(kind: .portrait)?.path == second.path)

    let sidecar = try Synthetic.file(
      "f.json", Data(Synthetic.sidecar(references: [("x", first.sha256)]).utf8), in: root)
    let face = try bundle.add(
      Synthetic.file("f.png", Synthetic.png(width: 16, height: 16), in: root), kind: .face,
      options: AddOptions(sidecar: sidecar, referenceRoles: ["portrait"], select: true))

    #expect(face.derivedFrom[0].sha256 == first.sha256)
    #expect(face.derivedFrom[0].path == first.path)
    #expect(bundle.stale().map(\.path) == [face.path])

  }

  @Test("§7: bytes sent that have left the bundle keep their hash, with the selection's path")
  func derivedFromLeftTheBundle() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let image = try Synthetic.file("g.png", Synthetic.png(width: 16, height: 16, shade: 2), in: root)
    let absent = String(repeating: "e", count: 64)
    let unknown = try Synthetic.file(
      "g.json", Data(Synthetic.sidecar(references: [("x", absent)]).utf8), in: root)
    let options = AddOptions(sidecar: unknown, referenceRoles: ["portrait"], select: true)

    // §7 requires the input, and with no selection there's no path for it.
    expectWriteError(.missingDerivedInput(kind: "face", role: "portrait")) {
      try bundle.add(image, kind: .face, options: options)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.url.path) == ["manifest.json"])

    let portrait = try addPortrait(to: &bundle, root: root)
    let face = try bundle.add(image, kind: .face, options: options)
    #expect(face.derivedFrom[0].sha256 == absent)
    #expect(face.derivedFrom[0].path == portrait.path)
    #expect(face.provenance.references[0].sha256 == absent)
    #expect(face.provenance.references[0].path == portrait.path)
    #expect(bundle.stale().map(\.path) == [face.path])
    let codes = try DossierBundle.validate(at: bundle.url).findings.map(\.code)
    #expect(codes.contains(.stale))
    #expect(!codes.contains { $0.level == .error })
  }

  @Test("§6: a reference's path: the asset with the hash, else the role's selection, else none")
  func referencePaths() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let portrait = try addPortrait(to: &bundle, root: root)
    let front = try bundle.add(
      Synthetic.file("front.png", Synthetic.png(shade: 3), in: root), kind: .view,
      options: AddOptions(variant: "front", select: true))
    let absent = String(repeating: "e", count: 64)
    let record = #"""
      {"references": [
        {"sha256": "\#(portrait.sha256)", "role": "pose"},
        {"sha256": "\#(absent)", "role": "portrait"},
        {"sha256": "\#(absent)", "role": "view:front"},
        {"sha256": "\#(absent)", "role": "view:back"},
        {"sha256": "\#(absent)", "role": "pose"},
        {"sha256": "\#(absent)"}
      ]}
      """#
    let sidecar = try Synthetic.file("r.json", Data(record.utf8), in: root)
    let asset = try bundle.add(
      Synthetic.file("r.png", Synthetic.png(shade: 4), in: root), kind: .crowdRef, options: AddOptions(sidecar: sidecar))

    let references = asset.provenance.references
    #expect(references.map(\.path) == [portrait.path, portrait.path, front.path, nil, nil, nil])
    #expect(references.dropFirst().allSatisfy { $0.sha256 == absent })
  }

  @Test("SD-10: a derived kind with no input is refused; explicit inputs are held to §7")
  func derivedRefusals() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let source = try Synthetic.file("f.png", Synthetic.png(width: 16, height: 16), in: root)

    expectWriteError(.missingDerivedInput(kind: "face", role: "portrait")) { try bundle.add(source, kind: .face) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.url.path) == ["manifest.json"])

    let portrait = try addPortrait(to: &bundle, root: root)
    let wrong = DerivedInput(role: "vox", sha256: portrait.sha256, path: portrait.path)
    expectWriteError(.missingDerivedInput(kind: "face", role: "portrait")) {
      try bundle.add(source, kind: .face, options: AddOptions(derivedFrom: [wrong]))
    }
    let right = DerivedInput(role: "portrait", sha256: portrait.sha256, path: portrait.path)
    let asset = try bundle.add(source, kind: .face, options: AddOptions(derivedFrom: [right]))
    #expect(asset.derivedFrom == [right])
    try expectClean(bundle)
  }

  @Test("DF-76: a voiceSample given a voice input needs no vox; given neither vox nor voice, it's refused")
  func hostedVoiceSample() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let source = try Synthetic.file("sample-neutral.m4a", Data("line".utf8), in: root)
    let options = { (inputs: [DerivedInput]) in
      AddOptions(
        variant: "neutral", model: "invented-hosted", sampleText: "Hold still.",
        provenance: try Synthetic.object(#"{"instructMethod": "audio-tag", "instructApplied": "unverified"}"#),
        derivedFrom: inputs, select: true)
    }
    let other = DerivedInput(role: "description", sha256: String(repeating: "0", count: 64), path: "CHARACTER.md")
    expectWriteError(.missingDerivedInput(kind: "voiceSample", role: "vox or voice")) {
      try bundle.add(source, kind: .voiceSample, options: try options([other]))
    }
    let voice = DerivedInput(voiceProvider: "invented", voiceId: "INVENTED0VOICE01")
    let sample = try bundle.add(source, kind: .voiceSample, options: try options([voice]))
    #expect(sample.derivedFrom == [voice])
    #expect(sample.provenance.instructMethod == "audio-tag")
    try expectClean(bundle)
  }

  @Test("DF-77: an imported view needs no input, and records none unless given one")
  func importedView() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let source = try Synthetic.file("v.png", Synthetic.png(shade: 21), in: root)
    let view = try bundle.add(
      source, kind: .view,
      options: AddOptions(
        variant: "front", provenance: try Synthetic.object(#"{"copiedFrom": "art/tinker-front.png"}"#), select: true))
    #expect(view.isImported)
    #expect(view.json["derivedFrom"] == nil)
    try expectClean(bundle)
    // A face without copiedFrom still needs its portrait input.
    let face = try Synthetic.file("f.png", Synthetic.png(width: 16, height: 16), in: root)
    expectWriteError(.missingDerivedInput(kind: "face", role: "portrait")) { try bundle.add(face, kind: .face) }
  }

  // MARK: select, reject, remove, delete

  @Test("SD-8: selecting demotes the previous selection of that kind and variant, only")
  func selectDemotes() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    _ = try addPortrait(to: &bundle, root: root)
    func view(_ variant: String, _ shade: UInt8) throws -> Asset {
      try bundle.add(
        Synthetic.file("v\(shade).png", Synthetic.png(shade: shade), in: root), kind: .view,
        options: AddOptions(variant: variant))
    }
    let front = try view("front", 1)
    let frontTwo = try view("front", 2)
    let back = try view("back", 3)
    try bundle.select(path: front.path)
    try bundle.select(path: back.path)

    let selected = try bundle.select(path: frontTwo.path)
    #expect(selected.status == .selected)

    func status(_ path: String) -> AssetStatus? { bundle.manifest.assets.first { $0.path == path }?.status }
    #expect(status(front.path) == .candidate)
    #expect(status(frontTwo.path) == .selected)
    #expect(status(back.path) == .selected)
    #expect(bundle.manifest.assets.contains { $0.kind == .portrait && $0.status == .selected })
    try expectClean(bundle)
  }

  @Test("SD-8: a voiceSample's selection is per kind, variant and model")
  func selectPerModel() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    try bundle.add(
      Synthetic.file("t.vox", Data("voice".utf8), in: root), kind: .vox, options: AddOptions(select: true))
    func sample(_ name: String, _ model: String) throws -> Asset {
      try bundle.add(
        Synthetic.file(name, Data(name.utf8), in: root), kind: .voiceSample,
        options: AddOptions(variant: "neutral", model: model, sampleText: "Hold still.", select: true))
    }
    let large = try sample("sample-neutral.m4a", "1.7b")
    let small = try sample("sample-neutral-0.6b.m4a", "0.6b")
    func status(_ path: String) -> AssetStatus? { bundle.manifest.assets.first { $0.path == path }?.status }
    #expect(status(large.path) == .selected)
    #expect(status(small.path) == .selected)

    let again = try sample("sample-neutral-take2.m4a", "1.7b")
    #expect(status(large.path) == .candidate)
    #expect(status(small.path) == .selected)
    #expect(status(again.path) == .selected)
    try expectClean(bundle)
  }

  @Test("SD-8: --select on add demotes in that one write")
  func addSelects() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let first = try addPortrait(to: &bundle, root: root, shade: 1)
    let second = try addPortrait(to: &bundle, root: root, shade: 2)
    #expect(bundle.manifest.assets.first { $0.path == first.path }?.status == .candidate)
    #expect(bundle.manifest.assets.first { $0.path == second.path }?.status == .selected)
    try expectClean(bundle)
  }

  @Test("select and reject of what's already so write nothing, and a stale value doesn't lose a write")
  func noOpsAndStaleValues() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let portrait = try addPortrait(to: &bundle, root: root)
    let manifestURL = bundle.url.appendingPathComponent("manifest.json")
    let before = try Data(contentsOf: manifestURL)
    try bundle.select(path: portrait.path)
    #expect(try Data(contentsOf: manifestURL) == before)

    // Two values of one bundle: each write starts from the disk.
    var other = try DossierBundle.open(at: bundle.url)
    let added = try bundle.add(Synthetic.file("g.png", Synthetic.png(shade: 66), in: root), kind: .portrait)
    try other.reject(path: portrait.path)
    #expect(other.manifest.assets.contains { $0.path == added.path })
    #expect(other.manifest.assets.first { $0.path == portrait.path }?.status == .rejected)
  }

  @Test("SD-9: reject keeps the file and promotes nothing")
  func rejectKeeps() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let first = try addPortrait(to: &bundle, root: root, shade: 1)
    let second = try addPortrait(to: &bundle, root: root, shade: 2)

    let rejected = try bundle.reject(path: second.path)
    #expect(rejected.status == .rejected)
    #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent(second.path).path))
    #expect(bundle.selectedAsset(kind: .portrait) == nil)
    #expect(bundle.manifest.assets.first { $0.path == first.path }?.status == .candidate)

    // A rejected asset can come back.
    try bundle.select(path: second.path)
    #expect(bundle.selectedAsset(kind: .portrait)?.path == second.path)
    try expectClean(bundle)

    expectWriteError(.assetNotFound("images/none.png")) { try bundle.reject(path: "images/none.png") }
    expectWriteError(.assetNotFound("images/none.png")) { try bundle.select(path: "images/none.png") }
    expectWriteError(.assetNotFound("images/none.png")) { try bundle.remove(path: "images/none.png") }
  }

  @Test("SD-9: remove deletes one asset and its file, and nothing else")
  func removeOne() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let first = try addPortrait(to: &bundle, root: root, shade: 1)
    let second = try addPortrait(to: &bundle, root: root, shade: 2)

    try bundle.remove(path: second.path)

    #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent(second.path).path))
    #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent(first.path).path))
    #expect(bundle.manifest.assets.map(\.path) == [first.path])
    #expect(bundle.manifest.files.map(\.path) == [first.path])
    // Nothing is promoted in its place.
    #expect(bundle.selectedAsset(kind: .portrait) == nil)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundle.url.appendingPathComponent("images").path)
    #expect(leftovers == [String(first.path.dropFirst("images/".count))])
    try expectClean(bundle)
  }

  @Test("§7, SD-9: what was derived from a removed asset stays, and reads as stale")
  func removeLeavesDerived() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let portrait = try addPortrait(to: &bundle, root: root)
    let face = try bundle.add(
      Synthetic.file("f.png", Synthetic.png(width: 16, height: 16), in: root), kind: .face,
      options: AddOptions(select: true))
    try bundle.remove(path: portrait.path)
    #expect(bundle.manifest.assets.map(\.path) == [face.path])
    #expect(bundle.stale().map(\.path) == [face.path])
  }

  @Test("remove takes an asset whose file is gone, and otherwise a missing file stops a write")
  func removeMissingFile() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let first = try addPortrait(to: &bundle, root: root, shade: 1)
    try FileManager.default.removeItem(at: bundle.url.appendingPathComponent(first.path))
    let manifestURL = bundle.url.appendingPathComponent("manifest.json")
    let before = try Data(contentsOf: manifestURL)

    let other = try Synthetic.file("o.png", Synthetic.png(shade: 2), in: root)
    expectWriteError(.assetFilesMissing([first.path])) { try bundle.add(other, kind: .portrait) }
    #expect(try Data(contentsOf: manifestURL) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.url.appendingPathComponent("images").path).isEmpty)

    try bundle.remove(path: first.path)
    #expect(bundle.manifest.assets.isEmpty)
    try expectClean(bundle)
  }

  @Test("remove doesn't follow a symbolic link at the asset's path")
  func removeLeavesLinkTarget() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let asset = try bundle.add(Synthetic.file("p.png", Synthetic.png(), in: root), kind: .portrait)
    let target = try Synthetic.file("target.png", Data("keep me".utf8), in: root)
    let path = bundle.url.appendingPathComponent(asset.path)
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)

    try bundle.remove(path: asset.path)

    #expect(try Data(contentsOf: target) == Data("keep me".utf8))
    #expect(bundle.manifest.assets.isEmpty)
  }

  @Test("SD-9: delete removes the bundle, and only a bundle")
  func deleteBundle() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    _ = try addPortrait(to: &bundle, root: root)
    let source = root.appendingPathComponent("outside")

    try bundle.delete()
    #expect(!FileManager.default.fileExists(atPath: bundle.url.path))
    #expect(FileManager.default.fileExists(atPath: source.path))

    expectWriteError(.notADossierDirectory(bundle.url.path)) { try bundle.delete() }

    let plain = root.appendingPathComponent("characters/PLAIN")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    try Manifest(character: "PLAIN", updatedAt: "2026-01-01T00:00:00Z").encoded()
      .write(to: plain.appendingPathComponent("manifest.json"))
    let notBundle = DossierBundle(
      url: plain, manifest: try Manifest(data: Data(contentsOf: plain.appendingPathComponent("manifest.json"))),
      member: nil)
    expectWriteError(.notADossierDirectory(plain.path)) { try notBundle.delete() }
    #expect(FileManager.default.fileExists(atPath: plain.path))
  }

  // MARK: Failed writes

  @Test("SD-3: a manifest that fails its schema isn't written, and what add placed is taken back")
  func schemaRefusal() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let portrait = try addPortrait(to: &bundle, root: root)
    let manifestURL = bundle.url.appendingPathComponent("manifest.json")
    let good = try Data(contentsOf: manifestURL)

    // A write whose result would fail: a voiceSample with no sampleText, with its own directory.
    let sample = try Synthetic.file("sample-neutral.m4a", Data("line".utf8), in: root)
    try bundle.add(
      Synthetic.file("t.vox", Data("voice".utf8), in: root), kind: .vox, options: AddOptions(select: true))
    let beforeSample = try Data(contentsOf: manifestURL)
    #expect(throws: DossierWriteError.self) {
      try bundle.add(sample, kind: .voiceSample, options: AddOptions(variant: "neutral", model: "1.7b"))
    }
    #expect(try Data(contentsOf: manifestURL) == beforeSample)
    #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("voice/sample-neutral.m4a").path))

    // The directory add made is taken back too.
    let tool = try Synthetic.object(#"{"tool": "a plain string"}"#)
    let photo = try Synthetic.file("photo.jpg", Data("photo".utf8), in: root)
    #expect(throws: DossierWriteError.self) {
      try bundle.add(photo, kind: .sourcePhoto, options: AddOptions(provenance: tool))
    }
    #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("source").path))

    // A manifest already failing the schema stays as it is, through every operation.
    var broken = try Manifest(data: good)
    broken.json["role"] = .string("protagonist")
    let brokenBytes = broken.encoded()
    try brokenBytes.write(to: manifestURL)
    #expect(throws: DossierWriteError.self) { try bundle.reject(path: portrait.path) }
    #expect(throws: DossierWriteError.self) { try bundle.remove(path: portrait.path) }
    #expect(try Data(contentsOf: manifestURL) == brokenBytes)
    #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent(portrait.path).path))
  }

  @Test("remove puts the file back when the manifest can't be written")
  func removeRestoresFile() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let portrait = try addPortrait(to: &bundle, root: root)
    let empty = bundle.url.appendingPathComponent("zero.txt")
    try Data().write(to: empty)
    let manifestURL = bundle.url.appendingPathComponent("manifest.json")
    let before = try Data(contentsOf: manifestURL)

    expectWriteError(.zeroByteFiles(["zero.txt"])) { try bundle.remove(path: portrait.path) }

    #expect(try Data(contentsOf: manifestURL) == before)
    #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent(portrait.path).path))
    let images = try FileManager.default.contentsOfDirectory(atPath: bundle.url.appendingPathComponent("images").path)
    #expect(images.count == 1)
  }

  @Test("§5.2: a zero-byte file in the bundle stops a write, and removing it as an asset is allowed")
  func zeroByteInBundle() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let portrait = try addPortrait(to: &bundle, root: root)
    let path = bundle.url.appendingPathComponent(portrait.path)
    try Data().write(to: path)

    expectWriteError(.zeroByteFiles([portrait.path])) { try bundle.reject(path: portrait.path) }
    try bundle.remove(path: portrait.path)
    #expect(bundle.manifest.assets.isEmpty)
    try expectClean(bundle)
  }

  @Test("§5.4: E-MULTI-SELECTED isn't written, and select repairs it")
  func multipleSelected() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let first = try addPortrait(to: &bundle, root: root, shade: 1)
    let second = try addPortrait(to: &bundle, root: root, shade: 2)
    let manifestURL = bundle.url.appendingPathComponent("manifest.json")
    var both = try Manifest(data: Data(contentsOf: manifestURL))
    var assets = both.assets
    for index in assets.indices { assets[index].status = .selected }
    both.assets = assets
    try both.encoded().write(to: manifestURL)

    let other = try Synthetic.file("c.png", Synthetic.png(shade: 3), in: root)
    expectWriteError(.multipleSelected(second.path)) { try bundle.add(other, kind: .portrait) }

    try bundle.select(path: first.path)
    #expect(bundle.selectedAsset(kind: .portrait)?.path == first.path)
    #expect(bundle.manifest.assets.first { $0.path == second.path }?.status == .candidate)
    try expectClean(bundle)
  }

  @Test("§5.6: a temporary file that can't be written leaves the manifest as it was")
  func unwritableBundle() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let portrait = try addPortrait(to: &bundle, root: root)
    let manifestURL = bundle.url.appendingPathComponent("manifest.json")
    let before = try Data(contentsOf: manifestURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundle.url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.url.path) }

    #expect(throws: DossierWriteError.self) { try bundle.reject(path: portrait.path) }
    #expect(try Data(contentsOf: manifestURL) == before)
    #expect(bundle.manifest.assets.first?.status == .selected)
  }

  @Test("§5.6: a manifest that doesn't read back as written is replaced by the prior one")
  func verificationFailure() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    _ = try addPortrait(to: &bundle, root: root)
    let manifestURL = bundle.url.appendingPathComponent("manifest.json")
    let before = try Data(contentsOf: manifestURL)

    let writer = ManifestWriter(bundle: bundle.url) { url in
      try? Data("{\"manifestVersion\": 2}\n".utf8).write(to: url)
    }
    expectWriteError(.verificationFailed) { try writer.update { _, _ in } }
    #expect(try Data(contentsOf: manifestURL) == before)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).allSatisfy { !$0.hasPrefix(".") })
  }

  @Test("Appendix A: a writer doesn't write version 1")
  func versionOneRefused() throws {
    let root = try Synthetic.temporaryDirectory()
    let project = root.appendingPathComponent("project")
    try FileManager.default.copyItem(at: Conformance.root.appendingPathComponent("warnings/W-V1"), to: project)
    let characters = project.appendingPathComponent("characters")
    let name = try #require(try FileManager.default.contentsOfDirectory(atPath: characters.path).first)
    let url = characters.appendingPathComponent(name)
    let manifestURL = url.appendingPathComponent("manifest.json")
    let before = try Data(contentsOf: manifestURL)
    var bundle = try DossierBundle.open(at: url)
    #expect(bundle.manifest.manifestVersion == 1)
    let path = try #require(bundle.manifest.assets.first?.path)

    expectWriteError(.versionOneManifest) { try bundle.select(path: path) }
    expectWriteError(.versionOneManifest) { try bundle.remove(path: path) }
    let image = try Synthetic.file("p.png", Synthetic.png(), in: root)
    expectWriteError(.versionOneManifest) { try bundle.add(image, kind: .portrait) }
    #expect(try Data(contentsOf: manifestURL) == before)
    #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path))
  }

  // MARK: Preservation

  @Test("§5.1, §5.4, §6: unknown keys and number literals survive every write")
  func unknownKeysPreserved() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    let portrait = try addPortrait(to: &bundle, root: root)
    let manifestURL = bundle.url.appendingPathComponent("manifest.json")
    var manifest = try Manifest(data: Data(contentsOf: manifestURL))
    manifest.json["x-top"] = try JSONValue.parse(Data(#"{"big": 18446744073709551615, "small": 1.50}"#.utf8))
    var assets = manifest.assets
    assets[0].json["x-asset"] = .string("kept")
    var provenance = assets[0].provenance
    provenance.json["x-provenance"] = .array([.number("1e3")])
    assets[0].provenance = provenance
    manifest.assets = assets
    manifest.manifestChecksum = manifest.computedChecksum
    try manifest.encoded().write(to: manifestURL)

    try bundle.add(Synthetic.file("g.png", Synthetic.png(shade: 33), in: root), kind: .portrait)
    try bundle.reject(path: portrait.path)

    let written = try Manifest(data: Data(contentsOf: manifestURL))
    #expect(written.json["x-top"] == manifest.json["x-top"])
    let asset = try #require(written.assets.first { $0.path == portrait.path })
    #expect(asset.json["x-asset"] == .string("kept"))
    #expect(asset.provenance.json["x-provenance"] == .array([.number("1e3")]))
    try expectClean(bundle)
  }

  @Test("§5.2: files is sorted by byte order, skips hidden files and symlinks, and keeps an asset's spelling")
  func rescan() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    _ = try addPortrait(to: &bundle, root: root)
    let manager = FileManager.default
    try Data("# THE TINKER\n".utf8).write(to: bundle.url.appendingPathComponent("CHARACTER.md"))
    try Data("note".utf8).write(to: bundle.url.appendingPathComponent(".hidden"))
    try manager.createDirectory(at: bundle.url.appendingPathComponent(".cache"), withIntermediateDirectories: true)
    try Data("note".utf8).write(to: bundle.url.appendingPathComponent(".cache/a"))
    try manager.createSymbolicLink(
      at: bundle.url.appendingPathComponent("link.txt"), withDestinationURL: bundle.url.appendingPathComponent(".hidden"))
    try Data("z".utf8).write(to: bundle.url.appendingPathComponent("z.txt"))
    try Data("a".utf8).write(to: bundle.url.appendingPathComponent("a.txt"))

    let nfd = "source/E\u{301}.jpg"
    let photo = try bundle.add(Synthetic.file("E\u{301}.jpg", Data("photo".utf8), in: root), kind: .sourcePhoto)
    #expect(photo.path.utf8.elementsEqual(nfd.utf8))

    let paths = bundle.manifest.files.map(\.path)
    #expect(paths == paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
    #expect(paths.contains("CHARACTER.md") && paths.contains("a.txt") && paths.contains("z.txt"))
    #expect(!paths.contains { $0.hasPrefix(".") || $0 == "link.txt" || $0 == "manifest.json" })
    #expect(bundle.manifest.manifestChecksum == Checksum.sorted(bundle.manifest.files.map(\.sha256)))
    let codes = try DossierBundle.validate(at: bundle.url).findings.map(\.code)
    #expect(!codes.contains { $0.level == .error }, "\(codes)")
  }

  @Test("§5.2: a manifest spelling a path in another normalization than the disk keeps its spelling")
  func spellingDiffersFromDisk() throws {
    let root = try Synthetic.temporaryDirectory()
    var bundle = try Synthetic.bundle(in: root)
    // The disk has the decomposed name; the manifest is rewritten to the composed one.
    let asset = try bundle.add(Synthetic.file("E\u{301}.jpg", Data("photo".utf8), in: root), kind: .sourcePhoto)
    let composed = "source/\u{C9}.jpg"
    #expect(!asset.path.utf8.elementsEqual(composed.utf8))
    let manifestURL = bundle.url.appendingPathComponent("manifest.json")
    var manifest = try Manifest(data: Data(contentsOf: manifestURL))
    var assets = manifest.assets
    assets[0].path = composed
    manifest.assets = assets
    manifest.files = [FileEntry(path: composed, sha256: manifest.files[0].sha256, sizeBytes: 5)]
    try manifest.encoded().write(to: manifestURL)

    let rejected = try bundle.reject(path: asset.path)

    #expect(rejected.path.utf8.elementsEqual(composed.utf8))
    #expect(bundle.manifest.files.map { Array($0.path.utf8) } == [Array(composed.utf8)])
    let codes = try DossierBundle.validate(at: bundle.url).findings.map(\.code)
    #expect(!codes.contains { $0.level == .error }, "\(codes)")
  }

  // MARK: Conformance fixtures, copied

  private static let validFixtures = Conformance.entries.filter { $0.verdict == "valid" }

  /// A copy of a fixture's project in a temporary directory.
  private func copy(_ path: String, to root: URL) throws -> URL {
    let project = root.appendingPathComponent("project")
    try FileManager.default.copyItem(at: Conformance.root.appendingPathComponent(path), to: project)
    return project
  }

  @Test("SD-3: a write to every valid fixture keeps it valid, and keeps everything but what it sets", arguments: validFixtures)
  func rewriteValidFixture(_ entry: Conformance.Entry) throws {
    let root = try Synthetic.temporaryDirectory()
    let project = try copy(entry.path, to: root)
    let castURL = project.appendingPathComponent("CAST.md")
    let url = project.appendingPathComponent(entry.bundle)
    let manifestURL = url.appendingPathComponent("manifest.json")
    let before = try Manifest(data: Data(contentsOf: manifestURL))
    if before.manifestVersion != 2 { return }

    let written = try ManifestWriter(bundle: url).update { _, _ in }

    var expected = before.json
    var actual = written.json
    for key in ["updatedAt", "generator"] {
      expected[key] = nil
      actual[key] = nil
    }
    #expect(actual == expected)
    let report = try DossierBundle.validate(cast: castURL, template: Conformance.template())
    let codes = Set(report.findings.map(\.code.rawValue))
    #expect(codes.subtracting(entry.codes).subtracting(entry.mayAlso).isEmpty, "\(codes)")
    #expect(report.exitStatus == 0)
  }

  @Test("A second selection on a whole fixture demotes the first and makes what's derived from it stale")
  func selectOnFixture() throws {
    let root = try Synthetic.temporaryDirectory()
    let project = try copy("valid/complete-lead", to: root)
    let cast = try Cast.load(project.appendingPathComponent("CAST.md"))
    let member = try #require(cast.members.first { $0.pointer != nil })
    var bundle = try #require(try cast.openBundle(for: member))
    let previous = try #require(bundle.selectedAsset(kind: .portrait))
    let before = bundle.stale(template: try Conformance.template())
    #expect(before.isEmpty)

    let asset = try bundle.add(
      Synthetic.file("new.png", Synthetic.png(shade: 123), in: root), kind: .portrait,
      options: AddOptions(select: true))

    #expect(bundle.selectedAsset(kind: .portrait)?.path == asset.path)
    #expect(bundle.manifest.assets.first { $0.path == previous.path }?.status == .candidate)
    let report = try DossierBundle.validate(
      cast: project.appendingPathComponent("CAST.md"), template: try Conformance.template())
    #expect(report.exitStatus == 1, "\(report.findings.map(\.code.rawValue))")
    #expect(report.findings.contains { $0.code == .stale })
  }
}
