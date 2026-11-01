import Foundation

/// What an asset is (§8.1), including the retired version 1 kinds (§8.1, Appendix A).
public enum AssetKind: Hashable, Sendable {
  /// `CHARACTER.md`.
  case description
  /// The anchor image.
  case portrait
  /// The square face crop.
  case face
  /// A front, profile or back view.
  case view
  /// A square expression.
  case expression
  /// The `.vox` voice identity.
  case vox
  /// A rendered voice sample.
  case voiceSample
  /// The HTML page.
  case dossier
  /// A real photo the character is based on.
  case sourcePhoto
  /// A character LoRA.
  case lora
  /// A training image.
  case training
  /// A reference for a background character.
  case crowdRef
  /// Retired: a view, in version 1.
  case turnaround
  /// Retired: the face, in version 1.
  case faceSheet
  /// Retired: an expression, in version 1.
  case expressions
  /// Retired, with no version 2 kind.
  case wardrobe
  /// Retired, with no version 2 kind.
  case palette
  /// Any other string a manifest holds.
  case unknown(String)

  /// The kind a manifest's string names.
  public init(rawValue: String) {
    switch rawValue {
    case "description": self = .description
    case "portrait": self = .portrait
    case "face": self = .face
    case "view": self = .view
    case "expression": self = .expression
    case "vox": self = .vox
    case "voiceSample": self = .voiceSample
    case "dossier": self = .dossier
    case "sourcePhoto": self = .sourcePhoto
    case "lora": self = .lora
    case "training": self = .training
    case "crowdRef": self = .crowdRef
    case "turnaround": self = .turnaround
    case "faceSheet": self = .faceSheet
    case "expressions": self = .expressions
    case "wardrobe": self = .wardrobe
    case "palette": self = .palette
    default: self = .unknown(rawValue)
    }
  }

  /// The string a manifest uses for this kind.
  public var rawValue: String {
    switch self {
    case .description: return "description"
    case .portrait: return "portrait"
    case .face: return "face"
    case .view: return "view"
    case .expression: return "expression"
    case .vox: return "vox"
    case .voiceSample: return "voiceSample"
    case .dossier: return "dossier"
    case .sourcePhoto: return "sourcePhoto"
    case .lora: return "lora"
    case .training: return "training"
    case .crowdRef: return "crowdRef"
    case .turnaround: return "turnaround"
    case .faceSheet: return "faceSheet"
    case .expressions: return "expressions"
    case .wardrobe: return "wardrobe"
    case .palette: return "palette"
    case .unknown(let value): return value
    }
  }

  /// Whether a version 2 writer must not produce this kind (§8.1).
  public var isRetired: Bool {
    switch self {
    case .turnaround, .faceSheet, .expressions, .wardrobe, .palette: return true
    default: return false
    }
  }

  /// Whether files of this kind are images, the kinds §6's "images" keys apply to (§8.1).
  public var isImage: Bool {
    switch self {
    case .portrait, .face, .view, .expression, .sourcePhoto, .training, .crowdRef: return true
    default: return false
    }
  }
}

/// An asset's status (§5.4).
public enum AssetStatus: Hashable, Sendable {
  /// The one in use for its kind and variant.
  case selected
  /// Kept, not in use.
  case candidate
  /// Kept, and marked as not to be used.
  case rejected
  /// Any other string a manifest holds.
  case unknown(String)

  /// The status a manifest's string names.
  public init(rawValue: String) {
    switch rawValue {
    case "selected": self = .selected
    case "candidate": self = .candidate
    case "rejected": self = .rejected
    default: self = .unknown(rawValue)
    }
  }

  /// The string a manifest uses for this status.
  public var rawValue: String {
    switch self {
    case .selected: return "selected"
    case .candidate: return "candidate"
    case .rejected: return "rejected"
    case .unknown(let value): return value
    }
  }
}

/// One `files` entry (§5.2), a view over its JSON.
public struct FileEntry: Sendable, Equatable {
  /// The entry's JSON. Everything else on this type reads and writes through it.
  public package(set) var json: JSONObject

  /// An entry over existing JSON.
  public init(json: JSONObject) { self.json = json }

  /// A new entry, in the shape §5.2 requires.
  package init(path: String, sha256: String, sizeBytes: Int64) {
    json = JSONObject([
      ("path", .string(path)), ("sha256", .string(sha256)), ("sizeBytes", .integer(sizeBytes)),
    ])
  }

  /// The bundle path. Empty when the manifest doesn't give a string.
  public var path: String { json["path"]?.stringValue ?? "" }
  /// The file's recorded hash. Empty when the manifest doesn't give a string.
  public var sha256: String { json["sha256"]?.stringValue ?? "" }
  /// The file's recorded size, when the manifest gives an integer.
  public var sizeBytes: Int64? { json["sizeBytes"]?.intValue }
}

