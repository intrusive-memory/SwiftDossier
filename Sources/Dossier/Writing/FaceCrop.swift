import CoreGraphics
import DossierCore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A face box in source pixels, origin top-left (§6 `box`, §8.5).
public struct FaceBox: Sendable, Equatable {
  /// The left edge.
  public var x: Double
  /// The top edge.
  public var y: Double
  /// The width.
  public var width: Double
  /// The height.
  public var height: Double

  /// A box in source pixels, origin top-left.
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  /// Whether the box can be recorded as `provenance.box` and cropped on (§6: non-negative
  /// numbers; a size of zero has no larger side to scale).
  public var isValid: Bool {
    [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0
  }

  var area: Double { width * height }
}

/// The square §8.5 crops, in pixels from the top-left.
public struct FaceCropRect: Sendable, Equatable {
  /// The left edge.
  public let left: Int
  /// The top edge.
  public let top: Int
  /// The width and the height.
  public let side: Int
}

/// §8.5's arithmetic, as pure functions.
public enum FaceCrop {
  /// §8.5's three steps, with every value rounded half away from zero.
  ///
  /// `1.8 × max(w, h)` is computed as `max(w, h) × 9 ÷ 5`: for a whole-number side the product
  /// is then exact, and can never fall on a half.
  ///
  /// - Parameters:
  ///   - box: The face box, origin top-left.
  ///   - width: The image's width in pixels, as stored.
  ///   - height: The image's height in pixels, as stored.
  public static func rect(box: FaceBox, imageWidth width: Int, imageHeight height: Int) -> FaceCropRect {
    let imageW = Double(width)
    let imageH = Double(height)
    let side = min(max(box.width, box.height) * 9 / 5, imageW, imageH).rounded(.toNearestOrAwayFromZero)
    let left = min(max(box.x + box.width / 2 - side / 2, 0), imageW - side).rounded(.toNearestOrAwayFromZero)
    let top = min(max(box.y + box.height / 2 - side / 2, 0), imageH - side).rounded(.toNearestOrAwayFromZero)
    return FaceCropRect(left: Int(left), top: Int(top), side: Int(side))
  }

  /// The largest box by area. The first wins a tie, so the choice doesn't depend on a sort.
  public static func largest(_ boxes: [FaceBox]) -> FaceBox? {
    var best: FaceBox?
    for box in boxes where best == nil || box.area > best!.area { best = box }
    return best
  }

  /// A Vision bounding box (normalized, origin bottom-left) as source pixels, origin top-left.
  public static func pixelBox(
    normalizedX x: Double, y: Double, width: Double, height: Double, imageWidth: Int, imageHeight: Int
  ) -> FaceBox {
    let w = Double(imageWidth)
    let h = Double(imageHeight)
    return FaceBox(x: x * w, y: (1 - y - height) * h, width: width * w, height: height * h)
  }
}

/// Finds faces. ``VisionFaceDetector`` is the real one; tests pass their own, so CI needs no face.
public protocol FaceDetector: Sendable {
  /// Every face in the image, as source pixels with the origin top-left, in the pixels of
  /// `image` as stored.
  func faces(in image: CGImage) throws -> [FaceBox]
}

/// `VNDetectFaceRectanglesRequest`.
///
/// The image is handed to Vision as stored, with orientation `.up`, which is the pixel frame
/// §8.1 measures shapes in. EXIF orientation is not applied here or when cropping.
public struct VisionFaceDetector: FaceDetector {
  /// A detector over Vision's face rectangles request.
  public init() {}

