import DossierCore
import Foundation
import ImageIO

/// §8.1's shape check.
enum ImageShape {
  /// The width and height a kind should be in proportion to. `nil` for a kind with no shape rule.
  static func target(of kind: AssetKind) -> (width: Int64, height: Int64)? {
    switch kind {
    case .portrait, .view: return (9, 16)
    case .face, .expression: return (1, 1)
    case .plate: return (16, 9)
    default: return nil
    }
  }

  /// Whether a size is outside §8.1's tolerance: |r − t| ÷ t over 0.01, in exact arithmetic.
  ///
  /// With r = w/h and t = a/b that is 100 × |w·b − a·h| > a·h.
  static func isOutsideTolerance(width: Int64, height: Int64, target: (width: Int64, height: Int64)) -> Bool {
    let denominator = target.width * height
    return 100 * abs(width * target.height - denominator) > denominator
  }

  /// The pixel size stored in an image file, or `nil` when it has none that can be read.
  static func dimensions(of url: URL) -> (width: Int64, height: Int64)? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
      (1...Int64(Int32.max)).contains(width), (1...Int64(Int32.max)).contains(height)
    else { return nil }
    return (width, height)
  }
}
