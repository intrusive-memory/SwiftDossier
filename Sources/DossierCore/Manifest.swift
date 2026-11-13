import Foundation

/// Which kind of bundle a manifest describes (§5.1, §16.1, DF-79).
public enum DossierType: String, Sendable, Equatable, CaseIterable {
  /// A character bundle: `dossierType` absent, `character`, or any value but `location`, which
  /// is reserved and read as `character`.
  case character
  /// A location bundle (§16): a place, with its description and plates.
  case location
}

/// A location bundle's `location` record (§16.3, DF-83), a view over its JSON. Every key is
/// optional, and unknown keys stay in ``json``.
public struct LocationRecord: Sendable, Equatable {
  /// One camera setup's recipe, keyed in ``LocationRecord/views`` by the plate variant it names.
  /// How a tool uses these is its own (§5.5).
  public struct View: Sendable, Equatable {
    /// The entry's JSON.
    public let json: JSONObject

    /// A view over existing JSON.
    public init(json: JSONObject) { self.json = json }

    /// The prompt the plate is made from.
    public var prompt: String? { json["prompt"]?.stringValue }
    /// What the view asks of a scene painted onto its plate.
    public var rule: String? { json["rule"]?.stringValue }
    /// The images the plate is painted from, in the tool's own notation.
    public var refs: [String] { json["refs"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    /// `true` for an outdoor view.
    public var exterior: Bool? { json["exterior"]?.boolValue }
    /// Overrides ``LocationRecord/theme`` for this view.
    public var theme: String? { json["theme"]?.stringValue }
  }

  /// The record's JSON.
  public let json: JSONObject

  /// A record over existing JSON.
  public init(json: JSONObject) { self.json = json }

  /// The location's name for people.
  public var name: String? { json["name"]?.stringValue }
  /// One line about the place.
  public var description: String? { json["description"]?.stringValue }
  /// The producing tool's name for the look the location shares with others.
  public var theme: String? { json["theme"]?.stringValue }
  /// The camera setups, in the order `manifest.json` has them (§16.6 step 3 relies on it), each
  /// with the plate variant it names. Entries that aren't objects are left out.
  public var views: [(variant: String, view: View)] {
    json["views"]?.objectValue?.entries.compactMap { entry in
      entry.value.objectValue.map { (entry.key, View(json: $0)) }
    } ?? []
  }
}

/// `manifest.json` (§5), version 1 or 2, as a view over its JSON.
///
/// The JSON is the only storage, so unknown keys and values of an unexpected type
/// survive a re-encode without being modelled (§5.1, §5.4, §6). A schema-invalid
/// manifest still decodes: telling it apart is the validator's job (`E-SCHEMA`), and
/// a missing or wrong-typed key reads as empty or `nil` here.
///
/// Setters are `package`: `DossierCore` holds no writers, and the `Dossier` target's
/// writers mutate this type and call ``encoded()``.
public struct Manifest: Sendable, Equatable {
  /// `generator` (§5.1).
  public struct Generator: Sendable, Equatable {
    /// The writing tool.
    public let name: String?
    /// Its version.
    public let version: String?

    /// A generator.
    package init(name: String?, version: String?) {
      self.name = name
      self.version = version
    }
  }

  /// `prompts` (§5.5), a view over its JSON.
  public struct Prompts: Sendable, Equatable {
    /// The object's JSON.
    public package(set) var json: JSONObject

    /// A view over existing JSON.
    public init(json: JSONObject) { self.json = json }

    /// Who the character is, visually.
    public package(set) var identity: String? {
      get { json["identity"]?.stringValue }
      set { json["identity"] = newValue.map(JSONValue.string) }
    }
    /// The working portrait prompt.
    public package(set) var portrait: String? {
      get { json["portrait"]?.stringValue }
      set { json["portrait"] = newValue.map(JSONValue.string) }
    }
    /// The noun prompts use for the character.
    public package(set) var subject: String? {
      get { json["subject"]?.stringValue }
      set { json["subject"] = newValue.map(JSONValue.string) }
    }
  }

  /// The whole manifest. Every property reads and writes through it.
  public package(set) var json: JSONObject

  /// Decodes a manifest.
  ///
  /// - Throws: ``DossierError/manifestNotJSON(_:)``, ``DossierError/manifestNotObject``, or
  ///   ``DossierError/unknownVersion(_:)`` for any `manifestVersion` that isn't the
  ///   integer 1 or 2.
  public init(data: Data) throws {
    guard let object = try JSONValue.parse(data).objectValue else {
      throw DossierError.manifestNotObject
    }
    // SPEC-GAP: §5.1, recon N7: a manifest with no `manifestVersion` has no code of its
    // own. It's read as an unknown version, the strictest of the available readings.
    guard case .number(let literal)? = object["manifestVersion"], literal == "1" || literal == "2"
    else {
      throw DossierError.unknownVersion(object["manifestVersion"]?.canonicalEncoded())
    }
    json = object
  }

