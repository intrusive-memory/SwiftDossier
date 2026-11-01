/// §11's `W-PAGE-EXTERNAL`: a page's references, read as HTML.
///
/// A tokenizer rather than a search, because comments, text and `<script>` contents aren't
/// searched, and because a `data:` URI can hold anything.
enum PageReferences {
  /// A reference §11 doesn't allow.
  struct External: Equatable {
    /// The element, lowercased.
    let element: String
    /// The attribute, or `style` for what came from a `<style>` element.
    let source: String
    /// The reference as written, with HTML's and CSS's escapes decoded.
    let value: String
  }

  private static let urlAttributes: Set<String> = [
    "src", "href", "xlink:href", "poster", "data", "action", "formaction", "background",
  ]
  /// Elements whose contents HTML reads as text, so a `<` in them doesn't open a tag.
  ///
  /// SPEC-GAP: §11: a `<script>` holding `<!-- <script>` has HTML's double-escaped state,
  /// which isn't followed. Such a script ends early and the rest is searched, which can only
  /// add a warning. `<noscript>` is read as markup, the reading that searches it.
  private static let textElements: Set<String> = [
    "script", "style", "title", "textarea", "xmp", "iframe", "noembed", "noframes",
  ]

  /// Everything in a page that §11 reports.
  static func external(in page: [UInt8]) -> [External] {
    page.withUnsafeBufferPointer { bytes in
      var scan = HTMLScan(bytes: bytes)
      return scan.run()
    }
  }

  /// Whether §11 allows a reference.
  static func isAllowed(_ value: String, element: String, attribute: String) -> Bool {
    let trimmed = trim(value)
    if trimmed.isEmpty || trimmed.hasPrefix("#") { return true }
    let lowered = trimmed.prefix(8).lowercased()
    if lowered.hasPrefix("data:") { return true }
    guard element == "a", attribute == "href" else { return false }
    return lowered.hasPrefix("http:") || lowered.hasPrefix("https:") || lowered.hasPrefix("mailto:")
  }

