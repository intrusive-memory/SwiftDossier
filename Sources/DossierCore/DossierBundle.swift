import Foundation

/// §5.2's rules for a path recorded in a manifest.
public enum BundlePath {
  /// Whether a path is relative to the bundle, `/`-separated, with no empty, `.` or
  /// `..` segment and no `\` (`E-PATH` when it isn't).
  public static func isValid(_ path: String) -> Bool {
    if path.isEmpty || path.hasPrefix("/") || path.contains("\\") { return false }
    let segments = path.split(separator: "/", omittingEmptySubsequences: false)
    if segments[0].contains(":") { return false }
    return segments.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
}

/// A `.dossier` bundle, opened for reading (§4).
public struct DossierBundle: Sendable {
  /// The bundle directory.
  public let url: URL
  /// The manifest, as read when the bundle was opened.
  public let manifest: Manifest
  /// The `CAST.md` member the bundle was opened through, if any.
  ///
  /// The current member is an input to staleness and completeness (§7, §8.3), and a
  /// bundle doesn't hold it. With none, those comparisons are left out or unsatisfied.
  public let member: Cast.Member?

  /// `CHARACTER.md`, or `LOCATION.md` in a location bundle (§16.3), as read when the bundle was
  /// opened.
  package let description: CharacterDocument?

  /// A bundle over a manifest already read. No check on the directory's name is made,
  /// which is what lets a validator report on a directory ``open(at:member:)`` refuses.
  package init(url: URL, manifest: Manifest, member: Cast.Member?) {
    self.url = url
    self.manifest = manifest
    self.member = member
    let text = (try? Data(contentsOf: url.appendingPathComponent(Self.descriptionPath(of: manifest.dossierType))))
      .map { String(decoding: $0, as: UTF8.self) }
    description = text.map(CharacterDocument.init(text:))
  }

  /// Opens the bundle at a directory.
  ///
  /// Refuses what can't be read as a bundle at all (§14's `E-MANIFEST`, `E-VERSION` and
  /// `E-NOT-BUNDLE`), and doesn't check its contents: that's `validate`.
  ///
  /// SPEC-GAP: §1, §14: `examples/README.md` says a reader rejects every `errors/` fixture,
  /// and the specification requires it only for `E-VERSION`. Opening doesn't hash files
  /// or compare names, so a reader that needs those guarantees validates first.
  ///
  /// - Parameters:
  ///   - url: The directory holding `manifest.json`.
  ///   - member: The `CAST.md` member, when the caller has it. ``Cast/openBundle(for:)``
  ///     passes it.
  public static func open(at url: URL, member: Cast.Member? = nil) throws -> DossierBundle {
    let manifestURL = url.appendingPathComponent("manifest.json")
    guard let data = try? Data(contentsOf: manifestURL) else {
      throw DossierError.manifestMissing(path: manifestURL.path)
    }
    let manifest = try Manifest(data: data)
    if manifest.manifestVersion == 2, !url.lastPathComponent.hasSuffix(".dossier") {
      throw DossierError.notABundle(path: url.path)
    }
    return DossierBundle(url: url, manifest: manifest, member: member)
  }

  /// The assets of a kind and variant, in manifest order. A `nil` argument matches any.
  public func assets(kind: AssetKind? = nil, variant: String? = nil) -> [Asset] {
    manifest.assets.filter { asset in
      if let kind, asset.kind != kind { return false }
      if let variant, !(asset.variant?.hasSameBytes(as: variant) ?? false) { return false }
      return true
    }
  }

  /// §8.1's lookup: the asset with that kind, that variant (or no variant, when none
  /// is asked for) and `status: selected`.
  ///
  /// A `voiceSample` can have one selection per `model`; this returns the first in
  /// manifest order. ``sampleURL(variant:model:)`` can ask for a model. Version 1's
  /// retired kinds aren't mapped: ask for `.turnaround` on a version 1 manifest.
  public func selectedAsset(kind: AssetKind, variant: String? = nil) -> Asset? {
    manifest.assets.first { asset in
      guard asset.kind == kind, asset.status == .selected else { return false }
      guard let variant else { return asset.variant == nil }
      return asset.variant?.hasSameBytes(as: variant) ?? false
    }
  }

