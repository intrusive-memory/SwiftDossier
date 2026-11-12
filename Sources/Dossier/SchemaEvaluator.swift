import DossierCore
import Foundation

/// One place an instance failed a schema (SD-13).
public struct SchemaViolation: Sendable, Equatable {
  /// A JSON Pointer (RFC 6901) to the offending value in the instance; `""` is the root.
  public let path: String
  /// The schema keyword that failed.
  public let keyword: String
  /// A description of the failure, for people.
  public let message: String
}

/// Why a schema can't be used. An unsupported keyword is a failure, never a pass (SD-13).
public enum SchemaError: Error, Equatable, Sendable, LocalizedError {
  /// A schema uses a keyword the evaluator doesn't implement.
  case unsupportedKeyword(schema: String, location: String, keyword: String)
  /// A `pattern` uses regular-expression syntax the evaluator can't give ECMA-262 meaning.
  case unsupportedPattern(String)
  /// A `$ref` names no loaded schema, points at nothing in its own, or has any other fragment.
  case unresolvedReference(String)
  /// A schema is malformed: not an object or boolean, no `$id`, or a keyword has the wrong shape.
  case malformedSchema(String)
  /// `validate` was asked about a schema that isn't loaded.
  case unknownSchema(String)

  /// A description of the failure, for people.
  public var errorDescription: String? {
    switch self {
    case .unsupportedKeyword(let schema, let location, let keyword):
      return "Schema \(schema) uses unsupported keyword \"\(keyword)\" at \(location)"
    case .unsupportedPattern(let detail): return "Unsupported pattern: \(detail)"
    case .unresolvedReference(let ref): return "Unresolved $ref: \(ref)"
    case .malformedSchema(let detail): return "Malformed schema: \(detail)"
    case .unknownSchema(let name): return "No schema named \(name)"
    }
  }
}

/// A small JSON Schema evaluator for exactly the keywords the pinned schemas use (SD-13):
/// `type`, `required`, `properties`, `additionalProperties`, `items`, `enum`, `const`,
/// `pattern`, `minimum`, `minLength`, `minItems`, `allOf`, `oneOf`, `if`/`then`/`else`, `contains`,
/// `$defs`, and `$ref`, either to another loaded schema or a `#/` pointer into its own.
/// `$id`, `$schema`, `title` and `description` are ignored.
///
/// Loading fails on any other keyword, so a schema change that adds one can't pass silently.
public struct SchemaEvaluator: Sendable {
  private static let ignored: Set<String> = ["$id", "$schema", "title", "description"]
  private static let supported: Set<String> = [
    "type", "required", "properties", "additionalProperties", "items", "enum", "const",
    "pattern", "minimum", "minLength", "minItems", "allOf", "oneOf", "if", "then", "else", "contains",
    "$ref", "$defs",
  ]
  private static let typeNames: Set<String> = [
    "null", "boolean", "object", "array", "number", "integer", "string",
  ]

  private struct Schema: Sendable {
    let name: String
    let id: String
    let root: JSONValue
  }

  private let schemas: [String: Schema]  // by $id
  private let names: [String: String]  // file name -> $id
  private let patterns: [String: CompiledPattern]

  /// The names (`manifest-v2.schema.json`) of the loaded schemas.
  public var schemaNames: [String] { names.keys.sorted() }

  /// Loads schemas, each an object with an absolute `$id`. Throws if any uses an unsupported
  /// keyword or pattern, or a `$ref` that doesn't resolve.
  public init(schemas documents: [JSONValue]) throws {
    var byID: [String: Schema] = [:]
    var byName: [String: String] = [:]
    for document in documents {
      guard let object = document.objectValue, let id = object["$id"]?.stringValue,
        let url = URL(string: id), url.scheme != nil
      else { throw SchemaError.malformedSchema("a schema needs an absolute $id") }
      let name = url.lastPathComponent
      byID[id] = Schema(name: name, id: id, root: document)
      byName[name] = id
    }
    var compiled: [String: CompiledPattern] = [:]
    for schema in byID.values {
      try Self.check(
        schema.root, schema: schema, location: "#", known: Set(byID.keys), patterns: &compiled)
    }
    self.schemas = byID
    self.names = byName
    self.patterns = compiled
  }

