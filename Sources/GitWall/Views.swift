import SwiftUI
import AppKit
import UserNotifications

extension View {
    /// macOS 26 shades the edges of a scroll view; inside the popover's own boxes
    /// that reads as a stray shadow, so turn it off where we draw the chrome.
    @ViewBuilder
    func noScrollEdgeShadow() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

/// Appearance options from Settings.
enum Theme {
    static let accents: [(String, String, Color?)] = [
        ("system", "System", nil),
        ("blue", "Blue", .blue),
        ("purple", "Purple", .purple),
        ("pink", "Pink", .pink),
        ("red", "Red", .red),
        ("orange", "Orange", .orange),
        ("green", "Green", .green),
        ("teal", "Teal", .teal),
        ("indigo", "Indigo", .indigo),
    ]
    static func accent(_ raw: String) -> Color {
        accents.first { $0.0 == raw }?.2 ?? .accentColor
    }
}

/// Rounded highlight behind a small control while the pointer is over it.
struct HoverHighlight: ViewModifier {
    var padding: CGFloat = 4
    @State private var hovering = false

    /// How many highlighted controls the pointer is over right now. A row
    /// ignores clicks while this is non-zero, so clicking a control — even on
    /// the edge of its highlight — never also opens the PR.
    @MainActor static var active = 0

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.12 : 0))
                    // Swallow clicks on the highlight's padding the control itself doesn't take.
                    .contentShape(Rectangle())
                    .onTapGesture {}
            )
            .contentShape(Rectangle())
            .onHover { h in
                guard h != hovering else { return }
                hovering = h
                Self.active += h ? 1 : -1
            }
            .onDisappear {
                if hovering { Self.active -= 1; hovering = false }
            }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

extension View {
    func hoverHighlight(padding: CGFloat = 4) -> some View { modifier(HoverHighlight(padding: padding)) }
}

/// Hands back the NSWindow hosting a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}

/// Behind-window blur for the glass theme.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Shared chrome for text inputs. The stock `.roundedBorder` style draws an AppKit
/// bezel with a drop shadow that looks wrong inside a menu-bar popover.
struct FieldBox<Content: View>: View {
    var focused = false
    var invalid = false
    @ViewBuilder var content: Content

    private var border: Color {
        if invalid { return .red.opacity(0.8) }
        return focused ? .accentColor.opacity(0.9) : .primary.opacity(0.14)
    }

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 1))
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @AppStorage("section") private var sectionRaw = ListSection.inbox.rawValue
    @AppStorage("compactRows") private var compactRows = false
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("theme") private var theme = "standard"
    @AppStorage("accent") private var accent = "system"
    @State private var appeared = false
    @State private var window: NSWindow?

    private var section: ListSection {
        get { ListSection(rawValue: sectionRaw) ?? .inbox }
        nonmutating set { sectionRaw = newValue.rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: Binding(get: { section }, set: { section = $0 }),
                    collapsed: sidebarCollapsed)
                .frame(width: sidebarCollapsed ? 54 : 168)
            Divider()
            VStack(spacing: 0) {
                if store.token.isEmpty || section == .settings {
                    SectionHeader(title: "Settings", symbol: "gearshape")
                    Divider()
                    SettingsView(showSettings: Binding(
                        get: { true }, set: { if !$0 { section = .inbox } }))
                } else if section == .report {
                    SectionHeader(title: "Work report", symbol: "doc.text")
                    Divider()
                    WorkReportView(isShown: Binding(
                        get: { true }, set: { if !$0 { section = .inbox } }))
                    Spacer(minLength: 0)
                } else {
                    listHeader
                    Divider()
                    PRList(section: section)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .background {
            if theme == "glass" {
                ZStack {
                    GlassBackground()
                    Theme.accent(accent).opacity(0.06)
                }
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .tint(Theme.accent(accent))
        .environment(\.themeAccent, Theme.accent(accent))
        .environment(\.glassTheme, theme == "glass")
        // Opening animation: a quick spring in, replayed each time the popover opens.
        .scaleEffect(appeared ? 1 : 0.94, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .blur(radius: appeared ? 0 : 6)
        .background(WindowAccessor { w in if window !== w { window = w } })
        // Only the popover's own window showing/hiding drives the animation —
        // menus and popovers opened from a row are other windows and must not
        // blur this one out.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let w = note.object as? NSWindow, w === window else { return }
            let visible = w.occlusionState.contains(.visible)
            store.panelVisible = visible
            if visible { playOpen() } else { appeared = false }
        }
        .onAppear { playOpen() }
        .onChange(of: sidebarCollapsed) { _, _ in resizeWindow() }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: sidebarCollapsed)
    }

    private var contentSize: CGSize { CGSize(width: sidebarCollapsed ? 526 : 640, height: 560) }

    /// MenuBarExtra windows don't shrink on their own when the content does,
    /// leaving a dead, shadowed strip. Resize the window, keeping it centred
    /// under the menu-bar icon and pinned at the top.
    private func resizeWindow() {
        guard let window else { return }
        let old = window.frame
        let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
        let frame = CGRect(x: old.midX - size.width / 2, y: old.maxY - size.height,
                           width: size.width, height: size.height)
        window.setFrame(frame, display: true, animate: true)
        window.invalidateShadow()
    }

    private func playOpen() {
        guard !appeared else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { appeared = true }
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            IconButton("sidebar.left", help: sidebarCollapsed ? "Show sidebar" : "Collapse sidebar") {
                sidebarCollapsed.toggle()
            }
            .padding(.leading, 10)
            SectionHeader(title: section.title, symbol: section.symbol,
                          subtitle: store.lastRefresh.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" }
                              ?? "Not synced yet")
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                IconButton("arrow.clockwise", help: "Refresh now") { Task { await store.refresh() } }
            }
            IconButton(compactRows ? "list.bullet.below.rectangle" : "list.bullet",
                       help: compactRows ? "Expanded rows" : "Compact rows") { compactRows.toggle() }
        }
        .padding(.trailing, 12)
    }
}

