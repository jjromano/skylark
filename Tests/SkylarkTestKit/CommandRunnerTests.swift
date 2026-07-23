import Testing
import SkylarkCore

/// Local backend fake for command-runner tests: configurable availability and a
/// fixed output (or a thrown error) for `generate`.
private actor CmdFakeLocalBackend: LocalCleanupBackend {
    let unavailable: String?
    let output: String
    let shouldThrow: Bool
    private(set) var generateCount = 0

    init(unavailable: String? = nil, output: String = "", shouldThrow: Bool = false) {
        self.unavailable = unavailable
        self.output = output
        self.shouldThrow = shouldThrow
    }

    func unavailability() async -> String? { unavailable }

    func generate(instructions: String, userMessage: String, maximumResponseTokens: Int) async throws -> String {
        generateCount += 1
        if shouldThrow { throw CleanerError.unusableOutput }
        return output
    }

    func prewarm(instructions: String) async {}

    func generations() -> Int { generateCount }
}

@Suite("CommandRunner — cloud→local degrade")
struct CommandRunnerTests {
    /// A cloud client with no key: `complete` throws `OpenRouterError.noKey`,
    /// which the runner maps to a cloud-path failure — the outage we degrade on.
    private func keylessCloud() -> OpenRouterClient {
        OpenRouterClient(keyProvider: { nil })
    }

    @Test("Cloud outage with an available local backend degrades to on-device + notes it")
    func cloudFailsLocalSucceeds() async throws {
        let local = CmdFakeLocalBackend(output: "The on-device rewrite.")
        let runner = CommandRunner(client: keylessCloud(), localBackend: local)

        let outcome = try await runner.run(
            instruction: "make it friendlier",
            selection: "the old text",
            tier: .cloud(slug: "test/model")
        )

        #expect(outcome.text == "The on-device rewrite.")
        #expect(outcome.note == CommandRunner.cloudDegradedNote)
        await #expect(local.generations() == 1) // local actually ran
    }

    @Test("Cloud outage with an UNAVAILABLE local backend throws (selection stays untouched)")
    func cloudFailsLocalUnavailable() async {
        let local = CmdFakeLocalBackend(unavailable: "Apple Intelligence is not enabled")
        let runner = CommandRunner(client: keylessCloud(), localBackend: local)

        await #expect(throws: CommandError.self) {
            _ = try await runner.run(
                instruction: "make it friendlier",
                selection: "the old text",
                tier: .cloud(slug: "test/model")
            )
        }
        await #expect(local.generations() == 0) // never generated (unavailable)
    }

    @Test("The local tier alone still carries no degrade note")
    func localTierNoNote() async throws {
        let local = CmdFakeLocalBackend(output: "Fresh on-device text.")
        let runner = CommandRunner(client: keylessCloud(), localBackend: local)

        let outcome = try await runner.run(
            instruction: "write a greeting", selection: nil, tier: .local
        )
        #expect(outcome.text == "Fresh on-device text.")
        #expect(outcome.note == nil)
    }

    @Test("Raw tier is still refused before any model runs")
    func rawTierRefused() async {
        let local = CmdFakeLocalBackend(output: "should never run")
        let runner = CommandRunner(client: keylessCloud(), localBackend: local)
        await #expect(throws: CommandError.self) {
            _ = try await runner.run(instruction: "do it", selection: "x", tier: .raw)
        }
        await #expect(local.generations() == 0)
    }
}
