import DossierCore
import Foundation

/// The regular files under a bundle directory, walked from the disk (§5.2).
///
/// A symlink isn't a file here, and isn't followed, so nothing read through this type
/// lies outside the bundle whatever the manifest says.
struct BundleInventory {
  struct File {
    /// Relative to the bundle, as the disk spells it.
    let path: String
    let url: URL
    let size: Int64
    /// A path segment starts with `.`.
    let isHidden: Bool
  }

  /// Every regular file except `manifest.json`, in byte order of the path. Hidden files
  /// are here so a `files` entry can name one; §5.2's inventory is ``visible``.
  let files: [File]
  private let byNormalizedPath: [[UInt8]: File]

  /// §5.2's inventory.
  var visible: [File] { files.filter { !$0.isHidden } }

  // SPEC-GAP: §5.2: how a manifest path compares with a name on disk isn't said. They're
  // compared as NFC strings, as §3 compares paths, because a filesystem may store either
  // form. The comparison is case-sensitive, so the result doesn't depend on the filesystem.
  static func key(_ path: String) -> [UInt8] {
    Array(path.precomposedStringWithCanonicalMapping.utf8)
  }

  /// The file a manifest path names.
  func file(at path: String) -> File? { byNormalizedPath[Self.key(path)] }

  init(bundle url: URL) {
    var found: [File] = []
    Self.walk(url, prefix: "", hidden: false, into: &found)
    files = found.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    byNormalizedPath = Dictionary(found.map { (Self.key($0.path), $0) }) { first, _ in first }
  }

  private static func walk(_ directory: URL, prefix: String, hidden: Bool, into found: inout [File]) {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys)
    else { return }
    for entry in entries {
      guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true
      else { continue }
      let name = entry.lastPathComponent
      let path = prefix + name
      let isHidden = hidden || name.hasPrefix(".")
      if values.isDirectory == true {
        walk(entry, prefix: path + "/", hidden: isHidden, into: &found)
      } else if values.isRegularFile == true, path != "manifest.json" {
        found.append(File(path: path, url: entry, size: Int64(values.fileSize ?? 0), isHidden: isHidden))
      }
    }
  }
}
