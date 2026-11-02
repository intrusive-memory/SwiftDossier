import CoreGraphics
import DossierCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `template/page-copies.json` (DF-43): the page copies' format, quality and sizes. Nothing here
/// is restated in Swift (SD-2).
struct PageCopySettings: Sendable {
  struct Size: Sendable, Equatable {
    let width: Int
    let height: Int
  }

  /// The JPEG quality, from 0 to 1.
  let quality: Double
  private let sizes: [String: Size]

  /// The size of a kind's copy, or `nil` for a kind that has none.
  func size(ofKind kind: String) -> Size? { sizes[kind] }

  /// - Throws: ``DossierCore/DossierError/resourceUnreadable(_:)`` when the file isn't this shape,
  ///   or asks for a format this renderer can't write.
  init(data: Data) throws {
    let name = "template/page-copies.json"
    guard let root = (try? JSONValue.parse(data))?.objectValue, root["format"]?.stringValue == "jpeg",
      let quality = root["quality"]?.doubleValue, (0...100).contains(quality),
      let sizes = root["sizes"]?.objectValue
    else { throw DossierError.resourceUnreadable(name) }
    self.quality = quality / 100
    var read: [String: Size] = [:]
    for key in sizes.keys {
      guard let size = sizes[key]?.objectValue, let width = size["width"]?.intValue, let height = size["height"]?.intValue,
        width > 0, height > 0
      else { throw DossierError.resourceUnreadable(name) }
      read[key] = Size(width: Int(width), height: Int(height))
    }
    self.sizes = read
  }
}

/// A page copy: rule 5's scale-to-cover and centre crop, as JPEG at fixed settings (§11, DF-43).
/// The same image and settings give the same bytes on one OS and ImageIO; across them only the
/// pixels' size is promised (DF-45).
enum PageCopy {
  /// The copy, or `nil` when the bytes can't be read as an image.
  ///
  /// The stored pixels are used, as the face crop uses them: an EXIF orientation isn't applied.
  ///
  /// SPEC-GAP: rule 5: what's behind a transparent image isn't said, and JPEG has no alpha. It's
  /// drawn on white, a fixed choice, so the same input still gives the same bytes.
  static func jpeg(of data: Data, size: PageCopySettings.Size, quality: Double) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
      image.width > 0, image.height > 0,
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }

    let width = Double(size.width)
    let height = Double(size.height)
    let scale = max(width / Double(image.width), height / Double(image.height))
    let drawn = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(
      image, in: CGRect(x: (width - drawn.width) / 2, y: (height - drawn.height) / 2, width: drawn.width, height: drawn.height))
    guard let copy = context.makeImage() else { return nil }

    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    CGImageDestinationAddImage(destination, copy, options)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return strippingMetadata(from: output as Data)
  }

  /// The JPEG without its comments and application segments, which is everything that can carry
  /// metadata: ImageIO writes a colour profile, and could write more. Only `APP0` stays when it's
  /// JFIF's, and the file reads as sRGB without the profile. `nil` for anything malformed.
  static func strippingMetadata(from jpeg: Data) -> Data? {
    let bytes = Array(jpeg)
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
    var kept: [UInt8] = [0xFF, 0xD8]
    kept.reserveCapacity(bytes.count)
    var index = 2
    while index + 4 <= bytes.count {
      guard bytes[index] == 0xFF else { return nil }
      let marker = bytes[index + 1]
      // Start of scan: the rest is entropy-coded data and the end marker.
      if marker == 0xDA {
        kept.append(contentsOf: bytes[index...])
        return Data(kept)
      }
      let end = index + 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
      guard end <= bytes.count else { return nil }
      let isMetadata = (0xE0...0xEF).contains(marker) || marker == 0xFE
      let isJFIF = marker == 0xE0 && bytes[(index + 4)..<end].starts(with: Array("JFIF".utf8))
      if !isMetadata || isJFIF { kept.append(contentsOf: bytes[index..<end]) }
      index = end
    }
    return nil
  }

  /// Rule 6: a sample's `data:` type, by its extension.
  ///
  /// SPEC-GAP: rule 6: only `.m4a` is named. §5.6's samples are all `.m4a`; a producer's other
  /// file (SD-6 keeps its name) gets the system's type for its extension, and with none
  /// `application/octet-stream`.
  static func audioMIMEType(ofPath path: String) -> String {
    let fileExtension = (path as NSString).pathExtension.lowercased()
    if fileExtension == "m4a" { return "audio/mp4" }
    return UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
  }
}
