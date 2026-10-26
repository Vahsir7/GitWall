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
        etags = [:]
    }

    /// Last response per URL, replayed when GitHub answers 304 Not Modified.
    /// Conditional requests are what GitHub Desktop does: unchanged resources
    /// come back fast and don't count against the rate limit.
    private var etags: [URL: (etag: String, data: Data)] = [:]

    private func get(_ path: String) async throws -> Data {
        guard let token else { throw GitHubError.noToken }
        let url = path.hasPrefix("http") ? URL(string: path)!
                                         : URL(string: "https://api.github.com" + path)!
        var req = URLRequest(url: url)
        // Our own ETag cache decides freshness; URLCache would serve stale bodies.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("GitWall", forHTTPHeaderField: "User-Agent")
        if let cached = etags[url] { req.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 304, let cached = etags[url] { return cached.data }
        guard (200..<300).contains(code) else {
            throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        if let etag = http?.value(forHTTPHeaderField: "ETag") { etags[url] = (etag, data) }
        return data
    }

    /// Forget cached bodies, e.g. after signing in as someone else.
    func clearCache() { etags = [:] }

    /// GraphQL call; returns the `data` object, throws on transport or GraphQL errors.
    /// Merges the base branch into the PR branch, like GitHub's "Update branch".
    /// `expectedSha` guards against updating a head that moved since we looked.
    func updateBranch(_ ref: PRRef, expectedSha: String) async throws {
        guard let token else { throw GitHubError.noToken }
        var req = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(ref.owner)/\(ref.repo)/pulls/\(ref.number)/update-branch")!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("GitWall", forHTTPHeaderField: "User-Agent")
        if !expectedSha.isEmpty {
            req.httpBody = try JSONSerialization.data(withJSONObject: ["expected_head_sha": expectedSha])
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            throw GitHubError.http(code, msg ?? String(data: data, encoding: .utf8) ?? "")
        }
    }

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
        let base: Base
        struct Head: Decodable { let sha: String }
        struct Base: Decodable { let ref: String }
    }

    private struct Compare: Decodable { let behind_by: Int }

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
    func myPRRefs(login: String, teams: Set<String> = []) async throws -> [(PRRef, Source)] {
        var queries: [(String, Source)] = [
            ("is:open is:pr assignee:\(login)", .assigned),
            ("is:open is:pr review-requested:\(login)", .reviewRequest),
            ("is:open is:pr author:\(login)", .authored),
            // GitHub drops a PR from review-requested once you review it;
            // this keeps it on the list until it merges.
            ("is:open is:pr reviewed-by:\(login) -author:\(login)", .reviewed),
        ]
        // Requests to a team you're on count as review requests too.
        for team in teams.sorted() {
            queries.append(("is:open is:pr team-review-requested:\(team) -author:\(login)", .reviewRequest))
        }
        // All searches at once instead of one after another.
        return try await withThrowingTaskGroup(of: [(PRRef, Source)].self) { group in
            for (i, (q, source)) in queries.enumerated() {
                let optional = i >= 4   // a team search failing shouldn't sink the refresh
                group.addTask {
                    let esc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
                    guard let data = optional
                        ? try? await self.get("/search/issues?per_page=50&q=\(esc)")
                        : try await self.get("/search/issues?per_page=50&q=\(esc)") else { return [] }
                    return try await self.decodeSearch(data).compactMap { item in
                        // repository_url looks like https://api.github.com/repos/owner/repo
                        let parts = item.repository_url.split(separator: "/").suffix(2).map(String.init)
                        guard parts.count == 2 else { return nil }
                        return (PRRef(owner: parts[0], repo: parts[1], number: item.number), source)
                    }
                }
            }
            var out: [(PRRef, Source)] = []
            for try await batch in group { out += batch }
            return out
        }
    }

    private func decodeSearch(_ data: Data) throws -> [SearchResult.Item] {
        try decode(SearchResult.self, data).items
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

    // MARK: - Batched GraphQL

    private static let prFields = """
        number title url isDraft merged state updatedAt mergedAt closedAt
        mergeable mergeStateStatus headRefOid baseRefName
        author { login }
        reviewRequests(first: 50) { nodes { requestedReviewer {
          ... on User { login } ... on Team { slug } ... on Bot { login } ... on Mannequin { login } } } }
        reviews(last: 100) { nodes { author { login } state submittedAt body } }
        comments(last: 100) { nodes { author { login } body createdAt } }
        reviewThreads(first: 100) { nodes { id isResolved path line
          comments(first: 1) { nodes { bodyText url author { login } } } } }
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        """

    /// Loads many PRs in a few GraphQL round trips — one request per chunk of
    /// PRs instead of ~7 REST calls each. PRs that fail are missing from the result.
    func details(_ refs: [PRRef], viewer: String, teams: Set<String>,
                 rules: [ReviewRule], chunkSize: Int = 5) async -> [String: PullRequest] {
        let chunks = stride(from: 0, to: refs.count, by: chunkSize).map { Array(refs[$0..<min($0 + chunkSize, refs.count)]) }
        return await withTaskGroup(of: [String: PullRequest].self) { group in
            for chunk in chunks {
                group.addTask { await self.detailsChunk(chunk, viewer: viewer, teams: teams, rules: rules) }
            }
            var out: [String: PullRequest] = [:]
            for await part in group { out.merge(part) { $1 } }
            return out
        }
    }

    private func detailsChunk(_ refs: [PRRef], viewer: String, teams: Set<String>,
                              rules: [ReviewRule]) async -> [String: PullRequest] {
        func lit(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let parts = refs.enumerated().map { i, r in
            "p\(i): repository(owner: \(lit(r.owner)), name: \(lit(r.repo))) { pullRequest(number: \(r.number)) { \(Self.prFields) } }"
        }
        let data: [String: Any]
        do {
            data = try await graphqlAllowingPartial("query { \(parts.joined(separator: "\n")) }")
        } catch {
            return [:]
        }
        var out: [String: PullRequest] = [:]
        for (i, ref) in refs.enumerated() {
            guard let repo = data["p\(i)"] as? [String: Any],
                  let node = repo["pullRequest"] as? [String: Any] else { continue }
            if let pr = Self.fromGraphQL(ref, node, viewer: viewer, teams: teams, rules: rules) {
                out[ref.id] = pr
            }
        }
        return out
    }

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func fromGraphQL(_ ref: PRRef, _ n: [String: Any], viewer: String,
                                    teams: Set<String>, rules: [ReviewRule]) -> PullRequest? {
        func str(_ d: [String: Any]?, _ k: String) -> String? { d?[k] as? String }
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { iso.date(from: $0) } }
        func nodes(_ k: String, in d: [String: Any]? = nil) -> [[String: Any]] {
            ((d ?? n)[k] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        }
        func login(_ d: [String: Any]) -> String? { str(d["author"] as? [String: Any], "login") }

        guard let title = n["title"] as? String, let url = n["url"] as? String,
              let updated = date(n["updatedAt"]) else { return nil }
        let state = (n["state"] as? String ?? "OPEN").lowercased()   // open / closed / merged
        let mergeable = n["mergeable"] as? String                   // MERGEABLE / CONFLICTING / UNKNOWN
        let mergeState = (n["mergeStateStatus"] as? String)?.lowercased()

        var users: [User] = []
        var reqTeams: [Team] = []
        for r in nodes("reviewRequests") {
            guard let who = r["requestedReviewer"] as? [String: Any] else { continue }
            if let l = who["login"] as? String { users.append(User(login: l, name: nil, avatar_url: nil)) }
            else if let slug = who["slug"] as? String { reqTeams.append(Team(slug: slug)) }
        }

        let payload = PRPayload(
            number: ref.number, title: title, html_url: url,
            draft: n["isDraft"] as? Bool, merged: n["merged"] as? Bool,
            mergeable: mergeable == "MERGEABLE" ? true : mergeable == "CONFLICTING" ? false : nil,
            mergeable_state: mergeState == "dirty" || mergeable == "CONFLICTING" ? "dirty" : mergeState,
            merged_at: date(n["mergedAt"]), closed_at: date(n["closedAt"]),
            state: state == "open" ? "open" : "closed", updated_at: updated,
            user: str(n["author"] as? [String: Any], "login").map { User(login: $0, name: nil, avatar_url: nil) },
            requested_reviewers: users, requested_teams: reqTeams,
            head: .init(sha: n["headRefOid"] as? String ?? ""),
            base: .init(ref: n["baseRefName"] as? String ?? ""))

        let reviews = nodes("reviews").map {
            Review(user: login($0).map { User(login: $0, name: nil, avatar_url: nil) },
                   state: $0["state"] as? String ?? "", submitted_at: date($0["submittedAt"]),
                   body: $0["body"] as? String)
        }
        let comments = nodes("comments").compactMap { c -> IssueComment? in
            guard let at = date(c["createdAt"]) else { return nil }
            return IssueComment(user: login(c).map { User(login: $0, name: nil, avatar_url: nil) },
                                body: c["body"] as? String, created_at: at)
        }

        var out = assemble(ref, pr: payload, reviews: reviews, comments: comments, behindBy: nil,
                           viewer: viewer, teams: teams, rules: rules)
        out.unresolved = nodes("reviewThreads").compactMap { t in
            guard (t["isResolved"] as? Bool) == false, let id = t["id"] as? String else { return nil }
            let first = nodes("comments", in: t).first
            return ReviewThread(id: id, author: first.flatMap(login) ?? "unknown",
                                path: t["path"] as? String, line: t["line"] as? Int,
                                body: first?["bodyText"] as? String ?? "", url: first?["url"] as? String ?? "")
        }
        let rollup = nodes("commits").first
            .flatMap { ($0["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any] }?["state"] as? String
        switch rollup {
        case "SUCCESS": out.ci = .success
        case "FAILURE", "ERROR": out.ci = .failure
        case "PENDING", "EXPECTED": out.ci = .pending
        default: out.ci = .none
        }
        return out
    }

    /// How many base commits each open PR is missing. GraphQL can't express
    /// this per PR, so it's a REST compare per PR — ETag-cached and parallel.
    func behindCounts(_ prs: [PullRequest]) async -> [String: Int] {
        await withTaskGroup(of: (String, Int?).self) { group in
            for pr in prs where !pr.isMerged && !pr.isClosed && !pr.headSha.isEmpty && !pr.baseRef.isEmpty {
                group.addTask {
                    let base = pr.baseRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pr.baseRef
                    let d = try? await self.get("/repos/\(pr.owner)/\(pr.repo)/compare/\(base)...\(pr.headSha)?per_page=1")
                    return (pr.id, d.flatMap { try? JSONDecoder().decode(Compare.self, from: $0).behind_by })
                }
            }
            var out: [String: Int] = [:]
            for await (id, n) in group { if let n { out[id] = n } }
            return out
        }
    }

    /// Like `graphql`, but keeps whatever data came back when some aliases
    /// failed (e.g. one PR the token can't see).
    private func graphqlAllowingPartial(_ query: String) async throws -> [String: Any] {
        guard let token else { throw GitHubError.noToken }
        var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("GitWall", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = json["data"] as? [String: Any] else {
            throw GitHubError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return d
    }

    /// Turns a PR and its reviews/comments into our model.
    private static func assemble(_ ref: PRRef, pr: PRPayload, reviews: [Review], comments: [IssueComment]?,
                                 behindBy: Int?, viewer: String, teams: Set<String>,
                                 rules: [ReviewRule]) -> PullRequest {
        var out = PullRequest(owner: ref.owner, repo: ref.repo, number: ref.number)
        out.title = pr.title
        out.author = pr.user?.login ?? ""
        out.url = pr.html_url
        out.isDraft = pr.draft ?? false
        out.isMerged = pr.merged ?? false
        out.isClosed = pr.state == "closed" && !(pr.merged ?? false)
        out.updatedAt = pr.updated_at
        out.finishedAt = pr.merged_at ?? pr.closed_at
        // mergeable is null while GitHub is still computing it (e.g. right after
        // the base moves); the store keeps the last known answer in that case.
        out.mergeableUnknown = pr.mergeable == nil && pr.mergeable_state != "dirty"
        out.hasConflicts = pr.mergeable == false || pr.mergeable_state == "dirty"
        // mergeable_state only says "behind" in some repos, so ask GitHub how
        // many base commits the head is missing.
        out.isBehind = pr.mergeable_state == "behind"
        if let behindBy { out.isBehind = behindBy > 0 }
        out.headSha = pr.head.sha
        out.baseRef = pr.base.ref

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

        // Reviews and PR comments can both carry a severity table; the user's
        // rules say whose posts to read and which columns to look for. Keep the
        // most recent table per rule (and per author when the rule has no name).
        var posts: [(login: String, body: String, at: Date, isReview: Bool)] = reviews.compactMap {
            guard let l = $0.user?.login, let b = $0.body, !b.isEmpty else { return nil }
            return (l, b, $0.submitted_at ?? .distantPast, true)
        }
        if let comments {
            posts += comments.compactMap {
                guard let l = $0.user?.login, let b = $0.body else { return nil }
                return (l, b, $0.created_at, false)
            }
        }
        var findings: [String: (BotFindings, Date)] = [:]
        for p in posts {
            for rule in rules where rule.matches(author: p.login, isReview: p.isReview, body: p.body) {
                let name = rule.name.trimmingCharacters(in: .whitespaces)
                let shown = name.isEmpty ? p.login : name
                guard let f = BotFindings.parse(p.body, login: shown, labels: rule.labelList) else { continue }
                let key = "\(rule.id)|\(shown)"
                if let cur = findings[key], cur.1 > p.at { continue }
                findings[key] = (f, p.at)
                break   // first matching rule wins for this post
            }
        }
        out.botFindings = findings.values.map(\.0).sorted { $0.login < $1.login }

        return out
    }
}