  /// Every face Vision finds, converted from its normalized bottom-left boxes to source pixels.
  public func faces(in image: CGImage) throws -> [FaceBox] {
    let request = VNDetectFaceRectanglesRequest()
    try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
    return (request.results ?? []).map {
      FaceCrop.pixelBox(
        normalizedX: $0.boundingBox.minX, y: $0.boundingBox.minY, width: $0.boundingBox.width,
        height: $0.boundingBox.height, imageWidth: image.width, imageHeight: image.height)
    }
  }
}

/// What ``DossierBundle/deriveFace(box:detector:)`` produced.
public struct FaceDerivation: Sendable {
  /// The face asset, selected.
  public let asset: Asset
  /// The face box the crop was centred on.
  public let box: FaceBox
  /// Whether the box was given or reused (and so recorded as `provenance.box`), not detected.
  public let handSet: Bool
  /// The crop, in the portrait's pixels.
  public let crop: FaceCropRect
  /// `false` when the same bytes were already an asset, so nothing but the selection could change.
  public let wasWritten: Bool
}

extension DossierBundle {
  /// Crops the face out of the selected portrait (§8.5), adds it as the selected `face`, and
  /// demotes the previous one to `candidate`; nothing is deleted.
  ///
  /// The box is, in order: `box` when given; else the selected face's `provenance.box`, so a
  /// hand-set box survives a new portrait; else the largest face the detector finds. With none
  /// of the three nothing is written. The same portrait and box give the same bytes, which
  /// name the file (SD-6), so a second run finds the asset and writes nothing new.
  ///
  /// The output is the portrait's stored pixels, cropped, written as PNG by ImageIO with no
  /// properties: no metadata, no timestamp.
  ///
  /// SPEC-GAP: §6, §8.5: `provider` is required and no value is given for this tool. It's
  /// `dossier`, with `tool.name` the same, and `width` and `height` the crop's side.
  ///
  /// - Parameters:
  ///   - box: A hand-set face box in the portrait's pixels, origin top-left.
  ///   - detector: Finds the face when there is no box. Default: Vision.
  /// - Throws: ``DossierWriteError``, ``DossierCore/DossierError``, or what the detector throws.
  @discardableResult
  public mutating func deriveFace(
    box given: FaceBox? = nil, detector: any FaceDetector = VisionFaceDetector()
  ) throws -> FaceDerivation {
    let writer = ManifestWriter(bundle: url)
    let current = try writer.currentManifest()
    let view = DossierBundle(url: url, manifest: current, member: member)

    guard let portrait = view.selectedAsset(kind: .portrait), let file = view.fileURL(forPath: portrait.path) else {
      throw DossierWriteError.noSelectedPortrait
    }
    if let given, !given.isValid { throw DossierWriteError.faceBoxInvalid }
    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), !data.isEmpty,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      // The stored pixels: CGImageSource applies no orientation unless asked to.
      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { throw DossierWriteError.imageUnreadable(portrait.path) }

    let reused = view.selectedAsset(kind: .face)?.provenance.box.map {
      FaceBox(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
    }
    let handSet = given ?? reused
    let found = try handSet ?? FaceCrop.largest(detector.faces(in: image).filter(\.isValid))
    guard let found else { throw DossierWriteError.noFaceFound(portrait.path) }
    if handSet == nil, !found.isValid { throw DossierWriteError.faceBoxInvalid }

    let crop = FaceCrop.rect(box: found, imageWidth: image.width, imageHeight: image.height)
    guard let cropped = image.cropping(to: CGRect(x: crop.left, y: crop.top, width: crop.side, height: crop.side)),
      let png = Self.encodePNG(cropped)
    else { throw DossierWriteError.faceEncodeFailed }

    let path = "images/face-\(Checksum.sha256(png).prefix(8)).png"
    if current.assets.contains(where: { $0.hasPath(path) }) {
      let asset = try select(path: path)
      return FaceDerivation(asset: asset, box: found, handSet: handSet != nil, crop: crop, wasWritten: false)
    }

    var provenance = JSONObject()
    provenance["provider"] = .string("dossier")
    provenance["tool"] = .object(Self.toolObject())
    provenance["width"] = .integer(Int64(crop.side))
    provenance["height"] = .integer(Int64(crop.side))
    if let handSet { provenance["box"] = .object(Self.boxObject(handSet)) }

    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("face-\(UUID().uuidString).png")
    try png.write(to: temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let asset = try add(temporary, kind: .face, options: AddOptions(provenance: provenance, select: true))
    return FaceDerivation(asset: asset, box: found, handSet: handSet != nil, crop: crop, wasWritten: true)
  }

  /// PNG through ImageIO at fixed settings (no properties), then with the ancillary metadata
  /// chunks ImageIO adds anyway (`eXIf`, text, `tIME`) removed. U-1 is settled for the OS and
  /// ImageIO that ran the tests; the bytes aren't promised across OS versions.
  static func encodePNG(_ image: CGImage) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return PNGMetadata.stripped(output as Data)
  }

  private static func toolObject() -> JSONObject {
    var tool = JSONObject()
    tool["name"] = .string("dossier")
    return tool
  }

  private static func boxObject(_ box: FaceBox) -> JSONObject {
    func number(_ value: Double) -> JSONValue {
      value == value.rounded() && abs(value) < 1e15 ? .integer(Int64(value)) : .number("\(value)")
    }
    var object = JSONObject()
    object["x"] = number(box.x)
    object["y"] = number(box.y)
    object["width"] = number(box.width)
    object["height"] = number(box.height)
    return object
  }
}
