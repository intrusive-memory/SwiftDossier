import Foundation
import Yams

/// Splits a YAML front-matter block from the text after it.
///
/// The same rules as Reparto's parser, which keeps its splitter internal: the first
/// line is a `---` line (trailing spaces and tabs allowed, LF or CRLF), and the block
/// ends at the first such line after it. No closing line means no front matter.
package enum FrontMatter {
  /// The block's YAML and the text after it, or `nil` when there is no block.
  package static func split(_ text: String) -> (yaml: String, body: String)? {
    let bytes = Array(text.utf8)
    func lineEnd(from start: Int) -> (content: Int, next: Int)? {
      guard start < bytes.count else { return nil }
      var cursor = start
      while cursor < bytes.count, bytes[cursor] != 0x0A { cursor += 1 }
      if cursor == bytes.count { return (cursor, cursor) }
      let content = cursor > start && bytes[cursor - 1] == 0x0D ? cursor - 1 : cursor
      return (content, cursor + 1)
    }
    func isDelimiter(_ start: Int, _ end: Int) -> Bool {
      guard end - start >= 3, bytes[start..<(start + 3)].allSatisfy({ $0 == 0x2D }) else {
        return false
      }
      return bytes[(start + 3)..<end].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }
    guard let opening = lineEnd(from: 0), isDelimiter(0, opening.content),
      opening.next > opening.content
    else { return nil }
    var start = opening.next
    while let line = lineEnd(from: start) {
      if isDelimiter(start, line.content) {
        return (
          String(decoding: bytes[opening.next..<start], as: UTF8.self),
          String(decoding: bytes[line.next...], as: UTF8.self)
        )
      }
      start = line.next
    }
    return nil
  }
}

/// `CHARACTER.md`, read as far as staleness and completeness need (§9).
///
/// Internal to the package. The public reader and writer of this file are
/// `CharacterDescription`, in the `Dossier` target.
package struct CharacterDocument: Sendable {
  /// §9.2's sections 1 to 9. The format has no data file for these.
  package static let fullSections = [
    "Logline", "Appearance", "Personality", "Backstory", "Arc", "Relationships", "Voice & Speech",
    "Pronunciation", "Wardrobe",
  ]
  /// §9.2's short set.
  package static let shortSections = ["Logline", "Appearance", "Voice & Speech"]

  package let frontMatterYAML: String?
  package let body: String
  /// Every `##` section, in file order: its heading text and its contents.
  package let sections: [(heading: String, content: String)]

  package init(text: String) {
    if let split = FrontMatter.split(text) {
      frontMatterYAML = split.yaml
      body = split.body
    } else {
      frontMatterYAML = nil
      body = text
    }
    sections = Self.parseSections(body)
  }

  /// A front-matter key's scalar text. `nil` when it's absent, null, not a scalar, or
  /// when the front matter doesn't parse, which is reported as such elsewhere.
  package func frontMatterText(_ key: String) -> String? {
    guard let yaml = frontMatterYAML, let root = try? Yams.compose(yaml: yaml),
      case .mapping(let mapping) = root, case .scalar(let scalar)? = mapping[key]
    else { return nil }
    if scalar.style == .plain, MemberHash.isNullText(scalar.string) { return nil }
    return scalar.string
  }

  /// Whether a section by this name exists: the exact name, optionally followed by a
  /// space and a parenthetical (§9.2).
  package func hasSection(_ name: String) -> Bool {
    sections.contains { Self.heading($0.heading, matches: name) }
  }

  /// Whether a section by this name has anything but whitespace in it.
  ///
  /// SPEC-GAP: §8.3: "non-empty" isn't defined further. Footnote definitions written
  /// under a section count as its text, which only matters for a last section.
  package func hasNonEmptySection(_ name: String) -> Bool {
    sections.contains {
      Self.heading($0.heading, matches: name)
        && !$0.content.allSatisfy { $0.isWhitespace }
    }
  }

  private static func heading(_ heading: String, matches name: String) -> Bool {
    if heading.hasSameBytes(as: name) { return true }
    return heading.hasPrefix(name + " (") && heading.hasSuffix(")")
  }

  // SPEC-GAP: §9.2: the text doesn't say a `##` line inside a fenced code block isn't a
  // heading. Markdown's rule is followed, so a fenced example can't satisfy a tier.
  private static func parseSections(_ body: String) -> [(heading: String, content: String)] {
    var result: [(heading: String, content: String)] = []
    var fence: Character?
    for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = String(rawLine)
      let trimmed = line.drop { $0 == " " }
      if let marker = trimmed.first, marker == "`" || marker == "~", trimmed.hasPrefix(String(repeating: marker, count: 3)) {
        if fence == nil {
          fence = marker
        } else if fence == marker {
          fence = nil
        }
      }
      if fence == nil, line.hasPrefix("## ") {
        let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        result.append((heading, ""))
      } else if !result.isEmpty {
        result[result.count - 1].content += line + "\n"
      }
    }
    return result
  }
}
