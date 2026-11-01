import CoreGraphics
import DossierCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Dossier

/// A detector that returns what it's told, and counts its calls. CI needs no face.
private final class StubDetector: FaceDetector, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  let boxes: [FaceBox]
  init(_ boxes: [FaceBox]) { self.boxes = boxes }
  var calls: Int { lock.withLock { count } }
  func faces(in image: CGImage) throws -> [FaceBox] {
    lock.withLock { count += 1 }
    return boxes
  }
}

/// A generated portrait: a gradient, so crops of it differ by where they are.
private func portraitPNG(width: Int = 180, height: Int = 320, seed: UInt8 = 0) throws -> Data {
  var pixels = [UInt8](repeating: 255, count: width * height * 4)
  for row in 0..<height {
    for column in 0..<width {
      let at = (row * width + column) * 4
      pixels[at] = UInt8((column * 255 / width + Int(seed)) % 256)
      pixels[at + 1] = UInt8(row * 255 / height)
      pixels[at + 2] = UInt8((row + column) % 256)
    }
  }
  let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
  let image = try #require(
    CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  return try #require(DossierBundle.encodePNG(image))
}

private func pngChunkTypes(_ data: Data) -> [String] {
  let bytes = [UInt8](data)
  var types: [String] = []
  var offset = 8
  while offset + 12 <= bytes.count {
    let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
    types.append(String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self))
    offset += 12 + length
  }
  return types
}

@Suite("FaceCropTests")
struct FaceCropTests {
  private func bundleWithPortrait(
    _ project: SyntheticProject, seed: UInt8 = 0, name: String = "THE COBBLER"
  ) throws -> DossierBundle {
    var bundle = try DossierBundle.create(character: name, role: "lead", in: project.characters).bundle
    try addPortrait(to: &bundle, in: project, seed: seed)
    return bundle
  }

  private func addPortrait(to bundle: inout DossierBundle, in project: SyntheticProject, seed: UInt8) throws {
    let file = project.root.appendingPathComponent("portrait-\(seed).png")
    try portraitPNG(seed: seed).write(to: file)
    try bundle.add(file, kind: .portrait, options: AddOptions(select: true))
  }

  // MARK: §8.5's arithmetic

  @Test("§8.5 worked example: box (50, 60, 80, 100) in 180 x 320 is 180 x 180 at (0, 20)")
  func workedExample() {
    let crop = FaceCrop.rect(box: FaceBox(x: 50, y: 60, width: 80, height: 100), imageWidth: 180, imageHeight: 320)
    #expect(crop == FaceCropRect(left: 0, top: 20, side: 180))
  }

  @Test("A crop that would pass an edge moves inward")
  func clampsToEdges() {
    // side = round(1.8 * 20) = 36; centred at (10, 10) wants (-8, -8).
    let corner = FaceCrop.rect(box: FaceBox(x: 0, y: 0, width: 20, height: 20), imageWidth: 400, imageHeight: 300)
    #expect(corner == FaceCropRect(left: 0, top: 0, side: 36))
    // Centred at (390, 290) wants (372, 272); the far edges are at 364 and 264.
    let far = FaceCrop.rect(box: FaceBox(x: 380, y: 280, width: 20, height: 20), imageWidth: 400, imageHeight: 300)
    #expect(far == FaceCropRect(left: 364, top: 264, side: 36))
  }

  @Test("It shrinks only when larger than the image, and never upscales")
  func shrinksToImage() {
    let crop = FaceCrop.rect(box: FaceBox(x: 10, y: 10, width: 90, height: 90), imageWidth: 100, imageHeight: 120)
    #expect(crop == FaceCropRect(left: 0, top: 5, side: 100))
  }

  @Test("The larger side of the box sets the size")
  func largerSide() {
    let wide = FaceCrop.rect(box: FaceBox(x: 100, y: 100, width: 50, height: 10), imageWidth: 500, imageHeight: 500)
    #expect(wide.side == 90)
    let tall = FaceCrop.rect(box: FaceBox(x: 100, y: 100, width: 10, height: 50), imageWidth: 500, imageHeight: 500)
    #expect(tall.side == 90)
  }

  @Test("Halves round away from zero")
  func roundsHalfAway() {
    // side = round(1.8 * 2.5) = round(4.5) = 5; left = round(10 + 1.25 - 2.5) = round(8.75) = 9.
    let side = FaceCrop.rect(box: FaceBox(x: 10, y: 10, width: 2.5, height: 2.5), imageWidth: 100, imageHeight: 100)
    #expect(side.side == 5)
    #expect(side.left == 9)
    // side = round(1.8) = 2; left = round(10.5 - 1) = round(9.5) = 10; top = round(20.5 - 1) = round(19.5) = 20.
    let half = FaceCrop.rect(box: FaceBox(x: 10, y: 20, width: 1, height: 1), imageWidth: 100, imageHeight: 100)
    #expect(half == FaceCropRect(left: 10, top: 20, side: 2))
  }

