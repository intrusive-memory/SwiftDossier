import Foundation

/// A JSON value that keeps what `JSONSerialization` and `Codable` lose: a number's
/// literal text (`1.50`, `1e3`, integers past 2^53) and a string's exact scalars.
///
/// This is why a manifest's unknown keys survive a re-encode (§5.1, §5.4, §6).
public enum JSONValue: Sendable, Equatable {
  /// `null`.
  case null
  /// `true` or `false`.
  case bool(Bool)
  /// A number, as its literal JSON text.
  case number(String)
  /// A string, with its scalars exactly as decoded. Never normalized.
  case string(String)
  /// An array.
  case array([JSONValue])
  /// An object.
  case object(JSONObject)

  /// The string, when this is one.
  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  /// The boolean, when this is one.
  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  /// The integer, when this is a number whose literal is a signed 64-bit integer.
  public var intValue: Int64? {
    if case .number(let literal) = self { return Int64(literal) }
    return nil
  }

  /// The number as a `Double`, when this is a number.
  public var doubleValue: Double? {
    if case .number(let literal) = self { return Double(literal) }
    return nil
  }

  /// The elements, when this is an array.
  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  /// The object, when this is one.
  public var objectValue: JSONObject? {
    if case .object(let value) = self { return value }
    return nil
  }

  /// A number holding an integer.
  package static func integer(_ value: Int64) -> JSONValue { .number(String(value)) }

  /// Whether two values are identical. Strings compare by bytes, not canonical
  /// equivalence, so an edit that only changes a string's normalization isn't equal.
  public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): return true
    case (.bool(let a), .bool(let b)): return a == b
    case (.number(let a), .number(let b)): return a.hasSameBytes(as: b)
    case (.string(let a), .string(let b)): return a.hasSameBytes(as: b)
    case (.array(let a), .array(let b)): return a == b
    case (.object(let a), .object(let b)): return a == b
    default: return false
    }
  }

  /// Parses one JSON document strictly (RFC 8259). The input must be UTF-8.
  public static func parse(_ data: Data) throws -> JSONValue {
    var parser = JSONParser(bytes: Array(data))
    return try parser.parseDocument()
  }

  /// §5's form: 2-space indentation, keys sorted by byte order, a final newline,
  /// no escaped `/`.
  public func prettyEncoded() -> Data {
    var out = ""
    writePretty(into: &out, indent: 0)
    out += "\n"
    return Data(out.utf8)
  }

  /// §7's canonical JSON: keys sorted by byte order, no whitespace outside strings.
  public func canonicalEncoded() -> String {
    var out = ""
    writeCanonical(into: &out)
    return out
  }

  private func writePretty(into out: inout String, indent: Int) {
    switch self {
    case .array(let items) where !items.isEmpty:
      let inner = String(repeating: " ", count: indent + 2)
      out += "[\n"
      for (index, item) in items.enumerated() {
        out += inner
        item.writePretty(into: &out, indent: indent + 2)
        out += index == items.count - 1 ? "\n" : ",\n"
      }
      out += String(repeating: " ", count: indent) + "]"
    case .object(let object) where !object.isEmpty:
      let inner = String(repeating: " ", count: indent + 2)
      let sorted = object.entriesInByteOrder
      out += "{\n"
      for (index, entry) in sorted.enumerated() {
        out += inner
        Self.writeString(entry.key, into: &out)
        out += ": "
        entry.value.writePretty(into: &out, indent: indent + 2)
        out += index == sorted.count - 1 ? "\n" : ",\n"
      }
      out += String(repeating: " ", count: indent) + "}"
    default:
      writeCanonical(into: &out)
    }
  }

  private func writeCanonical(into out: inout String) {
    switch self {
    case .null: out += "null"
    case .bool(let value): out += value ? "true" : "false"
    case .number(let literal): out += literal
    case .string(let value): Self.writeString(value, into: &out)
    case .array(let items):
      out += "["
      for (index, item) in items.enumerated() {
        if index > 0 { out += "," }
        item.writeCanonical(into: &out)
      }
      out += "]"
    case .object(let object):
      out += "{"
      for (index, entry) in object.entriesInByteOrder.enumerated() {
        if index > 0 { out += "," }
        Self.writeString(entry.key, into: &out)
        out += ":"
        entry.value.writeCanonical(into: &out)
      }
      out += "}"
    }
  }

  /// §7's escapes, which are also the only ones §5's form uses.
  private static func writeString(_ value: String, into out: inout String) {
    out.unicodeScalars.append("\"")
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out.unicodeScalars.append(contentsOf: "\\\"".unicodeScalars)
      case "\\": out.unicodeScalars.append(contentsOf: "\\\\".unicodeScalars)
      case "\u{08}": out.unicodeScalars.append(contentsOf: "\\b".unicodeScalars)
      case "\t": out.unicodeScalars.append(contentsOf: "\\t".unicodeScalars)
      case "\n": out.unicodeScalars.append(contentsOf: "\\n".unicodeScalars)
      case "\u{0C}": out.unicodeScalars.append(contentsOf: "\\f".unicodeScalars)
      case "\r": out.unicodeScalars.append(contentsOf: "\\r".unicodeScalars)
      case _ where scalar.value < 0x20:
        let hex = String(scalar.value, radix: 16)
        let escape = "\\u00" + (hex.count == 1 ? "0" : "") + hex
        out.unicodeScalars.append(contentsOf: escape.unicodeScalars)
      default:
        out.unicodeScalars.append(scalar)
      }
    }
    out.unicodeScalars.append("\"")
  }
}

