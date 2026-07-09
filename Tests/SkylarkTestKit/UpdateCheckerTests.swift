import Testing
import Foundation
@testable import SkylarkCore

/// Stub `UpdateFetching` — hands back a canned `(Data, HTTPURLResponse)` pair
/// or throws, so `UpdateChecker` tests never touch the network.
private struct StubFetcher: UpdateFetching {
    enum Outcome {
        case success(status: Int, headers: [String: String], body: Data)
        case failure(Error)
    }

    let outcome: Outcome

    func fetchCommit(owner: String, repo: String, branch: String) async throws -> (data: Data, response: HTTPURLResponse) {
        switch outcome {
        case let .success(status, headers, body):
            let response = HTTPURLResponse(
                url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits/\(branch)")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (body, response)
        case let .failure(error):
            throw error
        }
    }
}

private func commitJSON(sha: String, message: String, committerDate: String?) -> Data {
    var commit: [String: Any] = ["message": message]
    if let committerDate {
        commit["committer"] = ["date": committerDate]
    }
    let object: [String: Any] = ["sha": sha, "commit": commit]
    return try! JSONSerialization.data(withJSONObject: object)
}

@Suite("UpdateChecker (stubbed transport)")
struct UpdateCheckerTests {
    private let remote = URL(string: "https://github.com/jjromano/skylark")!

    @Test("Matching SHA reports up to date")
    func upToDate() async throws {
        let sha = "abc123def456"
        let fetcher = StubFetcher(outcome: .success(
            status: 200, headers: [:],
            body: commitJSON(sha: sha, message: "chore: bump", committerDate: "2026-07-01T12:00:00Z")
        ))
        let checker = UpdateChecker(fetcher: fetcher)

        let status = await checker.check(localCommit: sha, repoRemote: remote)
        #expect(status.state == .upToDate)
    }

    @Test("A prefix match (short local SHA) also reports up to date")
    func upToDatePrefixMatch() async throws {
        let fetcher = StubFetcher(outcome: .success(
            status: 200, headers: [:],
            body: commitJSON(sha: "abc123def456789", message: "chore: bump", committerDate: nil)
        ))
        let checker = UpdateChecker(fetcher: fetcher)

        let status = await checker.check(localCommit: "abc123d", repoRemote: remote)
        #expect(status.state == .upToDate)
    }

    @Test("A different remote SHA reports updateAvailable with summary + date")
    func updateAvailable() async throws {
        let fetcher = StubFetcher(outcome: .success(
            status: 200, headers: [:],
            body: commitJSON(
                sha: "newsha0001",
                message: "fix(sign): drop hardened runtime\n\nLonger body here.",
                committerDate: "2026-07-05T08:30:00Z"
            )
        ))
        let checker = UpdateChecker(fetcher: fetcher)

        let status = await checker.check(localCommit: "oldsha0000", repoRemote: remote)
        guard case let .updateAvailable(latestSHA, summary, date) = status.state else {
            Issue.record("expected .updateAvailable, got \(status.state)")
            return
        }
        #expect(latestSHA == "newsha0001")
        #expect(summary == "fix(sign): drop hardened runtime")
        #expect(date != nil)
    }

    @Test("A network error resolves to .unknown with a human-readable reason")
    func networkError() async throws {
        let fetcher = StubFetcher(outcome: .failure(URLError(.notConnectedToInternet)))
        let checker = UpdateChecker(fetcher: fetcher)

        let status = await checker.check(localCommit: "abc123", repoRemote: remote)
        guard case let .unknown(reason) = status.state else {
            Issue.record("expected .unknown, got \(status.state)")
            return
        }
        #expect(reason.lowercased().contains("offline"))
    }

    @Test("A 403 with rate-limit headers is detected and distinguished from a generic 403")
    func rateLimited() async throws {
        let fetcher = StubFetcher(outcome: .success(
            status: 403, headers: ["X-RateLimit-Remaining": "0"], body: Data()
        ))
        let checker = UpdateChecker(fetcher: fetcher)

        let status = await checker.check(localCommit: "abc123", repoRemote: remote)
        guard case let .unknown(reason) = status.state else {
            Issue.record("expected .unknown, got \(status.state)")
            return
        }
        #expect(reason.lowercased().contains("rate limit"))
    }

