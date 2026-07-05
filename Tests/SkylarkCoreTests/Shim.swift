// The real tests live in the `SkylarkTestKit` target so they can be shared by
// both this XCTest/swift-testing bundle (`swift test`) and the standalone
// `SkylarkTestRunner` executable (`make test` on the CLT-only build box).
// Importing the kit links its `@Test` functions into this bundle so
// `swift test` discovers them on toolchains that can host test bundles.
import SkylarkTestKit
