import DossierCore
import Foundation

/// `template/README.md`'s substitution and escaping.
enum PageText {
  /// *Text*: `&`, `<`, `>`, `"` and `'` escaped.
  static func escaped(_ text: String) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(text.utf8.count)
    for byte in text.utf8 { appendEscaped(byte, to: &out) }
    return String(decoding: out, as: UTF8.self)
  }

  static func appendEscaped(_ byte: UInt8, to out: inout [UInt8]) {
    switch byte {
    case 0x26: out.append(contentsOf: "&amp;".utf8)
    case 0x3C: out.append(contentsOf: "&lt;".utf8)
    case 0x3E: out.append(contentsOf: "&gt;".utf8)
    case 0x22: out.append(contentsOf: "&quot;".utf8)
    case 0x27: out.append(contentsOf: "&#x27;".utf8)
    default: out.append(byte)
    }
  }

  /// `{{name}}` replaced left to right, in one pass, so replacement text isn't scanned again.
  ///
  /// - Throws: ``DossierCore/DossierError/resourceUnreadable(_:)`` for a placeholder with no value,
  ///   which only a template this renderer doesn't match can have.
  static func filling(_ template: String, _ values: [String: String]) throws -> String {
    let bytes = Array(template.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count + values.values.reduce(0) { $0 + $1.utf8.count })
    let brace: (open: UInt8, close: UInt8) = (0x7B, 0x7D)
    var index = 0
    while index < bytes.count {
      if bytes[index] == brace.open, index + 1 < bytes.count, bytes[index + 1] == brace.open {
        var end = index + 2
        while end < bytes.count, bytes[end] != brace.open, bytes[end] != brace.close { end += 1 }
        if end > index + 2, end + 1 < bytes.count, bytes[end] == brace.close, bytes[end + 1] == brace.close {
          let name = String(decoding: bytes[(index + 2)..<end], as: UTF8.self)
          guard let value = values[name] else {
            throw DossierError.resourceUnreadable("template: no value for {{\(name)}}")
          }
          out.append(contentsOf: value.utf8)
          index = end + 2
          continue
        }
      }
      out.append(bytes[index])
      index += 1
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// `fragments.html`: each `<!-- fragment: name -->` line and the markup under it.
  static func fragments(in text: String) -> [String: String] {
    var found: [String: String] = [:]
    var name: String?
    var lines: [Substring] = []
    func close() {
      guard let name else { return }
      var body = lines.joined(separator: "\n")
      while body.hasSuffix("\n") { body.removeLast() }
      found[name] = body
    }
    let opening = "<!-- fragment: "
    let closing = " -->"
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix(opening), line.hasSuffix(closing) {
        close()
        name = String(line.dropFirst(opening.count).dropLast(closing.count))
        lines = []
      } else {
        lines.append(line)
      }
    }
    close()
    return found
  }
}

/// The footnotes of a `CHARACTER.md` body as the page shows them (field rule 2, §9.3): a definition
/// never cited comes after those that are, in file order, and a reference with no definition stays
/// plain text.
struct PageFootnotes {
  private let definitions: [(label: String, text: String)]
  private let numbers: [String: Int]

  /// `page.sources`, in order: the class, then the text.
  let sources: [String]

  /// SPEC-GAP: field rule 2: two definitions of one label aren't covered. It says one item per
  /// definition, so both are shown, side by side; a mark's number is the first's.
  ///
  /// A reference inside a definition's own text isn't a citation: nothing marks it, as a definition
  /// is shown only in `page.sources`.
  init(body: String) {
    let scan = Footnotes.scan(body: body)
    definitions = scan.definitions
    var ordered: [(label: String, text: String)] = []
    var placed: Set<[UInt8]> = []
    func place(_ label: String, from definitions: [(label: String, text: String)]) {
      guard placed.insert(Array(label.utf8)).inserted else { return }
      ordered += definitions.filter { $0.label.hasSameBytes(as: label) }
    }
    for label in scan.references where scan.definitions.contains(where: { $0.label.hasSameBytes(as: label) }) {
      place(label, from: scan.definitions)
    }
    for definition in scan.definitions { place(definition.label, from: scan.definitions) }
    sources = ordered.map(\.text)
    var numbers: [String: Int] = [:]
    for (position, definition) in ordered.enumerated() where numbers[definition.label] == nil {
      numbers[definition.label] = position + 1
    }
    self.numbers = numbers
  }

  /// A mark's number, or `nil` for a reference with no definition.
  func number(of label: String) -> Int? { numbers[label] }

