# GitWall

A macOS menu-bar app that watches your GitHub pull requests and tells you when
someone requests changes, re-requests a review, or CI goes red.

## What it tracks

Automatically, for the logged-in user:
- PRs **assigned** to you
- PRs where **your review was requested**
- PRs you **authored** (toggleable)

Plus anything you paste in: a `https://github.com/owner/repo/pull/123` link,
`owner/repo#123`, or a `git@github.com:owner/repo.git#123` ref.

## Layout of the popover

PRs are grouped under their repository. Repos are ordered by the loudest PR
inside them, so whatever needs attention floats to the top, with a count badge
on the repo. **Click a repo header to collapse or expand it** — collapsed repos
are remembered across restarts. Click a PR row to open that PR on GitHub. The
header shows the signed-in account (avatar, name, `@login`).

### Per-PR actions

Hover a row (or right-click it) for:

- **Working on it** — you've pushed the fixes for a changes-requested review.
  The PR turns teal, drops out of the menu-bar count, and stops being treated as
  attention-needed. It flips back automatically the moment any reviewer submits
  something new, with a *New review activity* notification.
- **Ignore** — mutes a PR entirely: no count, no notifications, parked in a
  collapsed **Ignored** section at the bottom. Reversible from there.
- **Stop watching** (pasted PRs only), **Copy link**, **Open on GitHub**.

Both are stored locally in `~/Library/Application Support/GitWall/prefs.json`.

### What counts as "needs work"

Colour follows whose move it is:

- **Red — changes requested.** At least one reviewer asked for changes *and has
  not been re-requested*, so the feedback is still yours to deal with.
- **Yellow — awaiting review.** Reviewers are assigned but haven't ruled yet.
  This includes the case where you asked for changes, pushed a fix, and
  re-requested the reviewer: the ball is in their court, so it goes yellow, not
  red, even though GitHub still records the old CHANGES_REQUESTED review.
- Green approved, blue commented, teal working-on-it, grey everything else.

Repo headers carry up to two badges, and the colour always means the same
thing: a **red** count is changes you owe, a **yellow** count is reviews you
owe. Never one badge covering both.

The **menu-bar count is only the red ones**, minus anything ignored or marked as
being worked on — the number you'd actually have to act on.

## Notifications

Fired only on a *transition*, so nothing nags you every poll:

| Event | Notification |
|---|---|
| A reviewer switches to CHANGES_REQUESTED and hasn't been re-requested | **Changes requested — repo#123** (names the reviewer) |
| Your own review gets requested | **Your review requested — repo#123** |
| PR reaches approved | **Approved** |
| CI flips to failing | **Checks failing** (toggleable) |
| PR is merged or closed | **Merged** / **Closed** |

A PR is never announced the first time GitWall sees it — only when its state
actually changes underneath you. Clicking a notification opens the PR.

## Installation

There's no signed release yet, so GitWall is installed by building the Swift
package locally — it only takes a couple of minutes.

### Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 16+, or just the Swift 6 command line tools (`xcode-select --install`
  is enough — check with `swift --version`, needs to report 6.0+)

### Build and install

```bash
git clone https://github.com/Vahsir7/GitWall.git
cd GitWall
chmod +x build.sh
./build.sh --install
```

This builds a universal (arm64 + x86_64) `GitWall.app` into `dist/` — falling
back to a native-only build if the universal one isn't available — ad-hoc
signs it, and copies it to `/Applications`. Drop `--install` to just build
without installing.

Launch GitWall from `/Applications` (or Spotlight). It appears in the menu
bar with no Dock icon and no window to close.

### Start it at login

System Settings → General → Login Items → add GitWall.

### Updating

Pull the latest changes and rebuild — `--install` overwrites the existing
`/Applications/GitWall.app`:

```bash
git pull
./build.sh --install
```

### Uninstalling

```bash
rm -rf /Applications/GitWall.app
rm -rf ~/Library/Application\ Support/GitWall   # also clears saved prefs
```

## Authentication

If the `gh` CLI is installed and logged in, GitWall picks up its token on first
launch with no setup. Otherwise open the gear icon and paste a personal access
token with the `repo` scope, or hit **Sign in with gh CLI**. A token with the `repo` scope (classic) or Pull requests: Read + Contents: Read
(fine-grained). Tokens are stored in the login keychain, never on disk.

## Layout

| File | Role |
|---|---|
| `Sources/GitWall/App.swift` | `MenuBarExtra` entry point |
| `Sources/GitWall/Store.swift` | Polling loop, transition detection, watched list |
| `Sources/GitWall/GitHub.swift` | REST client; derives verdict, re-review, CI |
| `Sources/GitWall/Models.swift` | `PullRequest`, `PRRef` link parsing |
| `Sources/GitWall/Views.swift` | Popover UI |
| `Sources/GitWall/TokenStore.swift` | Keychain + `gh auth token` fallback |

## Notes

- Poll interval defaults to 120s (30s–30min in settings). Each poll costs
  3 search calls plus ~3 calls per PR, well inside GitHub's limits.
- The verdict follows GitHub's own rule: only the latest APPROVED /
  CHANGES_REQUESTED per reviewer counts; a later plain comment doesn't clear it.
- The build is ad-hoc signed. It's a local tool, so macOS won't complain, but
  it isn't notarized for distribution to other machines.
