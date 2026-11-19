import DossierCore
import Foundation

/// Replaces or adds one `##` section of a description's body, leaving every other byte as it was
/// (SFV-5). ``CharacterDescription`` and ``LocationDescription`` share it.
///
/// The body is read as lines that keep their own line breaks, so the ranges below are ranges of the
/// original text. A heading is found by the same rule as `CharacterDocument`'s reader: a line
/// starting `## ` outside a fenced code block, with the heading text trimmed.
enum SectionEditor {
  /// One `##` section, as line indices into the body.
  struct Span {
    /// The heading, without `## `, as the reader gives it.
    let heading: String
    /// The heading line.
    let headingLine: Int
    /// The lines after the heading, up to the next heading or the end of the body.
    let content: Range<Int>
  }

  /// The body's lines, each with its line break. The last has none when the body doesn't end in one.
  static func lines(of body: String) -> [Substring] {
    var lines: [Substring] = []
    var start = body.startIndex
    var index = body.startIndex
    while index < body.endIndex {
      let next = body.index(after: index)
      if body[index].isNewline {
        lines.append(body[start..<next])
        start = next
      }
      index = next
    }
    if start < body.endIndex { lines.append(body[start...]) }
    return lines
  }

  /// Every `##` section, in file order.
  static func spans(of lines: [Substring]) -> [Span] {
    var headings: [(heading: String, line: Int)] = []
    var fence = CodeFence()
    for (number, line) in lines.enumerated() {
      let text = withoutBreak(line)
      if !fence.isCode(text), text.hasPrefix("## ") {
        headings.append((text.dropFirst(3).trimmingCharacters(in: .whitespaces), number))
      }
    }
    return headings.enumerated().map { index, heading in
      let end = index + 1 < headings.count ? headings[index + 1].line : lines.count
      return Span(heading: heading.heading, headingLine: heading.line, content: (heading.line + 1)..<end)
    }
  }

  /// The body with the first section named `name` given `content`, or with a new section when
  /// there's none.
  ///
  /// - Parameters:
  ///   - order: The format's section order. A new section goes after the nearest earlier section
  ///     in this order that the body has, else before the first later one, else at the end. `nil`,
  ///     or a name not in it, puts a new section at the end.
  static func setting(_ name: String, to content: String, in body: String, order: [String]?) -> String {
    var lines = lines(of: body)
    let lineBreak = body.contains("\r\n") ? "\r\n" : "\n"
    let newLines = contentLines(content, lineBreak: lineBreak)
    let spans = spans(of: lines)
    let firstSection = { (name: String) in spans.first { CharacterDocument.heading($0.heading, matches: name) } }

    if let span = firstSection(name) {
      let old = Array(lines[span.content])
      let isLast = span.content.upperBound == lines.count
      let followed = !isLast
      let isBlank = { (line: Substring) in line.allSatisfy(\.isWhitespace) }
      // The blank lines just under the heading and just above the next one stay, so the section
      // keeps its separation from its neighbours.
      let lead: [Substring]
      let trail: [Substring]
      if old.allSatisfy(isBlank) {
        lead = old
        trail = followed ? old : []
      } else {
        lead = Array(old.prefix(while: isBlank))
        trail = Array(old.reversed().prefix(while: isBlank).reversed())
      }
      var replacement: [Substring]
      if newLines.isEmpty {
        replacement = old.allSatisfy(isBlank) ? old : (trail.isEmpty ? lead : trail)
      } else {
        replacement = lead + newLines + trail
        // A body that ended without a line break still does.
        if isLast, trail.isEmpty, let last = old.last, withoutBreak(last) == last {
          replacement[replacement.count - 1] = withoutBreak(replacement[replacement.count - 1])
        }
        // A heading on the body's last line, with no break, gets one before the new text.
        let heading = lines[span.headingLine]
        if withoutBreak(heading) == heading {
          lines[span.headingLine] = Substring(heading + lineBreak)
        }
      }
      lines.replaceSubrange(span.content, with: replacement)
      return lines.joined()
    }

    var position = lines.count
    if let order, let target = order.firstIndex(where: { $0.hasSameBytes(as: name) }) {
      if let earlier = order[..<target].reversed().lazy.compactMap(firstSection).first {
        position = earlier.content.upperBound
      } else if let later = order[(target + 1)...].lazy.compactMap(firstSection).first {
        position = later.headingLine
      }
    }

    var block: [Substring] = ["## \(name)\(lineBreak)"]
    if !newLines.isEmpty { block += [Substring(lineBreak)] + newLines }
    if position < lines.count {
      block.append(Substring(lineBreak))
    } else if let last = lines.last {
      // At the end: the text before ends its line and is followed by a blank line.
      if withoutBreak(last) == last { lines[lines.count - 1] = Substring(last + lineBreak) }
      if !lines[lines.count - 1].allSatisfy(\.isWhitespace) { block.insert(Substring(lineBreak), at: 0) }
    }
    lines.insert(contentsOf: block, at: position)
    return lines.joined()
  }

  /// The caller's text as lines, without leading or trailing blank lines, each ending in the
  /// body's line break.
  private static func contentLines(_ content: String, lineBreak: String) -> [Substring] {
    let all = content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    let isBlank = { (line: Substring) in line.allSatisfy(\.isWhitespace) }
    guard let first = all.firstIndex(where: { !isBlank($0) }), let last = all.lastIndex(where: { !isBlank($0) })
    else { return [] }
    return all[first...last].map { Substring($0 + lineBreak) }
  }

  private static func withoutBreak(_ line: Substring) -> Substring {
    guard let last = line.last, last.isNewline else { return line }
    return line.dropLast()
  }
}
