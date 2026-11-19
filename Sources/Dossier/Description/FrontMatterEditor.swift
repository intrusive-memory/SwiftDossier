import DossierCore
import Foundation
import Yams

/// A description file's text, split at its front matter, with the one lossless key write that
/// ``CharacterDescription`` and ``LocationDescription`` share.
///
/// A change to the front matter replaces the lines of that one key; the text of every other key,
/// and any comment or blank line between keys, stays as it was (§9.1). A change to ``body``
/// leaves the front matter alone.
struct FrontMatterEditor: Sendable {
  private var opening: String
  private var yaml: String?
  private var closing: String
  /// The text after the front matter.
  var body: String

  /// The text split at its front matter. Nothing is rejected here.
  init(text: String) {
    guard let split = FrontMatter.split(text) else {
      (opening, yaml, closing, body) = ("", nil, "", text)
      return
    }
    let bytes = Array(text.utf8)
    let openingCount = (bytes.firstIndex(of: 0x0A) ?? -1) + 1
    let closingEnd = bytes.count - split.body.utf8.count
    opening = String(decoding: bytes[..<openingCount], as: UTF8.self)
    yaml = split.yaml
    closing = String(decoding: bytes[(openingCount + split.yaml.utf8.count)..<closingEnd], as: UTF8.self)
    body = split.body
  }

  /// The whole file.
  var text: String { opening + (yaml ?? "") + closing + body }

  /// Whether the file has a front-matter block.
  var hasFrontMatter: Bool { yaml != nil }

  /// Why the front matter can't be used, or `nil` when it can.
  var problem: String? {
    do {
      _ = try mapping()
      return nil
    } catch let error as DescriptionError {
      if case .frontMatterUnreadable(let detail) = error { return detail }
      return error.localizedDescription
    } catch {
      return error.localizedDescription
    }
  }

  /// The front matter's keys and values, in file order. `nil` with no block, or one that can't
  /// be used.
  var object: JSONObject? {
    guard hasFrontMatter, let mapping = try? mapping() else { return nil }
    return Self.object(of: mapping)
  }

  /// The front matter as a parsed node. An empty block is an empty mapping.
  func mapping() throws -> Node.Mapping {
    try Self.mapping(of: yaml ?? "")
  }

  /// Sets a front-matter key, or removes it with `nil`. Only that key's lines change. A new key
  /// goes at the end of the block, and a file with no block gets one. Setting a key to the value
  /// it has changes nothing.
  ///
  /// - Throws: ``DescriptionError``. The value is then as it was.
  mutating func set(_ key: String, _ value: JSONValue?) throws {
    guard let yaml else {
      guard let value else { return }
      let lineBreak = body.contains("\r\n") ? "\r\n" : "\n"
      opening = "---" + lineBreak
      self.yaml = try Self.rendered(key, value, lineBreak: lineBreak)
      closing = "---" + lineBreak
      return
    }
    let mapping = try mapping()
    let before = Self.object(of: mapping)
    if before[key] == value.map(Self.asRead) { return }

    var lines = Self.linesKeepingBreaks(yaml)
    let lineBreak = yaml.contains("\r\n") ? "\r\n" : "\n"
    let spans = try Self.keySpans(of: mapping, lines: lines)
    let replacement = try value.map { Self.linesKeepingBreaks(try Self.rendered(key, $0, lineBreak: lineBreak)) } ?? []
    if let span = spans.first(where: { $0.key.hasSameBytes(as: key) }) {
      lines.replaceSubrange(span.lines, with: replacement)
    } else {
      lines.append(contentsOf: replacement)
    }
    let edited = lines.joined()

    // An anchor in the replaced text, say, would change another key.
    var expected = before
    expected[key] = value.map(Self.asRead)
    let after = (try? Self.mapping(of: edited)).map(Self.object(of:))
    guard let after, after == expected else {
      throw DescriptionError.frontMatterNotEditable("changing \(key) would change another key")
    }
    self.yaml = edited
  }

