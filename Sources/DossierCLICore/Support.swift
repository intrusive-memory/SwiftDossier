import Dossier
import DossierCore
import Foundation

func fileURL(_ path: String) -> URL { URL(fileURLWithPath: path).standardizedFileURL }

func openBundle(_ path: String) throws -> DossierBundle {
  try DossierBundle.open(at: fileURL(path))
}

/// The `CAST.md` member whose `manifest:` leads to this bundle.
func castMember(pointingAt bundle: URL, in cast: Cast) -> Cast.Member? {
  let target = bundle.resolvingSymlinksInPath()
  return cast.members.first { member in
    cast.manifestURL(of: member)?.deletingLastPathComponent().resolvingSymlinksInPath().path == target.path
  }
}

func parseObject(_ text: String, option: String) throws -> JSONObject {
  guard let value = try? JSONValue.parse(Data(text.utf8)), let object = value.objectValue else {
    throw CLIFailure("usage", "\(option) must be a JSON object")
  }
  return object
}

func assetJSON(_ asset: Asset) -> Any { JSONOut.foundation(asset.json) }

func assetLine(_ asset: Asset) -> String {
  let variant = asset.variant.map { " \($0)" } ?? ""
  return "\(asset.status.rawValue)  \(asset.kind.rawValue)\(variant)  \(asset.path)"
}

/// SD-12's report as lines for people. Empty when the write needs no remark.
func castReportLines(_ report: CastWriteReport) -> [String] {
  guard report.suggestion != nil else { return [] }
  var lines: [String] = []
  if !report.isNormalized {
    lines.append(
      "CAST.md: Reparto has not written this file yet; the write normalizes its key order and quoting for every member.")
  }
  for exception in report.exceptions { lines.append("CAST.md: this write changes data: \(exception)") }
  for name in report.nonCanonicalMembers { lines.append("CAST.md: member \"\(name)\" is not canonically named") }
  if let suggestion = report.suggestion { lines.append("CAST.md: \(suggestion)") }
  return lines
}

func castReportJSON(_ report: CastWriteReport) -> [String: Any] {
  [
    "isNormalized": report.isNormalized,
    "exceptions": report.exceptions.map(\.description),
    "nonCanonicalMembers": report.nonCanonicalMembers,
    "suggestion": report.suggestion.map { $0 as Any } ?? NSNull(),
  ]
}