private struct ThemeAccentKey: EnvironmentKey { static let defaultValue: Color = .accentColor }
private struct GlassThemeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var themeAccent: Color {
        get { self[ThemeAccentKey.self] } set { self[ThemeAccentKey.self] = newValue }
    }
    var glassTheme: Bool {
        get { self[GlassThemeKey.self] } set { self[GlassThemeKey.self] = newValue }
    }
}

/// Title row at the top of the content pane.
struct SectionHeader: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }
}

/// Borderless toolbar icon with a hover highlight.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Source-list style sidebar: account, sections with counts, utilities.
/// Collapses to an icon rail; hover an icon for its name.
struct Sidebar: View {
    @EnvironmentObject var store: Store
    @Environment(\.themeAccent) private var accent
    @Environment(\.glassTheme) private var glass
    @Binding var selection: ListSection
    var collapsed: Bool
    @State private var pasted = ""
    @State private var badPaste = false
    @State private var showPaste = false
    @FocusState private var pasteFocused: Bool

    var body: some View {
        VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
            AccountChip(compact: collapsed)
                .padding(.horizontal, collapsed ? 0 : 10)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if collapsed {
                railButton("plus", help: "Watch a PR link", active: false) { showPaste.toggle() }
                    .popover(isPresented: $showPaste, arrowEdge: .trailing) {
                        pasteField.frame(width: 260).padding(10)
                    }
                    .padding(.bottom, 6)
            } else {
                pasteField
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                sectionLabel("Pull requests")
            }

            ForEach(ListSection.lists) { s in
                let count = store.prs(in: s).count
                if count > 0 || [.inbox, .needsYou].contains(s) || selection == s {
                    item(s, count: count)
                }
            }

            Spacer(minLength: 0)

            if !collapsed { sectionLabel("GitWall") }
            item(.report, count: nil)
            item(.settings, count: nil)
            if collapsed {
                railButton("power", help: "Quit GitWall", active: false) { NSApplication.shared.terminate(nil) }
                    .padding(.bottom, 10)
            } else {
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("Quit", systemImage: "power")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(glass ? 0.02 : 0.035))
    }

    private var pasteField: some View {
        FieldBox(focused: pasteFocused, invalid: badPaste) {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Watch PR link", text: $pasted)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($pasteFocused)
                    .onSubmit(add)
                    .onChange(of: pasted) { _, _ in badPaste = false }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 6).padding(.bottom, 2)
    }

