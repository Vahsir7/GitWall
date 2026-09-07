import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class Store: ObservableObject {
    @Published var prs: [PullRequest] = []
    @Published var watched: [PRRef] = []
    @Published var account: GitHub.Account?
    @Published var lastRefresh: Date?
    @Published var isRefreshing = false
    @Published var errorText: String?
    @Published var token: String = ""
    /// Whether macOS will actually show GitWall's notifications. Surfaced in
    /// Settings so a silently-denied permission doesn't look like a bug.
    @Published var notificationStatus: UNAuthorizationStatus = .notDetermined

    @AppStorage("pollSeconds") var pollSeconds: Int = 120
    @AppStorage("notifyCI") var notifyCI: Bool = true
    @AppStorage("includeAuthored") var includeAuthored: Bool = true

    private let api = GitHub()
    private var previous: [String: PullRequest] = [:]
    private var timer: Task<Void, Never>?
    private let watchedURL = URL.applicationSupportDirectory
        .appendingPathComponent("GitWall/watched.json")
    private let prefsURL = URL.applicationSupportDirectory
        .appendingPathComponent("GitWall/prefs.json")

    /// Hand-set state that has to survive relaunches.
    private struct Prefs: Codable {
        var ignored: Set<String> = []
        var collapsed: Set<String> = []
        /// PR id -> the review signature at the moment it was marked ongoing.
        var ongoing: [String: String] = [:]
    }
    @Published private var prefs = Prefs()

    init() {
        loadWatched()
        loadPrefs()
        token = TokenStore.load() ?? TokenStore.fromGHCLI() ?? ""
        Task { await api.setToken(token); await start() }
        Task { await refreshNotificationStatus() }
    }

    /// Re-checks the OS permission. Call this when Settings opens too, since
    /// the user may have flipped it in System Settings since launch.
    func refreshNotificationStatus() async {
        notificationStatus = await Notifier.authorizationStatus()
    }

    // MARK: - Menu bar summary

    /// What the menu bar shows: open PRs with changes requested that you have
    /// neither ignored nor already marked as being worked on.
    var changesRequestedCount: Int {
        prs.filter {
            $0.verdict == .changesRequested && !$0.isClosed && !$0.isMerged
                && !$0.isIgnored && !$0.isOngoing
        }.count
    }
    /// PRs waiting on a review from you.
    var yourTurnCount: Int {
        prs.filter { $0.myReviewRequested && !$0.isIgnored && !$0.isMerged && !$0.isClosed }.count
    }
    var menuBarSymbol: String {
        if errorText != nil { return "exclamationmark.icloud" }
        if changesRequestedCount > 0 { return "exclamationmark.bubble.fill" }
        if prs.contains(where: { $0.ci == .failure && !$0.isIgnored }) { return "xmark.octagon" }
        return "checkmark.bubble"
    }

    // MARK: - Token

    func updateToken(_ t: String) {
        token = t.trimmingCharacters(in: .whitespacesAndNewlines)
        TokenStore.save(token)
        account = nil
        Task { await api.setToken(token); await refresh() }
    }

    func signOut() {
        TokenStore.save("")
        token = ""
        account = nil
        prs = []
        previous = [:]
        errorText = nil
        Task { await api.setToken(nil) }
    }

    // MARK: - Watched PRs

    func addWatched(_ raw: String) -> Bool {
        guard let ref = PRRef.parse(raw) else { return false }
        if !watched.contains(ref) {
            watched.append(ref)
            saveWatched()
            Task { await refresh() }
        }
        return true
    }

    func removeWatched(_ ref: PRRef) {
        watched.removeAll { $0 == ref }
        prs.removeAll { $0.id == ref.id && $0.sources == [.watched] }
        saveWatched()
    }

    private func loadWatched() {
        guard let data = try? Data(contentsOf: watchedURL),
              let refs = try? JSONDecoder().decode([PRRef].self, from: data) else { return }
        watched = refs
    }

    private func saveWatched() {
        try? FileManager.default.createDirectory(
            at: watchedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(watched).write(to: watchedURL)
    }

    // MARK: - Polling

    func start() async {
        timer?.cancel()
        await refresh()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                let secs = self?.pollSeconds ?? 120
                try? await Task.sleep(for: .seconds(max(30, secs)))
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard !token.isEmpty else { errorText = GitHubError.noToken.localizedDescription; return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            if account == nil { account = try await api.currentAccount() }
            guard let login = account?.login else { return }

            var sources: [String: Set<Source>] = [:]
            var refs: [String: PRRef] = [:]

            for (ref, source) in try await api.myPRRefs(login: login) {
                if source == .authored && !includeAuthored { continue }
                refs[ref.id] = ref
                sources[ref.id, default: []].insert(source)
            }
            for ref in watched {
                refs[ref.id] = ref
                sources[ref.id, default: []].insert(.watched)
            }

            var fresh: [PullRequest] = []
            for ref in refs.values {
                var pr = try await api.detail(ref, viewer: login)
                pr.sources = sources[ref.id] ?? []
                pr.isIgnored = prefs.ignored.contains(pr.id)
                // A new review invalidates the pinned signature, un-mutes the PR.
                pr.isOngoing = prefs.ongoing[pr.id] == pr.reviewSignature
                fresh.append(pr)
            }
            fresh.sort {
                ($0.attentionRank, $0.repoSlug, -$0.number)
                    < ($1.attentionRank, $1.repoSlug, -$1.number)
            }

            notifyChanges(new: fresh)
            previous = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
            prs = fresh
            lastRefresh = Date()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// PRs bucketed by repository, repos that need attention first.
    /// Ignored PRs are pulled out into their own section at the bottom.
    var repoGroups: [RepoGroup] {
        Dictionary(grouping: prs.filter { !$0.isIgnored }, by: \.repoSlug)
            .values
            .map { RepoGroup(owner: $0[0].owner, repo: $0[0].repo,
                             prs: $0.sorted { $0.attentionRank < $1.attentionRank }) }
            .sorted { ($0.rank, $0.slug) < ($1.rank, $1.slug) }
    }

    var ignoredPRs: [PullRequest] {
        prs.filter(\.isIgnored).sorted { $0.slug < $1.slug }
    }

    // MARK: - Per-PR and per-repo state

    func isCollapsed(_ slug: String) -> Bool { prefs.collapsed.contains(slug) }

    func toggleCollapsed(_ slug: String) {
        if prefs.collapsed.contains(slug) { prefs.collapsed.remove(slug) }
        else { prefs.collapsed.insert(slug) }
        savePrefs()
    }

    func setIgnored(_ pr: PullRequest, _ ignored: Bool) {
        if ignored { prefs.ignored.insert(pr.id) } else { prefs.ignored.remove(pr.id) }
        savePrefs()
        apply()
    }

    /// "Changes are in progress" — drops the PR out of the attention count until
    /// a reviewer says something new.
    func setOngoing(_ pr: PullRequest, _ ongoing: Bool) {
        if ongoing { prefs.ongoing[pr.id] = pr.reviewSignature }
        else { prefs.ongoing[pr.id] = nil }
        savePrefs()
        apply()
    }

    /// Re-apply prefs to the PRs already in memory, no network round trip.
    private func apply() {
        for i in prs.indices {
            prs[i].isIgnored = prefs.ignored.contains(prs[i].id)
            prs[i].isOngoing = prefs.ongoing[prs[i].id] == prs[i].reviewSignature
        }
        prs.sort {
            ($0.attentionRank, $0.repoSlug, -$0.number)
                < ($1.attentionRank, $1.repoSlug, -$1.number)
        }
    }

    private func loadPrefs() {
        guard let data = try? Data(contentsOf: prefsURL),
              let p = try? JSONDecoder().decode(Prefs.self, from: data) else { return }
        prefs = p
    }

    private func savePrefs() {
        try? FileManager.default.createDirectory(
            at: prefsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(prefs).write(to: prefsURL)
    }

    /// Only fires on a *transition*, so a PR that has been red for a week
    /// doesn't re-notify every poll. First sighting is never announced.
    private func notifyChanges(new: [PullRequest]) {
        for pr in new {
            guard !pr.isIgnored else { continue }
            guard let old = previous[pr.id], old.fingerprint != pr.fingerprint else { continue }

            if pr.verdict == .changesRequested && old.verdict != .changesRequested {
                let who = pr.blockingReviewers.joined(separator: ", ")
                Notifier.post(title: "Changes requested — \(pr.slug)",
                              body: who.isEmpty ? pr.title : "\(who) — \(pr.title)",
                              url: pr.url)
            } else if pr.verdict == .approved && old.verdict != .approved {
                Notifier.post(title: "Approved — \(pr.slug)", body: pr.title, url: pr.url)
            } else if pr.myReviewRequested && !old.myReviewRequested {
                // Only worth a ping when the request is aimed at you. A re-review
                // you asked for yourself is not news.
                Notifier.post(title: "Your review requested — \(pr.slug)",
                              body: pr.title, url: pr.url)
            } else if pr.isMerged && !old.isMerged {
                Notifier.post(title: "Merged — \(pr.slug)", body: pr.title, url: pr.url)
            } else if pr.isClosed && !old.isClosed {
                Notifier.post(title: "Closed — \(pr.slug)", body: pr.title, url: pr.url)
            } else if old.isOngoing && !pr.isOngoing {
                // Was marked "working on it", but a reviewer has since spoken.
                Notifier.post(title: "New review activity — \(pr.slug)",
                              body: pr.title, url: pr.url)
            } else if notifyCI && pr.ci == .failure && old.ci != .failure {
                Notifier.post(title: "Checks failing — \(pr.slug)", body: pr.title, url: pr.url)
            }
        }
    }
}
