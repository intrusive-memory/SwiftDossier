// swift-tools-version: 6.2

import Foundation
import PackageDescription

// In CI we always pin to released remotes. Locally, prefer a sibling checkout
// at ../<name> if present so in-flight changes can be exercised end-to-end
// without publishing a release. Falls back to the remote pin if the sibling
// directory is missing, so fresh clones still build.
//
// When this manifest is evaluated as a transitive dependency inside Xcode's
// `SourcePackages/checkouts/` or SwiftPM's `.build/checkouts/`, every other
// dependency lives as a sibling in the same directory. Treating those as
// in-development local paths produces conflicting package identities, so we
// must skip the sibling shortcut in that context.
let manifestDir = (#filePath as NSString).deletingLastPathComponent
let isSPMCheckout =
  manifestDir.contains("/SourcePackages/checkouts/")
  || manifestDir.contains("/.build/checkouts/")
let isCI = ProcessInfo.processInfo.environment["CI"] == "true"
let useLocalSiblings = !isCI && !isSPMCheckout

func sibling(_ name: String, remote: String, from version: Version) -> Package.Dependency {
  let localPath = "../\(name)"
  if useLocalSiblings && FileManager.default.fileExists(atPath: localPath) {
    return .package(path: localPath)
  }
  return .package(url: remote, .upToNextMajor(from: version))
}

/// Same sibling-priority pattern as ``sibling(_:remote:from:)`` but pins to a
/// remote branch when no local sibling exists. Use only when a temporary
/// pre-release dependency on a feature branch is required; switch back to the
/// version-pinned ``sibling(_:remote:from:)`` once the upstream tags a release.
func sibling(_ name: String, remote: String, branch: String) -> Package.Dependency {
  let localPath = "../\(name)"
  if useLocalSiblings && FileManager.default.fileExists(atPath: localPath) {
    return .package(path: localPath)
  }
  return .package(url: remote, branch: branch)
}

// ArgumentParser is linked only by `DossierCLICore` (and so, transitively, the
// `dossier` executable). The read and write libraries never link it.
// `DossierCLICore` is deliberately not a product: it exists so command logic
// is unit-testable without a subprocess.

let package = Package(
  name: "SwiftDossier",
  platforms: [
    .macOS(.v26),
    .iOS(.v26),
  ],
  products: [
    .library(name: "DossierCore", targets: ["DossierCore"]),
    .library(name: "Dossier", targets: ["Dossier"]),
    .executable(name: "dossier", targets: ["dossier"]),
  ],
  dependencies: [
    sibling(
      "SwiftReparto",
      remote: "https://github.com/intrusive-memory/SwiftReparto.git",
      from: "0.2.1"),
    .package(url: "https://github.com/jpsim/Yams.git", .upToNextMajor(from: "6.2.2")),
    .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "1.7.1")),
  ],
  targets: [
    .target(
      name: "DossierCore",
      dependencies: [
        .product(name: "SwiftReparto", package: "SwiftReparto"),
        .product(name: "Yams", package: "Yams"),
      ],
      // `.copy`, never `.process`: the bytes must equal the pinned revision's.
      // Entries are listed individually because a directory named `Resources`
      // at an iOS bundle's root makes codesign reject the bundle.
      resources: [
        .copy("Resources/PINNED.sha256"),
        .copy("Resources/tiers.json"),
        .copy("Resources/review.json"),
        .copy("Resources/fields.json"),
      ],
      swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
    .target(
      name: "Dossier",
      // SwiftReparto directly: `CAST.md` is written only through it (SD-12).
      // Yams directly: `CHARACTER.md`'s front matter is edited by key (§9.1).
      dependencies: [
        "DossierCore",
        .product(name: "SwiftReparto", package: "SwiftReparto"),
        .product(name: "Yams", package: "Yams"),
      ],
      resources: [
        .copy("Resources/PINNED.sha256"),
        .copy("Resources/schemas"),
        // `.copy` matters most here: `template/README.md` rule 1 hashes these bytes.
        .copy("Resources/template"),
        .copy("Resources/data"),
      ],
      swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
    .target(
      name: "DossierCLICore",
      dependencies: [
        "Dossier",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
    .executableTarget(
      name: "dossier",
      dependencies: ["DossierCLICore"],
      // Not `Sources/dossier`: on a case-insensitive filesystem that is the
      // same directory as `Sources/Dossier`.
      path: "Sources/dossier-cli",
      swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
    .testTarget(
      name: "DossierCoreTests",
      dependencies: ["DossierCore"],
      swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
    .testTarget(
      name: "DossierTests",
      dependencies: [
        "Dossier",
        .product(name: "SwiftReparto", package: "SwiftReparto"),
      ],
      swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
    .testTarget(
      name: "DossierCLICoreTests",
      dependencies: [
        "DossierCLICore",
        "Dossier",
        "DossierCore",
      ],
      swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