    private func railButton(_ symbol: String, help: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 34, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? accent : .clear))
                .foregroundStyle(active ? Color.white : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func item(_ s: ListSection, count: Int?) -> some View {
        let selected = selection == s
        let urgent = s == .needsYou && (count ?? 0) > 0
        if collapsed {
            railButton(s.symbol, help: s.title + (count.map { $0 > 0 ? " (\($0))" : "" } ?? ""),
                       active: selected) { selection = s }
                .overlay(alignment: .topTrailing) {
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .padding(.horizontal, 3).padding(.vertical, 0.5)
                            .background(Capsule().fill(urgent ? Color.red : Color.secondary.opacity(0.8)))
                            .foregroundStyle(.white)
                            .offset(x: 2, y: -2)
                    }
                }
        } else {
            Button { selection = s } label: {
                HStack(spacing: 8) {
                    Image(systemName: s.symbol)
                        .font(.system(size: 12))
                        .frame(width: 16)
                        .foregroundStyle(selected ? Color.white : urgent ? .red : .secondary)
                    Text(s.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(selected ? Color.white.opacity(0.25)
                                                       : urgent ? Color.red.opacity(0.18) : Color.primary.opacity(0.08)))
                            .foregroundStyle(selected ? Color.white : urgent ? .red : .secondary)
                    }
                }
                .foregroundStyle(selected ? Color.white : .primary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? accent : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
        }
    }

    private func add() {
        badPaste = !store.addWatched(pasted)
        if !badPaste { pasted = ""; showPaste = false; selection = .watching }
    }
}

/// The PRs of one section, grouped by repository.
struct PRList: View {
    @EnvironmentObject var store: Store
    let section: ListSection

