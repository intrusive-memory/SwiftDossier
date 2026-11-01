import Foundation

/// Removes a PNG's metadata (§1) without decoding it (§4). The one routine `add` and the face
/// crop share.
enum PNGMetadata {
  private static let chunkTypes: Set<String> = ["tEXt", "zTXt", "iTXt", "eXIf", "tIME"]

  /// The file without its metadata chunks, with every other chunk's bytes as they were, in order.
  ///
  /// - Returns: `nil` when the file isn't well formed: it has no PNG signature, a chunk runs past
  ///   the end, `IHDR` isn't first, there's no `IEND`, or anything follows it. Chunk CRCs aren't
  ///   checked.
  static func stripped(_ png: Data) -> Data? {
    let bytes = [UInt8](png)
    guard VinetasPNG.isPNG(png) else { return nil }
    var result = Array(bytes[0..<8])
    var offset = 8
    while offset + 12 <= bytes.count {
      let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
      let end = offset + 12 + length
      guard length <= Int(Int32.max), end <= bytes.count else { return nil }
      let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
      if offset == 8, type != "IHDR" { return nil }
      if !chunkTypes.contains(type) { result += bytes[offset..<end] }
      offset = end
      if type == "IEND" { return offset == bytes.count ? Data(result) : nil }
    }
    return nil
  }
}
