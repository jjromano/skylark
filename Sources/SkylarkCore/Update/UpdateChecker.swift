import Foundation

/// Build metadata stamped into `Info.plist` by `Scripts/bundle.sh` (never
/// present in a plain `swift build`, only in a `dist/Skylark.app` built via
/// `make app`). Lets a running app know which commit it was built from and
/// where its source checkout lives, so `UpdateChecker` and the "Check for
/// Updates" UI have something to compare against and act on.
public struct BuildInfo: Sendable, Equatable {
    /// Full commit SHA the running build was made from.
    public let commit: String?
    /// UTC build timestamp.
    public let date: Date?
    /// Absolute path to the git checkout the build came from (used to run
    /// `git pull` / `Scripts/install.sh` later).
    public let repoPath: String?
    /// Normalized `https://github.com/owner/repo` remote URL.
    public let repoRemote: URL?

    /// Reads the four `SkylarkBuild*`/`SkylarkRepo*` keys `bundle.sh` stamps
    /// into `Info.plist`. Returns `nil` when none of them are present (e.g. a
    /// `swift build` / `swift run` debug binary that never went through
    /// `bundle.sh`), rather than a `BuildInfo` full of `nil`s.
    public static func current(bundle: Bundle = .main) -> BuildInfo? {
        guard let info = bundle.infoDictionary else { return nil }

        let commit = info["SkylarkBuildCommit"] as? String
        let repoPath = info["SkylarkRepoPath"] as? String
        let repoRemote = (info["SkylarkRepoRemote"] as? String).flatMap(URL.init(string:))
        let date = (info["SkylarkBuildDate"] as? String).flatMap { string in
            ISO8601DateFormatter().date(from: string)
        }

        guard commit != nil || repoPath != nil || repoRemote != nil || date != nil else {
            return nil
        }
        return BuildInfo(commit: commit, date: date, repoPath: repoPath, repoRemote: repoRemote)
    }
}

/// Result of comparing the running build's commit against the tip of the
/// remote repository's `main` branch.
public struct UpdateStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Local commit matches (or prefix-matches) the remote tip.
        case upToDate
        /// Remote `main` is ahead of the local build.
        case updateAvailable(latestSHA: String, commitSummary: String?, commitDate: Date?)
        /// Couldn't determine either way — offline, rate-limited, not a
        /// GitHub remote, malformed response, etc. `reason` is human-readable
        /// and safe to show directly in the UI.
        case unknown(reason: String)
    }

    public let state: State

    public init(state: State) {
        self.state = state
    }
}

/// Transport seam for `UpdateChecker` so tests can stub GitHub's response
/// without touching the network. `URLSessionUpdateFetcher` is the live
/// implementation.
public protocol UpdateFetching: Sendable {
    /// Fetches `GET https://api.github.com/repos/{owner}/{repo}/commits/{branch}`
    /// and returns the raw body alongside the HTTP response (so the caller
    /// can inspect status code and rate-limit headers).
    func fetchCommit(owner: String, repo: String, branch: String) async throws -> (data: Data, response: HTTPURLResponse)
}

/// `URLSession`-backed `UpdateFetching`. Unauthenticated (public GitHub API,
/// no token), 10 s timeout.
public struct URLSessionUpdateFetcher: UpdateFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchCommit(owner: String, repo: String, branch: String) async throws -> (data: Data, response: HTTPURLResponse) {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/commits/\(branch)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Compares the running build's commit against the remote's `main` branch tip
/// via the public GitHub REST API. Never blocks anything — the caller awaits
/// it on its own schedule (e.g. once at launch, or from a manual "Check for
/// Updates" button); every failure mode resolves to `.unknown(reason:)`
/// rather than throwing.
public struct UpdateChecker: Sendable {
    private let fetcher: any UpdateFetching

    public init(fetcher: any UpdateFetching = URLSessionUpdateFetcher()) {
        self.fetcher = fetcher
    }