    var body: some View {
        // A LazyVStack has no intrinsic height inside a MenuBarExtra window, so
        // use a plain VStack.
        ScrollView {
            VStack(spacing: 6) {
                if let err = store.errorText {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                }
                let groups = store.groups(for: section)
                if groups.isEmpty && store.errorText == nil {
                    VStack(spacing: 8) {
                        Image(systemName: store.isRefreshing ? "hourglass" : "checkmark.circle")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(store.isRefreshing ? "Loading…" : "Nothing here")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                }
                if section == .inbox && !store.pinnedPRs.isEmpty {
                    PinnedSection()
                }
                ForEach(section == .inbox ? store.repoGroups : groups) { group in
                    VStack(spacing: 4) {
                        RepoHeader(group: group)
                        if !store.isCollapsed(group.slug) {
                            ForEach(group.prs) { pr in
                                PRRow(pr: pr).opacity(pr.isIgnored && section != .ignored ? 0.55 : 1)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
        .noScrollEdgeShadow()
    }
}

struct PRRow: View {
    @EnvironmentObject var store: Store
    let pr: PullRequest
    @State private var hovering = false
    @State private var showComments = false
    @AppStorage("compactRows") private var compactSetting = false
    @Environment(\.glassTheme) private var glass
    /// Opened just this one row while the list is compact.
    @State private var expandedHere = false
    private var compact: Bool { compactSetting && !expandedHere }
    /// Room kept clear on the right for the always-visible comment badge and chevron.
    private var hoverActionsInset: CGFloat {
        10 + (compactSetting ? 26 : 0) + (pr.unresolvedThreads > 0 ? 56 : 0)
    }

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
                .padding(.top, compact ? 0 : 2)

            if compact {
                // Minimal: lifecycle icon, number, title, review status.
                HStack(spacing: 5) {
                    Image(systemName: pr.state.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StateBadge.color(pr.state))
                        .help(pr.state.label)
                    Text("#\(pr.number)").foregroundStyle(.secondary)
                    Text(pr.title.isEmpty ? pr.slug : pr.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 12, weight: .medium))
                .help("\(pr.title)\n\(pr.state.label) · \(pr.verdict.label)")
            } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(pr.title.isEmpty ? pr.slug : pr.title)
                    .lineLimit(2)
                    .font(.system(size: 13, weight: .semibold))

                // Wraps onto new lines instead of squeezing badges when space is tight.
                FlowLayout(spacing: 5) {
                    // The repo lives in the section header, so only the number here.
                    StateBadge(state: pr.state)
                    Text("#\(pr.number)" + (pr.author.isEmpty ? "" : " by \(pr.author)")).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    if pr.isPinned { Tag("pinned", .orange) }
                    if pr.isOngoing { Tag("working on it", .teal) }
                    if let mine = pr.myReview(login: store.account?.login) {
                        Tag(mine.label + (pr.myReviewRequested && !pr.myTeamRequests.isEmpty
                                ? " via \(pr.myTeamRequests.joined(separator: ", "))" : ""),
                            myReviewColor(mine), symbol: mine.symbol)
                    }
                    if pr.isIgnored { Tag("ignored", .secondary) }
                    if pr.isMenuBarMuted { Tag("not in menu bar", .secondary, symbol: "menubar.rectangle") }
                    if store.updatingBranch.contains(pr.id) {
                        Tag("updating branch…", .blue, symbol: "arrow.triangle.2.circlepath")
                    } else if store.isWatchingCI(pr) {
                        Tag("watching checks", .blue, symbol: "bell.badge")
                    } else if pr.isBehind && !pr.hasConflicts && !pr.isMerged && !pr.isClosed {
                        Button { Task { await store.updateBranch(pr) } } label: {
                            Tag("behind · update branch", .blue, symbol: "arrow.triangle.merge")
                        }
                        .buttonStyle(.plain)
                        .help("Merge the base branch into this PR, then notify when checks finish")
                    }
                    // Review sources are covered by the your-review tag above.
                    ForEach(Array(pr.sources.subtracting([.reviewRequest, .reviewed]))
                                .sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { s in
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

                if !pr.reviewers.isEmpty {
                    ReviewerStrip(reviewers: pr.reviewers.filter { !$0.isBot },
                                  me: store.account?.login)
                }

                ForEach(pr.botFindings) { f in
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                        Text(f.displayName).foregroundStyle(.secondary)
                        if f.counts.isEmpty {
                            Tag("no findings", .green)
                        }
                        ForEach(f.counts, id: \.severity) { c in
                            Tag("\(c.severity) · \(c.n)", SeverityColor.forRank(c.rank))
                        }
                    }
                    .font(.system(size: 10))
                }

                if !pr.botReviews.isEmpty {
                    Label(pr.botReviews.map { "\($0.login): \($0.verdict.label)" }.joined(separator: ", "),
                          systemImage: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            }

            Spacer(minLength: 0)

            if pr.unresolvedThreads > 0 {
                Button { showComments.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                        Text("\(pr.unresolvedThreads)").monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .hoverHighlight(padding: 0)
                .help("\(pr.unresolvedThreads) unresolved comment threads")
                .popover(isPresented: $showComments, arrowEdge: .trailing) {
                    UnresolvedComments(pr: pr) {
                        showComments = false
                        Task { await store.resolveAllComments(pr) }
                    }
                }
            }


            // Pinned to the far right so it never shifts when hover actions appear.
            if compactSetting {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedHere.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(expandedHere ? 180 : 0))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .hoverHighlight()
                .help(expandedHere ? "Collapse" : "Show details")
            }

        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, compact ? 6 : 10)
        // Hover actions float over the row instead of taking layout space, so
        // the content doesn't reflow (and grow taller) when the pointer enters.
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 2) {
                    Menu {
                        Button("Copy link") { Store.copyToPasteboard(pr.url) }
                        promptButtons
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .hoverHighlight()
                    .help("Copy the link or a saved prompt")

                    if pr.isBehind && !pr.hasConflicts && !pr.isMerged && !pr.isClosed {
                        Button { Task { await store.updateBranch(pr) } } label: {
                            Image(systemName: "arrow.triangle.merge")
                        }
                        .disabled(store.updatingBranch.contains(pr.id))
                        .hoverHighlight()
                        .help("Update branch from base")
                    }

                    Button { store.setPinned(pr, !pr.isPinned) } label: {
                        Image(systemName: pr.isPinned ? "pin.slash" : "pin")
                    }
                    .hoverHighlight()
                    .help(pr.isPinned ? "Unpin" : "Pin to the top")

                    Menu {
                        ignoreButtons
                    } label: {
                        Image(systemName: pr.isIgnored || pr.isMenuBarMuted ? "bell" : "bell.slash")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .hoverHighlight()
                    .help("Ignore options")

                    if pr.sources.contains(.watched) {
                        Button {
                            store.removeWatched(PRRef(owner: pr.owner, repo: pr.repo, number: pr.number))
                        } label: { Image(systemName: "xmark.circle") }
                            .hoverHighlight()
                            .help("Stop watching")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(
                    Capsule().fill(.regularMaterial)
                        // Gaps between the buttons shouldn't open the PR either.
                        .contentShape(Capsule())
                        .onTapGesture {}
                )
                .padding(.top, compact ? 4 : 8)
                .padding(.trailing, hoverActionsInset)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(glass ? AnyShapeStyle(Color.primary.opacity(hovering ? 0.09 : 0.05))
                            : AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1 : 0.7)))
                .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 4 : 1, y: 1)
        )
        .overlay(alignment: .leading) {
            // Status accent stripe.
            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.85))
                .frame(width: 3).padding(.vertical, 8)
        }
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Color.primary.opacity(hovering ? 0.12 : 0.06)))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { hovering = h } }
        .onTapGesture {
            // Only a real click inside the focused panel opens the PR — not a
            // stray mouse-up from a window resize or a click meant for another window.
            guard HoverHighlight.active == 0,
                  let e = NSApp.currentEvent, e.type == .leftMouseUp,
                  e.window?.isKeyWindow == true, e.window?.inLiveResize == false,
                  let u = URL(string: pr.url) else { return }
            NSWorkspace.shared.open(u)
        }
        .contextMenu {
            Button("Open on GitHub") {
                if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) }
            }
            Button("Copy link") { Store.copyToPasteboard(pr.url) }
            if !store.copyPrompts.isEmpty {
                Menu("Copy prompt") { promptButtons }
            }
            Divider()
            Button(pr.isOngoing ? "Needs attention again" : "Mark as working on it") {
                store.setOngoing(pr, !pr.isOngoing)
            }
            Button(pr.isPinned ? "Unpin" : "Pin to the top") {
                store.setPinned(pr, !pr.isPinned)
            }
            if pr.isBehind && !pr.hasConflicts && !pr.isMerged && !pr.isClosed {
                Button("Update branch") {
                    Task { await store.updateBranch(pr) }
                }
            }
            if pr.unresolvedThreads > 0 {
                Button("Resolve all comments (\(pr.unresolvedThreads))") { Task { await store.resolveAllComments(pr) } }
            }
            ignoreButtons
            if pr.sources.contains(.watched) {
                Button("Stop watching") {
                    store.removeWatched(PRRef(owner: pr.owner, repo: pr.repo, number: pr.number))
                }
            }
        }
    }