  /// The file a bundle path names, or `nil` when the path breaks §5.2's rules, so a
  /// manifest can't lead a reader outside the bundle. The disk isn't read.
  public func fileURL(forPath path: String) -> URL? {
    guard BundlePath.isValid(path) else { return nil }
    return path.split(separator: "/").reduce(url) { $0.appendingPathComponent(String($1)) }
  }

  /// The selected voice sample of a variant, as a file.
  ///
  /// SPEC-GAP: §8.2: nothing says which sample a reader plays when a variant has one per
  /// model and none is asked for. This returns the first in manifest order.
  ///
  /// - Parameters:
  ///   - variant: The register, such as `neutral`.
  ///   - model: The model size, such as `0.6b`. `nil` accepts any.
  public func sampleURL(variant: String, model: String? = nil) -> URL? {
    let sample = manifest.assets.first { asset in
      guard asset.kind == .voiceSample, asset.status == .selected,
        asset.variant?.hasSameBytes(as: variant) ?? false
      else { return false }
      guard let model else { return true }
      return asset.model?.hasSameBytes(as: model) ?? false
    }
    return sample.flatMap { fileURL(forPath: $0.path) }
  }

  /// Which kind of bundle this is (§16.1, DF-79), from the manifest's `dossierType`.
  public var dossierType: DossierType { manifest.dossierType }

  /// Whether this is a location bundle (§16).
  public var isLocation: Bool { dossierType == .location }

  /// The description's fixed path: `CHARACTER.md`, or `LOCATION.md` in a location bundle (§16.3).
  public var descriptionPath: String { Self.descriptionPath(of: dossierType) }

  /// The description's fixed path in a bundle of this type.
  public static func descriptionPath(of type: DossierType) -> String {
    type == .location ? "LOCATION.md" : "CHARACTER.md"
  }

  /// How people name the character (§5.1, DF-88): the member's `displayName`, which wins, or the
  /// manifest's copy when the member has none or there is no member. `nil` for a location, which
  /// has no display name (§16.3).
  public var displayName: String? {
    guard !isLocation else { return nil }
    return member?.displayName ?? manifest.displayName
  }

  /// A location's plates (§16.4), in manifest order: every take of every view. A `nil` variant
  /// matches any.
  public func plates(variant: String? = nil) -> [Asset] { assets(kind: .plate, variant: variant) }

  /// The selected plate for a view (§8.1's lookup), or `nil`.
  public func selectedPlate(variant: String) -> Asset? { selectedAsset(kind: .plate, variant: variant) }

  /// The selected plates, one per variant, in the LOCATIONS page's order (§16.6 step 3): the
  /// order of the keys of `location.views` as `manifest.json` has them, then the remaining
  /// variants in byte order. Where a variant has more than one selection (`E-MULTI-SELECTED`),
  /// the first in manifest order is used.
  public var selectedPlates: [Asset] {
    var byVariant: [[UInt8]: Asset] = [:]
    var variants: [String] = []
    for asset in manifest.assets where asset.kind == .plate && asset.status == .selected {
      guard let variant = asset.variant, byVariant[Array(variant.utf8)] == nil else { continue }
      byVariant[Array(variant.utf8)] = asset
      variants.append(variant)
    }
    var ordered: [Asset] = []
    var placed: Set<[UInt8]> = []
    for (variant, _) in manifest.location?.views ?? [] {
      let key = Array(variant.utf8)
      guard let plate = byVariant[key], placed.insert(key).inserted else { continue }
      ordered.append(plate)
    }
    for variant in variants.sorted(by: { $0.precedesInByteOrder($1) }) where placed.insert(Array(variant.utf8)).inserted {
      if let plate = byVariant[Array(variant.utf8)] { ordered.append(plate) }
    }
    return ordered
  }

  /// `prompts.identity` (§5.5).
  public var identityPrompt: String? { manifest.prompts?.identity }

  /// `artStyle` from `CHARACTER.md`'s front matter (§9.1).
  public var artStyle: String? { description?.frontMatterText("artStyle") }

  /// The selected page (§12), as a file.
  public var pageURL: URL? {
    selectedAsset(kind: .dossier).flatMap { fileURL(forPath: $0.path) }
  }
}