  /// The class of a footnote (§9.3), or `nil` when it has no definition or none of §9.3's classes.
  func footnoteClass(of label: String) -> String? {
    guard let text = definitions.first(where: { $0.label.hasSameBytes(as: label) })?.text else { return nil }
    return Footnotes.leadingClass(of: text)
  }
}

/// Rule 3's Markdown, with footnote references as marks (rule 4).
struct PageMarkdown {
  enum Block {
    case heading([Line])
    /// A list item, and the quote directly after its text, which is part of it (rule 3).
    case item([Line], quote: [Line]?)
    case paragraph([Line])
    case quote([Line])

    /// The block's own text: not an item's quote, which `**` and `*` don't span into.
    var lines: [Line] {
      switch self {
      case .heading(let lines), .item(let lines, _), .paragraph(let lines), .quote(let lines): return lines
      }
    }

    /// The text and the quote of an item, in order.
    var allLines: [Line] {
      if case .item(let lines, let quote?) = self { return lines + quote }
      return lines
    }
  }

  /// One line of a block. A line in a code fence holds no references (§9.3, as `W-FOOTNOTE` reads it).
  struct Line {
    let text: String
    let isCode: Bool
  }

  let footnotes: PageFootnotes
  /// The `mark` fragment for a number.
  let mark: (Int) throws -> String
  /// The `markSeparator` fragment, for two marks with nothing between them (rule 4).
  let markSeparator: () throws -> String

