import DossierCore
import Foundation
import Testing

@testable import Dossier

private func json(_ text: String) -> JSONValue {
  try! JSONValue.parse(Data(text.utf8))
}

/// A schema with a throwaway `$id`, around `body` (the text between the braces).
private func evaluator(_ body: String) throws -> SchemaEvaluator {
  try SchemaEvaluator(schemas: [
    json(#"{"$id": "https://example.invalid/s/t.schema.json", \#(body)}"#)
  ])
}

private func violations(_ body: String, _ instance: String) throws -> [SchemaViolation] {
  try evaluator(body).validate(json(instance), against: "t.schema.json")
}

private func valid(_ body: String, _ instance: String) throws -> Bool {
  try violations(body, instance).isEmpty
}

@Suite("SchemaEvaluator")
enum SchemaEvaluatorTests {
  @Suite("SchemaEvaluator keywords")
  struct Keyword {
    @Test func type() throws {
      #expect(try valid(#""type": "string""#, #""x""#))
      #expect(try !valid(#""type": "string""#, "1"))
      #expect(try valid(#""type": "object""#, "{}"))
      #expect(try valid(#""type": "array""#, "[]"))
      #expect(try valid(#""type": "boolean""#, "false"))
      #expect(try valid(#""type": "null""#, "null"))
      #expect(try !valid(#""type": "object""#, "[]"))
    }

    @Test func typeArray() throws {
      let body = #""type": ["string", "null"]"#
      #expect(try valid(body, #""x""#))
      #expect(try valid(body, "null"))
      #expect(try !valid(body, "3"))
    }

    @Test func integerAndNumber() throws {
      #expect(try valid(#""type": "integer""#, "3"))
      #expect(try valid(#""type": "integer""#, "3.0"))
      #expect(try valid(#""type": "integer""#, "1e3"))
      #expect(try !valid(#""type": "integer""#, "3.5"))
      #expect(try !valid(#""type": "integer""#, #""3""#))
      #expect(try valid(#""type": "number""#, "3.5"))
      #expect(try !valid(#""type": "number""#, "true"))
    }

    @Test func required() throws {
      let body = #""required": ["a", "b"]"#
      #expect(try valid(body, #"{"a": 1, "b": null}"#))
      let found = try violations(body, #"{"a": 1}"#)
      #expect(found.map(\.keyword) == ["required"])
      #expect(try valid(body, "[]"))  // only objects are constrained
    }

    @Test func properties() throws {
      let body = #""properties": {"a": {"type": "integer"}}"#
      #expect(try valid(body, #"{"a": 1, "other": "x"}"#))
      let found = try violations(body, #"{"a": "x"}"#)
      #expect(found.map(\.path) == ["/a"])
    }

    @Test func additionalPropertiesFalse() throws {
      let body = #""properties": {"a": {}}, "additionalProperties": false"#
      #expect(try valid(body, #"{"a": 1}"#))
      let found = try violations(body, #"{"a": 1, "b/c": 2}"#)
      #expect(found.map(\.path) == ["/b~1c"])
    }

    @Test func additionalPropertiesSchema() throws {
      let body = #""properties": {"a": {}}, "additionalProperties": {"type": "string"}"#
      #expect(try valid(body, #"{"a": 1, "b": "x"}"#))
      #expect(try !valid(body, #"{"a": 1, "b": 2}"#))
    }

    @Test func items() throws {
      let body = #""items": {"type": "string"}"#
      #expect(try valid(body, #"["a", "b"]"#))
      #expect(try valid(body, "[]"))
      #expect(try violations(body, #"["a", 2]"#).map(\.path) == ["/1"])
    }

    @Test func enumKeyword() throws {
      let body = #""enum": ["a", 1, null, {"k": [1.0]}]"#
      #expect(try valid(body, #""a""#))
      #expect(try valid(body, "1.0"))
      #expect(try valid(body, "null"))
      #expect(try valid(body, #"{"k": [1]}"#))
      #expect(try !valid(body, #""b""#))
      #expect(try !valid(body, "2"))
    }

    @Test func constKeyword() throws {
      #expect(try valid(#""const": 1"#, "1"))
      #expect(try valid(#""const": 1"#, "1.0"))
      #expect(try !valid(#""const": 1"#, "2"))
      #expect(try !valid(#""const": 1"#, #""1""#))
      #expect(try valid(#""const": false"#, "false"))
    }

    @Test func constComparesStringsByBytes() throws {
      let nfc = "\u{00E9}"
      let nfd = "e\u{0301}"
      let schema = json(#"{"$id": "https://example.invalid/s/t.schema.json", "const": "\#(nfc)"}"#)
      let evaluator = try SchemaEvaluator(schemas: [schema])
      #expect(try evaluator.validate(.string(nfc), against: "t.schema.json").isEmpty)
      #expect(try !evaluator.validate(.string(nfd), against: "t.schema.json").isEmpty)
    }

    @Test func minimum() throws {
      #expect(try valid(#""minimum": 1"#, "1"))
      #expect(try valid(#""minimum": 1"#, "2.5"))
      #expect(try !valid(#""minimum": 1"#, "0"))
      #expect(try !valid(#""minimum": 1"#, "0.99"))
      #expect(try valid(#""minimum": 1"#, #""x""#))  // not a number: unconstrained
      #expect(try valid(#""minimum": 9007199254740993"#, "9007199254740993"))
      #expect(try !valid(#""minimum": 9007199254740993"#, "9007199254740992"))
    }

    @Test func minLengthCountsScalars() throws {
      #expect(try valid(#""minLength": 1"#, #""x""#))
      #expect(try !valid(#""minLength": 1"#, #""""#))
      #expect(try valid(#""minLength": 2"#, "\"e\u{0301}\""))  // two scalars, one character
      #expect(try valid(#""minLength": 2"#, "5"))
    }

    @Test func minItems() throws {
      #expect(try valid(#""minItems": 1"#, "[0]"))
      #expect(try !valid(#""minItems": 1"#, "[]"))
    }

    @Test func allOf() throws {
      let body = #""allOf": [{"type": "object"}, {"required": ["a"]}]"#
      #expect(try valid(body, #"{"a": 1}"#))
      #expect(try !valid(body, "{}"))
      #expect(try !valid(body, "[]"))
    }

    @Test func oneOf() throws {
      let body = #""oneOf": [{"type": "string"}, {"minLength": 3}]"#
      #expect(try valid(body, #""ab""#))  // only the first matches
      #expect(try !valid(body, #""abc""#))  // both match
      #expect(try valid(body, "5"))  // only the second (minLength ignores numbers)
      let strict = #""oneOf": [{"type": "string"}, {"type": "integer"}]"#
      #expect(try valid(strict, #""a""#))
      #expect(try valid(strict, "1"))
      #expect(try !valid(strict, "null"))
    }

    @Test func ifThen() throws {
      let body = #"""
        "if": {"properties": {"kind": {"const": "x"}}, "required": ["kind"]},
        "then": {"required": ["extra"]}
        """#
      #expect(try valid(body, #"{"kind": "x", "extra": 1}"#))
      #expect(try !valid(body, #"{"kind": "x"}"#))
      #expect(try valid(body, #"{"kind": "y"}"#))
      #expect(try valid(body, "{}"))
    }

    @Test func booleanSubschemas() throws {
      #expect(try valid(#""properties": {"a": true}"#, #"{"a": 1}"#))
      #expect(try !valid(#""properties": {"a": false}"#, #"{"a": 1}"#))
    }

    @Test func ignoredKeywords() throws {
      #expect(try valid(#""$schema": "x", "title": "t", "description": "d", "type": "null""#, "null"))
    }

    @Test func refToAnotherSchemaRelative() throws {
      let base = json(
        #"""
        {"$id": "https://example.invalid/s/a.schema.json",
         "properties": {"inner": {"$ref": "b.schema.json"}}}
        """#)
      let other = json(
        #"""
        {"$id": "https://example.invalid/s/b.schema.json", "type": "integer", "minimum": 5}
        """#)
      let evaluator = try SchemaEvaluator(schemas: [base, other])
      #expect(try evaluator.validate(json(#"{"inner": 6}"#), against: "a.schema.json").isEmpty)
      #expect(
        try evaluator.validate(json(#"{"inner": 1}"#), against: "a.schema.json").map(\.path)
          == ["/inner"])
    }

    @Test func refToMissingSchemaFailsToLoad() {
      let schema = json(#"{"$id": "https://example.invalid/s/a.schema.json", "$ref": "nope.json"}"#)
      #expect(throws: SchemaError.self) { try SchemaEvaluator(schemas: [schema]) }
    }

    @Test func refWithFragmentFailsToLoad() {
      let schema = json(
        ##"{"$id": "https://example.invalid/s/a.schema.json", "$ref": "#/definitions/x"}"##)
      #expect(throws: SchemaError.self) { try SchemaEvaluator(schemas: [schema]) }
    }

    @Test func unknownSchemaName() throws {
      #expect(throws: SchemaError.unknownSchema("zzz")) {
        try evaluator(#""type": "null""#).validate(.null, against: "zzz")
      }
    }

    @Test(arguments: [
      "format", "default", "else", "not", "anyOf", "patternProperties", "maxLength", "maximum",
      "uniqueItems", "$defs", "definitions", "contains", "dependentRequired", "propertyNames",
      "maxItems", "multipleOf", "exclusiveMinimum", "$anchor",
    ])
    func unsupportedKeywordIsAFailure(keyword: String) {
      #expect(throws: SchemaError.self) { try evaluator(#""\#(keyword)": true"#) }
    }

    @Test func unsupportedKeywordNestedIsAFailure() {
      #expect(throws: SchemaError.self) {
        try evaluator(#""properties": {"a": {"items": {"allOf": [{"format": "date"}]}}}"#)
      }
      #expect(throws: SchemaError.self) {
        try evaluator(#""if": {"not": {}}, "then": {}"#)
      }
    }

    @Test func propertyNamedLikeAKeywordIsNotAKeyword() throws {
      #expect(try valid(#""properties": {"format": {"type": "string"}, "not": {}}"#, #"{"format": "x"}"#))
    }
  }

  /// `pattern` has ECMA-262 meaning. The expected strings were produced by running each pattern
  /// through `new RegExp(pattern).test(case)` in a JavaScript engine.
  @Suite("SchemaEvaluator patterns")
  struct Pattern {
    static let cases: [String] = [
      "a/b.png", "", "/a", "a:b", "a/b:c", "a\\b", "a/../b", "./a", "a/.", "..", "a//b",
      "a\nb", "a\n", "ab\u{2028}", "a\u{0085}b", "é/ü.png", "a/.hidden", ".hidden", "ok name",
      String(repeating: "a", count: 64), String(repeating: "a", count: 64) + "\n",
      String(repeating: "A", count: 64), "2026-01-02T03:04:05Z", "2026-01-02T03:04:05Z\n",
      "\u{0662}\u{0660}\u{0662}\u{0666}-01-02T03:04:05Z", "2026-1-02T03:04:05Z", "a.b", "a:b",
    ]

    static let expectations: [(pattern: String, expected: String)] = [
      (#"^(?!/)(?![^/]*:)(?!.*\\)(?!.*(^|/)\.{0,2}(/|$)).+$"#, "1000100000000011111101000010"),
      (#"^(?!/)(?!.*(^|/)\.{0,2}(/|$)).+$"#, "1001110000000011111101101111"),
      (#"^[0-9a-f]{64}$"#, "0000000000000000000100000000"),
      (#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, "0000000000000000000000100000"),
      (#"^[^/:.][^/:]*$"#, "0000010000011110001111000010"),
    ]

    @Test(arguments: expectations.map { $0.pattern })
    func matchesEcmaBehaviour(pattern: String) throws {
      let expected = try #require(Self.expectations.first { $0.pattern == pattern }).expected
      let encoded = String(data: JSONValue.string(pattern).canonicalEncoded().data(using: .utf8)!, encoding: .utf8)!
      let evaluator = try evaluator(#""pattern": \#(encoded)"#)
      var actual = ""
      for text in Self.cases {
        let hit = try evaluator.validate(.string(text), against: "t.schema.json").isEmpty
        actual += hit ? "1" : "0"
      }
      #expect(actual == expected, "\(pattern)")
    }

    @Test func everyPinnedPatternIsCovered() throws {
      // Every pattern in a pinned schema must appear in `expectations`.
      var found = Set<String>()
      func walk(_ value: JSONValue) {
        switch value {
        case .object(let object):
          for entry in object.entries {
            if entry.key == "pattern", let pattern = entry.value.stringValue { found.insert(pattern) }
            walk(entry.value)
          }
        case .array(let items): items.forEach(walk)
        default: break
        }
      }
      let root = try #require(DossierResources.bundle.resourceURL).appendingPathComponent("schemas")
      for file in try FileManager.default.contentsOfDirectory(atPath: root.path)
      where file.hasSuffix(".json") {
        walk(try JSONValue.parse(Data(contentsOf: root.appendingPathComponent(file))))
      }
      #expect(found == Set(Self.expectations.map(\.pattern)))
    }

    @Test(arguments: [#"\s"#, #"\w"#, #"(?<n>a)"#, #"(?<=a)b"#, #"a\1"#, #"[a"#, #"a{x}"#, #"\p{L}"#])
    func unsupportedSyntaxIsRefused(pattern: String) {
      let encoded = JSONValue.string(pattern).canonicalEncoded()
      #expect(throws: SchemaError.self) { try evaluator(#""pattern": \#(encoded)"#) }
    }
  }

  @Suite("SchemaEvaluator pinned schemas")
  struct Pinned {
    private static var schemaFiles: [URL] {
      get throws {
        let root = try #require(DossierResources.bundle.resourceURL).appendingPathComponent("schemas")
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
          .filter { $0.hasSuffix(".schema.json") }.sorted().map { root.appendingPathComponent($0) }
      }
    }

    @Test func pinnedSchemasLoadWithNoUnsupportedKeyword() throws {
      let evaluator = try SchemaEvaluator.pinned()
      #expect(
        evaluator.schemaNames == [
          "manifest-v1.schema.json", "manifest-v2.schema.json", "record.schema.json",
          "samples.schema.json",
        ])
    }

    @Test func addingAnUnsupportedKeywordToAnyPinnedSchemaFails() throws {
      let files = try Self.schemaFiles
      #expect(files.count == 4)
      let all = try files.map { try JSONValue.parse(Data(contentsOf: $0)) }
      for index in all.indices {
        var object = try #require(all[index].objectValue)
        object["format"] = .string("date-time")
        var documents = all
        documents[index] = .object(object)
        #expect(throws: SchemaError.self, "\(files[index].lastPathComponent)") {
          try SchemaEvaluator(schemas: documents)
        }
      }
    }

    @Test func pinnedSchemasReferenceOnlyLoadedSchemas() throws {
      // record refs manifest-v2; loading it alone fails.
      let files = try Self.schemaFiles
      let record = try #require(files.first { $0.lastPathComponent == "record.schema.json" })
      #expect(throws: SchemaError.self) {
        try SchemaEvaluator(schemas: [JSONValue.parse(Data(contentsOf: record))])
      }
    }
  }

  @Suite("SchemaEvaluator fixtures")
  struct Fixture {
    private static let examples = SpecTree.examples

    /// Fails, never skips, when the fixtures are absent.
    private static func manifests(under directory: String, matching: (String) -> Bool = { _ in true })
      throws -> [(name: String, manifest: JSONValue)]
    {
      let root = examples.appendingPathComponent(directory)
      var isDirectory: ObjCBool = false
      try #require(
        FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
        "fixtures missing: run `make fixtures`")
      let enumerator = try #require(FileManager.default.enumerator(atPath: root.path))
      var result: [(String, JSONValue)] = []
      for case let relative as String in enumerator
      where relative.hasSuffix("/manifest.json") && matching(relative) {
        let data = try Data(contentsOf: root.appendingPathComponent(relative))
        result.append((directory + "/" + relative, try JSONValue.parse(data)))
      }
      return result.sorted { $0.0 < $1.0 }
    }

    @Test func v1FixturesValidateAgainstManifestV1() throws {
      let evaluator = try SchemaEvaluator.pinned()
      let found = try Self.manifests(under: "warnings") { $0.hasPrefix("W-V1") }
      #expect(found.count == 2)
      for (name, manifest) in found {
        let result = try evaluator.validate(manifest, against: "manifest-v1.schema.json")
        #expect(result.isEmpty, "\(name): \(result)")
      }
    }

    @Test func validFixturesValidateAgainstManifestV2() throws {
      let evaluator = try SchemaEvaluator.pinned()
      let found = try Self.manifests(under: "valid")
      #expect(found.count == 14)
      for (name, manifest) in found {
        let result = try evaluator.validate(manifest, against: "manifest-v2.schema.json")
        #expect(result.isEmpty, "\(name): \(result)")
      }
    }

    @Test func schemaErrorFixtureFails() throws {
      let evaluator = try SchemaEvaluator.pinned()
      let found = try Self.manifests(under: "errors") { $0.hasPrefix("E-SCHEMA") }
      #expect(found.count == 1)
      for (name, manifest) in found {
        let result = try evaluator.validate(manifest, against: "manifest-v2.schema.json")
        #expect(!result.isEmpty, "\(name) should fail manifest-v2")
      }
    }
  }

}
