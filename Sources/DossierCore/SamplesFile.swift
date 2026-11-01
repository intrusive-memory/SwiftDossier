import Foundation
import Yams

/// `voice/samples.yaml` (§10) as the JSON its schema validates.
package enum SamplesFile {
  /// The file's JSON equivalent.
  ///
  /// SPEC-GAP: §10: "validated as its JSON equivalent" doesn't say what a plain scalar is in
  /// JSON. §7's rule is the format's only one, so it's used: `text: 5` is an integer, which the
  /// schema refuses, and `text: 1.5` is a string.
  ///
  /// - Throws: Yams' error when the text isn't YAML. A file with no document is `null`.
  package static func json(ofYAML text: String) throws -> JSONValue {
    guard let node = try Yams.compose(yaml: text) else { return .null }
    return MemberHash.generalValue(node)
  }
}
