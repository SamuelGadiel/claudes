# Spec: Status bar app (macOS)

Resolves: P6, P7, P8, P9, P10

## Goal

A single icon in the macOS status bar. Left click opens a custom panel
(SwiftUI, not a native `NSMenu` — necessary to fit progress bars and tabs,
which a native menu doesn't support). Right click opens a classic `NSMenu`
(updates, about, quit).

## Implemented and validated: functional scaffold

`StatusBarController` (AppKit): an `NSStatusItem` with a left click opening
an `NSPopover` (content via `NSHostingController<PanelView>`, SwiftUI) and a
right click temporarily assigning `statusItem.menu` to open a classic
`NSMenu` (the menu is removed right after — keeping it fixed would make
every click, including left clicks, open the NSMenu instead of the
popover). Validated by running it for real: the panel shows open projects
and real accounts, the classic menu opens with Check for Updates/About/Quit
working.

**A process note, not a product one**: during development, GUI processes
launched from this assistant's execution environment (this one, via a
terminal controlled by automation) end up with the `NSStatusItem`
positioned off any screen (`X=-4036`, confirmed via
`CGWindowListCopyWindowInfo` — reproduced identically by changing the
bundle name/identifier, ruling out app-specific caching). Running the same
binary from a terminal manually opened by the user works normally.
Practical implication: visual UI validation depends on the user running it
and reporting back — a screenshot taken from this environment can't be
trusted for this specific app.

## Decision: a list of open projects, without detecting "which one is in focus"

We evaluated and discarded trying to automatically identify which VS Code
window is in focus. Two reasons, in this order of weight:

1. **Fragile by design**: the VS Code window title is customizable by the
   user themselves (`window.title` in settings) — not a stable string to
   base logic on.
2. To resolve geometry ambiguity between maximized windows (empirically
   confirmed: two maximized VS Code windows have identical bounds via
   `CGWindowList`), Accessibility permission would be needed — friction the
   user preferred to avoid.

Instead: the panel lists **every project open right now**, read from
`~/Library/Application Support/Code/User/globalStorage/storage.json`
(`windowsState.openedWindows[].folder`, a `file://` URI with the **full
path** — no special permission needed to read this file). The list is
dynamic: opening/closing a VS Code window updates the list the next time
the panel is opened (or via a file watch, if we want real-time updates —
see "Out of scope"). No name ambiguity: each entry already comes with the
absolute path, we don't depend on a folder name.

Each row in the list has: the folder's name (the path's last component),
the account currently associated with it, and a way to switch (triggers the
same `cs set` flow — writes `.clauderc` + `.vscode/settings.json`, specs
02/07).

## Second section: `claude` sessions running in a terminal

Besides the projects open in VS Code, the panel lists `claude` processes
running outside any IDE — detection validated in `specs/06` via
`sysctl`/`KERN_PROCARGS2` (reads the process's real `CLAUDE_CONFIG_DIR`
from its environment, not an inference) + `proc_pidinfo`/`PROC_PIDVNODEPATHINFO`
(real cwd). Filters out VS Code extension processes by the flags only it
passes (`--output-format stream-json`, etc.), to avoid duplicating with the
projects section.

**Important limitation to communicate in the UI**: it's not possible to
switch the account of an **already-running** session — a running
process's environment variables are fixed from the moment it started,
there's no API to change them from outside. "Switching" here means
updating that directory's `.clauderc` (the same mechanism as `cs set`),
taking effect the next time `claude`/`cs` is run there — the current
session keeps the old account until restarted. The UI must make this clear
(e.g. "takes effect on the next run"), not suggest an immediate effect.

## Technical architecture

- An `NSStatusItem` with a button that distinguishes a left click from a
  right click (`NSStatusBarButton` + checking the event type, or
  `NSEvent.modifierFlags`/`rightMouseDown` — plain AppKit, SwiftUI's
  `MenuBarExtra` can't be used here because it doesn't separate left from
  right click in a simple way).
- Left click → an `NSPopover` whose `contentViewController` is an
  `NSHostingController` hosting the panel's SwiftUI view (allows using
  `TabView`, `ProgressView`, etc. with full SwiftUI freedom).
- Right click → a real classic `NSMenu` (`statusItem.menu`), populated with
  the basic items (see below).
- All the data logic comes from `ClaudeSCore` (the same Core as `cs`) —
  this target only builds UI on top of it, same as `cs` only does
  parsing/printing on top of it. No business logic duplication.

## Panel layout (left click)

```
Open Projects (VS Code)
  claudes                      Personal   [switch ▾]
  sivisamais_mobile_agente     Work       [switch ▾]
―――――――――――――――――――――――――――
Terminal Sessions
  ~/dev/other-project           Work       [switch ▾ — takes effect on the next run]
―――――――――――――――――――――――――――
[ Personal ]  [ Work ]          ← tabs
   5h:     ███████░░░ 68%  resets in 2h40
   Week:   ████░░░░░░ 41%  resets Fri 09:00
   (Extra: ██░░░░░░░░ 15%)         ← only if the account has active extra credit
```

Usage data comes from `specs/06-usage-expiry-monitoring` (already
resolved: real endpoint `GET /api/oauth/usage`, no longer blocked).

## Classic menu (right click)

Check for Updates · About ClaudeS · Quit.

## Data model

- Account: `RegisteredAccount` + `AccountStatus` (spec 01), already
  existing in Core, reused with no changes.
- Open project: `{ path, folder name }`, read from VS Code's
  `storage.json` — we don't persist this, it's read fresh every time the
  panel opens.
- Project↔account association: the source of truth is `.clauderc` (spec
  07), never duplicated in the app's own config — avoids the two getting
  out of sync. `.vscode/settings.json` is written as a derived projection
  in the same gesture (the same `VSCodeSettings.setConfigDir` function
  `cs set` already uses).

## Switching accounts in the panel — real effect

The same flow as `cs set`: writes `.clauderc`, updates
`.vscode/settings.json` via a safe merge, and (once spec 03 — leog's
patch — is implemented) makes sure the official extension recognizes the
change. Asks beforehand whether to sync that project's history (spec 04)
from the current account to the new one.

## Expiry notification

`UserNotifications` (native framework) when an account's
`refreshTokenExpiresAt` (never `expiresAt` — see spec 01) is close or past.
Periodic check reading the Keychain (negligible I/O cost, the same
mechanism as `AccountDiscovery.status`).

## Installing `cs` on first launch

On the app's first launch, calls `ShellInstall.install()` (spec 07) to make
the `cs` command available in the terminal, with no need for the user to
run anything manually. Shows the result (link created, or manual
instructions if no candidate directory is writable).

## Edge cases

- No account registered yet → an empty state pointing to using `cs add` or
  an equivalent flow in the GUI itself (to decide: does the GUI replicate
  `cs add`, or just point to running the command — see the next design
  round).
- VS Code isn't running / `storage.json` doesn't exist → empty project
  list, no error.
- An open project with no `.clauderc` yet → shows "account not set", offers
  to set one (or falls back to the default, same as `cs` does).

## Out of scope for this spec (for now)

- Real-time updates of the project list via a file watch on `storage.json`
  (start with just "read fresh when the panel opens").
- An account add/remove flow from the GUI itself (replicating what `cs`
  already does from the command line) — decide whether it goes in now or
  is left for later.
- Patch logic (spec 03) and session sync (spec 04) — this app only invokes them.
- A "full" management window (outside the icon's panel) — the user already
  confirmed this isn't a priority right now.
- Packaging the distribution `.app` (icon, signing, notarization, GitHub
  Releases) — see `specs/07-cli-gateway`.
