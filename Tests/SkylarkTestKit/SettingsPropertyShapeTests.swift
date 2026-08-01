import Foundation
import Testing

/// Guard for the bug class CLAUDE.md calls out by name: a settings property on
/// `AppController` that is COMPUTED from `UserDefaults`/`SMAppService` is
/// invisible to `@Observable`, so a SwiftUI toggle bound to it writes the value
/// but never re-renders — the control looks dead or snaps back. It shipped three
/// times (v0.2.2 cleanupOverride, v0.7.3 dictionary/history toggles, and Launch
/// at Login). `AppController` lives in an executable target that tests can't
/// import, so the rule is enforced on the source text instead.
@Suite("AppController settings-property shape")
struct SettingsPropertyShapeTests {
    /// `Tests/SkylarkTestKit/…` → repo root → the controller's source.
    private static var appControllerSource: String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SkylarkTestKit
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let path = root.appendingPathComponent("Sources/Skylark/AppController.swift")
        return try? String(contentsOf: path, encoding: .utf8)
    }

    /// Member-level computed properties (`    var x: T {` … `    }`) and their
    /// bodies. Deliberately crude — indentation is the only structure a text
    /// scan needs, and the file is consistently formatted.
    private static func computedProperties(in source: String) -> [(name: String, body: String)] {
        let lines = source.components(separatedBy: "\n")
        var found: [(String, String)] = []
        for (index, line) in lines.enumerated() {
            guard line.hasPrefix("    "), !line.hasPrefix("     "),
                  line.hasSuffix("{"), !line.contains("="),
                  let varRange = line.range(of: " var "),
                  line.contains(":")
            else { continue }
            let afterVar = line[varRange.upperBound...]
            guard let colon = afterVar.firstIndex(of: ":") else { continue }
            let name = afterVar[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            var body: [String] = []
            var cursor = index + 1
            while cursor < lines.count, lines[cursor] != "    }" {
                body.append(lines[cursor])
                cursor += 1
            }
            found.append((name, body.joined(separator: "\n")))
        }
        return found
    }

    @Test("No AppController property is computed from UserDefaults or SMAppService")
    func noComputedSettingsProperties() throws {
        guard let source = Self.appControllerSource else { return } // source not adjacent
        let offenders = Self.computedProperties(in: source)
            .filter { $0.body.contains("UserDefaults") || $0.body.contains("SMAppService") }
            .map(\.name)
        #expect(
            offenders.isEmpty,
            """
            Computed settings properties are invisible to @Observable — a bound \
            control writes but never re-renders. Make these stored \
            `private(set) var`s (init from the source of truth, setter assigns + \
            persists): \(offenders.joined(separator: ", "))
            """
        )
    }

    /// The specific one this test was added for.
    @Test("Launch at Login is a stored property")
    func launchAtLoginIsStored() throws {
        guard let source = Self.appControllerSource else { return }
        #expect(source.contains("private(set) var launchAtLoginStatus: SMAppService.Status ="))
        #expect(source.contains("func refreshLaunchAtLoginStatus()"))
    }
}