  @Test("Vision's normalized bottom-left box becomes top-left pixels")
  func visionCoordinates() {
    // A face in the top-left quarter of 200 x 400: y is measured up from the bottom.
    let box = FaceCrop.pixelBox(
      normalizedX: 0.1, y: 0.7, width: 0.2, height: 0.2, imageWidth: 200, imageHeight: 400)
    #expect(abs(box.x - 20) < 1e-9)
    #expect(abs(box.y - 40) < 1e-9)
    #expect(abs(box.width - 40) < 1e-9)
    #expect(abs(box.height - 80) < 1e-9)
  }

  @Test("The largest face wins; the first wins a tie")
  func largestFace() {
    let small = FaceBox(x: 0, y: 0, width: 10, height: 10)
    let big = FaceBox(x: 5, y: 5, width: 30, height: 20)
    let twin = FaceBox(x: 50, y: 50, width: 20, height: 30)
    #expect(FaceCrop.largest([small, big]) == big)
    #expect(FaceCrop.largest([big, twin]) == big)
    #expect(FaceCrop.largest([]) == nil)
  }

  // MARK: deriveFace

  @Test("A detected face becomes the selected face, derived from the portrait, with no box recorded")
  func detects() throws {
    let project = try SyntheticProject()
    var bundle = try bundleWithPortrait(project)
    let detector = StubDetector([
      FaceBox(x: 5, y: 5, width: 10, height: 10), FaceBox(x: 50, y: 60, width: 80, height: 100),
    ])
    let derived = try bundle.deriveFace(detector: detector)

    #expect(derived.crop == FaceCropRect(left: 0, top: 20, side: 180))
    #expect(!derived.handSet)
    #expect(derived.wasWritten)
    let face = try #require(bundle.selectedAsset(kind: .face))
    #expect(face.path == derived.asset.path)
    #expect(face.path.hasPrefix("images/face-") && face.path.hasSuffix(".png"))
    #expect(face.provenance.box == nil)
    #expect(face.derivedFrom.map(\.role) == ["portrait"])
    let portrait = try #require(bundle.selectedAsset(kind: .portrait))
    #expect(face.derivedFrom.first?.path == portrait.path)

    let data = try Data(contentsOf: try #require(bundle.fileURL(forPath: face.path)))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect((image.width, image.height) == (180, 180))
    try expectManifestValidates(bundle)
    let findings = try DossierBundle.validate(at: bundle.url).findings
    #expect(!findings.contains { $0.level == .error }, "\(findings)")
  }

  @Test("The PNG has no metadata chunks")
  func strippedMetadata() throws {
    let project = try SyntheticProject()
    var bundle = try bundleWithPortrait(project)
    let face = try bundle.deriveFace(box: FaceBox(x: 50, y: 60, width: 80, height: 100)).asset
    let data = try Data(contentsOf: try #require(bundle.fileURL(forPath: face.path)))
    let types = pngChunkTypes(data)
    for forbidden in ["tEXt", "iTXt", "zTXt", "eXIf", "tIME"] { #expect(!types.contains(forbidden), "\(types)") }
  }

  @Test("The same portrait and box give identical bytes, twice, in different bundles and in one")
  func byteIdentical() throws {
    let project = try SyntheticProject()
    let box = FaceBox(x: 50, y: 60, width: 80, height: 100)
    var first = try bundleWithPortrait(project, name: "THE COBBLER")
    var second = try bundleWithPortrait(project, name: "THE WEAVER")
    let a = try first.deriveFace(box: box)
    let b = try second.deriveFace(box: box)
    #expect(a.asset.path == b.asset.path, "the name is the content hash (SD-6)")
    let bytesA = try Data(contentsOf: try #require(first.fileURL(forPath: a.asset.path)))
    let bytesB = try Data(contentsOf: try #require(second.fileURL(forPath: b.asset.path)))
    #expect(bytesA == bytesB)

    // Again in the same bundle: nothing is added.
    let manifest = try Data(contentsOf: first.url.appendingPathComponent("manifest.json"))
    let again = try first.deriveFace(box: box)
    #expect(!again.wasWritten)
    #expect(again.asset.path == a.asset.path)
    #expect(first.manifest.assets.filter { $0.kind == .face }.count == 1)
    #expect(try Data(contentsOf: first.url.appendingPathComponent("manifest.json")) == manifest)
  }

  @Test("No face and no box is an error and writes nothing")
  func noFace() throws {
    let project = try SyntheticProject()
    var bundle = try bundleWithPortrait(project)
    let before = try snapshot(of: bundle.url)
    #expect(throws: DossierWriteError.self) { try bundle.deriveFace(detector: StubDetector([])) }
    do {
      try bundle.deriveFace(detector: StubDetector([]))
    } catch let error as DossierWriteError {
      guard case .noFaceFound = error else { Issue.record("\(error)"); return }
    }
    #expect(try snapshot(of: bundle.url) == before)
    #expect(bundle.manifest.assets.allSatisfy { $0.kind != .face })
  }

  @Test("No selected portrait is an error and writes nothing")
  func noPortrait() throws {
    let project = try SyntheticProject()
    var bundle = try DossierBundle.create(character: "THE COBBLER", role: "lead", in: project.characters).bundle
    let before = try snapshot(of: bundle.url)
    do {
      try bundle.deriveFace(box: FaceBox(x: 1, y: 1, width: 5, height: 5))
      Issue.record("expected an error")
    } catch let error as DossierWriteError {
      #expect(error == .noSelectedPortrait)
    }
    #expect(try snapshot(of: bundle.url) == before)
  }

  @Test("An invalid box is refused")
  func invalidBox() throws {
    let project = try SyntheticProject()
    var bundle = try bundleWithPortrait(project)
    for box in [FaceBox(x: -1, y: 0, width: 5, height: 5), FaceBox(x: 0, y: 0, width: 0, height: 5)] {
      #expect(throws: DossierWriteError.faceBoxInvalid) { try bundle.deriveFace(box: box) }
    }
  }

  @Test("A hand-set box is recorded, replaces detection, and the previous face is demoted, not deleted")
  func handSetBox() throws {
    let project = try SyntheticProject()
    var bundle = try bundleWithPortrait(project)
    let detector = StubDetector([FaceBox(x: 50, y: 60, width: 80, height: 100)])
    let detected = try bundle.deriveFace(detector: detector).asset

    let box = FaceBox(x: 20, y: 30, width: 40, height: 50)
    let hand = try bundle.deriveFace(box: box, detector: detector)
    #expect(detector.calls == 1, "a given box needs no detection")
    #expect(hand.handSet)
    #expect(hand.asset.provenance.box.map(FaceBox.init) == box)
    #expect(hand.crop == FaceCrop.rect(box: box, imageWidth: 180, imageHeight: 320))

    let faces = bundle.manifest.assets.filter { $0.kind == .face }
    #expect(faces.count == 2)
    #expect(faces.first { $0.path == hand.asset.path }?.status == .selected)
    #expect(faces.first { $0.path == detected.path }?.status == .candidate)
    #expect(FileManager.default.fileExists(atPath: try #require(bundle.fileURL(forPath: detected.path)).path))
  }

  @Test("A hand-set box on the selected face is reused when the portrait changes and no box is given")
  func boxReusedOnRefresh() throws {
    let project = try SyntheticProject()
    var bundle = try bundleWithPortrait(project, seed: 0)
    let box = FaceBox(x: 20, y: 30, width: 40, height: 50)
    let first = try bundle.deriveFace(box: box).asset

    try addPortrait(to: &bundle, in: project, seed: 90)
    let detector = StubDetector([FaceBox(x: 1, y: 1, width: 9, height: 9)])
    let second = try bundle.deriveFace(detector: detector)

    #expect(detector.calls == 0, "the hand-set box stands in for detection")
    #expect(second.handSet)
    #expect(second.asset.path != first.path, "a new portrait makes new pixels")
    #expect(second.asset.provenance.box.map(FaceBox.init) == box)
    #expect(second.asset.derivedFrom.first?.sha256 != first.derivedFrom.first?.sha256)
    #expect(bundle.manifest.assets.filter { $0.kind == .face && $0.status == .selected }.map(\.path) == [second.asset.path])
    // The old face now reads as stale (§7), and is kept.
    #expect(bundle.manifest.assets.contains { $0.path == first.path && $0.status == .candidate })
  }

  @Test("A detected face is not remembered as a box")
  func detectedNotReused() throws {
    let project = try SyntheticProject()
    var bundle = try bundleWithPortrait(project, seed: 0)
    try bundle.deriveFace(detector: StubDetector([FaceBox(x: 50, y: 60, width: 80, height: 100)]))
    try addPortrait(to: &bundle, in: project, seed: 90)
    let other = StubDetector([FaceBox(x: 10, y: 10, width: 30, height: 30)])
    let second = try bundle.deriveFace(detector: other)
    #expect(other.calls == 1)
    #expect(!second.handSet)
  }

  /// Every file in the bundle with its bytes, for "writes nothing".
  private func snapshot(of directory: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    let manager = FileManager.default
    for case let file as URL in try #require(manager.enumerator(at: directory, includingPropertiesForKeys: nil)) {
      if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        result[file.path] = try Data(contentsOf: file)
      }
    }
    return result
  }
}

extension FaceBox {
  fileprivate init(_ box: Provenance.Box) { self.init(x: box.x, y: box.y, width: box.width, height: box.height) }
}
