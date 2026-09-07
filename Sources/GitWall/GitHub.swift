import Foundation

enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No GitHub token. Paste a personal access token in Settings, or run `gh auth login`."
        case .http(401, _), .http(403, _):
            return "GitHub rejected the token (needs `repo` scope, or you're rate limited)."
        case .http(404, _):
            return "Not found — the token may not have access to that repository."
        case .http(let code, let body):
            return "GitHub error \(code): \(body.prefix(200))"
        }
    }
}

actor GitHub {
    private let session = URLSession(configuration: .default)
    private var token: String?

    func setToken(_ t: String?) {
        token = (t?.isEmpty == false) ? t : nil
    }

    private func get(_ path: String) async throws -> Data {
        guard let token else { throw GitHubError.noToken }
        let url = path.hasPrefix("http") ? URL(string: path)!
                                         : URL(string: "https://api.github.com" + path)!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("GitWall", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try Self.decoder.decode(type, from: data)
    }

    // MARK: - Wire types

    private struct User: Decodable {
        let login: String
        let name: String?
        let avatar_url: String?
    }
    private struct Team: Decodable { let slug: String }

    private struct SearchResult: Decodable {
        struct Item: Decodable {
            let number: Int
            let repository_url: String
            let user: User?
        }
        let items: [Item]
    }

    private struct PRPayload: Decodable {
        let number: Int
        let title: String
        let html_url: String
        let draft: Bool?
        let merged: Bool?
        let state: String
        let updated_at: Date
        let user: User?
        let requested_reviewers: [User]?
        let requested_teams: [Team]?
        let head: Head
        struct Head: Decodable { let sha: String }
    }

    private struct Review: Decodable {
        let user: User?
        let state: String
        let submitted_at: Date?
    }

    private struct CombinedStatus: Decodable { let state: String; let total_count: Int }
    private struct CheckRuns: Decodable {
        struct Run: Decodable { let status: String; let conclusion: String? }
        let check_runs: [Run]
    }

    // MARK: - API

    struct Account: Sendable {
        var login: String
        var name: String?
        var avatarURL: String?
        var displayName: String { name?.isEmpty == false ? name! : login }
        var profileURL: String { "https://github.com/\(login)" }
    }

    func currentAccount() async throws -> Account {
        let u = try decode(User.self, await get("/user"))
        return Account(login: u.login, name: u.name, avatarURL: u.avatar_url)
    }

    /// PRs GitHub considers mine: assigned, review-requested, or authored.
    func myPRRefs(login: String) async throws -> [(PRRef, Source)] {
        let queries: [(String, Source)] = [
            ("is:open is:pr assignee:\(login)", .assigned),
            ("is:open is:pr review-requested:\(login)", .reviewRequest),
            ("is:open is:pr author:\(login)", .authored),
        ]
        var out: [(PRRef, Source)] = []
        for (q, source) in queries {
            let esc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
            let data = try await get("/search/issues?per_page=50&q=\(esc)")
            for item in try decode(SearchResult.self, data).items {
                // repository_url looks like https://api.github.com/repos/owner/repo
                let parts = item.repository_url.split(separator: "/").suffix(2).map(String.init)
                guard parts.count == 2 else { continue }
                out.append((PRRef(owner: parts[0], repo: parts[1], number: item.number), source))
            }
        }
        return out
    }

    /// Full detail for one PR: review verdict, re-review requests, CI.
    func detail(_ ref: PRRef, viewer: String) async throws -> PullRequest {
        let base = "/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)"
        let pr = try decode(PRPayload.self, await get(base))
        let reviews = try decode([Review].self, await get(base + "/reviews?per_page=100"))

        var out = PullRequest(owner: ref.owner, repo: ref.repo, number: ref.number)
        out.title = pr.title
        out.author = pr.user?.login ?? ""
        out.url = pr.html_url
        out.isDraft = pr.draft ?? false
        out.isMerged = pr.merged ?? false
        out.isClosed = pr.state == "closed" && !(pr.merged ?? false)
        out.updatedAt = pr.updated_at

        // Latest meaningful review per reviewer. COMMENTED never overrides an
        // earlier APPROVED / CHANGES_REQUESTED — that's GitHub's own rule.
        var latest: [String: String] = [:]
        for r in reviews.sorted(by: { ($0.submitted_at ?? .distantPast) < ($1.submitted_at ?? .distantPast) }) {
            guard let login = r.user?.login else { continue }
            let s = r.state.uppercased()
            if s == "COMMENTED" && latest[login] != nil { continue }
            if s == "DISMISSED" { latest[login] = nil; continue }
            if s == "PENDING" { continue }
            latest[login] = s
        }
        out.reviewerStates = latest

        let pendingReviewers = (pr.requested_reviewers?.map(\.login) ?? [])
            + (pr.requested_teams?.map { "@\($0.slug)" } ?? [])
        // Someone who already reviewed but is back in requested_reviewers has
        // been asked for a re-review.
        out.reReviewRequested = pendingReviewers.filter { latest[$0] != nil }
        out.awaitingReview = pendingReviewers.filter { latest[$0] == nil }

        // A reviewer who asked for changes and has since been re-requested has
        // already been answered — the ball is back in their court, so that no
        // longer counts as changes you owe anyone.
        out.blockingReviewers = latest
            .filter { $0.value == "CHANGES_REQUESTED" }
            .keys
            .filter { !out.reReviewRequested.contains($0) }
            .sorted()
        out.myReviewRequested = pendingReviewers.contains(viewer)

        if !out.blockingReviewers.isEmpty {
            out.verdict = .changesRequested
        } else if !pendingReviewers.isEmpty {
            out.verdict = .pending
        } else if latest.values.contains("APPROVED") {
            out.verdict = .approved
        } else if latest.values.contains("COMMENTED") {
            out.verdict = .commented
        } else {
            out.verdict = .none
        }

        out.ci = (try? await ciStatus(ref, sha: pr.head.sha)) ?? .none
        return out
    }

    private func ciStatus(_ ref: PRRef, sha: String) async throws -> CIStatus {
        let base = "/repos/\(ref.owner)/\(ref.repo)/commits/\(sha)"
        var states: [String] = []
        // An empty combined status reports "pending" with zero contexts — ignore it.
        if let d = try? await get(base + "/status"),
           let combined = try? decode(CombinedStatus.self, d), combined.total_count > 0 {
            states.append(combined.state)
        }
        if let d = try? await get(base + "/check-runs?per_page=100"),
           let runs = try? decode(CheckRuns.self, d) {
            for r in runs.check_runs {
                states.append(r.status == "completed" ? (r.conclusion ?? "pending") : "pending")
            }
        }
        let bad: Set<String> = ["failure", "timed_out", "cancelled", "action_required", "startup_failure"]
        if states.contains(where: { bad.contains($0) }) { return .failure }
        if states.contains("pending") || states.contains("queued") || states.contains("in_progress") { return .pending }
        if states.contains(where: { $0 == "success" || $0 == "neutral" || $0 == "skipped" }) { return .success }
        return .none
    }
}