  /// Loads every `*.schema.json` bundled from the pinned dossier-format revision.
  public static func pinned() throws -> SchemaEvaluator {
    guard let root = DossierResources.bundle.resourceURL?.appendingPathComponent("schemas") else {
      throw SchemaError.malformedSchema("the schemas resource directory is missing")
    }
    let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0.hasSuffix(".schema.json") }.sorted()
    guard !files.isEmpty else { throw SchemaError.malformedSchema("no bundled schemas") }
    return try SchemaEvaluator(
      schemas: files.map { try JSONValue.parse(Data(contentsOf: root.appendingPathComponent($0))) })
  }

  /// Every way `instance` fails the named schema (a file name like `manifest-v2.schema.json`,
  /// or a full `$id`); empty when it validates.
  public func validate(_ instance: JSONValue, against name: String) throws -> [SchemaViolation] {
    guard let id = names[name] ?? (schemas[name] != nil ? name : nil), let schema = schemas[id]
    else { throw SchemaError.unknownSchema(name) }
    var violations: [SchemaViolation] = []
    evaluate(instance, schema.root, base: schema.id, path: "", into: &violations)
    return violations
  }

  // MARK: Loading

  private static func check(
    _ node: JSONValue, schema: Schema, location: String, known: Set<String>,
    patterns: inout [String: CompiledPattern]
  ) throws {
    if case .bool = node { return }
    guard let object = node.objectValue else {
      throw SchemaError.malformedSchema("\(schema.name) \(location) is not an object or boolean")
    }
    func sub(_ value: JSONValue, _ keyword: String) throws {
      try check(
        value, schema: schema, location: location + "/" + keyword, known: known,
        patterns: &patterns)
    }
    for entry in object.entries {
      let keyword = entry.key
      let value = entry.value
      if ignored.contains(keyword) { continue }
      guard supported.contains(keyword) else {
        throw SchemaError.unsupportedKeyword(
          schema: schema.name, location: location, keyword: keyword)
      }
      switch keyword {
      case "type":
        let names = value.stringValue.map { [$0] } ?? value.arrayValue?.compactMap(\.stringValue)
        guard let names, !names.isEmpty, names.allSatisfy(typeNames.contains),
          value.arrayValue.map({ $0.count == names.count }) ?? true
        else { throw SchemaError.malformedSchema("\(schema.name) \(location): bad type") }
      case "required":
        guard let items = value.arrayValue, items.allSatisfy({ $0.stringValue != nil }) else {
          throw SchemaError.malformedSchema("\(schema.name) \(location): bad required")
        }
      case "properties":
        guard let properties = value.objectValue else {
          throw SchemaError.malformedSchema("\(schema.name) \(location): bad properties")
        }
        for property in properties.entries {
          try check(
            property.value, schema: schema,
            location: location + "/properties/" + property.key, known: known, patterns: &patterns)
        }
      case "additionalProperties", "items", "if", "then", "else", "contains":
        try sub(value, keyword)
      case "$defs":
        guard let definitions = value.objectValue else {
          throw SchemaError.malformedSchema("\(schema.name) \(location): bad $defs")
        }
        for definition in definitions.entries {
          try check(
            definition.value, schema: schema,
            location: location + "/$defs/" + definition.key, known: known, patterns: &patterns)
        }
      case "allOf", "oneOf":
        guard let items = value.arrayValue, !items.isEmpty else {
          throw SchemaError.malformedSchema("\(schema.name) \(location): bad \(keyword)")
        }
        for (index, item) in items.enumerated() {
          try check(
            item, schema: schema, location: "\(location)/\(keyword)/\(index)", known: known,
            patterns: &patterns)
        }
      case "enum":
        guard value.arrayValue != nil else {
          throw SchemaError.malformedSchema("\(schema.name) \(location): bad enum")
        }
      case "const":
        break
      case "pattern":
        guard let pattern = value.stringValue else {
          throw SchemaError.malformedSchema("\(schema.name) \(location): bad pattern")
        }
        if patterns[pattern] == nil { patterns[pattern] = try CompiledPattern(pattern) }
      case "minimum":
        guard case .number = value else {
          throw SchemaError.malformedSchema("\(schema.name) \(location): bad minimum")
        }
      case "minLength", "minItems":
        guard let count = value.intValue, count >= 0 else {
          throw SchemaError.malformedSchema("\(schema.name) \(location): bad \(keyword)")
        }
      case "$ref":
        guard let ref = value.stringValue else {
          throw SchemaError.unresolvedReference("?")
        }
        if ref.hasPrefix("#") {
          guard pointer(ref, in: schema.root) != nil else {
            throw SchemaError.unresolvedReference(ref)
          }
        } else {
          guard let target = resolve(ref, base: schema.id), known.contains(target) else {
            throw SchemaError.unresolvedReference(ref)
          }
        }
      default:
        break
      }
    }
  }

  /// `ref` resolved against `base`, without a fragment; `nil` for a fragment or a bad URL.
  private static func resolve(_ ref: String, base: String) -> String? {
    guard let baseURL = URL(string: base), let url = URL(string: ref, relativeTo: baseURL),
      url.fragment == nil, !ref.contains("#")
    else { return nil }
    return url.absoluteURL.absoluteString
  }

  /// The subschema a `#/a/b` pointer names in `root`, through object keys, with RFC 6901's `~1`
  /// and `~0`. `nil` for anything else: a bare `#`, an array index, or percent-encoding.
  private static func pointer(_ ref: String, in root: JSONValue) -> JSONValue? {
    guard ref.hasPrefix("#/"), !ref.contains("%") else { return nil }
    var node = root
    for token in ref.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
      let key = token.replacingOccurrences(of: "~1", with: "/")
        .replacingOccurrences(of: "~0", with: "~")
      guard let next = node.objectValue?[key] else { return nil }
      node = next
    }
    return node
  }

  // MARK: Evaluation

  private func evaluate(
    _ instance: JSONValue, _ schema: JSONValue, base: String, path: String,
    into violations: inout [SchemaViolation]
  ) {
    if case .bool(let allowed) = schema {
      if !allowed {
        violations.append(.init(path: path, keyword: "false", message: "no value is allowed"))
      }
      return
    }
    guard let object = schema.objectValue else { return }

    func fail(_ keyword: String, _ message: String) {
      violations.append(.init(path: path, keyword: keyword, message: message))
    }
    func passes(_ sub: JSONValue) -> Bool {
      var scratch: [SchemaViolation] = []
      evaluate(instance, sub, base: base, path: path, into: &scratch)
      return scratch.isEmpty
    }

    if let ref = object["$ref"]?.stringValue {
      if ref.hasPrefix("#") {
        if let root = schemas[base]?.root, let target = Self.pointer(ref, in: root) {
          evaluate(instance, target, base: base, path: path, into: &violations)
        }
      } else if let id = Self.resolve(ref, base: base), let target = schemas[id] {
        evaluate(instance, target.root, base: target.id, path: path, into: &violations)
      }
    }
    if let type = object["type"] {
      let names = type.stringValue.map { [$0] } ?? type.arrayValue?.compactMap(\.stringValue) ?? []
      if !names.contains(where: { Self.matches(instance, type: $0) }) {
        fail("type", "expected \(names.joined(separator: " or ")), found \(Self.typeName(instance))")
      }
    }
    if let allowed = object["enum"]?.arrayValue,
      !allowed.contains(where: { Self.equal($0, instance) })
    {
      fail("enum", "not one of the allowed values")
    }
    if let expected = object["const"], !Self.equal(expected, instance) {
      fail("const", "does not equal the required value")
    }
    if let subschemas = object["allOf"]?.arrayValue {
      for sub in subschemas {
        evaluate(instance, sub, base: base, path: path, into: &violations)
      }
    }
    if let subschemas = object["oneOf"]?.arrayValue {
      let count = subschemas.filter(passes).count
      if count != 1 { fail("oneOf", "matches \(count) alternatives, expected exactly 1") }
    }
    // `then` and `else` without an `if` have no effect.
    if let condition = object["if"] {
      if let branch = passes(condition) ? object["then"] : object["else"] {
        evaluate(instance, branch, base: base, path: path, into: &violations)
      }
    }

    switch instance {
    case .string(let text):
      if let minimum = object["minLength"]?.intValue, Int64(text.unicodeScalars.count) < minimum {
        fail("minLength", "shorter than \(minimum)")
      }
      if let pattern = object["pattern"]?.stringValue, let compiled = patterns[pattern],
        !compiled.matches(text)
      {
        fail("pattern", "does not match \(pattern)")
      }
    case .number(let literal):
      if let limit = object["minimum"], case .number(let bound) = limit,
        Self.compare(literal, bound) == .orderedAscending
      {
        fail("minimum", "less than \(bound)")
      }
    case .array(let items):
      if let minimum = object["minItems"]?.intValue, Int64(items.count) < minimum {
        fail("minItems", "fewer than \(minimum) items")
      }
      if let itemSchema = object["items"] {
        for (index, item) in items.enumerated() {
          evaluate(item, itemSchema, base: base, path: path + "/\(index)", into: &violations)
        }
      }
      // 2020-12 with no `minContains`: at least one item matches.
      if let wanted = object["contains"], !items.contains(where: { item in
        var scratch: [SchemaViolation] = []
        evaluate(item, wanted, base: base, path: path, into: &scratch)
        return scratch.isEmpty
      }) {
        fail("contains", "no item matches")
      }
    case .object(let members):
      if let required = object["required"]?.arrayValue {
        for case .string(let key) in required where members[key] == nil {
          fail("required", "missing \"\(key)\"")
        }
      }
      let properties = object["properties"]?.objectValue
      for member in members.entries {
        let childPath = path + "/" + Self.escape(member.key)
        if let sub = properties?[member.key] {
          evaluate(member.value, sub, base: base, path: childPath, into: &violations)
        } else if let extra = object["additionalProperties"] {
          if case .bool(false) = extra {
            violations.append(
              .init(
                path: childPath, keyword: "additionalProperties",
                message: "\"\(member.key)\" is not allowed"))
          } else {
            evaluate(member.value, extra, base: base, path: childPath, into: &violations)
          }
        }
      }
    default:
      break
    }
  }

  private static func escape(_ key: String) -> String {
    key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
  }

  private static func typeName(_ value: JSONValue) -> String {
    switch value {
    case .null: return "null"
    case .bool: return "boolean"
    case .number: return "number"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    }
  }

  private static func matches(_ value: JSONValue, type: String) -> Bool {
    switch (type, value) {
    case ("null", .null), ("boolean", .bool), ("number", .number), ("string", .string),
      ("array", .array), ("object", .object):
      return true
    case ("integer", .number(let literal)):
      if Int64(literal) != nil { return true }
      guard let double = Double(literal), double.isFinite else { return false }
      return double == double.rounded()
    default:
      return false
    }
  }

  /// JSON Schema equality: numbers by value, strings by bytes, objects without regard to order.
  private static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
    switch (a, b) {
    case (.number(let x), .number(let y)): return compare(x, y) == .orderedSame
    case (.array(let x), .array(let y)):
      return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
    case (.object(let x), .object(let y)):
      guard x.keys.count == y.keys.count else { return false }
      return x.entries.allSatisfy { entry in
        y[entry.key].map { equal(entry.value, $0) } ?? false
      }
    default: return a == b
    }
  }

  private static func compare(_ a: String, _ b: String) -> ComparisonResult {
    if let x = Int64(a), let y = Int64(b) {
      return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }
    let x = Double(a) ?? .nan
    let y = Double(b) ?? .nan
    return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
  }
}