/// A JSON object. Keys compare by bytes, so keys that differ only in normalization
/// stay distinct, and encoding always sorts them.
public struct JSONObject: Sendable, Equatable {
  /// One key and its value.
  public struct Entry: Sendable, Equatable {
    /// The key, with its scalars exactly as decoded.
    public let key: String
    /// The value.
    public var value: JSONValue
  }

  /// The entries, in the order they were read or added.
  public private(set) var entries: [Entry] = []

  /// An empty object.
  package init() {}

  /// An object with these entries. A later duplicate key replaces an earlier one.
  package init(_ pairs: [(String, JSONValue)]) {
    for (key, value) in pairs { self[key] = value }
  }

  /// Whether the object has no keys.
  public var isEmpty: Bool { entries.isEmpty }

  /// The keys, in the order they were read or added.
  public var keys: [String] { entries.map(\.key) }

  /// The entries in byte order of their keys.
  public var entriesInByteOrder: [Entry] {
    entries.sorted { $0.key.precedesInByteOrder($1.key) }
  }

  /// The value of a key, compared by bytes. Setting `nil` removes the key.
  public package(set) subscript(key: String) -> JSONValue? {
    get { entries.first { $0.key.hasSameBytes(as: key) }?.value }
    set {
      let index = entries.firstIndex { $0.key.hasSameBytes(as: key) }
      switch (index, newValue) {
      case (let index?, let value?): entries[index].value = value
      case (let index?, nil): entries.remove(at: index)
      case (nil, let value?): entries.append(Entry(key: key, value: value))
      case (nil, nil): break
      }
    }
  }

  /// Whether two objects have the same keys and values, whatever the order.
  public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
    lhs.entriesInByteOrder == rhs.entriesInByteOrder
  }
}

extension JSONObject.Entry {
  /// Whether two entries have the same key bytes and the same value.
  public static func == (lhs: JSONObject.Entry, rhs: JSONObject.Entry) -> Bool {
    lhs.key.hasSameBytes(as: rhs.key) && lhs.value == rhs.value
  }
}

private struct JSONParser {
  let bytes: [UInt8]
  var position = 0
  static let maximumDepth = 512

  init(bytes: [UInt8]) { self.bytes = bytes }

  mutating func parseDocument() throws -> JSONValue {
    let value = try parseValue(depth: 0)
    skipWhitespace()
    guard position == bytes.count else { throw failure("trailing content") }
    return value
  }

  private func failure(_ what: String) -> DossierError {
    .manifestNotJSON("\(what) at byte \(position)")
  }

  private mutating func skipWhitespace() {
    while position < bytes.count {
      switch bytes[position] {
      case 0x20, 0x09, 0x0A, 0x0D: position += 1
      default: return
      }
    }
  }

  private mutating func parseValue(depth: Int) throws -> JSONValue {
    guard depth <= Self.maximumDepth else { throw failure("nesting too deep") }
    skipWhitespace()
    guard position < bytes.count else { throw failure("unexpected end") }
    switch bytes[position] {
    case UInt8(ascii: "{"): return try parseObject(depth: depth)
    case UInt8(ascii: "["): return try parseArray(depth: depth)
    case UInt8(ascii: "\""): return .string(try parseString())
    case UInt8(ascii: "t"): try expect("true"); return .bool(true)
    case UInt8(ascii: "f"): try expect("false"); return .bool(false)
    case UInt8(ascii: "n"): try expect("null"); return .null
    default: return .number(try parseNumber())
    }
  }

  private mutating func expect(_ word: String) throws {
    for byte in word.utf8 {
      guard position < bytes.count, bytes[position] == byte else {
        throw failure("expected \(word)")
      }
      position += 1
    }
  }

