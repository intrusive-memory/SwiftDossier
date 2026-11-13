import Foundation
import Yams

/// Why a project's locations can't be read (§16.2). Both are `E-CAST` (§14).
public enum LocationsError: Error, Equatable, Sendable, LocalizedError {
  /// `PROJECT.md` can't be read for its `locations` key: it isn't UTF-8, its front matter doesn't
  /// parse as a YAML mapping, or `locations` isn't a valid index path (§16.2 case 2).
  case projectUnreadable(String)
  /// The locations index can't be read: it isn't UTF-8, its front matter doesn't parse, its
  /// `type` isn't `locations`, it has no `locations` list, or an entry has no `location`
  /// (§16.2 case 4).
  case indexUnreadable(String)

  /// A description of the failure, for people.
  public var errorDescription: String? {
    switch self {
    case .projectUnreadable(let detail): return "PROJECT.md can't be read for its locations: \(detail)"
    case .indexUnreadable(let detail): return "The locations index can't be read: \(detail)"
    }
  }
}

/// A project directory, as the format reads it for locations (§16.2): the directory holding
/// `CAST.md`, or, with no `CAST.md`, the one a tool opens as the project.
///
/// The format reads two of `PROJECT.md`'s front-matter keys, `locations` and `title`, and writes
/// neither; the file belongs to SwiftProyecto. Character discovery never reads it (§3).
public struct DossierProject: Sendable, Equatable {
  /// The `PROJECT.md` file name.
  public static let projectFileName = "PROJECT.md"

  /// The project directory.
  public let directory: URL

  /// A project at a directory. Nothing is read.
  public init(directory: URL) {
    self.directory = directory
  }

  /// `<directory>/PROJECT.md`.
  public var projectFileURL: URL { directory.appendingPathComponent(Self.projectFileName) }

  /// `PROJECT.md`'s `title` when it is a non-empty string, or `nil`: no file, no front matter, no
  /// key, or a `PROJECT.md` that can't be read. Only the LOCATIONS page shows it (§16.6).
  public var title: String? {
    guard let mapping = try? frontMatter(), let node = mapping["title"], let title = yamlString(of: node),
      !title.isEmpty
    else { return nil }
    return title
  }

  /// Finds the project's locations (§16.2): one of its five outcomes. Reads `PROJECT.md` and, when
  /// it names one, the index. No directory is listed.
  public func discoverLocations() -> LocationsDiscovery {
    let mapping: [String: Node]
    do {
      guard let found = try frontMatter() else { return .none }
      mapping = found
    } catch let error as LocationsError {
      return .projectUnreadable(error)
    } catch {
      return .projectUnreadable(.projectUnreadable(error.localizedDescription))
    }
    guard let node = mapping["locations"] else { return .none }
    guard let raw = yamlString(of: node) else {
      return .projectUnreadable(.projectUnreadable("locations isn't a string"))
    }
    guard let segments = Self.indexSegments(raw) else {
      return .projectUnreadable(.projectUnreadable("locations isn't a valid index path: \(raw)"))
    }
    let url = segments.reduce(directory) { $0.appendingPathComponent($1) }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      return .indexMissing(path: raw)
    }
    do {
      return .index(try LocationsIndex.load(url))
    } catch let error as LocationsError {
      return .indexUnreadable(url: url, error: error)
    } catch {
      return .indexUnreadable(url: url, error: .indexUnreadable(error.localizedDescription))
    }
  }

  /// A valid index path's segments (§16.2 case 2): a non-empty string that doesn't start with `/`
  /// and that, resolved as §3 resolves a pointer, neither ends empty nor has a `..` left over.
  /// `nil` otherwise.
  public static func indexSegments(_ path: String) -> [String]? {
    guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
    let segments = ManifestPointer(path).segments
    guard !segments.isEmpty, !segments.contains("..") else { return nil }
    return segments
  }

  /// `PROJECT.md`'s front matter as a mapping by key: `nil` when there is no file or no front
  /// matter, and empty for an empty block. Of two equal keys, the last is kept.
  ///
  /// SPEC-GAP: §16.2: an empty front-matter block isn't named. It's read as a mapping with no
  /// keys, as a YAML document holding nothing has none, so the project has no locations.
  ///
  /// - Throws: ``LocationsError/projectUnreadable(_:)`` for a file that can't be read, isn't UTF-8,
  ///   or whose front matter doesn't parse as a YAML mapping.
  private func frontMatter() throws -> [String: Node]? {
    let url = projectFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
    guard !isDirectory.boolValue, let data = try? Data(contentsOf: url) else {
      throw LocationsError.projectUnreadable("the file can't be read")
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw LocationsError.projectUnreadable("it isn't UTF-8")
    }
    guard let yaml = FrontMatter.split(text)?.yaml else { return nil }
    let root: Node?
    do {
      root = try Yams.compose(yaml: yaml)
    } catch {
      throw LocationsError.projectUnreadable("its front matter isn't YAML")
    }
    guard let root else { return [:] }
    guard case .mapping(let mapping) = root else {
      throw LocationsError.projectUnreadable("its front matter isn't a mapping")
    }
    var keyed: [String: Node] = [:]
    for (key, value) in mapping { keyed[key.string ?? ""] = value }
    return keyed
  }
}

