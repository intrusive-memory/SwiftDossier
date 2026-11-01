import DossierCore
import Foundation
import Testing

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

/// The pinned revision's fixtures. A missing `.dossier-format/` fails the test rather than
/// skipping it (`make test` fetches them).
enum Fixtures {
  struct Entry: Decodable, Sendable {
    let path: String
    let bundle: String
    let verdict: String
    let codes: [String]
    let mayAlso: [String]
    let complete: Bool?
    let missingRequired: [String]?
  }

  struct Conformance: Decodable, Sendable {
    let templateVersion: String
    let templateSha256: String
    let fixtures: [Entry]
  }

  static let root = SpecTree.examples

  static func project(_ path: String) -> URL { root.appendingPathComponent(path) }

  static func conformance() throws -> Conformance {
    let data = try Data(contentsOf: root.appendingPathComponent("conformance.json"))
    return try JSONDecoder().decode(Conformance.self, from: data)
  }

  /// The project's cast, and the member pointing at the fixture's bundle.
  static func member(of entry: Entry) -> (cast: Cast, member: Cast.Member)? {
    let castURL = project(entry.path).appendingPathComponent("CAST.md")
    guard let cast = try? Cast.load(castURL) else { return nil }
    let manifest = entry.bundle + "/manifest.json"
    guard let member = cast.members.first(where: { $0.pointer?.points(at: manifest) ?? false }) else {
      return nil
    }
    return (cast, member)
  }

  static func bundleURL(of entry: Entry) -> URL {
    project(entry.path).appendingPathComponent(entry.bundle)
  }
}

/// Hex of a string's UTF-8 bytes, so a failure message shows an NFC/NFD difference.
func bytes(_ text: String) -> String {
  text.utf8.map { String(format: "%02x", $0) }.joined()
}