  /// Whether ``set(_:_:)`` can change this key without losing text a person wrote: `false` when
  /// the key's lines (its key line and its value's lines) hold a YAML comment, an anchor (`&name`)
  /// or an alias (`*name`), since a write replaces those lines with a rendered value. A `#` inside
  /// a quoted scalar or a block scalar's text isn't a comment.
  ///
  /// `true` for a key that isn't there, or a file with no block: setting it adds lines and
  /// replaces none. `false` when the block can't be edited by key at all (it doesn't parse, isn't a
  /// mapping, or is a flow mapping).
  func isEditable(_ key: String) -> Bool {
    guard let yaml else { return true }
    guard let mapping = try? mapping() else { return false }
    let lines = Self.linesKeepingBreaks(yaml)
    guard let spans = try? Self.keySpans(of: mapping, lines: lines) else { return false }
    guard let span = spans.first(where: { $0.key.hasSameBytes(as: key) }) else { return true }
    // The composer copies an alias's node, anchor and all, so an alias reads as an anchor here.
    for (name, value) in mapping where name.string.map({ $0.hasSameBytes(as: key) }) == true {
      if Self.hasAnchor(name) || Self.hasAnchor(value) { return false }
    }
    return !YAMLLineScan.hasCommentOrAnchor(lines[span.lines].map { $0.trimmingCharacters(in: .newlines) })
  }

  private static func hasAnchor(_ node: Node) -> Bool {
    if node.anchor != nil { return true }
    switch node {
    case .scalar: return false
    case .alias: return true
    case .mapping(let mapping): return mapping.contains { hasAnchor($0.key) || hasAnchor($0.value) }
    case .sequence(let sequence): return sequence.contains(where: hasAnchor)
    }
  }

  // MARK: Front matter text

  private static func mapping(of yaml: String) throws -> Node.Mapping {
    let root: Node?
    do {
      root = try Yams.compose(yaml: yaml)
    } catch {
      throw DescriptionError.frontMatterUnreadable(String(describing: error))
    }
    guard let root else { return Node.Mapping([]) }
    guard case .mapping(let mapping) = root else {
      throw DescriptionError.frontMatterUnreadable("it isn't a mapping")
    }
    return mapping
  }

  private static func object(of mapping: Node.Mapping) -> JSONObject {
    MemberHash.generalValue(.mapping(mapping)).objectValue ?? JSONObject()
  }

  /// The lines each top-level key occupies, from its key to its value's last line. Comments and
  /// blank lines after that belong to no key and stay.
  ///
  /// The parser finds the keys, so a line in a multi-line scalar can't be taken for one.
  private static func keySpans(
    of mapping: Node.Mapping, lines: [String]
  ) throws -> [(key: String, lines: Range<Int>)] {
    guard mapping.style != .flow else {
      throw DescriptionError.frontMatterNotEditable("the block is a flow mapping")
    }
    var starts: [(key: String, line: Int)] = []
    for (key, _) in mapping {
      guard let mark = key.mark, mark.column == 1, let name = key.string else {
        throw DescriptionError.frontMatterNotEditable("a top-level key isn't at the start of its line")
      }
      starts.append((name, mark.line - 1))
    }
    return starts.enumerated().map { index, start in
      var end = index + 1 < starts.count ? starts[index + 1].line : lines.count
      while end > start.line + 1 {
        let line = lines[end - 1]
        guard line.hasPrefix("#") || line.allSatisfy(\.isWhitespace) else { break }
        end -= 1
      }
      return (start.key, start.line..<end)
    }
  }

  /// `key: value`, ending in a line break.
  private static func rendered(_ key: String, _ value: JSONValue, lineBreak: String) throws -> String {
    let yaml: String
    do {
      yaml = try Yams.serialize(
        node: .mapping(Node.Mapping([(node(for: .string(key)), node(for: value))])), width: -1, allowUnicode: true)
    } catch {
      throw DescriptionError.frontMatterNotEditable(String(describing: error))
    }
    return lineBreak == "\n" ? yaml : yaml.replacingOccurrences(of: "\n", with: lineBreak)
  }

