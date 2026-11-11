// swift-tools-version: 6.2

import PackageDescription

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
    .library(name: "DossierUI", targets: ["DossierUI"]),
    .executable(name: "dossier", targets: ["dossier"]),
  ],
  dependencies: [
    .package(url: "https://github.com/intrusive-memory/SwiftReparto.git", .upToNextMajor(from: "0.2.1")),
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
    // The viewer (PV-17). The only target that links a UI framework: `DossierCore` and `Dossier`
    // import none.
    .target(
      name: "DossierUI",
      // `DossierCore` is already `Dossier`'s; it's named because `UpdateStatus` and
      // `DossierError` are used directly.
      dependencies: ["Dossier", "DossierCore"],
      swiftSettings: [.enableUpcomingFeature("StrictConcurrency")],
      linkerSettings: [
        .linkedFramework("SwiftUI"),
        .linkedFramework("WebKit"),
      ]
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
      name: "DossierUITests",
      dependencies: [
        "DossierUI",
        "Dossier",
        "DossierCore",
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
