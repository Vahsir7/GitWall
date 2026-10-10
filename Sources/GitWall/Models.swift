import Foundation

/// Where a PR came from: GitHub said it's mine, or the user pasted its link.
enum Source: String, Codable, Hashable {
    case assigned      // assigned to me
    case reviewRequest // my review was requested
    case authored      // I opened it
    case watched       // pasted link
    case reviewed      // I already reviewed it; kept until merged
}

/// The PR's lifecycle state, drawn GitHub-style on every row.
enum PRState: String, Codable {
    case open, draft, conflict, merged, closed

    var label: String {
        switch self {
        case .open: return "Open"
        case .draft: return "Draft"
        case .conflict: return "Conflicts"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    /// SF Symbol closest to GitHub's octicon for this state.
    var symbol: String {
        switch self {
        case .open: return "arrow.triangle.pull"
        case .draft: return "circle.dashed"
        case .conflict: return "exclamationmark.triangle.fill"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        }
    }
}

enum ReviewVerdict: String, Codable {
    case changesRequested
    case approved
    case commented
    case pending        // reviewers assigned, nobody has weighed in
    case none           // no reviewers at all

    var label: String {
        switch self {
        case .changesRequested: return "Changes requested"
        case .approved:         return "Approved"
        case .commented:        return "Commented"
        case .pending:          return "Awaiting review"
        case .none:             return "No reviewers"
        }
    }

    var symbol: String {
        switch self {
        case .changesRequested: return "exclamationmark.triangle.fill"
        case .approved:         return "checkmark.seal.fill"
        case .commented:        return "bubble.left.fill"
        case .pending:          return "clock.fill"
        case .none:             return "circle.dashed"
        }
    }
}

enum CIStatus: String, Codable {
    case success, failure, pending, none

    var label: String {
        switch self {
        case .success: return "Checks passing"
        case .failure: return "Checks failing"
        case .pending: return "Checks running"
        case .none:    return "No checks"
        }
    }
}

/// A pull request we're watching, plus everything we derived about it.
struct PullRequest: Codable, Identifiable, Hashable {
    var owner: String
    var repo: String
    var number: Int

    var title: String = ""
    var author: String = ""
    var url: String = ""
    var isDraft: Bool = false
    var isMerged: Bool = false
    var isClosed: Bool = false
    var updatedAt: Date = .distantPast
    /// When it was merged or closed; drives how long it lingers in the list.
    var finishedAt: Date?
    /// GitHub reports merge conflicts with the base branch.
    var hasConflicts: Bool = false

    var verdict: ReviewVerdict = .none
    var ci: CIStatus = .none

    /// Reviewers who already left a review and have been asked to look again.
    var reReviewRequested: [String] = []
    /// Reviewers currently on the hook (never reviewed yet).
    var awaitingReview: [String] = []
    /// Reviewers who asked for changes and have *not* been re-requested — the
    /// only ones whose feedback is still sitting in your court.
    var blockingReviewers: [String] = []
    /// GitHub is waiting on *you* to review this one.
    var myReviewRequested: Bool = false
    /// Your review requested through a team you belong to (e.g. "@backend").
    var myTeamRequests: [String] = []
    /// Review threads nobody has resolved yet.
    var unresolved: [ReviewThread] = []
    var unresolvedThreads: Int { unresolved.count }
    /// Still listed, but left out of the menu-bar count and icon.
    var isMenuBarMuted: Bool = false
    /// Reviewer login -> their latest verdict.
    var reviewerStates: [String: String] = [:]

    var sources: Set<Source> = []

    /// Muted by hand — never counted, never notified, parked at the bottom.
    var isIgnored: Bool = false
    /// "I've pushed the fixes" — still open, but no longer shouting.
    /// Cleared automatically as soon as a new review lands.
    var isOngoing: Bool = false
    /// Pinned by hand — always floats to its own section at the top, regardless
    /// of how loud (or quiet) it otherwise is.
    var isPinned: Bool = false

    var id: String { "\(owner)/\(repo)#\(number)" }
    var slug: String { "\(owner)/\(repo)#\(number)" }
    var state: PRState {
        if isMerged { return .merged }
        if isClosed { return .closed }
        if isDraft { return .draft }
        if hasConflicts { return .conflict }
        return .open
    }

    /// Everyone involved in review — users and teams — with where they stand.
    /// Includes you, so your own approval stays visible until the PR merges.
    var reviewers: [Reviewer] {
        var out: [String: Reviewer] = [:]
        for (login, raw) in reviewerStates {
            out[login] = Reviewer(login: login, verdict: Self.verdict(forRawState: raw), reRequested: false)
        }
        for login in reReviewRequested { out[login]?.reRequested = true }
        for login in awaitingReview where out[login] == nil {
            out[login] = Reviewer(login: login, verdict: .pending, reRequested: false)
        }
        return out.values.sorted { ($0.sortKey, $0.login.lowercased()) < ($1.sortKey, $1.login.lowercased()) }
    }
    var repoSlug: String { "\(owner)/\(repo)" }
    var repoURL: String { "https://github.com/\(owner)/\(repo)" }

    /// Lower means louder — drives both PR order and which repo floats to the top.
    var attentionRank: Int {
        if isIgnored { return 10 }
        if isMerged || isClosed { return 9 }
        if isOngoing { return 5 }
        if verdict == .changesRequested { return 0 }   // your move
        if myReviewRequested { return 1 }              // also your move
        if ci == .failure { return 2 }
        if !reReviewRequested.isEmpty { return 3 }     // their move — just waiting
        if verdict == .approved { return 4 }
        return 3
    }

    /// Only things you can actually do something about.
    var needsAttention: Bool { attentionRank <= 1 }

    /// Identifies the current round of review. Marking a PR "ongoing" pins this
    /// value, so the moment any reviewer submits something new it stops matching
    /// and the PR goes back to demanding attention.
    var reviewSignature: String {
        reviewerStates.map { "\($0.key):\($0.value)" }.sorted().joined(separator: "|")
            + "|" + reReviewRequested.sorted().joined(separator: ",")
    }

    /// The bits that, when they change, are worth a notification.
    var fingerprint: String {
        return "\(verdict.rawValue)|\(ci.rawValue)|\(reviewSignature)|\(myReviewRequested)|\(isMerged)|\(isClosed)|\(isDraft)"
    }

    /// Reviews left by bot accounts (CodeRabbit, Copilot, github-actions, …),
    /// keyed by login, latest verdict per bot. These logins are frequently not
    /// in `requested_reviewers` at all — bots often auto-review — so they'd
    /// otherwise be invisible outside `reviewerStates`.
    /// Severity tables ("Findings Summary": Total | P0 | P1 | …) parsed from bot
    /// reviews or comments, latest per bot. Empty when no bot posted one.
    var botFindings: [BotFindings] = []

    var botReviews: [(login: String, verdict: ReviewVerdict)] {
        reviewerStates
            .filter { $0.key.lowercased().hasSuffix("[bot]") }
            .map { ($0.key, Self.verdict(forRawState: $0.value)) }
            .sorted { $0.login < $1.login }
    }

    private static func verdict(forRawState raw: String) -> ReviewVerdict {
        switch raw {
        case "APPROVED":          return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "COMMENTED":         return .commented
        default:                 return .pending
        }
    }
}

/// An unresolved review thread, summarised by its first comment.
struct ReviewThread: Codable, Hashable, Identifiable {
    var id: String
    var author: String
    var path: String?
    var line: Int?
    var body: String
    var url: String
}

/// One bot's findings table, e.g. J-Bot's "Findings Summary".
struct BotFindings: Codable, Hashable, Identifiable {
    var login: String
    /// Non-zero severities in table order, e.g. [("P2", 2)].
    var counts: [Count]
    var id: String { login }

    struct Count: Codable, Hashable { var severity: String; var n: Int }

    var displayName: String {
        login.replacingOccurrences(of: "[bot]", with: "", options: .caseInsensitive)
    }

    /// Finds a header row containing P0 and P1 and reads the next row of numbers.
    /// Handles markdown pipe tables and tab/space separated text.
    static func parse(_ body: String, login: String) -> BotFindings? {
        func cells(_ line: String) -> [String] {
            line.split(whereSeparator: { $0 == "|" || $0 == "\t" || $0 == " " })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let lines = body.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            let header = cells(line)
            let upper = header.map { $0.uppercased() }
            guard upper.contains("P0"), upper.contains("P1") else { continue }
            for next in lines.dropFirst(i + 1) {
                let row = cells(next)
                if row.isEmpty || row.allSatisfy({ $0.allSatisfy { "-:".contains($0) } }) { continue }
                let nums = row.compactMap(Int.init)
                guard nums.count == header.count else { break }
                let counts = zip(header, nums)
                    .filter { $0.0.lowercased() != "total" && $0.1 > 0 }
                    .map { Count(severity: $0.0, n: $0.1) }
                return BotFindings(login: login, counts: counts)
            }
        }
        return nil
    }
}

/// Where *your* review stands on someone's PR — one tag instead of
/// separate "review requested" / "reviewed" labels.
enum MyReview {
    case yourTurn       // requested, you haven't reviewed
    case reRequested    // you reviewed, and they asked again
    case changesRequested
    case approved
    case commented

    var label: String {
        switch self {
        case .yourTurn: return "your turn"
        case .reRequested: return "your turn · re-requested"
        case .changesRequested: return "you requested changes"
        case .approved: return "you approved"
        case .commented: return "you commented"
        }
    }

    var symbol: String? {
        switch self {
        case .reRequested: return "arrow.triangle.2.circlepath"
        case .changesRequested: return "exclamationmark.triangle.fill"
        case .approved: return "checkmark.seal.fill"
        default: return nil
        }
    }
}

extension PullRequest {
    func myReview(login: String?) -> MyReview? {
        guard let login else { return nil }
        let mine = reviewerStates.first { $0.key.caseInsensitiveCompare(login) == .orderedSame }?.value
        if myReviewRequested { return mine == nil ? .yourTurn : .reRequested }
        switch mine {
        case "CHANGES_REQUESTED": return .changesRequested
        case "APPROVED": return .approved
        case "COMMENTED": return .commented
        default: return nil
        }
    }
}

struct Reviewer: Hashable, Identifiable {
    var login: String
    var verdict: ReviewVerdict
    /// Reviewed before and has been asked to look again.
    var reRequested: Bool
    var id: String { login }
    var isTeam: Bool { login.hasPrefix("@") }
    var isBot: Bool { login.lowercased().hasSuffix("[bot]") }
    fileprivate var sortKey: Int {
        switch verdict {
        case .changesRequested: return 0
        case .pending: return 1
        case .commented: return 2
        case .approved: return 3
        case .none: return 4
        }
    }
}

struct PRRef: Codable, Hashable, Identifiable {
    var owner: String
    var repo: String
    var number: Int
    var id: String { "\(owner)/\(repo)#\(number)" }

    /// Accepts https://github.com/o/r/pull/123 (with any trailing path/query),
    /// git@github.com:o/r.git#123, or plain o/r#123.
    static func parse(_ raw: String) -> PRRef? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"github\.com[/:]([\w.-]+)/([\w.-]+?)(?:\.git)?/pull/(\d+)"#,
            #"github\.com[/:]([\w.-]+)/([\w.-]+?)(?:\.git)?#(\d+)"#,
            #"^([\w.-]+)/([\w.-]+?)(?:\.git)?#(\d+)$"#,
        ]
        for p in patterns {
            guard let rx = try? NSRegularExpression(pattern: p),
                  let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  m.numberOfRanges == 4,
                  let r1 = Range(m.range(at: 1), in: s),
                  let r2 = Range(m.range(at: 2), in: s),
                  let r3 = Range(m.range(at: 3), in: s),
                  let n = Int(s[r3])
            else { continue }
            return PRRef(owner: String(s[r1]), repo: String(s[r2]), number: n)
        }
        return nil
    }
}