    @ViewBuilder
    private var ignoreButtons: some View {
        Button(pr.isIgnored ? "Stop ignoring" : "Ignore PR completely") {
            store.setIgnored(pr, !pr.isIgnored)
        }
        Button(pr.isMenuBarMuted ? "Count in menu bar again" : "Ignore in menu bar") {
            store.setMenuBarMuted(pr, !pr.isMenuBarMuted)
        }
    }

    private func myReviewColor(_ m: MyReview) -> Color {
        switch m {
        case .yourTurn, .reRequested: return .yellow
        case .changesRequested: return .red
        case .approved: return .green
        case .commented: return .blue
        }
    }

    /// Prompts that fit this PR's situation first, the rest under "Other prompts".
    @ViewBuilder
    private var promptButtons: some View {
        let suggested = store.copyPrompts.filter { $0.when != .always && $0.when.matches(pr) }
        let rest = store.copyPrompts.filter { !suggested.contains($0) }
        if !suggested.isEmpty {
            Divider()
            ForEach(suggested) { prompt in promptButton(prompt) }
        }
        if !rest.isEmpty {
            Divider()
            if suggested.isEmpty {
                ForEach(rest) { prompt in promptButton(prompt) }
            } else {
                Menu("Other prompts") {
                    ForEach(rest) { prompt in promptButton(prompt) }
                }
            }
        }
    }

    private func promptButton(_ prompt: CopyPrompt) -> some View {
        Button(prompt.name.isEmpty ? "Untitled prompt" : prompt.name) {
            Store.copyToPasteboard(prompt.render(for: pr))
        }
    }

    private func sourceLabel(_ s: Source) -> String {
        switch s {
        case .assigned: return "assigned"
        case .reviewRequest: return "your review"
        case .authored: return "yours"
        case .watched: return "watching"
        case .reviewed: return "reviewed"
        }
    }
}

/// GitHub-style lifecycle badge: open, draft, conflicts, merged, closed.
struct StateBadge: View {
    let state: PRState

    private var color: Color { Self.color(state) }