    /// - Parameters:
    ///   - localCommit: the running build's commit (`BuildInfo.current()?.commit`).
    ///   - repoRemote: the running build's normalized remote (`BuildInfo.current()?.repoRemote`).
    public func check(localCommit: String, repoRemote: URL) async -> UpdateStatus {
        guard let (owner, repo) = Self.githubOwnerRepo(from: repoRemote) else {
            return UpdateStatus(state: .unknown(reason: "Not a GitHub remote (\(repoRemote.absoluteString))."))
        }

        do {
            let (data, http) = try await fetcher.fetchCommit(owner: owner, repo: repo, branch: "main")

            if http.statusCode == 403 {
                if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                    return UpdateStatus(state: .unknown(reason: "GitHub API rate limit exceeded — try again later."))
                }
                return UpdateStatus(state: .unknown(reason: "GitHub API returned 403 Forbidden."))
            }
            guard (200..<300).contains(http.statusCode) else {
                return UpdateStatus(state: .unknown(reason: "GitHub API returned HTTP \(http.statusCode)."))
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let commit = try decoder.decode(GitHubCommitResponse.self, from: data)

            if commit.sha.hasPrefix(localCommit) || localCommit.hasPrefix(commit.sha) {
                return UpdateStatus(state: .upToDate)
            }

            let summary = commit.commit.message
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)
            return UpdateStatus(state: .updateAvailable(
                latestSHA: commit.sha,
                commitSummary: summary,
                commitDate: commit.commit.committer?.date
            ))
        } catch let error as URLError {
            return UpdateStatus(state: .unknown(reason: Self.reason(for: error)))
        } catch {
            return UpdateStatus(state: .unknown(reason: "Could not parse GitHub's response."))
        }
    }

    private static func reason(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "You appear to be offline."
        case .timedOut:
            return "The update check timed out."
        default:
            return "Network error: \(error.localizedDescription)"
        }
    }

    /// Extracts `(owner, repo)` from a normalized `https://github.com/owner/repo`
    /// remote URL (the form `bundle.sh` stamps). Returns `nil` for anything
    /// that isn't a github.com URL with an owner + repo path.
    static func githubOwnerRepo(from remote: URL) -> (owner: String, repo: String)? {
        guard let host = remote.host, host == "github.com" else { return nil }
        let parts = remote.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        guard !parts[0].isEmpty, !repo.isEmpty else { return nil }
        return (parts[0], repo)
    }

    /// Normalizes a raw `git remote get-url origin` value into
    /// `https://github.com/owner/repo` form. Handles both
    /// `git@github.com:owner/repo.git` (SCP-like) and
    /// `https://github.com/owner/repo(.git)`; returns `nil` for anything else
    /// (non-GitHub remotes, empty input). This mirrors the normalization
    /// `Scripts/bundle.sh` performs in bash when stamping `SkylarkRepoRemote`
    /// into `Info.plist` — duplicated here (rather than shared) so it's
    /// independently unit-testable and usable by callers that read `git
    /// remote` output directly instead of the embedded plist value.
    public static func normalizeGitHubRemote(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed
        if candidate.hasPrefix("git@github.com:") {
            candidate = "https://github.com/" + candidate.dropFirst("git@github.com:".count)
        }
        if candidate.hasSuffix(".git") {
            candidate.removeLast(4)
        }

        guard let url = URL(string: candidate), url.host == "github.com" else { return nil }
        return url
    }
}

/// Decodable shape of `GET /repos/{owner}/{repo}/commits/{branch}` — only the
/// fields `UpdateChecker` needs.
private struct GitHubCommitResponse: Decodable {
    struct Commit: Decodable {
        struct Committer: Decodable {
            let date: Date?
        }
        let message: String
        let committer: Committer?
    }
    let sha: String
    let commit: Commit
}

/// Writes the `.command` file that actually performs an update (`git pull
/// --ff-only` then re-running the installer). `SkylarkCore` only writes the
/// file; the app layer decides when to run it (`NSWorkspace.shared.open(_:)`
/// launches it in Terminal) — no `AppKit`/`NSWorkspace` dependency belongs in
/// this target.
public enum UpdateCommandWriter {
    /// Human-readable description of what the generated `.command` script
    /// does, for use in the Account pane's copy ("Skylark will run: …").
    public static let updateCommandDescription = "git pull --ff-only && Scripts/install.sh"

    public enum WriteError: Error, Sendable {
        case emptyRepoPath
    }

    /// Writes an executable temporary `.command` script that pulls
    /// `repoPath` fast-forward-only and re-runs `Scripts/install.sh`, then
    /// waits for a keypress before the Terminal window closes. Returns the
    /// script's URL for the caller to open.
    public static func makeUpdateScript(repoPath: String) throws -> URL {
        guard !repoPath.isEmpty else { throw WriteError.emptyRepoPath }

        // Double quotes are the only shell-meaningful character `repoPath`
        // (an absolute filesystem path) could plausibly contain.
        let escapedPath = repoPath.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        #!/bin/bash
        set -euo pipefail
        cd "\(escapedPath)"

        echo "Updating Skylark…"
        echo
        echo "→ git pull --ff-only"
        git pull --ff-only
        echo
        echo "→ Scripts/install.sh"
        "\(escapedPath)/Scripts/install.sh"
        echo
        echo "✓ Update complete."
        echo
        read -n 1 -r -s -p "Press any key to close this window..." _ || true
        echo

        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skylark-update-\(UUID().uuidString)")
            .appendingPathExtension("command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