/// One repository's PRs, collapsed into a section in the popover.
struct RepoGroup: Identifiable {
    var owner: String
    var repo: String
    var prs: [PullRequest]

    var id: String { "\(owner)/\(repo)" }
    var slug: String { "\(owner)/\(repo)" }
    var url: String { "https://github.com/\(owner)/\(repo)" }

    /// The loudest PR in the repo decides where the repo sits.
    var rank: Int { prs.map(\.attentionRank).min() ?? 9 }
    /// Red: feedback sitting in your court.
    var changesRequestedCount: Int {
        prs.filter { $0.verdict == .changesRequested && !$0.isOngoing }.count
    }
    /// Yellow: PRs waiting on a review from you.
    var yourTurnCount: Int { prs.filter(\.myReviewRequested).count }
    var visible: [PullRequest] { prs.filter { !$0.isIgnored } }
}

/// When a prompt is the obvious one to reach for on a PR row.
enum PromptContext: String, Codable, CaseIterable, Hashable {
    case always
    case reviewRequested
    case changesRequested

    var label: String {
        switch self {
        case .always: return "Any PR"
        case .reviewRequested: return "My review requested"
        case .changesRequested: return "Changes requested on mine"
        }
    }

    func matches(_ pr: PullRequest) -> Bool {
        switch self {
        case .always: return true
        case .reviewRequested: return pr.myReviewRequested
        case .changesRequested: return pr.verdict == .changesRequested && !pr.isMerged && !pr.isClosed
        }
    }
}

