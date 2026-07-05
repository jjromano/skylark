import Testing

// Standalone swift-testing entry point.
//
// On the CLT-only build box there is no XCTest host, so `swift test` builds the
// bundle but never executes it. This executable links `SkylarkTestKit` (which
// contains every `@Test`) and invokes swift-testing directly, so `make test`
// actually runs and reports the suite. Run:
//
//     swift run SkylarkTestRunner --testing-library swift-testing
//
// On machines with full Xcode, `swift test` works normally against the
// `SkylarkCoreTests` target instead.
await Testing.__swiftPMEntryPoint() as Never
