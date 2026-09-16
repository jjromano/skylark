import Foundation
import SkylarkCore
import Testing

/// Every cloud slug in `ModelRegistryEntry.seed` shows up in the quick
/// selectors the moment it lands. If nobody adds the matching
/// `ModelInfo.cloudSTT` / `cloudCleanup` entry, the Models pane renders that row
/// with no blurb, no accuracy/speed dots and no cost — the user is asked to pick
/// a model the app refuses to describe. The two files are edited in separate
/// passes (registry curation vs. copy), so the pairing needs a guard rather than
/// a convention.
///
/// `ModelInfo` lives in the `Skylark` executable target, which tests cannot
/// import, so this reads its source the way `SettingsPropertyShapeTests` does.
@Suite("Seed slugs are described in ModelInfo")
struct ModelInfoCoverageTests {
    private static var modelInfoSource: String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SkylarkTestKit
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let path = root.appendingPathComponent("Sources/Skylark/Settings/ModelInfo.swift")
        return try? String(contentsOf: path, encoding: .utf8)
    }

    /// The slugs keyed inside one dictionary literal, e.g. `cloudSTT`.
    private static func keys(inDictionary name: String, of source: String) -> Set<String> {
        guard let start = source.range(of: "static let \(name): [String: Entry] = [") else { return [] }
        let rest = source[start.upperBound...]
        // The literal ends at the first line that is exactly the closing
        // bracket at type-member indentation.
        let body = rest.components(separatedBy: "\n    ]").first ?? ""
        var slugs: Set<String> = []
        for line in body.components(separatedBy: "\n") {
            // Only a key line, `"slug": Entry(`. A description's opening line is
            // also a quoted string at similar indentation, so the `": Entry(`
            // tail is what separates the two.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\": Entry("),
                  let close = trimmed.dropFirst().firstIndex(of: "\"")
            else { continue }
            slugs.insert(String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]))
        }
        return slugs
    }

    @Test("Every seeded cloud STT slug has a ModelInfo entry")
    func sttSlugsDescribed() throws {
        let source = try #require(Self.modelInfoSource)
        let described = Self.keys(inDictionary: "cloudSTT", of: source)
        #expect(!described.isEmpty, "cloudSTT literal not found — the parser above needs updating")
        let seeded = ModelRegistryEntry.seed.filter { $0.kind == .stt }.map(\.slug)
        let missing = seeded.filter { !described.contains($0) }
        #expect(missing.isEmpty, "Add a ModelInfo.cloudSTT entry for: \(missing.joined(separator: ", "))")
    }

    @Test("Every seeded cloud cleanup slug has a ModelInfo entry")
    func cleanupSlugsDescribed() throws {
        let source = try #require(Self.modelInfoSource)
        let described = Self.keys(inDictionary: "cloudCleanup", of: source)
        #expect(!described.isEmpty, "cloudCleanup literal not found — the parser above needs updating")
        let seeded = ModelRegistryEntry.seed.filter { $0.kind == .cleanup }.map(\.slug)
        let missing = seeded.filter { !described.contains($0) }
        #expect(missing.isEmpty, "Add a ModelInfo.cloudCleanup entry for: \(missing.joined(separator: ", "))")
    }

    /// The reverse direction: a blurb for a slug that is no longer seeded is
    /// dead copy that will quietly rot. Ad-hoc/custom slugs never live here.
    @Test("ModelInfo describes no slug the seed has dropped")
    func noOrphanedDescriptions() throws {
        let source = try #require(Self.modelInfoSource)
        let seeded = Set(ModelRegistryEntry.seed.map(\.slug))
        let described = Self.keys(inDictionary: "cloudSTT", of: source)
            .union(Self.keys(inDictionary: "cloudCleanup", of: source))
        let orphans = described.subtracting(seeded).sorted()
        #expect(orphans.isEmpty, "ModelInfo still describes unseeded slugs: \(orphans.joined(separator: ", "))")
    }
}
