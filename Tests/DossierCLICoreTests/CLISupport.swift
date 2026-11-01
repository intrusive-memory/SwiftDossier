import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DossierCLICore

/// The dossier-format tree the tests read: `.dossier-format/` (the pinned tag, fetched by
/// `make fixtures`), or the directory in DOSSIER_SPEC_DIR when `make test SPEC_DIR=<path>` is used.
enum SpecTree {
  static let override: URL? = {
    guard let path = ProcessInfo.processInfo.environment["DOSSIER_SPEC_DIR"], !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }()
  static var isOverridden: Bool { override != nil }
  static let root: URL = override ?? URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".dossier-format")
  static let examples = root.appendingPathComponent("examples")

  /// An independent walk: every directory under examples/ that holds a CAST.md, relative to examples/.
  static func fixtureDirectories() -> [String] {
    let base = examples.resolvingSymlinksInPath().path
    guard let walker = FileManager.default.enumerator(atPath: base) else { return [] }
    var found: [String] = []
    for case let relative as String in walker where relative.hasSuffix("/CAST.md") {
      found.append(String(relative.dropLast("/CAST.md".count)))
    }
    return found.sorted()
  }
}

/// A sink that keeps both channels, and can run a hook on each write.
final class BufferSink: OutputSink, @unchecked Sendable {
  private let lock = NSLock()
  private var out = ""
  private var err = ""
  var onError: (@Sendable (String) -> Void)?

  func writeOutput(_ text: String) { lock.withLock { out += text } }
  func writeError(_ text: String) {
    lock.withLock { err += text }
    onError?(text)
  }
  var stdout: String { lock.withLock { out } }
  var stderr: String { lock.withLock { err } }
}

struct Ran {
  let status: Int32
  let stdout: String
  let stderr: String

  /// Standard output as the one JSON object it must be.
  func object() throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(stdout.utf8))
    return try #require(value as? [String: Any])
  }
}

@discardableResult
func dossier(_ arguments: [String], sink: BufferSink = BufferSink()) -> Ran {
  let status = DossierCLI.run(arguments, sink: sink)
  return Ran(status: status, stdout: sink.stdout, stderr: sink.stderr)
}

/// A project in a temporary directory. Invented characters only.
struct TempProject {
  let root: URL
  var cast: URL { root.appendingPathComponent("CAST.md") }
  var characters: URL { root.appendingPathComponent("characters", isDirectory: true) }

  init(castText: String? = nil) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("CLITests-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: characters, withIntermediateDirectories: true)
    if let castText { try Data(castText.utf8).write(to: cast) }
  }

  /// A copy of a pinned fixture project.
  init(copyOf fixture: String) throws {
    try self.init()
    try FileManager.default.removeItem(at: root)
    let source = FixturePaths.root.appendingPathComponent(fixture)
    try FileManager.default.copyItem(at: source, to: root)
  }

  func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }
  func castBytes() throws -> Data { try Data(contentsOf: cast) }
}

enum FixturePaths {
  static let root = SpecTree.examples
}

func syntheticPNG(width: Int = 18, height: Int = 32, shade: UInt8 = 40) throws -> Data {
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

func writePNG(named name: String, in directory: URL, shade: UInt8 = 40) throws -> URL {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent(name)
  try syntheticPNG(shade: shade).write(to: url)
  return url
}

let plainCast = """
  ---
  type: cast
  schemaVersion: 1
  cast:
  - character: THE LAMPLIGHTER
    role: lead
  ---
  """ + "\n"

/// A value a `@Sendable` hook can set.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  func set(_ value: Value) { lock.withLock { stored = value } }
  var value: Value { lock.withLock { stored } }
}

func sha256(of path: String) throws -> String {
  let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
  return digest.map { String(format: "%02x", $0) }.joined()
}
