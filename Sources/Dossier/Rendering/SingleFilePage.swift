import DossierCore
import Foundation

/// HTML for a single `CHARACTER.md` or `LOCATION.md` shown on its own (SFV-8, SFV-10), from the
/// file's text. It reuses the Markdown the LOCATIONS page already draws (`LocationMarkdown`, over
/// `PageMarkdown`): lists, tables, bold, emphasis, code spans and footnote marks. There is no second
/// renderer, no file access, no script and no image.
public struct SingleFilePage: Sendable {
  private let body: String
  private let footnotes: PageFootnotes

  /// - Parameter text: The whole file. Footnote definitions are read from its body, so a mark in
  ///   one section finds its definition in another.
  public init(text: String) {
    body = FrontMatter.split(text)?.body ?? text
    footnotes = PageFootnotes(body: body)
  }

  /// `text` escaped as HTML text: `&`, `<`, `>`, `"` and `'`.
  public static func escaped(_ text: String) -> String { PageText.escaped(text) }

  /// Markdown (a section's content, or a whole body) as an HTML fragment. All text is escaped.
  public func markup(ofMarkdown markdown: String) -> String {
    let renderer = LocationMarkdown(
      footnotes: footnotes, mark: { "<sup>\($0)</sup>" }, markSeparator: { "<sup>,</sup>" })
    return (try? renderer.markup(ofBody: markdown)) ?? "<p>\(Self.escaped(markdown))</p>"
  }

  /// The footnote definitions as an ordered list, or an empty string when there are none.
  public var sourcesMarkup: String {
    guard !footnotes.sources.isEmpty else { return "" }
    return "<ol class=\"sources\">" + footnotes.sources.map { "<li>\(Self.escaped($0))</li>" }.joined() + "</ol>"
  }

  /// A complete page around `content` (already-escaped HTML). Its Content-Security-Policy allows
  /// no script and no image; styling is inline and follows light or dark.
  public static func page(content: String) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8">\
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">\
    <meta name="color-scheme" content="light dark">\
    <style>\
    body{font:-apple-system-body;font-family:-apple-system,system-ui,sans-serif;line-height:1.5;margin:16px;max-width:46em}\
    h1{font-size:1.6em;margin:0}h2{font-size:1.2em;margin:1.2em 0 .3em}h4{margin:.8em 0 .2em}\
    .meta{color:gray;margin:.2em 0}dl{margin:.8em 0}dt{font-weight:600;float:left;clear:left;margin-right:.5em}dd{margin:0 0 .2em}\
    table{border-collapse:collapse;margin:.5em 0}th,td{border:1px solid gray;padding:4px 8px;text-align:left}\
    .problem{color:#b25000;font-weight:600}\
    </style></head><body>\(content)</body></html>
    """
  }
}