/// A reusable snippet copied from a PR row, e.g. a prompt for an AI reviewer.
struct CopyPrompt: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var template: String
    /// Which PRs this prompt is suggested for; it stays copyable on any PR.
    var when: PromptContext = .always

    // Hand-written so prompts.json from an older build (no `when`) still loads.
    init(id: UUID = UUID(), name: String, template: String, when: PromptContext = .always) {
        self.id = id
        self.name = name
        self.template = template
        self.when = when
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        template = try c.decode(String.self, forKey: .template)
        when = try c.decodeIfPresent(PromptContext.self, forKey: .when) ?? .always
    }

    static let placeholderHelp = "{{pr-no}}, {{pr-link}}, {{pr-title}}, {{repo}}"

    func render(for pr: PullRequest) -> String {
        template
            .replacingOccurrences(of: "{{pr-no}}", with: String(pr.number))
            .replacingOccurrences(of: "{{pr-link}}", with: pr.url)
            .replacingOccurrences(of: "{{pr-title}}", with: pr.title)
            .replacingOccurrences(of: "{{repo}}", with: pr.repoSlug)
    }

    static let defaults = [
        CopyPrompt(
            name: "Review this PR",
            template: """
                Review pull request #{{pr-no}} in {{repo}}: {{pr-link}}

                Read the diff and the surrounding code before judging anything. Report only problems \
                you can point at in the code: bugs, wrong logic, unhandled edge cases, security issues, \
                race conditions, broken contracts. Skip style preferences. For each one, quote the code, \
                say when it fails, and how to fix it. If the change looks fine, say so.
                """,
            when: .reviewRequested),
        CopyPrompt(
            name: "Address requested changes",
            template: """
                Address the review feedback on my pull request #{{pr-no}} in {{repo}}: {{pr-link}}

                Read every review comment and unresolved thread first, then list what each reviewer is \
                asking for. Make the changes, keeping them to what was asked. Then summarise what you \
                changed per comment, and flag anything you disagree with rather than silently skipping it.
                """,
            when: .changesRequested),
    ]
}

