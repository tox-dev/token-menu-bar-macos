// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .treatAllWarnings(as: .error),
]

let package = Package(
  name: "TokenMenuBar",
  platforms: [.macOS(.v26)],
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