/// One `derivedFrom` input record (§7), a view over its JSON.
public struct DerivedInput: Sendable, Equatable {
  /// The record's JSON.
  public package(set) var json: JSONObject

  /// A record over existing JSON.
  public init(json: JSONObject) { self.json = json }

  /// A new record. `path` is for bundle inputs and `version` for the template (§7).
  package init(role: String, sha256: String, path: String? = nil, version: String? = nil) {
    json = JSONObject([("role", .string(role)), ("sha256", .string(sha256))])
    if let path { json["path"] = .string(path) }
    if let version { json["version"] = .string(version) }
  }

  /// `portrait`, `face`, `vox`, `description`, `castMember`, `bundle` or `template`.
  public var role: String { json["role"]?.stringValue ?? "" }
  /// The input's hash when the asset was made.
  public var sha256: String { json["sha256"]?.stringValue ?? "" }
  /// The bundle path, on an asset input.
  public var path: String? { json["path"]?.stringValue }
  /// The template version, on a template input.
  public var version: String? { json["version"]?.stringValue }
}

/// One reference image sent to an engine (§6), a view over its JSON.
public struct ProvenanceReference: Sendable, Equatable {
  /// The record's JSON.
  public package(set) var json: JSONObject

  /// A record over existing JSON.
  public init(json: JSONObject) { self.json = json }

  /// The bytes sent.
  public var sha256: String? { json["sha256"]?.stringValue }
  /// The bundle path of the asset with that hash at the time of writing.
  public var path: String? { json["path"]?.stringValue }
  /// Why it was sent.
  public var role: String? { json["role"]?.stringValue }
}

/// How a file was made (§6), a view over its JSON. Unknown keys stay in ``json``.
public struct Provenance: Sendable, Equatable {
  /// The program actually run (§6).
  public struct Tool: Sendable, Equatable {
    /// The program's name.
    public let name: String?
    /// Its version.
    public let version: String?
    /// Informational; never relied on.
    public let binary: String?
  }

  /// A hand-set face box, in source pixels, origin top-left (§6, §8.5).
  public struct Box: Sendable, Equatable {
    /// The left edge.
    public let x: Double
    /// The top edge.
    public let y: Double
    /// The width.
    public let width: Double
    /// The height.
    public let height: Double
  }

  /// The record's JSON. A writer changes provenance through this.
  public package(set) var json: JSONObject

  /// A record over existing JSON.
  public init(json: JSONObject) { self.json = json }

  private func text(_ key: String) -> String? { json[key]?.stringValue }

