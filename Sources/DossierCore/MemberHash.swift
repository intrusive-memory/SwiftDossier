import Foundation
import Yams

/// The hash of a `CAST.md` member (§7): the SHA-256 of the canonical JSON of its normal form.
///
/// A member is read as a YAML node rather than decoded, because §7's values depend on
/// a scalar's style (`5` and `"5"` differ), which a decoder doesn't report.
public enum MemberHash {
  /// §7's keys whose values are always strings, and absent when null.
  private static let stringKeys: [String] = [
    "character", "role", "actor", "gender", "language", "voicePrompt", "manifest",
  ]

  /// The hash of a member given as YAML: a mapping, or a list holding one.
  public static func hash(ofMemberYAML yaml: String) throws -> String {
    Checksum.sha256(try canonicalJSON(ofMemberYAML: yaml))
  }

  /// The canonical JSON of a member given as YAML: a mapping, or a list holding one.
  public static func canonicalJSON(ofMemberYAML yaml: String) throws -> String {
    let root: Node?
    do {
      root = try Yams.compose(yaml: yaml)
    } catch {
      throw DossierError.memberUnreadable(String(describing: error))
    }
    var member = root
    if case .sequence(let sequence)? = root, sequence.count == 1 { member = sequence[0] }
    guard let member, case .mapping = member else {
      throw DossierError.memberUnreadable("expected one mapping")
    }
    return normalForm(of: member).canonicalEncoded()
  }

  /// §7's normal form of one member node.
  static func normalForm(of node: Node) -> JSONValue {
    guard case .mapping(let mapping) = node else { return .object(JSONObject()) }
    var object = JSONObject()
    var legacyPrompt: JSONValue?
    var voices = JSONObject()
    for (keyNode, value) in mapping {
      let key = keyNode.string ?? ""
      if key == "voiceDescription" {
        legacyPrompt = stringKeyValue(value)
      } else if key == "voices" {
        voices = normalVoices(value)
      } else if stringKeys.contains(where: { $0.hasSameBytes(as: key) }) {
        object[key] = stringKeyValue(value)
      } else {
        object[key] = generalValue(value)
      }
    }
    if object["voicePrompt"] == nil { object["voicePrompt"] = legacyPrompt }
    object["voices"] = .object(voices)
    return .object(object)
  }

  /// Whether a plain scalar's text is §7's null.
  package static func isNullText(_ text: String) -> Bool {
    ["", "~", "null", "Null", "NULL"].contains(text)
  }

  /// A value in one of ``stringKeys``: its text, or `nil` when null.
  private static func stringKeyValue(_ node: Node) -> JSONValue? {
    guard case .scalar(let scalar) = node else {
      // SPEC-GAP: §7: a mapping or list under a string key is unspecified. Reparto refuses
      // such a member (E-CAST), so it's only reachable through `hash(ofMemberYAML:)`.
      return generalValue(node)
    }
    if scalar.style == .plain, isNullText(scalar.string) { return nil }
    return .string(scalar.string)
  }

  // SPEC-GAP: §7: "everything in voices" is a string written as its text, so a plain `5`
  // here is "5", though the fixtures' generator drops it. The null scalars aren't strings
  // and are dropped, alone or in a list. Providers that collide once lowercased (recon
  // N6) resolve to the last in the file.
  private static func normalVoices(_ node: Node) -> JSONObject {
    var voices = JSONObject()
    guard case .mapping(let mapping) = node else { return voices }
    for (keyNode, value) in mapping {
      let provider = (keyNode.string ?? "").lowercased()
      switch value {
      case .scalar:
        if let text = stringKeyValue(value) { voices[provider] = .array([text]) }
      case .sequence(let sequence):
        let items = sequence.map { item -> JSONValue? in
          guard case .scalar = item else { return nil }
          return stringKeyValue(item)
        }
        if items.allSatisfy({ $0 != nil }) { voices[provider] = .array(items.compactMap { $0 }) }
      default:
        break
      }
    }
    return voices
  }

  /// The provider keys of a member node's `voices`, as written.
  static func voiceProviderSpellings(of node: Node) -> [String] {
    guard case .mapping(let mapping) = node, case .mapping(let voices)? = mapping["voices"] else { return [] }
    return voices.map { $0.0.string ?? "" }
  }

  /// A value in any other key, at any depth.
  static func generalValue(_ node: Node) -> JSONValue {
    switch node {
    case .scalar(let scalar):
      // SPEC-GAP: §7: an explicit YAML tag on a plain scalar isn't mentioned, so tags are
      // ignored. Block scalars aren't plain, so they are strings.
      guard scalar.style == .plain else { return .string(scalar.string) }
      return plainScalar(scalar.string)
    case .mapping(let mapping):
      var object = JSONObject()
      for (key, value) in mapping { object[key.string ?? ""] = generalValue(value) }
      return .object(object)
    case .sequence(let sequence):
      return .array(sequence.map(generalValue))
    case .alias:
      // Yams' composer resolves aliases, so a parsed document doesn't hold this case.
      return .null
    }
  }

  private static func plainScalar(_ text: String) -> JSONValue {
    if isNullText(text) { return .null }
    if ["true", "True", "TRUE"].contains(text) { return .bool(true) }
    if ["false", "False", "FALSE"].contains(text) { return .bool(false) }
    if matchesIntegerPattern(text), let value = Int64(text) { return .integer(value) }
    return .string(text)
  }

  /// `-?(0|[1-9][0-9]*)`.
  private static func matchesIntegerPattern(_ text: String) -> Bool {
    let digits = Array((text.hasPrefix("-") ? text.dropFirst() : Substring(text)).utf8)
    guard let first = digits.first, digits.allSatisfy({ (0x30...0x39).contains($0) }) else {
      return false
    }
    return first != 0x30 || digits.count == 1
  }
}
