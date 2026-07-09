import Testing
import Foundation
@testable import SkylarkCore

@Suite("SnippetStore + SnippetMatcher")
struct SnippetStoreTests {
    private func makeDB() throws -> SkylarkDatabase {
        try SkylarkDatabase.inMemory()
    }

    // MARK: - SnippetStore CRUD

    @Test("add inserts a snippet and all() returns it")
    func addAndAll() async throws {
        let store = SnippetStore(db: try makeDB())
        let record = try await store.add(trigger: "my email", replacement: "jj@example.com")
        #expect(record.id != nil)

        let all = try await store.all()
        #expect(all.count == 1)
        #expect(all.first?.trigger == "my email")
        #expect(all.first?.replacement == "jj@example.com")
    }

    @Test("add trims whitespace from trigger and replacement")
    func addTrimsWhitespace() async throws {
        let store = SnippetStore(db: try makeDB())
        let record = try await store.add(trigger: "  my email  ", replacement: "  jj@example.com  ")
        #expect(record.trigger == "my email")
        #expect(record.replacement == "jj@example.com")
    }

    @Test("add throws duplicateTrigger for a case-insensitive collision")
    func addDuplicateTriggerThrows() async throws {
        let store = SnippetStore(db: try makeDB())
        _ = try await store.add(trigger: "My Email", replacement: "a@b.com")

        await #expect(throws: SnippetStoreError.self) {
            try await store.add(trigger: "my email", replacement: "c@d.com")
        }
        let all = try await store.all()
        #expect(all.count == 1)
    }

    @Test("update renames trigger/replacement in place")
    func updateInPlace() async throws {
        let store = SnippetStore(db: try makeDB())
        let record = try await store.add(trigger: "sig", replacement: "old sig")
        let id = try #require(record.id)

        try await store.update(id: id, trigger: "signature", replacement: "new sig")
        let all = try await store.all()
        #expect(all.count == 1)
        #expect(all.first?.trigger == "signature")
        #expect(all.first?.replacement == "new sig")
    }

    @Test("update throws duplicateTrigger when colliding with a different snippet")
    func updateDuplicateTriggerThrows() async throws {
        let store = SnippetStore(db: try makeDB())
        _ = try await store.add(trigger: "one", replacement: "1")
        let two = try await store.add(trigger: "two", replacement: "2")
        let id = try #require(two.id)

        await #expect(throws: SnippetStoreError.self) {
            try await store.update(id: id, trigger: "ONE", replacement: "2-updated")
        }
        let all = try await store.all()
        #expect(all.first { $0.id == id }?.trigger == "two")
    }

    @Test("update does not throw when the trigger is unchanged")
    func updateSameTriggerDoesNotThrow() async throws {
        let store = SnippetStore(db: try makeDB())
        let record = try await store.add(trigger: "sig", replacement: "old")
        let id = try #require(record.id)

        try await store.update(id: id, trigger: "sig", replacement: "new")
        let all = try await store.all()
        #expect(all.first?.replacement == "new")
    }

    @Test("delete removes the snippet")
    func delete() async throws {
        let store = SnippetStore(db: try makeDB())
        let record = try await store.add(trigger: "x", replacement: "y")
        let id = try #require(record.id)

        try await store.delete(id: id)
        let all = try await store.all()
        #expect(all.isEmpty)
    }

    // MARK: - SnippetMatcher (pure, no DB)

    @Test("Whole-utterance match ignores case, trims, and strips edge punctuation")
    func matcherNormalizesCaseTrimAndPunctuation() {
        let snippets = [SnippetRecord(trigger: "my email address", replacement: "jj@example.com")]
        #expect(SnippetMatcher.match(text: "My Email Address.", snippets: snippets) == "jj@example.com")
        #expect(SnippetMatcher.match(text: "  my email address  ", snippets: snippets) == "jj@example.com")
        #expect(SnippetMatcher.match(text: "my email address!?", snippets: snippets) == "jj@example.com")
    }

    @Test("Collapses internal whitespace before comparing")
    func matcherCollapsesInternalWhitespace() {
        let snippets = [SnippetRecord(trigger: "my email address", replacement: "jj@example.com")]
        #expect(SnippetMatcher.match(text: "my   email\naddress", snippets: snippets) == "jj@example.com")
    }

    @Test("Partial text containing the trigger does not match (whole-utterance only)")
    func matcherRequiresWholeUtterance() {
        let snippets = [SnippetRecord(trigger: "my email address", replacement: "jj@example.com")]
        #expect(SnippetMatcher.match(text: "please send my email address now", snippets: snippets) == nil)
        #expect(SnippetMatcher.match(text: "my email address please", snippets: snippets) == nil)
    }

    @Test("No matching trigger returns nil")
    func matcherNoMatchReturnsNil() {
        let snippets = [SnippetRecord(trigger: "trigger", replacement: "expansion")]
        #expect(SnippetMatcher.match(text: "something else entirely", snippets: snippets) == nil)
    }

    @Test("Empty snippet list returns nil")
    func matcherEmptySnippetList() {
        #expect(SnippetMatcher.match(text: "anything", snippets: []) == nil)
    }
}