/// One PR you worked on inside a work-report window.
struct WorkItem: Hashable {
    var owner: String
    var repo: String
    var number: Int
    var title: String
    var url: String
    /// Someone else's PR that you reviewed, as opposed to your own.
    var reviewed: Bool
}

enum WorkReport {
    /// Two sections, each grouped by repository, with linked PR numbers:
    ///
    ///     Work
    ///
    ///     `repo`
    ///
    ///     * [#12](link) : Title
    ///
    ///     Reviews
    ///
    ///     `repo2`
    ///
    ///     * [#9](link) : Title
    static func format(_ items: [WorkItem]) -> String {
        let sections = [("Work", items.filter { !$0.reviewed }), ("Reviews", items.filter(\.reviewed))]
        return sections
            .filter { !$0.1.isEmpty }
            .map { "\($0.0)\n\n" + repoGroups($0.1) }
            .joined(separator: "\n\n")
    }

    /// Rich-text twin of `format`, for apps that take pasted HTML (Slack, Notion,
    /// Gmail). Slack's composer ignores markdown links but honours pasted HTML,
    /// so this is what makes `#123` clickable there.
    static func html(_ items: [WorkItem]) -> String {
        let sections = [("Work", items.filter { !$0.reviewed }), ("Reviews", items.filter(\.reviewed))]
        let body = sections
            .filter { !$0.1.isEmpty }
            .map { "<p><b>\($0.0)</b></p>" + repoGroupsHTML($0.1) }
            .joined()
        return "<meta charset=\"utf-8\">" + body
    }

