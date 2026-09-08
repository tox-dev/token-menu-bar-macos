// swift-tools-version: 6.0
import Foundation
import PackageDescription

let nativeTests = ProcessInfo.processInfo.environment["TOKEN_MENU_BAR_TEST_DESKTOP"] == "github-hosted"
if nativeTests {
  guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
    ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted"
  else {
    FileHandle.standardError.write(Data("Native tests require a GitHub-hosted desktop. Run just test locally.\n".utf8))
    exit(1)
  }
}
let nativeTestSources = nativeTests || ProcessInfo.processInfo.environment["TOKEN_MENU_BAR_COMPILE_NATIVE_TESTS"] == "1"

let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  // SwiftPM 6.0 has no typed warnings-as-errors setting; this keeps Xcode 16 support.
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
    .target(
      name: "TokenMenuBarTestSupport",
      dependencies: ["TokenMenuBarCore"],
      path: "Tests/TokenMenuBarTestSupport",
      swiftSettings: strict
    ),
    .testTarget(
      name: "TokenMenuBarCoreTests",
      dependencies: ["TokenMenuBarCore", "TokenMenuBarTestSupport"],
      resources: [.copy("Fixtures")],
      swiftSettings: strict
    ),
    .testTarget(
      name: "TokenMenuBarUITests",
      dependencies: ["TokenMenuBarUI", "TokenMenuBarTestSupport"]
        + (nativeTestSources ? [.target(name: "TokenMenuBarNativeGuard")] : []),
      exclude: nativeTestSources ? [] : ["Native"],
      swiftSettings: strict + (nativeTestSources ? [] : [.define("NONPRESENTING_TESTS")])
    ),
    .target(name: "TokenMenuBarNativeGuard", path: "Tests/TokenMenuBarNativeGuard"),
    .testTarget(
      name: "TokenMenuBarWidgetsTests",
      dependencies: ["TokenMenuBarWidgets", "TokenMenuBarTestSupport"],
      swiftSettings: strict + (nativeTests ? [] : [.define("NONPRESENTING_TESTS")])
    ),
  ]
)
