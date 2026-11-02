import DossierCore
import Foundation

/// The page template this package carries (§11), copied byte for byte from the pinned
/// dossier-format revision, with the version and hash published beside it.
///
/// The hash is `template/README.md` rule 1's. It's read from `VERSION.json`, not computed;
/// the tests compute it over these files.
public enum DossierTemplate {
  private struct Published: Decodable, Sendable {
    let version: String
    let sha256: String
  }

  private static let published: Result<Published, DossierError> = {
    guard let data = try? data(at: "VERSION.json"),
      let published = try? JSONDecoder().decode(Published.self, from: data)
    else { return .failure(.resourceUnreadable("template/VERSION.json")) }
    return .success(published)
  }()

  /// The version the template is published with.
  ///
  /// - Throws: ``DossierError/resourceUnreadable(_:)`` when `VERSION.json` can't be read.
  public static var version: String { get throws { try published.get().version } }

  /// The hash the template is published with.
  ///
  /// - Throws: ``DossierError/resourceUnreadable(_:)`` when `VERSION.json` can't be read.
  public static var sha256: String { get throws { try published.get().sha256 } }

  /// The template's identity, for `validate(template:)` and `stale(template:)`.
  ///
  /// - Throws: ``DossierError/resourceUnreadable(_:)`` when `VERSION.json` can't be read.
  public static var current: PageTemplate {
    get throws { PageTemplate(version: try version, sha256: try sha256) }
  }

  /// The bundled `template/` directory: the files rule 1 hashes, and `VERSION.json`.
  ///
  /// - Throws: ``DossierError/resourceUnreadable(_:)`` when the bundle has no resource directory.
  public static var directory: URL {
    get throws {
      guard let root = DossierResources.bundle.resourceURL else {
        throw DossierError.resourceUnreadable("template/")
      }
      return root.appendingPathComponent("template", isDirectory: true)
    }
  }

  /// A template file's bytes.
  ///
  /// - Parameter path: The `/`-separated path under `template/`, such as `skeleton.html` or
  ///   `fonts/ibm-plex-mono/OFL.txt`.
  /// - Throws: ``DossierError/resourceUnreadable(_:)`` when there's no such file.
  public static func data(at path: String) throws -> Data {
    guard let data = try? Data(contentsOf: try directory.appendingPathComponent(path)) else {
      throw DossierError.resourceUnreadable("template/\(path)")
    }
    return data
  }
}
