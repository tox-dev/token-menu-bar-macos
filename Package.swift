// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .unsafeFlags(["-warnings-as-errors"]),
]

let package = Package(
  name: "TokenMenuBar",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "TokenMenuBarCore", targets: ["TokenMenuBarCore"]),
    .library(name: "TokenMenuBarUI", targets: ["TokenMenuBarUI"]),
    .library(name: "TokenMenuBarWidgets", targets: ["TokenMenuBarWidgets"]),
    .executable(name: "TokenMenuBar", targets: ["TokenMenuBar"]),
  ],
  targets: [
    .target(name: "TokenMenuBarCore", swiftSettings: strict),
    .target(
      name: "TokenMenuBarUI",
      dependencies: ["TokenMenuBarCore"],
      resources: [.process("Resources")],
      swiftSettings: strict
    ),
    .target(name: "TokenMenuBarWidgets", dependencies: ["TokenMenuBarCore"], swiftSettings: strict),
    .executableTarget(name: "TokenMenuBar", dependencies: ["TokenMenuBarUI"], swiftSettings: strict),
    .testTarget(
      name: "TokenMenuBarCoreTests",
      dependencies: ["TokenMenuBarCore"],
      resources: [.copy("Fixtures")],
      swiftSettings: strict
    ),
    .testTarget(name: "TokenMenuBarUITests", dependencies: ["TokenMenuBarUI"], swiftSettings: strict),
    .testTarget(name: "TokenMenuBarWidgetsTests", dependencies: ["TokenMenuBarWidgets"], swiftSettings: strict),
  ]
)
