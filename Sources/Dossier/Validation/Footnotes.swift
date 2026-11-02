import DossierCore
import Foundation

/// §9.3's check of `CHARACTER.md`'s footnotes.
enum Footnotes {
  /// §9.3's classes. The format has no data file for these.
  private static let classes = ["Stated", "Inferred", "Author"]

  /// The labels referenced with no definition, defined with no reference, and defined without one
  /// of §9.3's classes, each sorted. The last isn't `W-FOOTNOTE`, which §14 keeps for the other two.
  ///
  /// SPEC-GAP: §9.3: the text doesn't say a footnote in a code block or code span isn't one.
  /// Markdown's rule is followed, as §9.2's headings do. A definition's own text can hold a
  /// reference, which counts.
  static func check(body: String) -> (undefined: [String], unused: [String], unclassified: [String]) {
    var references: Set<String> = []
    var definitions: Set<String> = []
    var unclassified: Set<String> = []
    var fence = CodeFence()
    for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      if fence.isCode(rawLine) { continue }
      let line = removingCodeSpans(Array(rawLine.utf8))
      let indent = line.prefix { $0 == 0x20 }.count
      var searchFrom = 0
      if indent <= 3, let (label, end) = label(in: line, at: indent), end < line.count, line[end] == 0x3A {
        definitions.insert(label)
        searchFrom = end + 1
        if !hasClass(line[(end + 1)...]) { unclassified.insert(label) }
      }
      var index = searchFrom
      while index < line.count {
        if line[index] == 0x5C {
          index += 2
        } else if let (label, end) = label(in: line, at: index) {
          references.insert(label)
          index = end
        } else {
          index += 1
        }
      }
    }
    return (
      references.subtracting(definitions).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) },
      definitions.subtracting(references).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) },
      unclassified.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    )
  }

  /// One piece of a line, as the page reads it.
  enum Segment {
    /// Text that holds no reference.
    case text(String)
    /// `[^label]`, and how it's written.
    case reference(label: String, written: String)
  }

  /// A line cut at its references, by the rule ``check(body:)`` reads them with: a code span and a
  /// backslash-escaped character hold none. Joined, the pieces are the line.
  static func segments(ofLine text: String) -> [Segment] {
    let line = Array(text.utf8)
    var segments: [Segment] = []
    var start = 0
    func flush(upTo end: Int) {
      if end > start { segments.append(.text(String(decoding: line[start..<end], as: UTF8.self))) }
    }
    var index = 0
    while index < line.count {
      if line[index] == 0x5C {
        index += 2
      } else if line[index] == 0x60 {
        index = endOfCodeSpan(in: line, at: index)
      } else if let (label, end) = label(in: line, at: index) {
        flush(upTo: index)
        segments.append(.reference(label: label, written: String(decoding: line[index..<end], as: UTF8.self)))
        index = end
        start = end
      } else {
        index += 1
      }
    }
    flush(upTo: line.count)
    return segments
  }

  /// Where to go on from a backtick: past its code span, or past the run when it closes nothing.
  private static func endOfCodeSpan(in line: [UInt8], at index: Int) -> Int {
    func run(at start: Int) -> Int {
      var end = start
      while end < line.count, line[end] == 0x60 { end += 1 }
      return end - start
    }
    let length = run(at: index)
    var search = index + length
    while search < line.count {
      if line[search] == 0x60 {
        let other = run(at: search)
        if other == length { return search + length }
        search += other
      } else {
        search += 1
      }
    }
    return index + length
  }

  /// A body's definitions and the references outside them, each in file order.
  ///
  /// The body is read a line at a time, by the rules ``check(body:)`` reads it with.
  static func scan(body: String) -> (definitions: [(label: String, text: String)], references: [String]) {
    var definitions: [(label: String, text: String)] = []
    var references: [String] = []
    var fence = CodeFence()
    for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      if fence.isCode(rawLine) { continue }
      let bytes = Array(rawLine.utf8)
      let indent = bytes.prefix { $0 == 0x20 }.count
      if indent <= 3, let (label, end) = label(in: bytes, at: indent), end < bytes.count, bytes[end] == 0x3A {
        let text = String(decoding: bytes[(end + 1)...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        definitions.append((label, text))
        continue
      }
      for segment in segments(ofLine: String(rawLine)) {
        if case .reference(let label, _) = segment { references.append(label) }
      }
    }
    return (definitions, references)
  }

  /// The `<class>` a definition's text starts with, when it's one of §9.3's.
  static func leadingClass(of text: String) -> String? {
    let bytes = Array(text.utf8)[...]
    guard hasClass(bytes), let dot = bytes.firstIndex(of: 0x2E) else { return nil }
    return String(decoding: bytes[..<dot], as: UTF8.self).trimmingCharacters(in: .whitespaces)
  }

  /// Whether a line is a footnote's definition, by the rule ``check(body:)`` reads them with.
  static func isDefinition(_ line: some StringProtocol) -> Bool {
    let bytes = Array(line.utf8)
    let indent = bytes.prefix { $0 == 0x20 }.count
    guard indent <= 3, let (_, end) = label(in: bytes, at: indent), end < bytes.count else { return false }
    return bytes[end] == 0x3A
  }

  /// Whether a definition's text starts with `<class>.`.
  private static func hasClass(_ text: ArraySlice<UInt8>) -> Bool {
    let start = text.drop { $0 == 0x20 || $0 == 0x09 }
    guard let dot = start.firstIndex(of: 0x2E) else { return false }
    let word = String(decoding: start[start.startIndex..<dot], as: UTF8.self)
    return classes.contains { $0.hasSameBytes(as: word) }
  }

  /// `[^label]` at an offset, and the offset after it.
  private static func label(in line: [UInt8], at index: Int) -> (String, Int)? {
    guard index + 1 < line.count, line[index] == 0x5B, line[index + 1] == 0x5E else { return nil }
    var end = index + 2
    while end < line.count, line[end] != 0x5D {
      if line[end] == 0x20 || line[end] == 0x09 { return nil }
      end += 1
    }
    guard end < line.count, end > index + 2 else { return nil }
    return (String(decoding: line[(index + 2)..<end], as: UTF8.self), end + 1)
  }

  /// The line without its code spans: a run of backticks up to the next run of the same length.
  private static func removingCodeSpans(_ line: [UInt8]) -> [UInt8] {
    guard line.contains(0x60) else { return line }
    var result: [UInt8] = []
    var index = 0
    func run(at start: Int) -> Int {
      var end = start
      while end < line.count, line[end] == 0x60 { end += 1 }
      return end - start
    }
    while index < line.count {
      guard line[index] == 0x60 else {
        result.append(line[index])
        index += 1
        continue
      }
      let length = run(at: index)
      var search = index + length
      var close: Int?
      while search < line.count {
        if line[search] == 0x60 {
          let other = run(at: search)
          if other == length {
            close = search
            break
          }
          search += other
        } else {
          search += 1
        }
      }
      if let close {
        index = close + length
      } else {
        result.append(contentsOf: line[index..<(index + length)])
        index += length
      }
    }
    return result
  }
}