/// A scalar's text when YAML reads it as a string (a quoted scalar, or a plain one that isn't a
/// null, a boolean or a number), or `nil`.
func yamlString(of node: Node) -> String? {
  guard case .scalar(let scalar) = node, node.tag.description == Tag.Name.str.rawValue else { return nil }
  return scalar.string
}

/// What finding a project's locations gives (§16.2's five outcomes).
public enum LocationsDiscovery: Sendable {
  /// No `PROJECT.md`, no front matter, or no `locations` key: the project has no locations, and
  /// nothing is read, listed or reported (case 1).
  case none
  /// `PROJECT.md` can't be read for its key, `E-CAST`. The locations are unknown (case 2).
  case projectUnreadable(LocationsError)
  /// The path reaches no file, or a directory, `W-POINTER`. The project has no locations (case 3).
  case indexMissing(path: String)
  /// The index can't be read, `E-CAST`. No location is checked and nothing is listed (case 4).
  case indexUnreadable(url: URL, error: LocationsError)
  /// The project's locations index (case 5).
  case index(LocationsIndex)

  /// The index, in case 5.
  public var index: LocationsIndex? {
    if case .index(let index) = self { return index }
    return nil
  }
}

/// A project's locations index, `LOCATIONS.md` by convention (§16.2): where discovery of location
/// bundles goes after `PROJECT.md`.
public struct LocationsIndex: Sendable {
  /// One entry of the `locations` list: one location.
  public struct Entry: Sendable {
    /// The location's name, canonical by §2, exactly as written.
    public let location: String
    /// The entry's `manifest:`, relative to the index's directory. `nil` means no bundle yet,
    /// which is valid.
    public let pointer: ManifestPointer?
    /// The whole entry, as §7's general YAML-to-JSON reading gives it. Its other keys are copies
    /// for people, and the manifest is the authority.
    public let fields: JSONObject
  }

  /// The index file.
  public let url: URL
  /// The directory `manifest:` paths are relative to, and where `locations/` is looked for.
  public var directory: URL { url.deletingLastPathComponent() }
  /// The entries, in document order.
  public let entries: [Entry]

  /// Reads a locations index (§16.2 case 4).
  ///
  /// SPEC-GAP: §16.2: an entry whose `manifest` isn't a string isn't named among the faults. It
  /// can't be resolved as a pointer, so it's read as one the index can't hold, `E-CAST`.
  ///
  /// - Throws: ``LocationsError/indexUnreadable(_:)`` for every fault §16.2 case 4 names, and
  ///   when the file can't be read at all.
  public static func load(_ url: URL) throws -> LocationsIndex {
    func refuse(_ detail: String) -> LocationsError { .indexUnreadable(detail) }
    guard let data = try? Data(contentsOf: url) else { throw refuse("the file can't be read") }
    guard let text = String(data: data, encoding: .utf8) else { throw refuse("it isn't UTF-8") }
    guard let yaml = FrontMatter.split(text)?.yaml else { throw refuse("it has no front matter") }
    let root: Node?
    do {
      root = try Yams.compose(yaml: yaml)
    } catch {
      throw refuse("its front matter isn't YAML")
    }
    guard case .mapping(let mapping)? = root else { throw refuse("its front matter isn't a mapping") }
    guard let type = mapping["type"].flatMap(yamlString(of:)), type == "locations" else {
      throw refuse("its type isn't locations")
    }
    guard case .sequence(let nodes)? = mapping["locations"] else { throw refuse("it has no locations list") }
    var entries: [Entry] = []
    for (index, node) in nodes.enumerated() {
      guard case .mapping(let entry) = node else { throw refuse("entry \(index + 1) isn't a mapping") }
      guard let location = entry["location"].flatMap(yamlString(of:)) else {
        throw refuse("entry \(index + 1) has no location")
      }
      var pointer: ManifestPointer?
      if let manifest = entry["manifest"] {
        guard let value = yamlString(of: manifest) else { throw refuse("\(location): manifest isn't a string") }
        pointer = ManifestPointer(value)
      }
      let fields = MemberHash.generalValue(node).objectValue ?? JSONObject()
      entries.append(Entry(location: location, pointer: pointer, fields: fields))
    }
    return LocationsIndex(url: url, entries: entries)
  }

  /// The file an entry's pointer leads to, or `nil` when it has no `manifest:`. The disk isn't read.
  public func manifestURL(of entry: Entry) -> URL? {
    guard let pointer = entry.pointer else { return nil }
    return pointer.segments.reduce(directory) { $0.appendingPathComponent($1) }
  }

  /// Opens the bundle an entry points at, or returns `nil` when it has no `manifest:`.
  ///
  /// - Throws: ``DossierError/pointerNotManifest(_:)`` when the pointer doesn't name a
  ///   `manifest.json`, and whatever ``DossierBundle/open(at:member:)`` throws. The bundle's type
  ///   isn't checked: a character bundle here is `E-TYPE-MISMATCH`, which `validate` reports.
  public func openBundle(for entry: Entry) throws -> DossierBundle? {
    guard let pointer = entry.pointer, let manifest = manifestURL(of: entry) else { return nil }
    guard pointer.namesManifest else { throw DossierError.pointerNotManifest(pointer.raw) }
    return try DossierBundle.open(at: manifest.deletingLastPathComponent())
  }
}
