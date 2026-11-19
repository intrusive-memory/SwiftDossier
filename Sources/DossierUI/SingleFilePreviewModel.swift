import Dossier
import DossierCore
import Foundation

/// One labelled front-matter value a preview shows.
public struct PreviewField: Sendable, Equatable {
  public let key: String
  public let label: String
  public let value: String
}

/// One `##` section a preview shows. `content` is Markdown.
public struct PreviewSection: Sendable, Equatable {
  public let heading: String
  public let content: String
}

extension JSONValue {
  /// The value as the one line a preview shows. `nil` for null, an empty string or list, and an
  /// object (which a preview doesn't flatten).
  fileprivate var previewText: String? {
    switch self {
    case .null, .object: return nil
    case .bool(let value): return value ? "true" : "false"
    case .number(let literal): return literal
    case .string(let value):
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    case .array(let items):
      let parts = items.compactMap(\.previewText)
      return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
  }
}

/// What `CharacterPreview` shows, from the file's text alone (SFV-1, SFV-8). Reads nothing from
/// disk and has no images.
///
/// Order: ``name``, ``role``, ``aliases``, ``fields`` in `fields.json` order, ``sections`` in
/// §9.2 order, then ``openQuestions``. When the front matter doesn't read, ``problem`` is set and
/// ``body`` is the text to draw as Markdown; the structured parts are then empty.
public struct CharacterPreviewModel: Sendable, Equatable {
  /// The `character` key, or `nil`.
  public let name: String?
  /// The `role` key (it comes from the record in `fields.json`, so it isn't in ``fields``), or `nil`.
  public let role: String?
  /// The `aliases` items, in file order.
  public let aliases: [String]
  /// The top-level front-matter keys `fields.json` takes from front matter, in its order, that the
  /// file has with a value. `draft.*` keys are never shown.
  public let fields: [PreviewField]
  /// §9.2's sections the file has, in §9.2's order (a section §9.2 doesn't name follows them, in file
  /// order). Open Questions isn't here: see ``openQuestions``.
  public let sections: [PreviewSection]
  /// The Open Questions groups with at least one question.
  public let openQuestions: [OpenQuestionGroup]
  /// Why the front matter can't be read, or `nil`.
  public let problem: String?
  /// The text after the front matter. Drawn as Markdown only when ``problem`` is set.
  public let body: String
  /// The file's text, kept to draw ``html``.
  let text: String

  public init(text: String) {
    self.text = text
    let description = CharacterDescription(text: text)
    body = description.body
    if let problem = description.frontMatterProblem {
      self.problem = problem
      name = nil
      role = nil
      aliases = []
      fields = []
      sections = []
      openQuestions = []
      return
    }
    problem = nil
    let matter = description.frontMatter
    name = matter?["character"]?.previewText
    role = matter?["role"]?.previewText
    aliases = matter?["aliases"]?.arrayValue?.compactMap(\.previewText) ?? []
    fields = Self.frontMatterFields.compactMap { key, label in
      matter?[key]?.previewText.map { PreviewField(key: key, label: label, value: $0) }
    }
    let order = CharacterDocument.allSections
    let shown = description.sections.filter { !CharacterDocument.heading($0.heading, matches: "Open Questions") }
    let ranked = shown.enumerated().map { offset, section in
      (
        rank: order.firstIndex { CharacterDocument.heading(section.heading, matches: $0) } ?? order.count,
        offset: offset, section: section
      )
    }
    sections = ranked.sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
      .map { PreviewSection(heading: $0.section.heading, content: $0.section.content) }
    openQuestions = description.openQuestions.filter { !$0.isEmpty }
  }

  /// The preview as one HTML page (SFV-8): sections and body through the package's Markdown, every
  /// text value escaped, no script and no image.
  public var html: String {
    let page = SingleFilePage(text: text)
    let esc = SingleFilePage.escaped
    var out = ""
    if let problem {
      out += "<p class=\"problem\">\(esc(problem))</p>" + page.markup(ofMarkdown: body)
      return SingleFilePage.page(content: out)
    }
    if let name { out += "<h1>\(esc(name))</h1>" }
    if let role { out += "<p class=\"meta\">\(esc(role))</p>" }
    if !aliases.isEmpty { out += "<p class=\"meta\">Also known as \(esc(aliases.joined(separator: ", ")))</p>" }
    if !fields.isEmpty {
      out += "<dl>" + fields.map { "<dt>\(esc($0.label))</dt><dd>\(esc($0.value))</dd>" }.joined() + "</dl>"
    }
    for section in sections { out += "<h2>\(esc(section.heading))</h2>" + page.markup(ofMarkdown: section.content) }
    if !openQuestions.isEmpty {
      out += "<h2>Open Questions</h2>"
      for group in openQuestions {
        if let name = group.name { out += "<h4>\(esc(name))</h4>" }
        out += "<ul>" + group.items.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
      }
    }
    return SingleFilePage.page(content: out + page.sourcesMarkup)
  }

  /// The top-level front-matter keys `fields.json` reads from front matter, with their labels, in
  /// its order. Read from the bundled file (SD-2); dotted keys (`draft.*`) and a key that
  /// repeats are left out.
  static let frontMatterFields: [(key: String, label: String)] = {
    guard let tabs = try? DossierTabs.bundled() else { return [] }
    var seen = Set<String>()
    var found: [(key: String, label: String)] = []
    for tab in tabs.tabs {
      for field in tab.fields {
        guard field.source["from"]?.stringValue == "frontMatter",
          let key = field.source["key"]?.stringValue, !key.contains("."), seen.insert(key).inserted
        else { continue }
        found.append((key, field.label))
      }
    }
    return found
  }()
}

/// What `LocationPreview` shows, from the file's text alone (SFV-1, SFV-10).
///
/// Order: ``name`` (the `location` key), ``theme``, then ``sections`` in file order. When the front
/// matter doesn't read, ``problem`` is set and ``body`` is the text to draw as Markdown.
public struct LocationPreviewModel: Sendable, Equatable {
  public let name: String?
  public let theme: String?
  /// Every `##` section, in file order.
  public let sections: [PreviewSection]
  public let problem: String?
  public let body: String
  let text: String

  public init(text: String) {
    self.text = text
    let description = LocationDescription(text: text)
    body = description.body
    problem = description.frontMatterProblem
    guard problem == nil else {
      name = nil
      theme = nil
      sections = []
      return
    }
    name = description.frontMatter?["location"]?.previewText
    theme = description.frontMatter?["theme"]?.previewText
    sections = description.sections.map { PreviewSection(heading: $0.heading, content: $0.content) }
  }

  /// The preview as one HTML page (SFV-10), as ``CharacterPreviewModel/html`` is for a character.
  public var html: String {
    let page = SingleFilePage(text: text)
    let esc = SingleFilePage.escaped
    var out = ""
    if let problem {
      out += "<p class=\"problem\">\(esc(problem))</p>" + page.markup(ofMarkdown: body)
      return SingleFilePage.page(content: out)
    }
    if let name { out += "<h1>\(esc(name))</h1>" }
    if let theme { out += "<p class=\"meta\">\(esc(theme))</p>" }
    for section in sections { out += "<h2>\(esc(section.heading))</h2>" + page.markup(ofMarkdown: section.content) }
    return SingleFilePage.page(content: out + page.sourcesMarkup)
  }
}
