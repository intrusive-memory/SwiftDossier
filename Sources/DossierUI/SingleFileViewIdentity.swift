/// The label and SF Symbol a host shows for a single-file view, in a tab or a picker (SFV-3).
///
/// Each view exposes its own as `identity`, both as a static and per instance, so a host can list
/// the views without making one.
public struct SingleFileViewIdentity: Sendable, Equatable {
  /// The words a host shows, such as "Character".
  public let label: String
  /// An SF Symbol name.
  public let systemImage: String

  public init(label: String, systemImage: String) {
    self.label = label
    self.systemImage = systemImage
  }

  /// `CharacterEditor`: "Character", `person.crop.rectangle`.
  public static let characterEditor = SingleFileViewIdentity(label: "Character", systemImage: "person.crop.rectangle")
  /// `LocationEditor`: "Location", `mappin.circle`.
  public static let locationEditor = SingleFileViewIdentity(label: "Location", systemImage: "mappin.circle")
  /// `CharacterPreview`: "Character Preview", `person.text.rectangle`.
  public static let characterPreview = SingleFileViewIdentity(
    label: "Character Preview", systemImage: "person.text.rectangle")
  /// `LocationPreview`: "Location Preview", `mappin.and.ellipse`.
  public static let locationPreview = SingleFileViewIdentity(
    label: "Location Preview", systemImage: "mappin.and.ellipse")
}