  /// Who produced the file.
  public var provider: String? { text("provider") }
  /// The program run. `nil` for version 1's plain string, which stays in ``json``.
  public var tool: Tool? {
    guard let object = json["tool"]?.objectValue else { return nil }
    return Tool(
      name: object["name"]?.stringValue, version: object["version"]?.stringValue,
      binary: object["binary"]?.stringValue)
  }
  /// The model, as the tool reports it.
  public var model: String? { text("model") }
  /// The models a `.vox` holds, as the tool reports them.
  public var models: [String] { json["models"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
  /// The prompt sent, before style.
  public var prompt: String? { text("prompt") }
  /// Style and prompt as the engine received them.
  public var composedPrompt: String? { text("composedPrompt") }
  /// The full style string sent.
  public var style: String? { text("style") }
  /// The character's `artStyle` when the image was made: the staleness key (§7).
  public var artStyle: String? { text("artStyle") }
  /// The negative prompt.
  public var negative: String? { text("negative") }
  /// `false` when the engine ignored ``negative``.
  public var negativeApplied: Bool? { json["negativeApplied"]?.boolValue }
  /// The seed.
  public var seed: Int64? { json["seed"]?.intValue }
  /// The step count.
  public var steps: Int64? { json["steps"]?.intValue }
  /// The guidance scale.
  public var guidance: Double? { json["guidance"]?.doubleValue }
  /// The output width in pixels.
  public var width: Int64? { json["width"]?.intValue }
  /// The output height in pixels.
  public var height: Int64? { json["height"]?.intValue }
  /// The engine.
  public var engine: String? { text("engine") }
  /// The mode.
  public var mode: String? { text("mode") }
  /// How long generation took.
  public var durationSeconds: Double? { json["durationSeconds"]?.doubleValue }
  /// Every reference image sent, in the order sent. Version 1's path strings aren't included.
  public var references: [ProvenanceReference] {
    json["references"]?.arrayValue?.compactMap { $0.objectValue.map(ProvenanceReference.init(json:)) } ?? []
  }
  /// The prompt round.
  public var round: String? { text("round") }
  /// A hand-set face box.
  public var box: Box? {
    guard let object = json["box"]?.objectValue, let x = object["x"]?.doubleValue,
      let y = object["y"]?.doubleValue, let width = object["width"]?.doubleValue,
      let height = object["height"]?.doubleValue
    else { return nil }
    return Box(x: x, y: y, width: width, height: height)
  }
  /// The voice-design prompt of a `.vox`.
  public var voicePrompt: String? { text("voicePrompt") }
  /// The project-relative path an existing `.vox` was copied from.
  public var copiedFrom: String? { text("copiedFrom") }
  /// The delivery instruction sent.
  public var instruct: String? { text("instruct") }
  /// `yes`, `no` or `unverified`.
  public var instructApplied: String? { text("instructApplied") }
  /// Where a sample's line comes from.
  public var source: String? { text("source") }
  /// A producing tool's process gate that was skipped.
  public var gateOverridden: String? { text("gateOverridden") }
  /// Free text.
  public var notes: String? { text("notes") }
}

/// One entry of `assets` (§5.4), a view over its JSON. Unknown keys stay in ``json``.
public struct Asset: Sendable, Equatable {
  /// The entry's JSON. Every property reads and writes through it.
  public package(set) var json: JSONObject

  /// An asset over existing JSON.
  public init(json: JSONObject) { self.json = json }

  /// A new asset with §5.4's required keys.
  package init(
    path: String, kind: AssetKind, status: AssetStatus, createdAt: String, provenance: Provenance
  ) {
    json = JSONObject([
      ("path", .string(path)), ("kind", .string(kind.rawValue)), ("status", .string(status.rawValue)),
      ("createdAt", .string(createdAt)), ("provenance", .object(provenance.json)),
    ])
  }

  private mutating func set(_ key: String, _ value: String?) {
    json[key] = value.map(JSONValue.string)
  }

  /// The bundle path. Empty when the manifest doesn't give a string.
  public package(set) var path: String {
    get { json["path"]?.stringValue ?? "" }
    set { set("path", newValue) }
  }
  /// What the asset is.
  public package(set) var kind: AssetKind {
    get { AssetKind(rawValue: json["kind"]?.stringValue ?? "") }
    set { set("kind", newValue.rawValue) }
  }
  /// Its status.
  public package(set) var status: AssetStatus {
    get { AssetStatus(rawValue: json["status"]?.stringValue ?? "") }
    set { set("status", newValue.rawValue) }
  }
  /// The variant, when the kind has variants.
  public package(set) var variant: String? {
    get { json["variant"]?.stringValue }
    set { set("variant", newValue) }
  }
  /// Display text. Never a key; never parsed.
  public package(set) var label: String? {
    get { json["label"]?.stringValue }
    set { set("label", newValue) }
  }
  /// When the file was made. Sometimes absent in version 1.
  public package(set) var createdAt: String? {
    get { json["createdAt"]?.stringValue }
    set { set("createdAt", newValue) }
  }
  /// How it was made. Sometimes absent in version 1, which reads as empty here.
  public package(set) var provenance: Provenance {
    get { Provenance(json: json["provenance"]?.objectValue ?? JSONObject()) }
    set { json["provenance"] = .object(newValue.json) }
  }
  /// Its inputs. Empty for version 1's string and object forms, which stay in ``json``.
  public package(set) var derivedFrom: [DerivedInput] {
    get { json["derivedFrom"]?.arrayValue?.compactMap { $0.objectValue.map(DerivedInput.init(json:)) } ?? [] }
    set { json["derivedFrom"] = .array(newValue.map { .object($0.json) }) }
  }
  /// The `review` object (§5.4).
  public package(set) var review: JSONObject? {
    get { json["review"]?.objectValue }
    set { json["review"] = newValue.map(JSONValue.object) }
  }
  /// The size a `voiceSample` was rendered with.
  public package(set) var model: String? {
    get { json["model"]?.stringValue }
    set { set("model", newValue) }
  }
  /// A `voiceSample`'s language, as BCP 47.
  public package(set) var language: String? {
    get { json["language"]?.stringValue }
    set { set("language", newValue) }
  }
  /// The words a `voiceSample` speaks.
  public package(set) var sampleText: String? {
    get { json["sampleText"]?.stringValue }
    set { set("sampleText", newValue) }
  }
  /// The `lora` object (§8.4).
  public package(set) var lora: JSONObject? {
    get { json["lora"]?.objectValue }
    set { json["lora"] = newValue.map(JSONValue.object) }
  }
  /// The `training` object (§8.4).
  public package(set) var training: JSONObject? {
    get { json["training"]?.objectValue }
    set { json["training"] = newValue.map(JSONValue.object) }
  }
}