  private mutating func parseObject(depth: Int) throws -> JSONValue {
    position += 1
    var object = JSONObject()
    skipWhitespace()
    if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
      position += 1
      return .object(object)
    }
    while true {
      skipWhitespace()
      guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else {
        throw failure("expected a key")
      }
      let key = try parseString()
      skipWhitespace()
      guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else {
        throw failure("expected a colon")
      }
      position += 1
      object[key] = try parseValue(depth: depth + 1)
      skipWhitespace()
      guard position < bytes.count else { throw failure("unexpected end") }
      if bytes[position] == UInt8(ascii: ",") {
        position += 1
      } else if bytes[position] == UInt8(ascii: "}") {
        position += 1
        return .object(object)
      } else {
        throw failure("expected a comma or a closing brace")
      }
    }
  }

  private mutating func parseArray(depth: Int) throws -> JSONValue {
    position += 1
    var items: [JSONValue] = []
    skipWhitespace()
    if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
      position += 1
      return .array(items)
    }
    while true {
      items.append(try parseValue(depth: depth + 1))
      skipWhitespace()
      guard position < bytes.count else { throw failure("unexpected end") }
      if bytes[position] == UInt8(ascii: ",") {
        position += 1
      } else if bytes[position] == UInt8(ascii: "]") {
        position += 1
        return .array(items)
      } else {
        throw failure("expected a comma or a closing bracket")
      }
    }
  }

  private mutating func parseNumber() throws -> String {
    let start = position
    func isDigit(_ index: Int) -> Bool {
      index < bytes.count && (0x30...0x39).contains(bytes[index])
    }
    if position < bytes.count, bytes[position] == UInt8(ascii: "-") { position += 1 }
    guard isDigit(position) else { throw failure("expected a value") }
    if bytes[position] == 0x30 {
      position += 1
      if isDigit(position) { throw failure("leading zero") }
    } else {
      while isDigit(position) { position += 1 }
    }
    if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
      position += 1
      guard isDigit(position) else { throw failure("expected a fraction") }
      while isDigit(position) { position += 1 }
    }
    if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
      position += 1
      if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") {
        position += 1
      }
      guard isDigit(position) else { throw failure("expected an exponent") }
      while isDigit(position) { position += 1 }
    }
    return String(decoding: bytes[start..<position], as: UTF8.self)
  }

  private mutating func parseString() throws -> String {
    position += 1
    var out: [UInt8] = []
    while true {
      guard position < bytes.count else { throw failure("unterminated string") }
      let byte = bytes[position]
      position += 1
      switch byte {
      case UInt8(ascii: "\""):
        guard let text = String(validating: out, as: UTF8.self) else {
          throw failure("invalid UTF-8")
        }
        return text
      case UInt8(ascii: "\\"):
        try parseEscape(into: &out)
      case 0..<0x20:
        throw failure("unescaped control character")
      default:
        out.append(byte)
      }
    }
  }

  private mutating func parseEscape(into out: inout [UInt8]) throws {
    guard position < bytes.count else { throw failure("unterminated escape") }
    let byte = bytes[position]
    position += 1
    switch byte {
    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(byte)
    case UInt8(ascii: "b"): out.append(0x08)
    case UInt8(ascii: "f"): out.append(0x0C)
    case UInt8(ascii: "n"): out.append(0x0A)
    case UInt8(ascii: "r"): out.append(0x0D)
    case UInt8(ascii: "t"): out.append(0x09)
    case UInt8(ascii: "u"):
      var value = try parseHex4()
      if (0xD800..<0xDC00).contains(value) {
        guard position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"),
          bytes[position + 1] == UInt8(ascii: "u")
        else { throw failure("lone surrogate") }
        position += 2
        let low = try parseHex4()
        guard (0xDC00..<0xE000).contains(low) else { throw failure("lone surrogate") }
        value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
      }
      guard let scalar = Unicode.Scalar(value) else { throw failure("lone surrogate") }
      out.append(contentsOf: Array(String(Character(scalar)).utf8))
    default:
      throw failure("unknown escape")
    }
  }

  private mutating func parseHex4() throws -> UInt32 {
    guard position + 4 <= bytes.count else { throw failure("short unicode escape") }
    var value: UInt32 = 0
    for _ in 0..<4 {
      guard let digit = Character(Unicode.Scalar(bytes[position])).hexDigitValue else {
        throw failure("bad unicode escape")
      }
      value = value * 16 + UInt32(digit)
      position += 1
    }
    return value
  }
}
