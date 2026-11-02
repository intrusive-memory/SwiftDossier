import CoreGraphics
import DossierCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Dossier

/// A project in a temporary directory, for a render. Invented characters only.
struct RenderProject {
  static let character = "THE TINKER"
  let root: URL
  var cast: URL { root.appendingPathComponent("CAST.md") }
  var bundleURL: URL { root.appendingPathComponent("characters/\(Self.character).dossier", isDirectory: true) }
  var pageURL: URL { bundleURL.appendingPathComponent("\(Self.character)-dossier.html") }
  var manifestURL: URL { bundleURL.appendingPathComponent("manifest.json") }

  static func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("RenderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
  }

  /// A bundle holding only the given `CHARACTER.md`, selected.
  init(description: String, role: String = "lead", extraMemberLines: String = "") throws {
    root = try Self.temporaryRoot()
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("characters"), withIntermediateDirectories: true)
    try Data(
      """
      ---
      type: cast
      schemaVersion: 1
      cast:
      - character: \(Self.character)
        role: \(role)
        voicePrompt: A low voice.
      \(extraMemberLines.isEmpty ? "  voices: {}" : extraMemberLines)
        manifest: characters/\(Self.character).dossier/manifest.json
      ---
      """.utf8
    ).write(to: cast)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    try Manifest(character: Self.character, updatedAt: "2026-01-01T00:00:00Z").encoded().write(to: manifestURL)
    let file = root.appendingPathComponent("CHARACTER.md")
    try Data(description.utf8).write(to: file)
    var bundle = try open()
    try bundle.add(
      file, kind: .description,
      options: AddOptions(
        provenance: JSONObject([("provider", .string("manual"))]), createdAt: Self.made, select: true))
    try FileManager.default.removeItem(at: file)
  }

  static let made = Date(timeIntervalSince1970: 1_790_000_000)

  func open() throws -> DossierBundle {
    let loaded = try Cast.load(cast)
    let member = try #require(loaded.members.first)
    return try #require(try loaded.openBundle(for: member))
  }

  /// Adds a synthetic image, selected.
  @discardableResult
  func addImage(
    _ kind: AssetKind, variant: String? = nil, width: Int = 18, height: Int = 32, shade: UInt8 = 40,
    provenance: JSONObject = JSONObject([("provider", .string("manual"))]), select: Bool = true,
    derivedFrom: [DerivedInput]? = nil
  ) throws -> Asset {
    let file = root.appendingPathComponent("image-\(UUID().uuidString).png")
    try RenderImages.png(width: width, height: height, shade: shade).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    var bundle = try open()
    return try bundle.add(
      file, kind: kind,
      options: AddOptions(variant: variant, provenance: provenance, derivedFrom: derivedFrom, createdAt: Self.made, select: select))
  }

  func page() throws -> String { String(decoding: try Data(contentsOf: pageURL), as: UTF8.self) }
  func manifest() throws -> Manifest { try Manifest(data: try Data(contentsOf: manifestURL)) }

  /// Everything in the bundle's directory by name, with its bytes.
  func tree() throws -> [String: Data] {
    try RenderTree.files(under: bundleURL)
  }
}

/// `---` front matter and a body, for a project's description.
func synthetic(frontMatter: String = "", body: String) -> String {
  "---\ntype: character\ncharacter: \(RenderProject.character)\n\(frontMatter)---\n\(body)"
}

enum RenderTree {
  /// Every file under a directory, hidden ones too, with its bytes.
  static func files(under root: URL) throws -> [String: Data] {
    let base = root.resolvingSymlinksInPath().path + "/"
    var result: [String: Data] = [:]
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = walker?.nextObject() as? URL {
      if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        result[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = try Data(contentsOf: url)
      }
    }
    return result
  }
}

enum RenderImages {
  static func png(width: Int, height: Int, shade: UInt8) throws -> Data {
    try encoded(width: width, height: height, type: UTType.png) { context in
      context.setFillColor(red: CGFloat(shade) / 255, green: 0.2, blue: 0.3, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
  }

  static func encoded(width: Int, height: Int, type: UTType, draw: (CGContext) -> Void) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    draw(context)
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
  }
}

/// A rendered page, read back.
struct PageReader {
  let text: String

  /// The page's markup: no `<style>` or `<script>` contents.
  var markup: String {
    var out = ""
    var rest = Substring(text)
    while let open = rest.range(of: "<(style|script)[ >]", options: .regularExpression) {
      out += rest[..<open.lowerBound]
      let isStyle = rest[open].hasPrefix("<style")
      guard let close = rest[open.upperBound...].range(of: isStyle ? "</style>" : "</script>") else { return out }
      rest = rest[close.upperBound...]
    }
    out += rest
    return out
  }

  /// Every `name="value"` in the markup, in order.
  func attributes(_ name: String) -> [String] {
    Self.matches(of: " \(name)=\"([^\"]*)\"", in: markup)
  }

  static func matches(of pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let whole = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: whole).compactMap { match in
      Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
  }

  /// The `{{value}}` of a field: what's between its element's opening tag and its end.
  func element(key: String) throws -> String {
    let source = markup
    let opening = try #require(source.range(of: " id=\"\(key)\" data-key=\"\(key)\""), "no \(key)")
    let end = try #require(source[opening.upperBound...].range(of: "</dossier-"), "\(key) doesn't end")
    return String(source[opening.upperBound..<end.lowerBound])
  }

  func state(key: String) throws -> String? {
    let found = PageReader.matches(of: " id=\"\(key)\" data-key=\"\(key)\" data-kind=\"[^\"]*\" data-state=\"([^\"]*)\"", in: markup)
    return found.first
  }

  /// The record's text, as the page holds it.
  var recordText: String? {
    guard let open = text.range(of: "<script type=\"application/json\" id=\"character-record\">"),
      let close = text[open.upperBound...].range(of: "</script>")
    else { return nil }
    return String(text[open.upperBound..<close.lowerBound])
  }

  func record() throws -> JSONObject {
    let text = try #require(recordText)
    return try #require(try JSONValue.parse(Data(text.utf8)).objectValue)
  }

  /// The image data in an element's markup.
  func images(inElement key: String) throws -> [Data] {
    PageReader.matches(of: "src=\"data:image/jpeg;base64,([^\"]*)\"", in: try element(key: key))
      .compactMap { Data(base64Encoded: $0) }
  }
}

/// A JPEG's segments, for what a page copy holds.
enum JPEGSegments {
  /// The markers before the scan, and the pixel size from the frame header.
  static func read(_ jpeg: Data) -> (markers: [UInt8], width: Int, height: Int)? {
    let bytes = Array(jpeg)
    guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
    var markers: [UInt8] = []
    var size: (Int, Int)?
    var index = 2
    while index + 4 <= bytes.count, bytes[index] == 0xFF {
      let marker = bytes[index + 1]
      markers.append(marker)
      if marker == 0xDA { break }
      if (0xC0...0xC2).contains(marker) {
        size = (Int(bytes[index + 7]) << 8 | Int(bytes[index + 8]), Int(bytes[index + 5]) << 8 | Int(bytes[index + 6]))
      }
      index += 2 + (Int(bytes[index + 2]) << 8 | Int(bytes[index + 3]))
    }
    return size.map { (markers, $0.0, $0.1) }
  }
}

extension JSONObject {
  init(_ pairs: KeyValuePairs<String, JSONValue>) {
    self.init()
    for (key, value) in pairs { self[key] = value }
  }
}
