import SwiftUI
import AppKit
import UserNotifications

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var pasted = ""
    @State private var badPaste = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.token.isEmpty || showSettings {
                SettingsView(showSettings: $showSettings)
            } else {
                pasteBar
                Divider()
                list
                Divider()
                footer
            }
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            AccountChip()
            if store.changesRequestedCount > 0 {
                Pill("\(store.changesRequestedCount) needs work", .red)
            }
            if store.yourTurnCount > 0 {
                Pill("\(store.yourTurnCount) to review", .yellow)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless).help("Refresh now")
            }
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
        }
        .padding(10)
    }

    private var pasteBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "link").foregroundStyle(.secondary)
            TextField("Paste a PR link to watch it", text: $pasted)
                .textFieldStyle(.plain)
                .onSubmit(add)
            if !pasted.isEmpty {
                Button("Watch", action: add).controlSize(.small)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(badPaste ? Color.red.opacity(0.15) : Color.clear)
    }

    private func add() {
        badPaste = !store.addWatched(pasted)
        if !badPaste { pasted = "" }
    }

    private var list: some View {
        // A LazyVStack has no intrinsic height, so inside a MenuBarExtra window
        // the scroll view collapses to nothing and the rows never appear.
        // Plain VStack + an explicit height range keeps the list visible.
        ScrollView {
            VStack(spacing: 0) {
                if let err = store.errorText {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                if store.prs.isEmpty && store.errorText == nil {
                    Text(store.isRefreshing ? "Loading…" : "Nothing to watch right now.")
                        .foregroundStyle(.secondary)
                        .padding(24)
                }
                ForEach(store.repoGroups) { group in
                    RepoHeader(group: group)
                    if !store.isCollapsed(group.slug) {
                        ForEach(group.prs) { pr in
                            PRRow(pr: pr)
                            Divider()
                        }
                    }
                }
                if !store.ignoredPRs.isEmpty {
                    IgnoredSection()
                }
            }
        }
        .frame(minHeight: 140, idealHeight: 460, maxHeight: 520)
    }

    private var footer: some View {
        HStack {
            if let t = store.lastRefresh {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Not synced yet")
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

struct PRRow: View {
    @EnvironmentObject var store: Store
    let pr: PullRequest
    @State private var hovering = false

    private var tint: Color {
        if pr.isMerged { return .purple }
        if pr.isClosed { return .secondary }
        if pr.isOngoing { return .teal }
        switch pr.verdict {
        case .changesRequested: return .red      // your move
        case .pending: return .yellow            // waiting on a reviewer
        case .approved: return .green
        case .commented: return .blue
        case .none: return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: pr.isMerged ? "arrow.triangle.merge"
                            : pr.isOngoing ? "hammer.fill" : pr.verdict.symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(pr.title.isEmpty ? pr.slug : pr.title)
                    .lineLimit(2)
                    .font(.system(size: 12, weight: .medium))

                HStack(spacing: 5) {
                    // The repo lives in the section header, so only the number here.
                    Text("#\(pr.number)").foregroundStyle(.secondary)
                    if pr.isDraft { Tag("Draft", .secondary) }
                    if pr.isOngoing { Tag("working on it", .teal) }
                    if pr.myReviewRequested { Tag("your turn", .yellow) }
                    if pr.isIgnored { Tag("ignored", .secondary) }
                    ForEach(Array(pr.sources).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { s in
                        Tag(sourceLabel(s), .secondary)
                    }
                }
                .font(.system(size: 10))

                HStack(spacing: 6) {
                    Text(pr.isMerged ? "Merged"
                         : pr.isClosed ? "Closed"
                         : pr.isOngoing ? "In progress — \(pr.verdict.label.lowercased())"
                         : pr.verdict == .changesRequested
                            ? "Changes requested by \(pr.blockingReviewers.joined(separator: ", "))"
                         : pr.verdict.label)
                        .foregroundStyle(tint)
                    if pr.ci != .none {
                        Text("· \(pr.ci.label)")
                            .foregroundStyle(pr.ci == .failure ? .red : .secondary)
                    }
                }
                .font(.system(size: 11, weight: .medium))

                if !pr.reReviewRequested.isEmpty {
                    Label("Re-review requested from \(pr.reReviewRequested.joined(separator: ", "))",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if !pr.awaitingReview.isEmpty {
                    Text("Waiting on \(pr.awaitingReview.joined(separator: ", "))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if hovering {
                HStack(spacing: 4) {
                    Button { store.setOngoing(pr, !pr.isOngoing) } label: {
                        Image(systemName: pr.isOngoing ? "arrow.uturn.backward" : "hammer")
                    }
                    .help(pr.isOngoing
                          ? "Back to needing attention"
                          : "I'm working on these changes — stop counting it")

                    Button { store.setIgnored(pr, !pr.isIgnored) } label: {
                        Image(systemName: pr.isIgnored ? "bell" : "bell.slash")
                    }
                    .help(pr.isIgnored ? "Stop ignoring" : "Ignore this PR")

                    if pr.sources.contains(.watched) {
                        Button {
                            store.removeWatched(PRRef(owner: pr.owner, repo: pr.repo, number: pr.number))
                        } label: { Image(systemName: "xmark.circle") }
                            .help("Stop watching")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) }
        }
        .contextMenu {
            Button("Open on GitHub") {
                if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) }
            }
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.url, forType: .string)
            }
            Divider()
            Button(pr.isOngoing ? "Needs attention again" : "Mark as working on it") {
                store.setOngoing(pr, !pr.isOngoing)
            }
            Button(pr.isIgnored ? "Stop ignoring" : "Ignore this PR") {
                store.setIgnored(pr, !pr.isIgnored)
            }
            if pr.sources.contains(.watched) {
                Button("Stop watching") {
                    store.removeWatched(PRRef(owner: pr.owner, repo: pr.repo, number: pr.number))
                }
            }
        }
    }

    private func sourceLabel(_ s: Source) -> String {
        switch s {
        case .assigned: return "assigned"
        case .reviewRequest: return "your review"
        case .authored: return "yours"
        case .watched: return "watching"
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Binding var showSettings: Bool
    @State private var draft = ""
    @State private var ghToken: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub token").font(.headline)
            Text("Needs the `repo` scope. Stored in your login keychain. If `gh` is installed and logged in, GitWall picks its token up automatically.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("ghp_… / github_pat_…", text: $draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save") {
                    store.updateToken(draft)
                    draft = ""
                    showSettings = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Sign in with gh CLI") {
                    if let t = ghToken { store.updateToken(t); showSettings = false }
                }
                .disabled(ghToken == nil)
                .help(ghToken == nil ? "Run `gh auth login` first" : "Use the token gh is already signed in with")
                Spacer()
                if let a = store.account {
                    Text("Signed in as \(a.login)").font(.caption).foregroundStyle(.secondary)
                    Button("Sign out") { store.signOut() }
                        .buttonStyle(.borderless).font(.caption)
                }
            }

            Divider()

            notificationsSection

            Divider()

            Stepper("Check every \(store.pollSeconds)s",
                    value: $store.pollSeconds, in: 30...1800, step: 30)
            Toggle("Notify when CI starts failing", isOn: $store.notifyCI)
            Toggle("Include PRs I authored", isOn: $store.includeAuthored)

            HStack {
                Spacer()
                if !store.token.isEmpty {
                    Button("Done") { showSettings = false }
                }
                Button("Quit GitWall") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .task { ghToken = TokenStore.fromGHCLI() }
        .task { await store.refreshNotificationStatus() }
        .onChange(of: store.pollSeconds) { _, _ in Task { await store.start() } }
        .onChange(of: store.includeAuthored) { _, _ in Task { await store.refresh() } }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Notifications").font(.headline)
                Spacer()
                notificationStatusBadge
            }

            switch store.notificationStatus {
            case .denied:
                Text("Turned off in System Settings — GitWall can't alert you about changes requested, review requests, or CI.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open System Settings") { Notifier.openSystemSettings() }
                    .buttonStyle(.link)
            case .notDetermined:
                Text("macOS hasn't asked yet. Relaunch GitWall to trigger the permission prompt.")
                    .font(.caption).foregroundStyle(.secondary)
            default:
                Button("Send test notification") {
                    Notifier.post(title: "GitWall", body: "Notifications are working.", url: nil)
                }
                .buttonStyle(.link)
            }
        }
    }

    private var notificationStatusBadge: some View {
        let (label, color): (String, Color) = switch store.notificationStatus {
        case .authorized, .provisional: ("On", .green)
        case .denied: ("Off", .red)
        default: ("Unknown", .secondary)
        }
        return Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
    }
}


/// Who GitWall is signed in as. Click to open the GitHub profile.
struct AccountChip: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 6) {
            if let s = store.account?.avatarURL, let url = URL(string: s) {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(.quaternary)
                }
                .frame(width: 20, height: 20)
                .clipShape(Circle())
            } else {
                Image(systemName: "shield.lefthalf.filled")
                    .frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(store.account?.displayName ?? "GitWall")
                    .font(.system(size: 12, weight: .semibold))
                if let login = store.account?.login {
                    Text("@\(login)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let s = store.account?.profileURL, let u = URL(string: s) {
                NSWorkspace.shared.open(u)
            }
        }
        .help(store.account.map { "Open github.com/\($0.login)" } ?? "Not signed in")
    }
}

/// Section header for one repository. Click to collapse or expand it.
struct RepoHeader: View {
    @EnvironmentObject var store: Store
    let group: RepoGroup
    @State private var hovering = false

    private var collapsed: Bool { store.isCollapsed(group.slug) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))

            Text(group.owner).foregroundStyle(.secondary)
                + Text("/").foregroundStyle(.tertiary)
                + Text(group.repo).foregroundStyle(.primary)

            // Red counts changes you owe; yellow counts reviews you owe.
            // Never one badge for both — the colour has to mean something.
            if group.changesRequestedCount > 0 {
                CountBadge(group.changesRequestedCount, .red,
                           help: "Changes requested of you")
            }
            if group.yourTurnCount > 0 {
                CountBadge(group.yourTurnCount, .yellow,
                           help: "Waiting on your review")
            }

            Spacer()
            Text(collapsed ? "\(group.prs.count) hidden" : "\(group.prs.count)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.035))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.toggleCollapsed(group.slug) }
    }
}

/// Muted PRs, parked at the bottom and collapsed by default.
struct IgnoredSection: View {
    @EnvironmentObject var store: Store
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Image(systemName: "bell.slash.fill").font(.system(size: 9))
                Text("Ignored")
                Spacer()
                Text("\(store.ignoredPRs.count)").font(.system(size: 10))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035))
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }

            if expanded {
                ForEach(store.ignoredPRs) { pr in
                    PRRow(pr: pr).opacity(0.55)
                    Divider()
                }
            }
        }
    }
}



struct CountBadge: View {
    let count: Int
    let color: Color
    let help: String
    init(_ count: Int, _ color: Color, help: String) {
        self.count = count; self.color = color; self.help = help
    }
    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
            .help(help)
    }
}


struct Pill: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
    }
}
