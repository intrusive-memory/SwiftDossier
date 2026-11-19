import DossierCore
import Foundation

/// The atomic write of a description file (`CHARACTER.md`, `LOCATION.md`) into its bundle, shared
/// by ``CharacterDescription/write(to:)`` and ``LocationDescription/write(to:)``.
enum DescriptionFile {
  static func write(_ text: String, as fileName: String, to bundle: inout DossierBundle) throws {
    let writer = ManifestWriter(bundle: bundle.url)
    let current = try writer.currentManifest()

    let manager = FileManager.default
    let destination = bundle.url.appendingPathComponent(fileName)
    let bytes = Data(text.utf8)
    guard !bytes.isEmpty else { throw DossierWriteError.zeroByteFiles([fileName]) }

    var prior: Data?
    if let attributes = try? manager.attributesOfItem(atPath: destination.path) {
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw DossierWriteError.destinationNotInBundle(fileName)
      }
      guard let data = try? Data(contentsOf: destination) else {
        throw DossierWriteError.fileUnreadable(fileName)
      }
      prior = data
    }

    // The same text, unlisted, still needs a rescan to list it.
    let isSameText = prior == bytes
    let isListed = current.files.contains { $0.path == fileName }
    if isSameText, isListed { return }

    let target = bundle.url
    try UpdateHolding.holding(bundle: target, label: "write \(fileName)") {
      if !isSameText { try replace(destination, with: bytes) }
      do {
        let manifest = try writer.update(accepting: isSameText ? [] : [fileName]) { _, _ in }
        bundle = DossierBundle(url: bundle.url, manifest: manifest, member: bundle.member)
      } catch {
        if !isSameText {
          if let prior {
            try? replace(destination, with: prior)
          } else {
            try? manager.removeItem(at: destination)
          }
        }
        throw error
      }
    }
  }

  /// A temporary file in the same directory, renamed over the target. A leading `.` keeps it out
  /// of §5.2's inventory if the process dies first.
  private static func replace(_ destination: URL, with bytes: Data) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".description-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    do {
      try bytes.write(to: temporary)
    } catch {
      throw DossierWriteError.replaceFailed(error.localizedDescription)
    }
    guard rename(temporary.path, destination.path) == 0 else {
      throw DossierWriteError.replaceFailed(String(cString: strerror(errno)))
    }
  }
}
