import Foundation
import AppKit
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
    /// How long a merged or closed PR stays on the list before it's dropped.
    @AppStorage("finishedRetentionMinutes") var finishedRetentionMinutes: Int = 30
    /// Snippets offered by each PR row's copy button, edited in Settings.
    @Published var copyPrompts: [CopyPrompt] = CopyPrompt.defaults {
        didSet { savePrompts() }
    }
    /// End of the last work-report window (seconds since 1970); 0 until you reset one.
    @AppStorage("lastWorkReportAt") var lastWorkReportAt: Double = 0
    /// One-time merge of the situation-aware default prompts into an older prompts.json.
    @AppStorage("seededSituationPrompts") var seededSituationPrompts: Bool = false
    /// First launch of GitWall — where the very first work report starts.
    @AppStorage("monitoringSince") var monitoringSince: Double = 0

    private let api = GitHub()
    private var previous: [String: PullRequest] = [:]
    private var myTeams: Set<String>?
    private var timer: Task<Void, Never>?
    private let watchedURL = URL.applicationSupportDirectory
        .appendingPathComponent("GitWall/watched.json")
    private let prefsURL = URL.applicationSupportDirectory
        .appendingPathComponent("GitWall/prefs.json")
    private let rulesURL = URL.applicationSupportDirectory
        .appendingPathComponent("GitWall/review-rules.json")
    private let promptsURL = URL.applicationSupportDirectory
        .appendingPathComponent("GitWall/prompts.json")

    /// Hand-set state that has to survive relaunches.
    private struct Prefs: Codable {
        var ignored: Set<String> = []
        var collapsed: Set<String> = []
        /// PR id -> the review signature at the moment it was marked ongoing.
        var ongoing: [String: String] = [:]
        /// Pinned to the top of the list, across repos.
        var pinned: Set<String> = []
        /// Listed as usual but left out of the menu-bar count.
        var menuBarMuted: Set<String> = []

        init() {}
        // Hand-written so prefs.json from an older build still loads.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ignored = try c.decodeIfPresent(Set<String>.self, forKey: .ignored) ?? []
            collapsed = try c.decodeIfPresent(Set<String>.self, forKey: .collapsed) ?? []
            ongoing = try c.decodeIfPresent([String: String].self, forKey: .ongoing) ?? [:]
            pinned = try c.decodeIfPresent(Set<String>.self, forKey: .pinned) ?? []
            menuBarMuted = try c.decodeIfPresent(Set<String>.self, forKey: .menuBarMuted) ?? []
        }
    }
    @Published private var prefs = Prefs()

    init() {
        loadWatched()
        loadPrefs()
        loadPrompts()
        loadRules()
        NotificationDelegate.onAction = { [weak self] action, id in
            guard let self, let pr = self.prs.first(where: { $0.id == id }) else { return }
            if action == Notifier.ignoreAction { self.setIgnored(pr, true) }
            else { self.setMenuBarMuted(pr, true) }
        }
        if monitoringSince == 0 { monitoringSince = Date().timeIntervalSince1970 }
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
                && !$0.isIgnored && !$0.isOngoing && !$0.isMenuBarMuted
        }.count
    }
    /// PRs waiting on a review from you.
    var yourTurnCount: Int {
        prs.filter { $0.myReviewRequested && !$0.isIgnored && !$0.isMenuBarMuted && !$0.isMerged && !$0.isClosed }.count
    }
    var menuBarSymbol: String {
        if errorText != nil { return "exclamationmark.icloud" }
        if changesRequestedCount > 0 { return "exclamationmark.bubble.fill" }
        if prs.contains(where: { $0.ci == .failure && !$0.isIgnored && !$0.isMenuBarMuted }) { return "xmark.octagon" }
        return "checkmark.bubble"
    }

    // MARK: - Token

    func updateToken(_ t: String) {
        token = t.trimmingCharacters(in: .whitespacesAndNewlines)
        TokenStore.save(token)
        account = nil
        myTeams = nil
        Task { await api.setToken(token); await refresh() }
    }

    func signOut() {
        TokenStore.save("")
        token = ""
        account = nil
        myTeams = nil
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
            if myTeams == nil { myTeams = await api.myTeams() }
            let teams = myTeams ?? []

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

            // PRs that dropped out of the open-PR searches since last poll: most
            // were just merged or closed. Keep them around for the retention window.
            var lingering: [PullRequest] = []
            for old in previous.values where refs[old.id] == nil {
                let ref = PRRef(owner: old.owner, repo: old.repo, number: old.number)
                if old.isMerged || old.isClosed {
                    if isWithinRetention(old) { lingering.append(old) }
                    continue
                }
                guard var pr = try? await api.detail(ref, viewer: login, teams: teams, rules: reviewRules),
                      pr.isMerged || pr.isClosed else { continue }
                pr.sources = old.sources
                if isWithinRetention(pr) { lingering.append(pr) }
            }

            var fresh: [PullRequest] = []
            for ref in refs.values {
                var pr = try await api.detail(ref, viewer: login, teams: teams, rules: reviewRules)
                pr.sources = sources[ref.id] ?? []
                // A pasted link stays forever, but once it's done it ages out too.
                if (pr.isMerged || pr.isClosed) && !isWithinRetention(pr) { continue }
                fresh.append(pr)
            }
            for pr in lingering where !fresh.contains(where: { $0.id == pr.id }) {
                fresh.append(pr)
            }
            for i in fresh.indices {
                var pr = fresh[i]
                pr.isIgnored = prefs.ignored.contains(pr.id)
                pr.isPinned = prefs.pinned.contains(pr.id)
                pr.isMenuBarMuted = prefs.menuBarMuted.contains(pr.id)
                // A new review invalidates the pinned signature, un-mutes the PR.
                pr.isOngoing = prefs.ongoing[pr.id] == pr.reviewSignature
                fresh[i] = pr
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

    private func isWithinRetention(_ pr: PullRequest) -> Bool {
        guard let done = pr.finishedAt else { return true }
        return Date().timeIntervalSince(done) < Double(finishedRetentionMinutes) * 60
    }

    /// PRs bucketed by repository, repos that need attention first.
    /// Pinned PRs live in their own section up top instead; ignored PRs are
    /// pulled out into their own section at the bottom.
    var repoGroups: [RepoGroup] {
        groups(prs.filter { !$0.isIgnored && !$0.isPinned })
    }

    /// PRs in a sidebar section, bucketed by repository, loudest repo first.
    func groups(for section: ListSection) -> [RepoGroup] {
        groups(prs(in: section))
    }

    func prs(in section: ListSection) -> [PullRequest] {
        prs.filter { section.contains($0) }
    }

    private func groups(_ list: [PullRequest]) -> [RepoGroup] {
        Dictionary(grouping: list, by: \.repoSlug)
            .values
            .map { RepoGroup(owner: $0[0].owner, repo: $0[0].repo,
                             prs: $0.sorted { $0.attentionRank < $1.attentionRank }) }
            .sorted { ($0.rank, $0.slug) < ($1.rank, $1.slug) }
    }

    /// Hand-pinned PRs, loudest first, regardless of repo.
    var pinnedPRs: [PullRequest] {
        prs.filter { $0.isPinned && !$0.isIgnored }.sorted { $0.attentionRank < $1.attentionRank || ($0.attentionRank == $1.attentionRank && $0.slug < $1.slug) }
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

    /// Keep the PR listed but stop counting it in the menu bar.
    func setMenuBarMuted(_ pr: PullRequest, _ muted: Bool) {
        if muted { prefs.menuBarMuted.insert(pr.id) } else { prefs.menuBarMuted.remove(pr.id) }
        savePrefs()
        apply()
    }

    /// Resolves every open review thread on the PR, then refreshes.
    func resolveAllComments(_ pr: PullRequest) async {
        do {
            _ = try await api.resolveAllThreads(PRRef(owner: pr.owner, repo: pr.repo, number: pr.number))
            errorText = nil
        } catch {
            errorText = "Couldn't resolve comments on \(pr.slug): \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Pin or unpin a PR — pinned PRs float to their own section at the top.
    func setPinned(_ pr: PullRequest, _ pinned: Bool) {
        if pinned { prefs.pinned.insert(pr.id) } else { prefs.pinned.remove(pr.id) }
        savePrefs()
        apply()
    }

    // MARK: - Copy prompts

    /// Copies plain text, optionally with an HTML twin. Apps that take rich text
    /// (Slack, Notion, Gmail) use the HTML and get real links; editors get the text.
    static func copyToPasteboard(_ text: String, html: String? = nil) {
        NSPasteboard.general.clearContents()
        if let html {
            NSPasteboard.general.setString(html, forType: .html)
        }
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// How severity tables are read from reviews and comments. Edited in Settings.
    @Published var reviewRules: [ReviewRule] = ReviewRule.defaults {
        didSet { saveRules() }
    }

    private func loadRules() {
        guard let data = try? Data(contentsOf: rulesURL),
              let saved = try? JSONDecoder().decode([ReviewRule].self, from: data) else { return }
        reviewRules = saved
    }

    private func saveRules() {
        try? FileManager.default.createDirectory(
            at: rulesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(reviewRules).write(to: rulesURL)
    }

    private func loadPrompts() {
        guard let data = try? Data(contentsOf: promptsURL),
              let saved = try? JSONDecoder().decode([CopyPrompt].self, from: data) else { return }
        copyPrompts = saved
        // Prompts saved before the situation-aware defaults existed: add the new
        // ones once, so an upgrade isn't stuck with the original single prompt.
        if !seededSituationPrompts {
            let names = Set(saved.map(\.name))
            copyPrompts += CopyPrompt.defaults.filter { !names.contains($0.name) }
            seededSituationPrompts = true
        }
    }

    private func savePrompts() {
        try? FileManager.default.createDirectory(
            at: promptsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(copyPrompts).write(to: promptsURL)
    }

    // MARK: - Work report

    /// Reports run back-to-back: each starts where the last one was reset, and the
    /// first starts when GitWall was installed and began watching.
    var workReportSince: Date {
        let start = lastWorkReportAt > 0 ? lastWorkReportAt : monitoringSince
        return start > 0 ? Date(timeIntervalSince1970: start) : Date()
    }

    func buildWorkReport() async throws -> (text: String, html: String, since: Date, until: Date) {
        guard !token.isEmpty else { throw GitHubError.noToken }
        if account == nil { account = try await api.currentAccount() }
        guard let login = account?.login else { throw GitHubError.noToken }
        let since = workReportSince
        let until = Date()
        let items = try await api.workItems(login: login, since: since)
        let text = items.isEmpty
            ? "No PR work since \(since.formatted(date: .abbreviated, time: .shortened))."
            : WorkReport.format(items)
        let html = items.isEmpty ? "<p>\(text)</p>" : WorkReport.html(items)
        return (text, html, since, until)
    }

    /// Reset: the next report starts where this one ended. Retain is simply not calling this.
    func resetWorkReportWindow(until: Date) {
        lastWorkReportAt = until.timeIntervalSince1970
    }

    /// Re-apply prefs to the PRs already in memory, no network round trip.
    private func apply() {
        for i in prs.indices {
            prs[i].isIgnored = prefs.ignored.contains(prs[i].id)
            prs[i].isPinned = prefs.pinned.contains(prs[i].id)
            prs[i].isMenuBarMuted = prefs.menuBarMuted.contains(prs[i].id)
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
                              url: pr.url, prID: pr.id)
            } else if pr.verdict == .approved && old.verdict != .approved {
                Notifier.post(title: "Approved — \(pr.slug)", body: pr.title, url: pr.url, prID: pr.id)
            } else if pr.myReviewRequested && !old.myReviewRequested {
                // Only worth a ping when the request is aimed at you. A re-review
                // you asked for yourself is not news.
                Notifier.post(title: "Your review requested — \(pr.slug)",
                              body: pr.title, url: pr.url, prID: pr.id)
            } else if pr.isMerged && !old.isMerged {
                Notifier.post(title: "Merged — \(pr.slug)", body: pr.title, url: pr.url, prID: pr.id)
            } else if pr.isClosed && !old.isClosed {
                Notifier.post(title: "Closed — \(pr.slug)", body: pr.title, url: pr.url, prID: pr.id)
            } else if old.isOngoing && !pr.isOngoing {
                // Was marked "working on it", but a reviewer has since spoken.
                Notifier.post(title: "New review activity — \(pr.slug)",
                              body: pr.title, url: pr.url, prID: pr.id)
            } else if notifyCI && pr.ci == .failure && old.ci != .failure {
                Notifier.post(title: "Checks failing — \(pr.slug)", body: pr.title, url: pr.url, prID: pr.id)
            }
        }
    }
}
