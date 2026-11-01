import DossierCore
import Foundation
import Testing

@Suite("CHARACTER.md, as completeness reads it (§9)")
struct CharacterDocumentTests {
  @Test("Front matter: LF, CRLF, trailing space, a later rule, and none")
  func frontMatter() {
    #expect(FrontMatter.split("---\na: 1\n---\nbody\n---\n")?.yaml == "a: 1\n")
    #expect(FrontMatter.split("---\na: 1\n---\nbody\n---\n")?.body == "body\n---\n")
    #expect(FrontMatter.split("---\r\na: 1\r\n---\r\nbody")?.body == "body")
    #expect(FrontMatter.split("--- \na: 1\n---\t\n")?.yaml == "a: 1\n")
    #expect(FrontMatter.split("---\na: 1\n----\n") == nil)
    #expect(FrontMatter.split("text\n---\na: 1\n---\n") == nil)
    #expect(FrontMatter.split("---\n") == nil)
    #expect(FrontMatter.split("") == nil)
  }

  @Test("A front-matter key: plain, quoted, null, absent, and unparseable")
  func frontMatterKeys() {
    let document = CharacterDocument(text: "---\nartStyle: woodcut\nb: 'null'\nc: ~\nd: [x]\n---\n")
    #expect(document.frontMatterText("artStyle") == "woodcut")
    #expect(document.frontMatterText("b") == "null")
    #expect(document.frontMatterText("c") == nil)
    #expect(document.frontMatterText("d") == nil)
    #expect(document.frontMatterText("e") == nil)
    #expect(CharacterDocument(text: "---\na: [\n---\n").frontMatterText("a") == nil)
    #expect(CharacterDocument(text: "no front matter").frontMatterText("a") == nil)
  }

  @Test("§9.2's heading match: a name, optionally a space and a parenthetical")
  func headings() {
    let document = CharacterDocument(
      text: """
        ---
        type: character
        ---
        # Title

        ## Arc (Season 1)
        text
        ## Logline
        ## Voice & Speech
        ### Sub

        ## Wardrobes
        words
        ##Backstory
        ## personality
        ## Appearance(x)
        """)
    #expect(document.hasSection("Arc"))
    #expect(document.hasSection("Logline"))
    #expect(document.hasSection("Voice & Speech"))
    #expect(!document.hasSection("Wardrobe"))
    #expect(!document.hasSection("Backstory"))
    #expect(!document.hasSection("Personality"))
    #expect(!document.hasSection("Appearance"))
    #expect(!document.hasNonEmptySection("Logline"))
    #expect(document.hasNonEmptySection("Arc"))
    #expect(document.hasNonEmptySection("Voice & Speech"), "A `###` belongs to its section")
  }

  @Test("SPEC-GAP: §9.2: a `##` line in a fence isn't a heading")
  func fences() {
    let document = CharacterDocument(text: "## Logline\n```\n## Arc\n```\n~~~\n```\n## Backstory\n~~~\n## Wardrobe\n")
    #expect(document.hasSection("Logline"))
    #expect(!document.hasSection("Arc"))
    #expect(!document.hasSection("Backstory"))
    #expect(document.hasSection("Wardrobe"))
    #expect(document.hasNonEmptySection("Logline"))
  }

  @Test("CRLF files have the same sections")
  func crlf() {
    let document = CharacterDocument(text: "---\r\ntype: character\r\n---\r\n## Logline\r\nx\r\n## Arc\r\n")
    #expect(document.hasNonEmptySection("Logline"))
    #expect(document.hasSection("Arc"))
    #expect(!document.hasNonEmptySection("Arc"))
  }
}