  private static func isSpace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
  }

  private static func trim(_ value: String) -> Substring {
    let utf8 = value.utf8
    let start = utf8.firstIndex { !isSpace($0) } ?? utf8.endIndex
    let end = utf8.lastIndex { !isSpace($0) }.map { utf8.index(after: $0) } ?? start
    return value[start..<end]
  }

  /// A `srcset`'s candidate URLs, as HTML's parser splits them: a comma ends a URL only at
  /// its end, so one inside a `data:` URI doesn't split it.
  static func srcsetCandidates(_ value: String) -> [String] {
    let bytes = Array(value.utf8)
    var candidates: [String] = []
    var index = 0
    while true {
      while index < bytes.count, isSpace(bytes[index]) || bytes[index] == 0x2C { index += 1 }
      guard index < bytes.count else { return candidates }
      let start = index
      while index < bytes.count, !isSpace(bytes[index]) { index += 1 }
      var end = index
      if bytes[end - 1] == 0x2C {
        while end > start, bytes[end - 1] == 0x2C { end -= 1 }
      } else {
        var depth = 0
        while index < bytes.count {
          let byte = bytes[index]
          index += 1
          if byte == 0x28 {
            depth += 1
          } else if byte == 0x29, depth > 0 {
            depth -= 1
          } else if byte == 0x2C, depth == 0 {
            break
          }
        }
      }
      candidates.append(String(decoding: bytes[start..<end], as: UTF8.self))
    }
  }

  /// Every `url(...)` and `@import` in a stylesheet or `style` attribute.
  ///
  /// SPEC-GAP: §11: the text doesn't say a CSS comment isn't searched, and says it of HTML's.
  /// It's read as CSS, so a comment or a string that merely holds `url(` isn't a reference.
  static func cssReferences(_ text: String) -> [String] {
    let bytes = Array(text.utf8)
    var found: [String] = []
    var index = 0

    func skipSpaceAndComments() {
      while index < bytes.count {
        if isSpace(bytes[index]) {
          index += 1
        } else if index + 1 < bytes.count, bytes[index] == 0x2F, bytes[index + 1] == 0x2A {
          skipComment()
        } else {
          return
        }
      }
    }
    func skipComment() {
      index += 2
      while index < bytes.count {
        if bytes[index] == 0x2A, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
          index += 2
          return
        }
        index += 1
      }
    }
    /// Reads an escape, with `index` on the `\`, into `out`.
    func readEscape(into out: inout [UInt8]) {
      index += 1
      guard index < bytes.count else { return }
      var scalar: UInt32 = 0
      var digits = 0
      while index < bytes.count, digits < 6, let digit = hexValue(bytes[index]) {
        scalar = scalar * 16 + digit
        digits += 1
        index += 1
      }
      if digits > 0 {
        if index < bytes.count, isSpace(bytes[index]) { index += 1 }
        let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
        out.append(contentsOf: Array(String(character).utf8))
      } else if bytes[index] == 0x0A || bytes[index] == 0x0C {
        index += 1  // a line continuation
      } else {
        out.append(bytes[index])
        index += 1
      }
    }
    /// Reads a string, with `index` on its opening quote.
    func readString() -> String {
      let quote = bytes[index]
      index += 1
      var out: [UInt8] = []
      while index < bytes.count, bytes[index] != quote {
        if bytes[index] == 0x5C {
          readEscape(into: &out)
        } else {
          out.append(bytes[index])
          index += 1
        }
      }
      index += 1
      return String(decoding: out, as: UTF8.self)
    }
    func isNameByte(_ byte: UInt8) -> Bool {
      (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        || byte == 0x2D || byte == 0x5F || byte >= 0x80
    }
    func readName() -> String {
      var out: [UInt8] = []
      while index < bytes.count {
        if bytes[index] == 0x5C {
          readEscape(into: &out)
        } else if isNameByte(bytes[index]) {
          out.append(bytes[index])
          index += 1
        } else {
          break
        }
      }
      return String(decoding: out, as: UTF8.self).lowercased()
    }
    /// Reads a URL's contents, with `index` after the `(`.
    func readURL() -> String {
      while index < bytes.count, isSpace(bytes[index]) { index += 1 }
      guard index < bytes.count else { return "" }
      var value: String
      if bytes[index] == 0x22 || bytes[index] == 0x27 {
        value = readString()
      } else {
        var out: [UInt8] = []
        while index < bytes.count, bytes[index] != 0x29, !isSpace(bytes[index]) {
          if bytes[index] == 0x5C {
            readEscape(into: &out)
          } else {
            out.append(bytes[index])
            index += 1
          }
        }
        value = String(decoding: out, as: UTF8.self)
      }
      while index < bytes.count, bytes[index] != 0x29 { index += 1 }
      index += 1
      value = String(trim(value))
      return value
    }

    while index < bytes.count {
      let byte = bytes[index]
      if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
        skipComment()
      } else if byte == 0x22 || byte == 0x27 {
        _ = readString()
      } else if byte == 0x40 {
        index += 1
        if readName() == "import" {
          skipSpaceAndComments()
          // `@import url(x)` is found by the loop below, as any url() is.
          if index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 {
            found.append(readString())
          }
        }
      } else if byte == 0x5C || (isNameByte(byte) && !(0x30...0x39).contains(byte)) {
        let name = readName()
        if name == "url", index < bytes.count, bytes[index] == 0x28 {
          index += 1
          found.append(readURL())
        }
      } else {
        index += 1
      }
    }
    return found
  }

  private static func hexValue(_ byte: UInt8) -> UInt32? {
    switch byte {
    case 0x30...0x39: return UInt32(byte - 0x30)
    case 0x41...0x46: return UInt32(byte - 0x41 + 10)
    case 0x61...0x66: return UInt32(byte - 0x61 + 10)
    default: return nil
    }
  }

  /// An attribute value with HTML's character references decoded.
  ///
  /// SPEC-GAP: §11: "reads the page as HTML" brings in character references, and the full
  /// named table isn't carried. Numeric references and the ASCII names that can spell a URL
  /// are decoded. Any other name stays as written, so at the start of a value it can only
  /// make the reference disallowed, and report it.
  static func decodingCharacterReferences(_ value: String) -> String {
    guard value.utf8.contains(0x26) else { return value }
    let names: [String: UInt8] = [
      "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27, "colon": 0x3A, "sol": 0x2F,
      "num": 0x23, "lpar": 0x28, "rpar": 0x29, "period": 0x2E, "comma": 0x2C, "commat": 0x40,
      "equals": 0x3D, "quest": 0x3F, "semi": 0x3B, "Tab": 0x09, "NewLine": 0x0A,
    ]
    let bytes = Array(value.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var index = 0
    while index < bytes.count {
      guard bytes[index] == 0x26 else {
        out.append(bytes[index])
        index += 1
        continue
      }
      var cursor = index + 1
      if cursor < bytes.count, bytes[cursor] == 0x23 {
        cursor += 1
        var radix: UInt32 = 10
        if cursor < bytes.count, bytes[cursor] == 0x78 || bytes[cursor] == 0x58 {
          radix = 16
          cursor += 1
        }
        var scalar: UInt32 = 0
        let start = cursor
        while cursor < bytes.count, let digit = hexValue(bytes[cursor]), digit < radix, scalar <= 0x10FFFF {
          scalar = scalar * radix + digit
          cursor += 1
        }
        if cursor > start {
          if cursor < bytes.count, bytes[cursor] == 0x3B { cursor += 1 }
          let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
          out.append(contentsOf: Array(String(character).utf8))
          index = cursor
          continue
        }
      } else {
        while cursor < bytes.count, (0x41...0x5A).contains(bytes[cursor]) || (0x61...0x7A).contains(bytes[cursor]) {
          cursor += 1
        }
        if cursor < bytes.count, bytes[cursor] == 0x3B,
          let byte = names[String(decoding: bytes[(index + 1)..<cursor], as: UTF8.self)]
        {
          out.append(byte)
          index = cursor + 1
          continue
        }
      }
      out.append(bytes[index])
      index += 1
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// HTML's tokenizer, as far as tags and their attributes.
  private struct HTMLScan {
    let bytes: UnsafeBufferPointer<UInt8>
    private var found: [External] = []

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    private struct Tag {
      let name: String
      /// First wins, as in HTML.
      let attributes: [(name: String, value: String)]
      /// The offset after the `>`.
      let end: Int
    }

    mutating func run() -> [External] {
      var index = 0
      let count = bytes.count
      while let open = next(0x3C, from: index) {
        index = open
        let following = byte(index + 1)
        if following == 0x21 {  // <!
          if matches("<!--", at: index) {
            index = commentEnd(from: index + 4)
          } else {
            index = (next(0x3E, from: index + 2) ?? count - 1) + 1
          }
        } else if following == 0x3F {  // <?
          index = (next(0x3E, from: index + 2) ?? count - 1) + 1
        } else if following == 0x2F {  // </
          let afterSlash = byte(index + 2)
          if isLetter(afterSlash) {
            guard let tag = parseTag(from: index + 2) else { return found }
            index = tag.end
          } else if afterSlash == 0x3E {
            index += 3
          } else {
            index = (next(0x3E, from: index + 2) ?? count - 1) + 1
          }
        } else if isLetter(following) {
          // A tag the file ends inside of never existed, as in HTML.
          guard let tag = parseTag(from: index + 1) else { return found }
          report(tag)
          index = tag.end
          if tag.name == "plaintext" { return found }
          if textElements.contains(tag.name) {
            let close = closingTag(of: tag.name, from: index)
            if tag.name == "style" {
              let css = String(decoding: UnsafeBufferPointer(rebasing: bytes[index..<close]), as: UTF8.self)
              reportCSS(css, element: "style")
            }
            index = close
          }
        } else {
          index += 1
        }
      }
      return found
    }

    private mutating func report(_ tag: Tag) {
      for attribute in tag.attributes {
        if attribute.name == "srcset" {
          for candidate in srcsetCandidates(attribute.value)
          where !isAllowed(candidate, element: tag.name, attribute: "srcset") {
            found.append(External(element: tag.name, source: "srcset", value: candidate))
          }
        } else if attribute.name == "style" {
          reportCSS(attribute.value, element: tag.name)
        } else if urlAttributes.contains(attribute.name),
          !isAllowed(attribute.value, element: tag.name, attribute: attribute.name)
        {
          found.append(External(element: tag.name, source: attribute.name, value: attribute.value))
        }
      }
    }

    private mutating func reportCSS(_ css: String, element: String) {
      for reference in cssReferences(css) where !isAllowed(reference, element: element, attribute: "style") {
        found.append(External(element: element, source: "style", value: reference))
      }
    }

    private func byte(_ index: Int) -> UInt8 { index < bytes.count ? bytes[index] : 0 }

    private func next(_ target: UInt8, from start: Int) -> Int? {
      var index = start
      while index < bytes.count {
        if bytes[index] == target { return index }
        index += 1
      }
      return nil
    }

    private func isLetter(_ byte: UInt8) -> Bool {
      (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    /// A case-insensitive match of ASCII text.
    private func matches(_ text: StaticString, at index: Int) -> Bool {
      let count = text.utf8CodeUnitCount
      guard index + count <= bytes.count else { return false }
      return text.withUTF8Buffer { needle in
        for offset in 0..<count {
          var value = bytes[index + offset]
          if (0x41...0x5A).contains(value) { value += 0x20 }
          if value != needle[offset] { return false }
        }
        return true
      }
    }

    /// The offset after a comment whose `<!--` ends just before `start`.
    private func commentEnd(from start: Int) -> Int {
      if byte(start) == 0x3E { return start + 1 }
      if byte(start) == 0x2D, byte(start + 1) == 0x3E { return start + 2 }
      var index = start
      while let dash = next(0x2D, from: index) {
        if byte(dash + 1) == 0x2D {
          if byte(dash + 2) == 0x3E { return dash + 3 }
          if byte(dash + 2) == 0x21, byte(dash + 3) == 0x3E { return dash + 4 }
        }
        index = dash + 1
      }
      return bytes.count
    }

    /// The offset of the `</name` that closes a text element, or the end of the file.
    private func closingTag(of name: String, from start: Int) -> Int {
      let needle = Array(name.utf8)
      var index = start
      while let open = next(0x3C, from: index) {
        if byte(open + 1) == 0x2F, open + 2 + needle.count <= bytes.count {
          var same = true
          for offset in 0..<needle.count {
            var value = bytes[open + 2 + offset]
            if (0x41...0x5A).contains(value) { value += 0x20 }
            if value != needle[offset] {
              same = false
              break
            }
          }
          let after = byte(open + 2 + needle.count)
          if same, isSpace(after) || after == 0x2F || after == 0x3E { return open }
        }
        index = open + 1
      }
      return bytes.count
    }

    /// Parses a tag from its name's first byte. `nil` when the file ends inside it.
    private func parseTag(from start: Int) -> Tag? {
      var index = start
      while index < bytes.count, !isSpace(bytes[index]), bytes[index] != 0x2F, bytes[index] != 0x3E {
        index += 1
      }
      let name = text(start, index).lowercased()
      var attributes: [(name: String, value: String)] = []
      var seen: Set<String> = []
      while true {
        while index < bytes.count, isSpace(bytes[index]) || bytes[index] == 0x2F { index += 1 }
        guard index < bytes.count else { return nil }
        if bytes[index] == 0x3E { return Tag(name: name, attributes: attributes, end: index + 1) }

        let nameStart = index
        index += 1  // a leading `=` is part of the name, as in HTML
        while index < bytes.count, !isSpace(bytes[index]), bytes[index] != 0x2F, bytes[index] != 0x3E,
          bytes[index] != 0x3D
        {
          index += 1
        }
        let attributeName = text(nameStart, index).lowercased()
        while index < bytes.count, isSpace(bytes[index]) { index += 1 }

        var value = ""
        if byte(index) == 0x3D {
          index += 1
          while index < bytes.count, isSpace(bytes[index]) { index += 1 }
          guard index < bytes.count else { return nil }
          if bytes[index] == 0x22 || bytes[index] == 0x27 {
            let quote = bytes[index]
            guard let close = next(quote, from: index + 1) else { return nil }
            value = text(index + 1, close)
            index = close + 1
          } else if bytes[index] != 0x3E {
            let valueStart = index
            while index < bytes.count, !isSpace(bytes[index]), bytes[index] != 0x3E { index += 1 }
            value = text(valueStart, index)
          }
        }
        if seen.insert(attributeName).inserted {
          attributes.append((attributeName, decodingCharacterReferences(value)))
        }
      }
    }

    private func text(_ start: Int, _ end: Int) -> String {
      String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
    }
  }
}