  private static func node(for value: JSONValue) -> Node {
    switch value {
    case .null: return Node("null", Tag(.null))
    case .bool(let flag): return Node(flag ? "true" : "false", Tag(.bool))
    case .number(let literal): return Node(literal, Tag(Int64(literal) == nil ? .float : .int))
    // Yams quotes a string that would otherwise read as something else.
    case .string(let text): return .scalar(text.represented())
    case .array(let items): return .sequence(Node.Sequence(items.map(node(for:))))
    case .object(let object):
      return .mapping(Node.Mapping(object.entries.map { (node(for: .string($0.key)), node(for: $0.value)) }))
    }
  }

  /// A value as ``object`` would read it back: a plain number that isn't an integer is text.
  private static func asRead(_ value: JSONValue) -> JSONValue {
    switch value {
    case .number(let literal): return Int64(literal) == nil ? .string(literal) : value
    case .array(let items): return .array(items.map(asRead))
    case .object(let object):
      var result = JSONObject()
      for entry in object.entries { result[entry.key] = asRead(entry.value) }
      return .object(result)
    default: return value
    }
  }

  private static func linesKeepingBreaks(_ text: String) -> [String] {
    var lines: [String] = []
    var current = ""
    for character in text {
      current.append(character)
      if character == "\n" || character == "\r\n" {
        lines.append(current)
        current = ""
      }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
  }
}

/// Finds YAML comments, anchors and aliases in a key's lines, for
/// ``FrontMatterEditor/isEditable(_:)``.
///
/// Yams drops comments and resolves aliases, so the lines are read here. The scan follows quoted
/// scalars (across lines), block scalars and flow collections, and errs toward finding something:
/// a line of a multi-line plain scalar that starts with `*` or `&` reads as an alias or anchor, so
/// the key reads as not editable. It never misses a `#` comment, which YAML defines as a `#` at the
/// start of a line or after whitespace, outside a quoted or block scalar.
private enum YAMLLineScan {
  /// The lines, without their line breaks.
  static func hasCommentOrAnchor(_ lines: [String]) -> Bool {
    var quote: Character?
    var flowDepth = 0
    // While set, lines indented more than this, and blank lines, are a block scalar's text.
    var blockScalarOwnerIndent: Int?
    for line in lines {
      let characters = Array(line)
      let indent = characters.prefix { $0 == " " }.count
      if let owner = blockScalarOwnerIndent {
        if characters.allSatisfy(\.isWhitespace) || indent > owner { continue }
        blockScalarOwnerIndent = nil
      }
      var atNodeStart = quote == nil
      var afterSpace = true
      var index = 0
      while index < characters.count {
        let character = characters[index]
        let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
        let nextIsSpace = next == nil || next == " " || next == "\t"
        index += 1
        if let open = quote {
          if open == "\"", character == "\\" {
            index += 1
          } else if character == open {
            if open == "'", next == "'" {
              index += 1
            } else {
              quote = nil
            }
          }
          afterSpace = false
          continue
        }
        if character == " " || character == "\t" {
          afterSpace = true
          continue
        }
        defer { afterSpace = false }
        if character == "#", afterSpace { return true }
        if atNodeStart {
          switch character {
          case "&", "*":
            if !nextIsSpace { return true }
          case "'", "\"":
            quote = character
            atNodeStart = false
            continue
          case "-", "?", ":":
            if nextIsSpace { continue }
          case "[", "{":
            flowDepth += 1
            continue
          case "|", ">":
            if flowDepth == 0 {
              blockScalarOwnerIndent = indent
              atNodeStart = false
              continue
            }
          case "!":
            // A tag: the node starts after it.
            while index < characters.count, characters[index] != " ", characters[index] != "\t" { index += 1 }
            continue
          default:
            break
          }
        }
        if flowDepth > 0 {
          switch character {
          case ",":
            atNodeStart = true
            continue
          case "[", "{":
            flowDepth += 1
            atNodeStart = true
            continue
          case "]", "}":
            flowDepth -= 1
            atNodeStart = false
            continue
          default:
            break
          }
        }
        if character == ":", nextIsSpace || (flowDepth > 0 && next.map { ",]}".contains($0) } == true) {
          atNodeStart = true
          continue
        }
        atNodeStart = false
      }
    }
    return false
  }
}