  /// A section's text as blocks. A footnote's definition isn't text here: it's shown only in
  /// `page.sources` (field rule 2). Rule 3 has no code fences, so a fence is literal text and its
  /// lines are read like any others. All a fence changes is that it holds no definitions or
  /// references (§9.3).
  static func blocks(of content: String) -> [Block] {
    var found: [Block] = []
    var paragraph: [Line] = []
    /// The list item, and that item's quote, that a line break continues (rule 3).
    var item: [Line]?
    var itemQuote: [Line]?
    /// The top-level quote that a line break continues.
    var quote: [Line]?
    func flush() {
      if let open = item { found.append(.item(open, quote: itemQuote)) }
      item = nil
      itemQuote = nil
      if let open = quote { found.append(.quote(open)) }
      quote = nil
      if !paragraph.isEmpty { found.append(.paragraph(paragraph)) }
      paragraph = []
    }
    var fence = CodeFence()
    for rawLine in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let line = String(rawLine)
      let isCode = fence.isCode(line)
      if !isCode, Footnotes.isDefinition(line) {
        if item != nil || quote != nil { flush() }
        continue
      }
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      let text = Line(text: trimmed, isCode: isCode)
      if trimmed.isEmpty || isRule(line) {
        flush()
      } else if line.hasPrefix("### ") {
        flush()
        found.append(.heading([Line(text: String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines), isCode: isCode)]))
      } else if line.hasPrefix("- ") {
        flush()
        item = [Line(text: String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines), isCode: isCode)]
      } else if let content = quoteContent(of: line) {
        let held = Line(text: content, isCode: isCode)
        if item != nil {
          itemQuote = (itemQuote ?? []) + [held]
        } else if quote != nil {
          quote?.append(held)
        } else {
          flush()
          quote = [held]
        }
      } else if itemQuote != nil {
        itemQuote?.append(text)
      } else if quote != nil {
        quote?.append(text)
      } else if item != nil {
        item?.append(text)
      } else {
        paragraph.append(text)
      }
    }
    flush()
    return found
  }

  /// A line that is only `---`, spaces aside (rule 3).
  private static func isRule(_ line: String) -> Bool {
    let start = line.drop { $0 == " " }
    var rest = start
    while rest.last == " " { rest.removeLast() }
    return rest == "---"
  }

  /// What a quote line holds, or `nil` when the line isn't one: its first non-space character is
  /// `>` (rule 3).
  private static func quoteContent(of line: String) -> String? {
    let start = line.drop { $0 == " " }
    guard start.first == ">" else { return nil }
    return start.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Whether a section's text, once its definitions are gone, has anything but whitespace.
  static func hasText(_ content: String) -> Bool { !blocks(of: content).isEmpty }

  /// Blocks as markup.
  func markup(_ blocks: [Block]) throws -> String {
    var out = ""
    var inList = false
    for block in blocks {
      var isItem = false
      if case .item = block { isItem = true }
      if isItem, !inList { out += "<ul>" }
      if !isItem, inList { out += "</ul>" }
      inList = isItem
      switch block {
      case .heading(let lines): out += "<h4>\(try inline(lines))</h4>"
      case .item: out += "<li>\(try content(of: block))</li>"
      case .paragraph: out += "<p>\(try content(of: block))</p>"
      case .quote: out += try content(of: block)
      }
    }
    if inList { out += "</ul>" }
    return out
  }

  /// Field rule 1's items: each paragraph, list item or top-level quote, with the classes of the
  /// footnotes it cites, quote included.
  func canonItems(_ blocks: [Block]) throws -> [(text: String, source: String)] {
    try blocks.compactMap { block in
      if case .heading = block { return nil }
      var classes: [String] = []
      for line in block.allLines where !line.isCode {
        for segment in Footnotes.segments(ofLine: line.text) {
          if case .reference(let label, _) = segment, let found = footnotes.footnoteClass(of: label) {
            classes.append(found)
          }
        }
      }
      return (try content(of: block), classes.joined(separator: ", "))
    }
  }

  /// A paragraph's or an item's markup, or a quote's whole element. An item's quote comes after its
  /// text, and each is inline text of its own, so no pair of delimiters joins them (rule 3).
  private func content(of block: Block) throws -> String {
    switch block {
    case .heading(let lines), .paragraph(let lines), .item(let lines, quote: nil):
      return try inline(lines)
    case .item(let lines, let quote?):
      return try inline(lines) + "<blockquote>\(try inline(quote))</blockquote>"
    case .quote(let lines):
      return "<blockquote>\(try inline(lines))</blockquote>"
    }
  }

  /// Text with `**bold**`, `*emphasis*` and marks. Held as bytes and, below zero, mark numbers, so
  /// a mark's markup and the escaped text can't be read as delimiters. Everything else is literal,
  /// and a Markdown link stays as text (rule 3).
  func inline(_ lines: [Line]) throws -> String {
    var tokens: [Int32] = []
    for (index, line) in lines.enumerated() {
      if index > 0 { tokens.append(0x0A) }
      if line.isCode {
        append(line.text, to: &tokens)
        continue
      }
      for segment in Footnotes.segments(ofLine: line.text) {
        switch segment {
        case .text(let text):
          append(text, to: &tokens)
        case .reference(let label, let written):
          if let number = footnotes.number(of: label) {
            tokens.append(Int32(-number))
          } else {
            append(written, to: &tokens)
          }
        }
      }
    }
    tokens = Self.applying(delimiter: 2, opening: "<strong>", closing: "</strong>", to: tokens)
    tokens = Self.applying(delimiter: 1, opening: "<em>", closing: "</em>", to: tokens)

    var out: [UInt8] = []
    out.reserveCapacity(tokens.count)
    var previous: Int32 = 0
    for token in tokens {
      if token >= 0 {
        out.append(UInt8(token))
      } else {
        if previous < 0 { out.append(contentsOf: try markSeparator().utf8) }
        out.append(contentsOf: try mark(Int(-token)).utf8)
      }
      previous = token
    }
    return String(decoding: out, as: UTF8.self)
  }

  private func append(_ text: String, to tokens: inout [Int32]) {
    var escaped: [UInt8] = []
    for byte in text.utf8 { PageText.appendEscaped(byte, to: &escaped) }
    tokens.append(contentsOf: escaped.map(Int32.init))
  }

  /// Pairs of a run of `*`, nearest first, with at least one token between. A pair may span a line
  /// break in its block (rule 3).
  private static func applying(delimiter length: Int, opening: String, closing: String, to tokens: [Int32]) -> [Int32] {
    let star: Int32 = 0x2A
    func isDelimiter(at index: Int) -> Bool {
      index + length <= tokens.count && tokens[index..<(index + length)].allSatisfy { $0 == star }
    }
    var out: [Int32] = []
    out.reserveCapacity(tokens.count)
    var index = 0
    while index < tokens.count {
      if isDelimiter(at: index) {
        var found: Int?
        var search = index + length
        while search < tokens.count {
          if search > index + length, isDelimiter(at: search) {
            found = search
            break
          }
          search += 1
        }
        if let found {
          out.append(contentsOf: opening.utf8.map(Int32.init))
          out.append(contentsOf: tokens[(index + length)..<found])
          out.append(contentsOf: closing.utf8.map(Int32.init))
          index = found + length
          continue
        }
      }
      out.append(tokens[index])
      index += 1
    }
    return out
  }
}
