import DossierCore
import Foundation

/// What a PNG from Vinetas embeds (recon V-03): one uncompressed `iTXt` chunk, keyword
/// `vinetas`, whose text is the same JSON as its sidecar.
enum VinetasPNG {
  static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  private static let keyword = Array("vinetas".utf8)

  static func isPNG(_ data: Data) -> Bool { data.starts(with: signature) }

  /// The text of the first uncompressed `vinetas` chunk. Stops at the first malformed chunk.
  static func embeddedJSON(in data: Data) -> Data? {
    guard isPNG(data) else { return nil }
    let bytes = [UInt8](data)
    var offset = 8
    while offset + 12 <= bytes.count {
      let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
      let start = offset + 8
      guard start + length + 4 <= bytes.count else { return nil }
      if bytes[(offset + 4)..<start].elementsEqual("iTXt".utf8),
        let text = text(ofITXt: bytes[start..<(start + length)])
      {
        return text
      }
      if bytes[(offset + 4)..<start].elementsEqual("IEND".utf8) { return nil }
      offset = start + length + 4
    }
    return nil
  }

  /// keyword NUL, compression flag, compression method, language NUL, translated keyword NUL, text.
  private static func text(ofITXt chunk: ArraySlice<UInt8>) -> Data? {
    guard let keywordEnd = chunk.firstIndex(of: 0), chunk[..<keywordEnd].elementsEqual(keyword),
      keywordEnd + 2 < chunk.endIndex, chunk[keywordEnd + 1] == 0
    else { return nil }
    let afterMethod = chunk[(keywordEnd + 3)...]
    guard let languageEnd = afterMethod.firstIndex(of: 0),
      let translatedEnd = afterMethod[(languageEnd + 1)...].firstIndex(of: 0)
    else { return nil }
    return Data(afterMethod[(translatedEnd + 1)...])
  }
}

/// SD-7: a generator's metadata and `--provenance`, folded into a `provenance` object (§6).
struct FoldedProvenance {
  var json: JSONObject
  /// The sidecar's `generatedAt`, in §1's form.
  var createdAt: String?

  /// - Parameters:
  ///   - metadata: A Vinetas sidecar or embedded record, with its keys as written. What it
  ///     says is recorded as it says it: a `prompt` may already be composed (recon V-04), and
  ///     keys §6 doesn't list (`character`, `bundle`, `glosa`) are preserved (§6).
  ///   - extra: `--provenance`, whose keys replace those of the same name.
  init(metadata: JSONObject?, extra: JSONObject?) throws {
    json = JSONObject()
    // §6 requires a provider. A sidecar comes from Vinetas, and a file with no record is
    // "an existing file brought in".
    json["provider"] = .string(metadata == nil ? "import" : "vinetas")
    for entry in metadata?.entries ?? [] {
      if entry.key == "generatedAt" {
        guard let text = entry.value.stringValue, let time = Timestamp.normalized(text) else {
          throw DossierWriteError.timestampUnreadable(entry.value.canonicalEncoded())
        }
        createdAt = time
      } else {
        json[entry.key] = entry.value
      }
    }
    for entry in extra?.entries ?? [] { json[entry.key] = entry.value }
  }

  /// The record's `references`, each without `source`, with `path` where an asset in the bundle
  /// has that hash, and `role` by position.
  ///
  /// SPEC-GAP: SD-7, §6: SD-7 says a reference becomes `{sha256, path, role}`, and §6 also
  /// lists `originalWidth`, `originalHeight`, `effectiveWidth`, `effectiveHeight`. SD-7 says
  /// too that every §6 key the sidecar has is recorded, so those stay. Only `source` goes.
  ///
  /// SPEC-GAP: §6: when two assets have the hash, a `selected` one is named, else the first in
  /// manifest order.
  mutating func resolveReferences(roles: [String], manifest: Manifest, scan: BundleScan) throws {
    guard let value = json["references"] else {
      guard roles.isEmpty else { throw DossierWriteError.referenceRolesMismatch(roles: roles.count, references: 0) }
      return
    }
    guard let items = value.arrayValue else {
      throw DossierWriteError.provenanceMalformed("references isn't an array")
    }
    guard roles.count <= items.count else {
      throw DossierWriteError.referenceRolesMismatch(roles: roles.count, references: items.count)
    }
    let candidates = manifest.assets.filter { $0.status == .selected } + manifest.assets.filter { $0.status != .selected }
    json["references"] = .array(
      try items.enumerated().map { index, item in
        guard var reference = item.objectValue else {
          throw DossierWriteError.provenanceMalformed("a reference isn't an object")
        }
        reference["source"] = nil
        if reference["path"] == nil, let sha256 = reference["sha256"]?.stringValue,
          let asset = candidates.first(where: { scan.sha256(ofPath: $0.path)?.hasSameBytes(as: sha256) ?? false })
        {
          reference["path"] = .string(asset.path)
        }
        if reference["role"] == nil, index < roles.count { reference["role"] = .string(roles[index]) }
        return .object(reference)
      })
  }

  /// §6 names `loras[].path` a bundle path when it's this character's `lora` asset, and §1 has
  /// no absolute path anywhere in a bundle. A record gives a path as the caller supplied it.
  ///
  /// SPEC-GAP: §1, §6: a LoRA entry has no hash, and nothing says what an absolute path
  /// becomes. It becomes the bundle path of the `lora` asset of that file name; with none,
  /// the file name alone, which is all of it that means anything on another machine.
  mutating func resolveLoras(manifest: Manifest) {
    guard let items = json["loras"]?.arrayValue else { return }
    json["loras"] = .array(
      items.map { item in
        guard var lora = item.objectValue, let path = lora["path"]?.stringValue,
          path.hasPrefix("~") || !BundlePath.isValid(path)
        else { return item }
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        let asset = manifest.assets.first { asset in
          asset.kind == .lora && asset.path.split(separator: "/").last.map(String.init) == name
        }
        lora["path"] = .string(asset?.path ?? name)
        return .object(lora)
      })
  }
}