  /// A new version 2 manifest with no files or assets. Its checksum is correct as made.
  package init(character: String, updatedAt: String) {
    json = JSONObject([
      ("manifestVersion", .integer(2)), ("character", .string(character)),
      ("updatedAt", .string(updatedAt)), ("files", .array([])), ("assets", .array([])),
    ])
    manifestChecksum = computedChecksum
  }

  /// §5's byte form: 2-space indentation, sorted keys, final newline, no `\/`.
  public func encoded() -> Data {
    JSONValue.object(json).prettyEncoded()
  }

  /// `manifestVersion`, 1 or 2.
  public var manifestVersion: Int { Int(json["manifestVersion"]?.intValue ?? 0) }

  /// The manifest's `character`, exactly as written. Empty when it isn't a string.
  public package(set) var character: String {
    get { json["character"]?.stringValue ?? "" }
    set { json["character"] = .string(newValue) }
  }
  /// Which kind of bundle this is (§16.1, DF-79): ``DossierType/location`` only when
  /// `dossierType` is the string `location`. Nothing else, such as the directory, decides it.
  public package(set) var dossierType: DossierType {
    get { json["dossierType"]?.stringValue == "location" ? .location : .character }
    set { json["dossierType"] = newValue == .location ? .string("location") : nil }
  }
  /// `dossierType` exactly as written, or `nil` when it's absent or not a string. A value other
  /// than `character` or `location` is reserved, and ``dossierType`` reads it as a character.
  public var dossierTypeText: String? { json["dossierType"]?.stringValue }
  /// How people name the character in prose, captions and prompts (§5.1, DF-88). A copy of the
  /// `CAST.md` member's `displayName`, which wins (``DossierBundle/displayName``). Display text,
  /// never a key. Not defined for a location (§16.3).
  public package(set) var displayName: String? {
    get { json["displayName"]?.stringValue }
    set { json["displayName"] = newValue.map(JSONValue.string) }
  }
  /// A location bundle's record (§16.3), or `nil` when there is none or it isn't an object.
  public var location: LocationRecord? { json["location"]?.objectValue.map(LocationRecord.init(json:)) }
  /// A copy of the `CAST.md` role. `CAST.md` wins (§8.3).
  public package(set) var role: String? {
    get { json["role"]?.stringValue }
    set { json["role"] = newValue.map(JSONValue.string) }
  }
  /// The last write. Empty when it isn't a string.
  public package(set) var updatedAt: String {
    get { json["updatedAt"]?.stringValue ?? "" }
    set { json["updatedAt"] = .string(newValue) }
  }
  /// The writing tool.
  public package(set) var generator: Generator? {
    get {
      guard let object = json["generator"]?.objectValue else { return nil }
      return Generator(name: object["name"]?.stringValue, version: object["version"]?.stringValue)
    }
    set {
      guard let newValue else {
        json["generator"] = nil
        return
      }
      var object = json["generator"]?.objectValue ?? JSONObject()
      object["name"] = newValue.name.map(JSONValue.string)
      object["version"] = newValue.version.map(JSONValue.string)
      json["generator"] = .object(object)
    }
  }
  /// The prompts images are built from.
  public package(set) var prompts: Prompts? {
    get { json["prompts"]?.objectValue.map(Prompts.init(json:)) }
    set { json["prompts"] = newValue.map { .object($0.json) } }
  }
  /// The integrity layer, in the manifest's order.
  public package(set) var files: [FileEntry] {
    get { json["files"]?.arrayValue?.compactMap { $0.objectValue.map(FileEntry.init(json:)) } ?? [] }
    set { json["files"] = .array(newValue.map { .object($0.json) }) }
  }
  /// The semantic layer, in the manifest's order.
  public package(set) var assets: [Asset] {
    get { json["assets"]?.arrayValue?.compactMap { $0.objectValue.map(Asset.init(json:)) } ?? [] }
    set { json["assets"] = .array(newValue.map { .object($0.json) }) }
  }
  /// The recorded checksum. Empty when it isn't a string.
  public package(set) var manifestChecksum: String {
    get { json["manifestChecksum"]?.stringValue ?? "" }
    set { json["manifestChecksum"] = .string(newValue) }
  }

  /// The checksum `files` gives, in this manifest version's form (§5.3, Appendix A).
  public var computedChecksum: String {
    let hashes = files.map(\.sha256)
    return manifestVersion == 1 ? Checksum.pathOrder(hashes) : Checksum.sorted(hashes)
  }
}
