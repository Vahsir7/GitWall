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

    /// GraphQL call; returns the `data` object, throws on transport or GraphQL errors.
    private func graphql(_ query: String, _ variables: [String: Any]) async throws -> [String: Any] {
        guard let token else { throw GitHubError.noToken }
        var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("GitWall", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if !(200..<300).contains(code) || json["errors"] != nil {
            throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    /// Review threads on the PR that are still unresolved, with their first comment.
    func unresolvedThreads(_ ref: PRRef) async throws -> [ReviewThread] {
        let q = """
            query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){
              reviewThreads(first:100){nodes{id isResolved path line
                comments(first:1){nodes{bodyText url author{login}}}}}}}}
            """
        let data = try await graphql(q, ["o": ref.owner, "r": ref.repo, "n": ref.number])
        let repo = data["repository"] as? [String: Any]
        let pr = repo?["pullRequest"] as? [String: Any]
        let threads = pr?["reviewThreads"] as? [String: Any]
        let nodes = threads?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap { n in
            guard (n["isResolved"] as? Bool) == false, let id = n["id"] as? String else { return nil }
            let comments = (n["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]
            let first = comments?.first
            return ReviewThread(
                id: id,
                author: ((first?["author"] as? [String: Any])?["login"] as? String) ?? "unknown",
                path: n["path"] as? String,
                line: n["line"] as? Int,
                body: (first?["bodyText"] as? String) ?? "",
                url: (first?["url"] as? String) ?? "")
        }
    }

    /// Resolves every unresolved review thread; returns how many were resolved.
    func resolveAllThreads(_ ref: PRRef) async throws -> Int {
        let ids = try await unresolvedThreads(ref).map(\.id)
        let m = "mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id}}}"
        for id in ids { _ = try await graphql(m, ["id": id]) }
        return ids.count
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
    private struct MyTeam: Decodable {
        struct Org: Decodable { let login: String }
        let slug: String
        let organization: Org
    }

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
        let mergeable: Bool?
        let mergeable_state: String?
        let merged_at: Date?
        let closed_at: Date?
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
        let body: String?
    }

    private struct IssueComment: Decodable {
        let user: User?
        let body: String?
        let created_at: Date
    }

    private struct WorkSearch: Decodable {
        struct Item: Decodable {
            let number: Int
            let title: String
            let html_url: String
            let repository_url: String
            let created_at: Date
            let pull_request: Links?
        }
        struct Links: Decodable { let merged_at: Date? }
        let items: [Item]
    }

    private struct CommitEntry: Decodable {
        struct Commit: Decodable {
            struct Stamp: Decodable { let date: Date? }
            let committer: Stamp?
        }
        let commit: Commit
        let author: User?
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

    /// Teams you belong to, as "org/slug" (lowercased). Needs `read:org` or `repo`;
    /// empty if the token can't see them.
    func myTeams() async -> Set<String> {
        guard let data = try? await get("/user/teams?per_page=100"),
              let teams = try? decode([MyTeam].self, data) else { return [] }
        return Set(teams.map { "\($0.organization.login)/\($0.slug)".lowercased() })
    }

    /// PRs GitHub considers mine: assigned, review-requested (directly or via a
    /// team), authored, or already reviewed by me and still open.
    func myPRRefs(login: String) async throws -> [(PRRef, Source)] {
        let queries: [(String, Source)] = [
            ("is:open is:pr assignee:\(login)", .assigned),
            ("is:open is:pr review-requested:\(login)", .reviewRequest),
            ("is:open is:pr author:\(login)", .authored),
            // GitHub drops a PR from review-requested once you review it;
            // this keeps it on the list until it merges.
            ("is:open is:pr reviewed-by:\(login) -author:\(login)", .reviewed),
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

    /// PRs you worked on since `since`: your own PRs that you opened, pushed commits
    /// to, or that got merged in that window, plus others' PRs you submitted a
    /// review on. Your own work wins if a PR somehow qualifies both ways.
    func workItems(login: String, since: Date) async throws -> [WorkItem] {
        let stamp = ISO8601DateFormatter().string(from: since)
        var items: [String: WorkItem] = [:]

        for hit in try await searchPRs("is:pr author:\(login) updated:>=\(stamp)") {
            guard let (owner, repo) = Self.ownerRepo(hit.repository_url) else { continue }
            // "Updated" also covers other people's comments, so confirm the work was yours.
            var worked = hit.created_at >= since || (hit.pull_request?.merged_at ?? .distantPast) >= since
            if !worked {
                let commits = try decode([CommitEntry].self,
                    await get("/repos/\(owner)/\(repo)/pulls/\(hit.number)/commits?per_page=100"))
                worked = commits.contains {
                    ($0.commit.committer?.date ?? .distantPast) >= since
                        && ($0.author.map { $0.login.caseInsensitiveCompare(login) == .orderedSame } ?? true)
                }
            }
            if worked {
                items["\(owner)/\(repo)#\(hit.number)"] = WorkItem(
                    owner: owner, repo: repo, number: hit.number, title: hit.title, url: hit.html_url, reviewed: false)
            }
        }

        for hit in try await searchPRs("is:pr reviewed-by:\(login) -author:\(login) updated:>=\(stamp)") {
            guard let (owner, repo) = Self.ownerRepo(hit.repository_url) else { continue }
            let key = "\(owner)/\(repo)#\(hit.number)"
            guard items[key] == nil else { continue }
            let reviews = try decode([Review].self,
                await get("/repos/\(owner)/\(repo)/pulls/\(hit.number)/reviews?per_page=100"))
            let reviewedInWindow = reviews.contains {
                $0.user?.login.caseInsensitiveCompare(login) == .orderedSame
                    && ($0.submitted_at ?? .distantPast) >= since
            }
            if reviewedInWindow {
                items[key] = WorkItem(
                    owner: owner, repo: repo, number: hit.number, title: hit.title, url: hit.html_url, reviewed: true)
            }
        }
        return Array(items.values)
    }

    private func searchPRs(_ query: String) async throws -> [WorkSearch.Item] {
        let esc = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        return try decode(WorkSearch.self, await get("/search/issues?per_page=100&q=\(esc)")).items
    }

    /// repository_url looks like https://api.github.com/repos/owner/repo
    private static func ownerRepo(_ repositoryURL: String) -> (String, String)? {
        let parts = repositoryURL.split(separator: "/").suffix(2).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// Full detail for one PR: review verdict, re-review requests, CI.
    func detail(_ ref: PRRef, viewer: String, teams: Set<String> = []) async throws -> PullRequest {
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
        out.finishedAt = pr.merged_at ?? pr.closed_at
        // mergeable is null while GitHub is still computing it; treat as clean.
        out.hasConflicts = pr.mergeable == false || pr.mergeable_state == "dirty"

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
        out.myTeamRequests = (pr.requested_teams ?? [])
            .filter { teams.contains("\(ref.owner)/\($0.slug)".lowercased()) }
            .map { "@\($0.slug)" }
        // A team request still counts as yours until you've reviewed yourself.
        out.myReviewRequested = pendingReviewers.contains(viewer)
            || (!out.myTeamRequests.isEmpty && latest[viewer] == nil)

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

        // Bot reviews and bot comments can both carry a findings table; keep
        // each bot's most recent one.
        var posts: [(login: String, body: String, at: Date)] = reviews.compactMap {
            guard let l = $0.user?.login, let b = $0.body else { return nil }
            return (l, b, $0.submitted_at ?? .distantPast)
        }
        if let d = try? await get("/repos/\(ref.owner)/\(ref.repo)/issues/\(ref.number)/comments?per_page=100"),
           let comments = try? decode([IssueComment].self, d) {
            posts += comments.compactMap {
                guard let l = $0.user?.login, let b = $0.body else { return nil }
                return (l, b, $0.created_at)
            }
        }
        var findings: [String: (BotFindings, Date)] = [:]
        for p in posts where p.login.lowercased().hasSuffix("[bot]") {
            guard let f = BotFindings.parse(p.body, login: p.login) else { continue }
            if let cur = findings[p.login], cur.1 > p.at { continue }
            findings[p.login] = (f, p.at)
        }
        out.botFindings = findings.values.map(\.0).sorted { $0.login < $1.login }

        out.unresolved = (try? await unresolvedThreads(ref)) ?? []
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