    static func color(_ state: PRState) -> Color {
        switch state {
        case .open: return .green
        case .draft: return .secondary
        case .conflict: return .orange
        case .merged: return .purple
        case .closed: return .red
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: state.symbol).font(.system(size: 9, weight: .semibold))
            Text(state.label)
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .fixedSize()
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
        .help(state == .conflict ? "This branch has conflicts with the base branch" : state.label)
    }
}

/// Every reviewer with their current verdict, so you can see where the PR
/// stands even after your own review is in.
struct ReviewerStrip: View {
    let reviewers: [Reviewer]
    let me: String?

    var body: some View {
        if !reviewers.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowRow(reviewers) { r in chip(r) }
            }
            .font(.system(size: 10))
        }
    }

    private var summary: String {
        let count = { (v: ReviewVerdict) in reviewers.filter { $0.verdict == v }.count }
        var parts: [String] = []
        if count(.approved) > 0 { parts.append("\(count(.approved)) approved") }
        if count(.changesRequested) > 0 { parts.append("\(count(.changesRequested)) changes requested") }
        if count(.commented) > 0 { parts.append("\(count(.commented)) commented") }
        if count(.pending) > 0 { parts.append("\(count(.pending)) pending") }
        let noun = reviewers.count == 1 ? "reviewer" : "reviewers"
        return "\(reviewers.count) \(noun) · " + parts.joined(separator: ", ")
    }

    private func chip(_ r: Reviewer) -> some View {
        let isMe = me.map { r.login.caseInsensitiveCompare($0) == .orderedSame } ?? false
        let color: Color = switch r.verdict {
        case .approved: .green
        case .changesRequested: .red
        case .commented: .blue
        case .pending, .none: .yellow
        }
        let symbol = r.reRequested ? "arrow.triangle.2.circlepath"
            : r.isTeam ? "person.2.fill" : r.verdict.symbol
        return HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 8))
            Text(isMe ? "you" : r.login).fontWeight(isMe ? .bold : .regular)
        }
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(color.opacity(0.13), in: Capsule())
        .foregroundStyle(color)
        .help("\(r.login): \(r.verdict.label)\(r.reRequested ? " — re-review requested" : "")")
    }
}