    @Test("A plain 403 (no rate-limit header) is still .unknown but doesn't claim rate limiting")
    func genericForbidden() async throws {
        let fetcher = StubFetcher(outcome: .success(status: 403, headers: [:], body: Data()))
        let checker = UpdateChecker(fetcher: fetcher)

        let status = await checker.check(localCommit: "abc123", repoRemote: remote)
        guard case let .unknown(reason) = status.state else {
            Issue.record("expected .unknown, got \(status.state)")
            return
        }
        #expect(!reason.lowercased().contains("rate limit"))
    }

    @Test("A non-GitHub remote resolves to .unknown without ever calling the fetcher")
    func nonGitHubRemote() async throws {
        let fetcher = StubFetcher(outcome: .failure(URLError(.badURL)))
        let checker = UpdateChecker(fetcher: fetcher)

        let status = await checker.check(localCommit: "abc123", repoRemote: URL(string: "https://gitlab.com/jjromano/skylark")!)
        guard case let .unknown(reason) = status.state else {
            Issue.record("expected .unknown, got \(status.state)")
            return
        }
        #expect(reason.contains("GitHub"))
    }

    // MARK: - Remote URL normalization

    @Test("normalizeGitHubRemote handles the git@ SCP-like form")
    func normalizeGitAtForm() {
        let normalized = UpdateChecker.normalizeGitHubRemote("git@github.com:jjromano/skylark.git")
        #expect(normalized == URL(string: "https://github.com/jjromano/skylark"))
    }

    @Test("normalizeGitHubRemote handles https with and without .git suffix")
    func normalizeHTTPSForm() {
        #expect(UpdateChecker.normalizeGitHubRemote("https://github.com/jjromano/skylark.git")
                == URL(string: "https://github.com/jjromano/skylark"))
        #expect(UpdateChecker.normalizeGitHubRemote("https://github.com/jjromano/skylark")
                == URL(string: "https://github.com/jjromano/skylark"))
    }

    @Test("normalizeGitHubRemote rejects non-GitHub and empty remotes")
    func normalizeRejectsNonGitHub() {
        #expect(UpdateChecker.normalizeGitHubRemote("git@gitlab.com:jjromano/skylark.git") == nil)
        #expect(UpdateChecker.normalizeGitHubRemote("") == nil)
        #expect(UpdateChecker.normalizeGitHubRemote("   ") == nil)
    }
}

@Suite("UpdateCommandWriter")
struct UpdateCommandWriterTests {
    @Test("makeUpdateScript writes an executable .command file that cds, pulls, and reruns install.sh")
    func writesExecutableScript() throws {
        let url = try UpdateCommandWriter.makeUpdateScript(repoPath: "/Users/jj/repos/skylark")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.pathExtension == "command")

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("cd \"/Users/jj/repos/skylark\""))
        #expect(contents.contains("git pull --ff-only"))
        #expect(contents.contains("\"/Users/jj/repos/skylark/Scripts/install.sh\""))
        #expect(contents.contains("Press any key to close"))
        #expect(contents.hasPrefix("#!/bin/bash"))

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        #expect(permissions & 0o111 != 0) // at least one execute bit set
    }

    @Test("makeUpdateScript escapes embedded double quotes in the repo path")
    func escapesQuotes() throws {
        let url = try UpdateCommandWriter.makeUpdateScript(repoPath: "/tmp/weird\"path")
        defer { try? FileManager.default.removeItem(at: url) }

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("\\\"path"))
    }

    @Test("makeUpdateScript rejects an empty repo path")
    func rejectsEmptyPath() {
        #expect(throws: UpdateCommandWriter.WriteError.self) {
            try UpdateCommandWriter.makeUpdateScript(repoPath: "")
        }
    }
}
