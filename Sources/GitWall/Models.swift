import Foundation

/// Where a PR came from: GitHub said it's mine, or the user pasted its link.
enum Source: String, Codable, Hashable {
    case assigned      // assigned to me
    case reviewRequest // my review was requested
    case authored      // I opened it
    case watched       // pasted link
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
    /// Reviewer login -> their latest verdict.
    var reviewerStates: [String: String] = [:]

    var sources: Set<Source> = []

    /// Muted by hand — never counted, never notified, parked at the bottom.
    var isIgnored: Bool = false
    /// "I've pushed the fixes" — still open, but no longer shouting.
    /// Cleared automatically as soon as a new review lands.
    var isOngoing: Bool = false

    var id: String { "\(owner)/\(repo)#\(number)" }
    var slug: String { "\(owner)/\(repo)#\(number)" }
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