/// Minimal wrapping row for chips.
struct FlowRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items; self.content = content
    }
    var body: some View {
        FlowLayout(spacing: 3) {
            ForEach(items) { content($0) }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

enum SeverityColor {
    /// Most severe first: red, orange, yellow, blue, then grey.
    static func forRank(_ rank: Int) -> Color {
        [Color.red, .orange, .yellow, .blue][safe: rank] ?? .secondary
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Settings editor for review-summary rules, with a live test box.
struct ReviewRulesSection: View {
    @EnvironmentObject var store: Store
    @State private var sample = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Review summaries").font(.headline)
                Spacer()
                Button {
                    store.reviewRules.append(ReviewRule(name: "New rule", authors: ""))
                } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
            Text("Show severity counts from a review bot or person. GitWall finds a table whose header names your labels (e.g. Total | P0 | P1 | P2) and shows the non-zero counts on the PR.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(store.reviewRules) { rule in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Toggle("", isOn: binding(rule.id).enabled).labelsHidden().toggleStyle(.switch)
                            .controlSize(.mini)
                        FieldBox {
                            TextField("Name shown (blank = author's login)", text: binding(rule.id).name)
                                .textFieldStyle(.plain)
                        }
                        Button {
                            store.reviewRules.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete this rule")
                    }
                    labeled("Authors") {
                        TextField("*[bot], alice", text: binding(rule.id).authors).textFieldStyle(.plain)
                    }
                    labeled("Contains") {
                        TextField("optional, e.g. Findings Summary", text: binding(rule.id).marker).textFieldStyle(.plain)
                    }
                    labeled("Labels") {
                        TextField("P0, P1, P2, P3, nit", text: binding(rule.id).labels).textFieldStyle(.plain)
                    }
                    Picker("Read from", selection: binding(rule.id).whereFrom) {
                        ForEach(ReviewRule.Where.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }

            Text("Test a rule").font(.subheadline.weight(.semibold)).padding(.top, 4)
            FieldBox {
                TextEditor(text: $sample)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .noScrollEdgeShadow()
                    .frame(minHeight: 54, maxHeight: 100)
            }
            if !sample.isEmpty {
                ForEach(store.reviewRules.filter(\.enabled)) { rule in
                    HStack(spacing: 4) {
                        Text(rule.name.isEmpty ? "Rule" : rule.name).font(.caption.weight(.semibold))
                        if let f = BotFindings.parse(sample, login: rule.name, labels: rule.labelList) {
                            if f.counts.isEmpty { Tag("no findings", .green) }
                            ForEach(f.counts, id: \.severity) { c in
                                Tag("\(c.severity) · \(c.n)", SeverityColor.forRank(c.rank))
                            }
                        } else {
                            Text("no table found").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 10))
                }
            } else {
                Text("Paste a sample review or comment to preview what each rule reads.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ field: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            FieldBox { field() }
        }
    }

    private func binding(_ id: UUID) -> Binding<ReviewRule> {
        Binding(
            get: { store.reviewRules.first { $0.id == id } ?? ReviewRule() },
            set: { updated in
                if let i = store.reviewRules.firstIndex(where: { $0.id == id }) {
                    store.reviewRules[i] = updated
                }
            })
    }
}

/// Popover listing a PR's unresolved review threads; each opens on GitHub.
struct UnresolvedComments: View {
    let pr: PullRequest
    let resolveAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Unresolved comments").font(.headline)
                Spacer()
                Text("\(pr.unresolvedThreads)").foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(pr.unresolved) { t in ThreadRow(thread: t) }
                }
                .padding(8)
            }
            .noScrollEdgeShadow()
            .frame(maxHeight: 340)
            Divider()
            HStack {
                Button("Open PR") {
                    if let u = URL(string: pr.url + "/files") { NSWorkspace.shared.open(u) }
                }
                Spacer()
                Button("Resolve all", action: resolveAll)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(10)
        }
        .frame(width: 360)
    }
}

struct ThreadRow: View {
    let thread: ReviewThread
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                Text(thread.author).fontWeight(.semibold)
                Spacer()
                if let path = thread.path {
                    Text(URL(fileURLWithPath: path).lastPathComponent + (thread.line.map { ":\($0)" } ?? ""))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(path)
                }
            }
            .font(.system(size: 11))
            Text(thread.body.isEmpty ? "(no text)" : thread.body)
                .font(.system(size: 11))
                .lineLimit(3)
                .foregroundStyle(.primary.opacity(0.85))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(hovering ? Color.primary.opacity(0.09) : Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let u = URL(string: thread.url) { NSWorkspace.shared.open(u) }
        }
        .help("Open this comment on GitHub")
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var symbol: String? = nil
    init(_ text: String, _ color: Color, symbol: String? = nil) {
        self.text = text; self.color = color; self.symbol = symbol
    }
    var body: some View {
        HStack(spacing: 2) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8)) }
            Text(text)
        }
            .padding(.horizontal, 5).padding(.vertical, 1)
            .lineLimit(1)
            .fixedSize()
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Binding var showSettings: Bool
    @State private var draft = ""
    @State private var ghToken: String?
    @AppStorage("compactRows") private var compactRows = false
    @AppStorage("theme") private var theme = "standard"
    @AppStorage("accent") private var accent = "system"

    var body: some View {
        // Settings outgrew the popover; same explicit height range as the PR list.
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub token").font(.headline)
            Text("Needs the `repo` scope. Stored in your login keychain. If `gh` is installed and logged in, GitWall picks its token up automatically.")
                .font(.caption).foregroundStyle(.secondary)
            FieldBox {
                SecureField("ghp_… / github_pat_…", text: $draft)
                    .textFieldStyle(.plain)
            }
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

            promptsSection

            Divider()

            ReviewRulesSection()

            Divider()

            Stepper("Check every \(store.pollSeconds)s",
                    value: $store.pollSeconds, in: 30...1800, step: 30)
            Toggle("Notify when CI starts failing", isOn: $store.notifyCI)
            Toggle("Include PRs I authored", isOn: $store.includeAuthored)
            Picker("Theme", selection: $theme) {
                Text("Standard").tag("standard")
                Text("Liquid glass").tag("glass")
            }
            .pickerStyle(.segmented)
            HStack(spacing: 8) {
                Text("Accent")
                ForEach(Theme.accents, id: \.0) { key, name, color in
                    Button { accent = key } label: {
                        Circle()
                            .fill(color.map { AnyShapeStyle($0) }
                                  ?? AnyShapeStyle(LinearGradient(colors: [.blue, .purple, .pink],
                                                                  startPoint: .topLeading, endPoint: .bottomTrailing)))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(accent == key ? 0.9 : 0), lineWidth: 2)
                                .padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            Picker("View", selection: $compactRows) {
                Text("Expanded").tag(false)
                Text("Compact").tag(true)
            }
            .pickerStyle(.segmented)
            Stepper(store.finishedRetentionMinutes == 0
                        ? "Remove merged/closed PRs right away"
                        : "Keep merged/closed PRs for \(store.finishedRetentionMinutes) min",
                    value: $store.finishedRetentionMinutes, in: 0...1440, step: 5)

            HStack {
                Spacer()
                if !store.token.isEmpty {
                    Button("Done") { showSettings = false }
                }
                Button("Quit GitWall") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        }
        .noScrollEdgeShadow()
        .frame(minHeight: 260, idealHeight: 520, maxHeight: 520)
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

    private var promptsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Copy prompts").font(.headline)
                Spacer()
                Button {
                    store.copyPrompts.append(CopyPrompt(name: "New prompt", template: "{{pr-link}}"))
                } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
            Text(verbatim: "Offered by the copy button on each PR. Placeholders: \(CopyPrompt.placeholderHelp)")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(store.copyPrompts) { prompt in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        FieldBox {
                            TextField("Name", text: promptBinding(prompt.id).name)
                                .textFieldStyle(.plain)
                        }
                        Button {
                            store.copyPrompts.removeAll { $0.id == prompt.id }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete this prompt")
                    }
                    Picker("Suggested on", selection: promptBinding(prompt.id).when) {
                        ForEach(PromptContext.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    FieldBox {
                        TextEditor(text: promptBinding(prompt.id).template)
                            .font(.system(size: 11, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .noScrollEdgeShadow()
                            .frame(minHeight: 64, maxHeight: 120)
                    }
                }
            }
        }
    }

    /// Looks the prompt up by id on every access, so deleting one mid-edit can't index out of range.
    private func promptBinding(_ id: UUID) -> Binding<CopyPrompt> {
        Binding(
            get: { store.copyPrompts.first { $0.id == id } ?? CopyPrompt(name: "", template: "") },
            set: { updated in
                if let i = store.copyPrompts.firstIndex(where: { $0.id == id }) {
                    store.copyPrompts[i] = updated
                }
            }
        )
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
    /// Avatar only, for the collapsed sidebar.
    var compact = false

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

            if !compact {
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
        .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.toggleCollapsed(group.slug) }
    }
}

/// Hand-pinned PRs, always shown expanded at the top of the list.
struct PinnedSection: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill").font(.system(size: 9))
                Text("Pinned")
                Spacer()
                Text("\(store.pinnedPRs.count)").font(.system(size: 10))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))

            ForEach(store.pinnedPRs) { pr in
                PRRow(pr: pr)
                Divider()
            }
        }
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