    private static func repoGroupsHTML(_ items: [WorkItem]) -> String {
        grouped(items).map { label, prs in
            let rows = prs.map {
                "<li><a href=\"\(escape($0.url))\">#\($0.number)</a> : \(escape($0.title))</li>"
            }.joined()
            return "<p><code>\(escape(label))</code></p><ul>\(rows)</ul>"
        }.joined()
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Repo label (bare name unless two owners share it) with its PRs, repo order stable.
    private static func grouped(_ items: [WorkItem]) -> [(String, [WorkItem])] {
        let groups = Dictionary(grouping: items) { "\($0.owner)/\($0.repo)" }
        let nameCounts = Dictionary(grouping: groups.keys) { $0.split(separator: "/").last.map(String.init) ?? $0 }
        return groups.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { slug in
                let prs = groups[slug]!.sorted { $0.number < $1.number }
                let label = (nameCounts[prs[0].repo]?.count ?? 0) > 1 ? slug : prs[0].repo
                return (label, prs)
            }
    }

    private static func repoGroups(_ items: [WorkItem]) -> String {
        grouped(items).map { label, prs in
            let lines = prs.map { "* [#\($0.number)](\($0.url)) : \($0.title)" }
            return "`\(label)`\n\n" + lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}

/// A sidebar section of the popover.
enum ListSection: String, CaseIterable, Identifiable {
    case inbox, needsYou, mine, reviews, assigned, watching, pinned, ignored
    case report, settings

    var id: String { rawValue }
    static let lists: [ListSection] = [.inbox, .needsYou, .mine, .reviews, .assigned, .watching, .pinned, .ignored]

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .needsYou: return "Needs you"
        case .mine: return "My PRs"
        case .reviews: return "Reviews"
        case .assigned: return "Assigned"
        case .watching: return "Watching"
        case .pinned: return "Pinned"
        case .ignored: return "Ignored"
        case .report: return "Work report"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: return "tray.full"
        case .needsYou: return "exclamationmark.circle"
        case .mine: return "person"
        case .reviews: return "eye"
        case .assigned: return "person.badge.clock"
        case .watching: return "binoculars"
        case .pinned: return "pin"
        case .ignored: return "bell.slash"
        case .report: return "doc.text"
        case .settings: return "gearshape"
        }
    }

    func contains(_ pr: PullRequest) -> Bool {
        if self == .ignored { return pr.isIgnored }
        if pr.isIgnored { return false }
        switch self {
        case .inbox: return true
        case .needsYou: return pr.needsAttention && !pr.isMerged && !pr.isClosed && !pr.isOngoing
        case .mine: return pr.sources.contains(.authored)
        case .reviews: return pr.sources.contains(.reviewRequest) || pr.sources.contains(.reviewed)
        case .assigned: return pr.sources.contains(.assigned)
        case .watching: return pr.sources.contains(.watched)
        case .pinned: return pr.isPinned
        default: return false
        }
    }
}
