import DossierCore

/// One thing a validator has to say about a bundle or a cast (§14).
public struct Finding: Sendable, Equatable {
  /// How much a finding matters.
  public enum Level: String, Sendable, Equatable {
    /// A reader may reject the bundle.
    case error
    /// A reader opens the bundle.
    case warning
  }

  /// §14's stable codes.
  public enum Code: String, Sendable, Equatable, CaseIterable {
    /// Unknown `manifestVersion`.
    case version = "E-VERSION"
    /// Name invalid (§2).
    case name = "E-NAME"
    /// Bundle name, manifest `character`, `CAST.md` member and `CHARACTER.md` disagree (§3), or,
    /// for a location, bundle name, manifest `character`, `LOCATIONS.md` entry and `LOCATION.md`
    /// (§16.1).
    case nameMismatch = "E-NAME-MISMATCH"
    /// `CAST.md` can't be read, or `PROJECT.md` can't be read for its `locations` key, or the
    /// locations index it names can't be read (§16.2).
    case cast = "E-CAST"
    /// A directory a member points at has no `manifest.json`, or it isn't a JSON object.
    case manifest = "E-MANIFEST"
    /// A version 2 manifest in a directory without `.dossier`.
    case notBundle = "E-NOT-BUNDLE"
    /// A `CAST.md` member points at a location bundle, or a `LOCATIONS.md` entry at a character
    /// bundle (§16.1).
    case typeMismatch = "E-TYPE-MISMATCH"
    /// A path in the manifest breaks §5.2's rules.
    case path = "E-PATH"
    /// A `files` entry has no file.
    case fileMissing = "E-FILE-MISSING"
    /// A file's hash or size doesn't match its entry.
    case fileHash = "E-FILE-HASH"
    /// A zero-byte file.
    case zeroByte = "E-ZERO-BYTE"
    /// `manifestChecksum` doesn't match.
    case checksum = "E-CHECKSUM"
    /// An asset with no `files` entry.
    case assetNoFile = "E-ASSET-NO-FILE"
    /// Two assets with the same `path`.
    case assetDuplicate = "E-ASSET-DUPLICATE"
    /// More than one `selected` for a `kind` + `variant` (`voiceSample`: + `model`).
    case multiSelected = "E-MULTI-SELECTED"
    /// A retired kind in a version 2 manifest.
    case kindRetired = "E-KIND-RETIRED"
    /// The manifest fails its schema.
    case schema = "E-SCHEMA"
    /// A file with no asset entry.
    case unclassified = "W-UNCLASSIFIED"
    /// A derived asset's inputs changed.
    case stale = "W-STALE"
    /// Wrong aspect ratio for the kind, on an asset that isn't imported (§8.1).
    case shape = "W-SHAPE"
    /// An `expression` variant outside the standard set, or a `view` variant outside the standard
    /// set and its families (§8.1).
    case variant = "W-VARIANT"
    /// A `.json` sidecar in `images/`.
    case sidecar = "W-SIDECAR"
    /// No index entry points at the bundle (§3, §16.2).
    case orphan = "W-ORPHAN"
    /// The member's or entry's `manifest:` doesn't point at this bundle (§3), or `PROJECT.md`'s
    /// `locations` reaches no file (§16.2).
    case pointer = "W-POINTER"
    /// A member with a `manifest:` has no `role`.
    case role = "W-ROLE"
    /// The manifest's `displayName` differs from the member's (§5.1).
    case displayName = "W-DISPLAY-NAME"
    /// `voices.voxalta` doesn't name the selected `vox`.
    case voiceElsewhere = "W-VOICE-ELSEWHERE"
    /// `voicePrompt` differs from the vox's.
    case voicePrompt = "W-VOICE-PROMPT"
    /// An undefined or unused footnote.
    case footnote = "W-FOOTNOTE"
    /// The page is over 10,000,000 bytes.
    case pageSize = "W-PAGE-SIZE"
    /// The page references something outside itself (§11).
    case pageExternal = "W-PAGE-EXTERNAL"
    /// A required tier row is missing.
    case incomplete = "W-INCOMPLETE"
    /// A version 1 manifest.
    case v1 = "W-V1"

    /// The level §14 gives this code.
    public var level: Level { rawValue.hasPrefix("E-") ? .error : .warning }
  }

  /// The stable code.
  public let code: Code
  /// A description of the finding, for people.
  public let message: String
  /// What the finding is about, or `nil` when it's about no one file. Relative to the
  /// directory validated: the bundle, or for a cast or project the project directory, the one
  /// holding `CAST.md`.
  public let path: String?

  /// The level §14 gives the code.
  public var level: Level { code.level }

  /// A finding.
  package init(code: Code, message: String, path: String?) {
    self.code = code
    self.message = message
    self.path = path
  }
}

/// What a validator found (§14): the findings, and completeness against each tier.
public struct ValidationReport: Sendable, Equatable {
  /// A bundle measured against its member's tier.
  public struct BundleCompleteness: Sendable, Equatable {
    /// The bundle, relative to the directory validated. Empty when the bundle is that directory.
    public let bundlePath: String
    /// Every row with its state.
    public let report: CompletenessReport
  }

  /// Every finding, in a stable order.
  public let findings: [Finding]
  /// One entry per bundle whose completeness is defined, which takes a `CAST.md` member
  /// with a `role` and a readable version 2 manifest (§8.3, Appendix A).
  public let completeness: [BundleCompleteness]

  /// A report.
  package init(findings: [Finding], completeness: [BundleCompleteness]) {
    self.findings = findings
    self.completeness = completeness
  }

  /// 0 clean, 1 warnings only, 2 errors.
  public var exitStatus: Int32 {
    if findings.contains(where: { $0.level == .error }) { return 2 }
    return findings.isEmpty ? 0 : 1
  }
}