/// Everything you worked on since the last report, grouped by repository.
struct WorkReportView: View {
    @EnvironmentObject var store: Store
    @Binding var isShown: Bool
    @State private var text = ""
    @State private var html = ""
    @State private var since: Date?
    @State private var until: Date?
    @State private var loading = true
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Work report").font(.headline)
                Spacer()
                if let since {
                    Text("since \(since.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            } else {
                FieldBox {
                    ScrollView {
                        Text(verbatim: text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .noScrollEdgeShadow()
                    .frame(minHeight: 120, idealHeight: 260, maxHeight: 340)
                }
            }

            HStack {
                Button("Back") { isShown = false }
                Spacer()
                Button(copied ? "Copied ✓" : "Copy") {
                    Store.copyToPasteboard(text, html: html)
                    copied = true
                }
                .disabled(loading || error != nil)
                Button("Retain") { isShown = false }
                    .help("Keep this window; the next report covers this period again, plus anything new")
                Button("Reset") {
                    if let until { store.resetWorkReportWindow(until: until) }
                    isShown = false
                }
                .keyboardShortcut(.defaultAction)
                .help("Start the next report from now")
                .disabled(loading || error != nil)
            }
            Text(verbatim: "Copies as rich text for Slack and as markdown for editors. Retain keeps the start time for the next report; Reset starts the next one from now.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        copied = false
        do {
            let report = try await store.buildWorkReport()
            text = report.text
            html = report.html
            since = report.since
            until = report.until
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
