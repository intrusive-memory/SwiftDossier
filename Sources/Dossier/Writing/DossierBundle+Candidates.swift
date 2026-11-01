import DossierCore
import Foundation

/// A file in `.generations/<CHARACTER>/`, which isn't in the bundle (§4).
public struct Candidate: Sendable, Equatable {
  /// The file.
  public let url: URL
  /// Its path under `.generations/<CHARACTER>/`.
  public let name: String
  /// What its name says it is, when it says.
  public let kind: AssetKind?
  /// What its name says its variant is, when it says.
  public let variant: String?
  /// A sidecar beside it, to pass to ``AddOptions/sidecar``.
  public let sidecar: URL?
}

extension DossierBundle {
  /// What's in `<charactersDir>/.generations/<CHARACTER>/` (§4). Nothing is changed. A
  /// directory that isn't there holds nothing.
  ///
  /// SPEC-GAP: §4, DF-17: the format "defines this location and nothing about its contents",
  /// and the arguments ask for a kind. A kind is read from the name by §4's patterns:
  /// `<kind>[-<variant>]-…` for images, `.vox`, `sample-<variant>[-<model>].m4a`, `.safetensors`.
  /// Any other name has no kind, and is returned only when no kind is asked for. `<name>.json`
  /// or `<stem>.json` beside a file is its sidecar. Hidden files and links aren't listed.
  ///
  /// - Parameters:
  ///   - kind: Only this kind. `nil` is every file.
  ///   - variant: Only this variant. `nil` is any.
  ///   - charactersDirectory: The directory holding `.generations`. `nil` is the one holding
  ///     this bundle.
  /// - Returns: The candidates, in byte order of their names.
  public func candidates(
    kind: AssetKind? = nil, variant: String? = nil, in charactersDirectory: URL? = nil
  ) -> [Candidate] {
    let root = (charactersDirectory ?? url.deletingLastPathComponent())
      .appendingPathComponent(".generations", isDirectory: true)
      .appendingPathComponent(manifest.character, isDirectory: true)
    let files = BundleInventory(bundle: root).visible
    let paths = Set(files.map { BundleInventory.key($0.path) })

    func sidecar(of path: String) -> String? {
      guard !path.hasSuffix(".json") else { return nil }
      return [path + ".json", (path as NSString).deletingPathExtension + ".json"]
        .first { paths.contains(BundleInventory.key($0)) }
    }
    let sidecars = Dictionary(uniqueKeysWithValues: files.compactMap { file in
      sidecar(of: file.path).map { (file.path, $0) }
    })
    let taken = Set(sidecars.values.map(BundleInventory.key))

    return files.compactMap { file in
      guard !taken.contains(BundleInventory.key(file.path)) else { return nil }
      let (fileKind, fileVariant) = Self.kindAndVariant(ofName: (file.path as NSString).lastPathComponent)
      if let kind, kind != fileKind { return nil }
      if let variant, !(fileVariant?.hasSameBytes(as: variant) ?? false) { return nil }
      return Candidate(
        url: file.url, name: file.path, kind: fileKind, variant: fileVariant,
        sidecar: sidecars[file.path].map { root.appendingPathComponent($0) })
    }
  }

  private static func kindAndVariant(ofName name: String) -> (AssetKind?, String?) {
    let stem = (name as NSString).deletingPathExtension
    switch (name as NSString).pathExtension {
    case "vox":
      return (.vox, nil)
    case "safetensors":
      return (.lora, nil)
    case "m4a":
      guard stem.hasPrefix("sample-") else { return (nil, nil) }
      var variant = String(stem.dropFirst("sample-".count))
      if let dash = variant.lastIndex(of: "-"), ModelSize.isSize(String(variant[variant.index(after: dash)...])) {
        variant = String(variant[..<dash])
      }
      return (.voiceSample, variant.isEmpty ? nil : variant)
    default:
      break
    }
    let parts = stem.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    guard let first = parts.first else { return (nil, nil) }
    let kind = AssetKind(rawValue: first)
    switch kind {
    case .view, .expression:
      return (kind, parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    case .portrait, .face, .crowdRef, .sourcePhoto, .training:
      return (kind, nil)
    default:
      return (nil, nil)
    }
  }
}