/// A `pattern`, with ECMA-262 meaning (no `u` or `m` flag), run on ICU's engine.
///
/// ICU differs from ECMA-262 in four ways that matter to the pinned patterns: `$` also matches
/// before a final line terminator; `\d` matches any Unicode digit; `.` leaves out `\u0085`
/// (ECMA-262 only leaves out `\n \r    `); and `&&` and a nested `[` in a class are
/// set operations. The translation fixes each; anything it doesn't know is refused, not guessed.
private struct CompiledPattern: @unchecked Sendable {
  private let expression: NSRegularExpression

  init(_ source: String) throws {
    let translated = try Self.translate(source)
    do {
      expression = try NSRegularExpression(pattern: translated, options: [])
    } catch {
      throw SchemaError.unsupportedPattern(source)
    }
  }

  /// ECMA-262's `RegExp.prototype.test`: an unanchored search.
  func matches(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return expression.firstMatch(in: text, options: [], range: range) != nil
  }

  private static func translate(_ source: String) throws -> String {
    let characters = Array(source)
    var out = ""
    var inClass = false
    var index = 0
    func refuse() -> SchemaError { .unsupportedPattern(source) }
    while index < characters.count {
      let c = characters[index]
      index += 1
      switch c {
      case "\\":
        guard index < characters.count else { throw refuse() }
        let next = characters[index]
        index += 1
        if next == "d" {
          out += inClass ? "0-9" : "[0-9]"
        } else if ".\\/-^$|()[]{}*+?".contains(next) {
          out += next == "/" ? "/" : "\\" + String(next)
        } else {
          throw refuse()
        }
      case "[":
        if inClass {
          out += "\\["
        } else {
          inClass = true
          out += "["
          if index < characters.count, characters[index] == "^" {
            out += "^"
            index += 1
          }
        }
      case "]":
        inClass = false
        out += "]"
      case "&":
        out += inClass ? "\\&" : "&"
      case ".":
        out += inClass ? "." : "[^\\n\\r\\u2028\\u2029]"
      case "$":
        out += inClass ? "\\$" : "\\z"
      case "(" where !inClass:
        out += "("
        if index < characters.count, characters[index] == "?" {
          guard index + 1 < characters.count, ":=!".contains(characters[index + 1]) else {
            throw refuse()
          }
          out += "?" + String(characters[index + 1])
          index += 2
        }
      case "{" where !inClass:
        guard let close = characters[index...].firstIndex(of: "}"),
          String(characters[index..<close]).range(
            of: "^[0-9]+(,[0-9]*)?$", options: .regularExpression) != nil
        else { throw refuse() }
        out += String(characters[(index - 1)...close])
        index = close + 1
      default:
        out.append(c)
      }
    }
    guard !inClass else { throw refuse() }
    return out
  }
}
