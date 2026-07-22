import Foundation
import Testing
import SkylarkCore

@Suite("DeepLink parsing")
struct DeepLinkTests {
    private func url(_ string: String) -> URL {
        // `URL(string:)` fails on some malformed inputs used deliberately
        // below; force-unwrap only the ones expected to parse as a URL at all.
        guard let url = URL(string: string) else {
            fatalError("test fixture URL failed to parse: \(string)")
        }
        return url
    }

    @Test("record/start")
    func recordStart() {
        #expect(DeepLink.parse(url("skylark://record/start")) == .recordStart)
    }

    @Test("record/stop")
    func recordStop() {
        #expect(DeepLink.parse(url("skylark://record/stop")) == .recordStop)
    }

    @Test("record/toggle")
    func recordToggle() {
        #expect(DeepLink.parse(url("skylark://record/toggle")) == .recordToggle)
    }

    @Test("record/cancel")
    func recordCancel() {
        #expect(DeepLink.parse(url("skylark://record/cancel")) == .recordCancel)
    }

    @Test("settings")
    func settings() {
        #expect(DeepLink.parse(url("skylark://settings")) == .settings)
    }

    @Test("settings with trailing slash")
    func settingsTrailingSlash() {
        #expect(DeepLink.parse(url("skylark://settings/")) == .settings)
    }

    @Test("wrong scheme is rejected")
    func wrongScheme() {
        #expect(DeepLink.parse(url("http://record/start")) == nil)
        #expect(DeepLink.parse(url("skylarks://record/start")) == nil)
    }

    @Test("unknown host is rejected")
    func unknownHost() {
        #expect(DeepLink.parse(url("skylark://frobnicate")) == nil)
    }

    @Test("unknown record action is rejected")
    func unknownRecordAction() {
        #expect(DeepLink.parse(url("skylark://record/explode")) == nil)
    }

    @Test("extra path segments are rejected")
    func extraPathSegments() {
        #expect(DeepLink.parse(url("skylark://record/start/extra")) == nil)
        #expect(DeepLink.parse(url("skylark://settings/general")) == nil)
    }

    @Test("missing path on record host is rejected")
    func missingRecordPath() {
        #expect(DeepLink.parse(url("skylark://record")) == nil)
    }

    @Test("host is case-insensitive")
    func hostCaseInsensitive() {
        #expect(DeepLink.parse(url("skylark://RECORD/start")) == .recordStart)
        #expect(DeepLink.parse(url("skylark://Settings")) == .settings)
    }

    @Test("junk input is rejected")
    func junk() {
        #expect(DeepLink.parse(url("not-a-scheme-at-all")) == nil)
        #expect(DeepLink.parse(url("skylark://")) == nil)
    }
}
