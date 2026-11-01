import DossierCore
import Foundation
import Testing

@Suite("MemberHash (§7)")
struct MemberHashTests {
  private static let workedExample = """
    - character: INÉS
      voiceDescription: A low voice.
      voices: {VoxAlta: a/b.vox}
      bio: null
    """

  @Test("§7's worked hash")
  func section7WorkedHash() throws {
    let json = try MemberHash.canonicalJSON(ofMemberYAML: Self.workedExample)
    #expect(
      json
        == #"{"bio":null,"character":"INÉS","voicePrompt":"A low voice.","voices":{"voxalta":["a/b.vox"]}}"#
    )
    #expect(
      try MemberHash.hash(ofMemberYAML: Self.workedExample)
        == "bf956f8fe4278f30b800f8899b3a634ef1ac15ad101796b31e9d592fa0b73168")
  }

  /// The page's `castMember` input holds the hash the format's own tool computed.
  private func recordedHash(_ path: String, _ character: String) throws -> (Cast.Member, String) {
    let url = Fixtures.project(path).appendingPathComponent("CAST.md")
    let cast = try Cast.load(url)
    let member = try #require(cast.members.first { $0.character == character })
    let bundle = try #require(try cast.openBundle(for: member))
    let page = try #require(bundle.selectedAsset(kind: .dossier))
    let input = try #require(page.derivedFrom.first { $0.role == "castMember" })
    return (member, input.sha256)
  }

  @Test("valid/member-scalars: every plain, quoted and out-of-range scalar")
  func memberScalars() throws {
    let (member, recorded) = try recordedHash("valid/member-scalars", "THE ARCHIVIST")
    #expect(member.hash == recorded)
    #expect(
      member.canonicalJSON
        == #"{"aBlock":"line one\nline\ttwo \"quoted\" back\\slash\n","aDate":"2026-08-01","aFalse":false,"aFloat":"1.5","aList":[1,true,"x",null,"1.5"],"aMap":{"k":"1.5","t":true},"aNegative":-5,"aNull":null,"aTilde":null,"aTrue":true,"aYes":"yes","aZero":0,"actor":"5","anEmpty":null,"anInt":5,"anOctal":"0755","character":"THE ARCHIVIST","language":"no","leadingZero":"007","manifest":"characters/THE ARCHIVIST.dossier/manifest.json","plusSign":"+5","quotedInt":"5","quotedTrue":"true","role":"background","tooBig":"99999999999999999999","voices":{}}"#
    )
  }

  /// Recon U-2. This package reads the node instead, but the question was whether a
  /// `JSONEncoder` encode of `CastMember` gives canonical JSON. The answer: only with
  /// both options, and on these fixtures, where every key is ASCII.
  @Test("U-2: valid/non-ascii-underfive's member, and what JSONEncoder does with it")
  func nonAsciiUnderfive() throws {
    let (member, recorded) = try recordedHash("valid/non-ascii-underfive", "INÉS")
    #expect(member.hash == recorded)
    #expect(member.canonicalJSON.contains("characters/INÉS.dossier/manifest.json"))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = String(decoding: try encoder.encode(member.fields), as: UTF8.self)
    #expect(encoded == member.canonicalJSON)
    encoder.outputFormatting = [.sortedKeys]
    let escaped = String(decoding: try encoder.encode(member.fields), as: UTF8.self)
    #expect(escaped != member.canonicalJSON)
  }

  @Test("U-2: JSONEncoder agrees on the scalar and hand-edited fixtures too")
  func encoderAgreesOnOtherFixtures() throws {
    for (path, character) in [
      ("valid/member-scalars", "THE ARCHIVIST"), ("valid/hand-edited-member", "THE FERRYMAN"),
    ] {
      let (member, _) = try recordedHash(path, character)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let encoded = String(decoding: try encoder.encode(member.fields), as: UTF8.self)
      #expect(encoded == member.canonicalJSON, "\(path)")
    }
  }

  @Test("valid/hand-edited-member: legacy prompt, scalar voices, mixed-case provider, undeclared null")
  func handEdited() throws {
    let (member, recorded) = try recordedHash("valid/hand-edited-member", "THE FERRYMAN")
    #expect(member.hash == recorded)
    #expect(member.canonicalJSON.contains(#""voices":{"voxalta":["characters/THE FERRYMAN.dossier/voice/THE FERRYMAN.vox"]}"#))
    #expect(member.canonicalJSON.contains(#""bio":null"#))
    #expect(!member.canonicalJSON.contains("voiceDescription"))
  }

  @Test("Key order and quoting style of the string keys don't change the hash")
  func writtenFormDoesNotMatter() throws {
    let one = try MemberHash.hash(
      ofMemberYAML: "character: ODA\nlanguage: no\nvoices: {A: x.vox}\nnote: 5")
    let two = try MemberHash.hash(
      ofMemberYAML: "note: 5\nvoices:\n  a:\n  - x.vox\nlanguage: 'no'\ncharacter: \"ODA\"")
    #expect(one == two)
  }

  @Test("§7's normal form, rule by rule")
  func normalFormRules() throws {
    func json(_ yaml: String) throws -> String { try MemberHash.canonicalJSON(ofMemberYAML: yaml) }
    // voicePrompt wins over the legacy key, and a null voicePrompt doesn't.
    #expect(try json("voicePrompt: a\nvoiceDescription: b") == #"{"voicePrompt":"a","voices":{}}"#)
    #expect(try json("voicePrompt: ~\nvoiceDescription: b") == #"{"voicePrompt":"b","voices":{}}"#)
    #expect(try json("voicePrompt: null\nvoiceDescription:") == #"{"voices":{}}"#)
    // A quoted null is a string.
    #expect(try json("actor: 'null'\nbio: 'null'") == #"{"actor":"null","bio":"null","voices":{}}"#)
    // Wrong-typed voices are dropped; null ones aren't strings.
    #expect(try json("voices: {a: {b: c}, d: [x, {y: z}], e: null, f: [null]}") == #"{"voices":{}}"#)
    #expect(try json("voices: null") == #"{"voices":{}}"#)
    // Integers: the pattern and the 64-bit range.
    #expect(try json("a: 9223372036854775807\nb: 9223372036854775808\nc: -0") == #"{"a":9223372036854775807,"b":"9223372036854775808","c":0,"voices":{}}"#)
    // Escapes: only the listed ones; `/` and non-ASCII are themselves.
    #expect(try json("a: \"/\\t\\u0001é\"") == "{\"a\":\"/\\t\\u0001é\",\"voices\":{}}")
    // Keys sort by bytes at every level: 'B' before 'a'.
    #expect(try json("a: {z: 1, B: 2}\nB: 3") == #"{"B":3,"a":{"B":2,"z":1},"voices":{}}"#)
  }

  @Test("NFC and NFD spellings of a member hash differently: nothing normalizes it")
  func normalizationIsNotApplied() throws {
    let nfd = try MemberHash.hash(ofMemberYAML: "character: JOSE\u{0301}")
    let nfc = try MemberHash.hash(ofMemberYAML: "character: JOS\u{00C9}")
    #expect(nfd != nfc)
  }

  @Test("What isn't one mapping is refused")
  func refusals() {
    #expect(throws: DossierError.self) { try MemberHash.hash(ofMemberYAML: "just a string") }
    #expect(throws: DossierError.self) { try MemberHash.hash(ofMemberYAML: "[a, b]") }
    #expect(throws: DossierError.self) { try MemberHash.hash(ofMemberYAML: "a: [") }
  }
}
