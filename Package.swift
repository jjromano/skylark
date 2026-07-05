// swift-tools-version: 6.2
import PackageDescription
import Foundation

// swift-testing ships as a framework inside the Command Line Tools, but SwiftPM
// (CLT-only, no Xcode) doesn't add its search path or rpath automatically. When
// that framework is present, wire the flags so building/running tests works. On
// machines with full Xcode the framework is found normally and these are empty.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
var testingSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
var testingLinkerSettings: [LinkerSetting] = []
if FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework") {
    testingSwiftSettings.append(.unsafeFlags(["-F", cltFrameworks]))
    testingLinkerSettings.append(.unsafeFlags([
        "-F", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
    ]))
}

let package = Package(
    name: "Skylark",
    platforms: [
        // `.v26` is not yet exposed in this PackageDescription; use the string form.
        .macOS("26.0"),
    ],
    products: [
        .library(name: "SkylarkCore", targets: ["SkylarkCore"]),
        .executable(name: "Skylark", targets: ["Skylark"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SkylarkCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Skylark",
            dependencies: ["SkylarkCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Shared home for every `@Test` case, consumed by both the test bundle
        // and the standalone runner (see Sources/SkylarkTestRunner/main.swift).
        .target(
            name: "SkylarkTestKit",
            dependencies: ["SkylarkCore"],
            path: "Tests/SkylarkTestKit",
            swiftSettings: testingSwiftSettings
        ),
        .executableTarget(
            name: "SkylarkTestRunner",
            dependencies: ["SkylarkTestKit"],
            swiftSettings: testingSwiftSettings,
            linkerSettings: testingLinkerSettings
        ),
        .testTarget(
            name: "SkylarkCoreTests",
            dependencies: ["SkylarkTestKit"],
            swiftSettings: testingSwiftSettings,
            linkerSettings: testingLinkerSettings
        ),
    ]
)
