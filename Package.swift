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
    // This CLT distribution ships `Testing.framework`'s Foundation cross-import
    // overlay declaration (`Testing.swiftcrossimport/Foundation.swiftoverlay`,
    // pointing at `_Testing_Foundation`) without the overlay module itself
    // (`_Testing_Foundation.framework/Modules` is empty — no .swiftmodule). Any
    // file that imports both `Testing` and `Foundation` then fails with
    // "no such module '_Testing_Foundation'". Disabling cross-import overlay
    // search avoids the auto-import; on machines with full Xcode (where the
    // overlay is actually present) this flag is a no-op.
    testingSwiftSettings.append(.unsafeFlags(["-Xfrontend", "-disable-cross-import-overlay-search"]))
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
        .executable(name: "SkylarkBench", targets: ["SkylarkBench"]),
    ],
    dependencies: [
        // Local Parakeet ASR + Silero VAD (Apache-2.0, no external transitive deps).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
        // Persistence (MIT) — history/dictionary/modes/model-registry storage.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // WhisperKit fallback STT engine (MIT). Package/repo renamed to
        // argmax-oss-swift; we consume only the `WhisperKit` product (which pulls
        // just its `ArgmaxCore` target — no ArgumentParser/Vapor).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
    ],
    targets: [
        // llama.cpp (MIT) as a prebuilt binary framework — local GGUF cleanup
        // models (Qwen3). Consumption approach follows `eastriverlee/LLM.swift`'s
        // Package.swift: a `binaryTarget` on the official `llama.xcframework`
        // rather than building llama.cpp from source. Critically, that prebuilt
        // framework embeds its Metal shaders and compiles them at RUNTIME
        // (`GGML_METAL_EMBED_LIBRARY`), so it needs no `metal` compiler — which
        // this Command-Line-Tools-only toolchain does not have.
        //
        // Vendored copy is THINNED to the single slice we ship (macos-arm64,
        // ~6 MB of the upstream 780 MB all-platform artifact). Upstream release
        // b10107; license at `Vendor/LICENSE-llama.cpp.txt`.
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .target(
            name: "SkylarkCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                "llama",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Skylark",
            dependencies: ["SkylarkCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SkylarkBench",
            dependencies: ["SkylarkCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Shared home for every `@Test` case, consumed by both the test bundle
        // and the standalone runner (see Sources/SkylarkTestRunner/main.swift).
        .target(
            name: "SkylarkTestKit",
            dependencies: [
                "SkylarkCore",
                // Needed to drive `SkylarkDatabase.migrator` directly against a
                // raw `DatabaseQueue` in migration tests (seeding pre-"v3" rows
                // that a fully-migrated `SkylarkDatabase.inMemory()` can't
                // represent).
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
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
