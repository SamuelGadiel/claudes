# claudes (ClaudeS) — Overview

## Problem

Using multiple Claude accounts (personal + work) in VS Code today depends on:
duplicated VS Code profiles, a third-party extension to fix credential
isolation, a manual process to move chat between accounts, and no visibility
into usage/expiry. See the conversation history for the full list (13 points).

## What this project is (current MVP state)

A **management** layer on top of Claude Code accounts already logged in:

- Discovers existing accounts (`CLAUDE_CONFIG_DIR` directories + Keychain credentials).
- Decides, per project opened in VS Code, which account it uses — without needing profiles.
- Fixes the official Anthropic extension's bug that ignores `CLAUDE_CONFIG_DIR`
  outside the launch process.
- Shared chats between accounts via a single symlinked directory (`~/.claude-shared-chats`)
  — no longer "sync on switch" (one-off copy), see `specs/04-session-sync`.
- Shows usage and expiry for each account in a macOS status bar icon, with
  account switching per project right there, and notifies (login expiry,
  usage threshold, quota renewal) even with the panel closed.

## What this project is NOT (today)

- Doesn't log in or manage OAuth. Only reads what Claude Code already wrote.
- Doesn't replace the Claude Code CLI/extension — operates alongside them.
- Not cross-platform at this stage (macOS only, native SwiftUI).

## Long-term vision — why the name is "ClaudeS", not "Claude VS Code Switcher"

The MVP's scope is deliberately narrow (macOS + VS Code), but the project's
vision isn't. Stated goal: **wherever Claude operates, this project should be
able to operate too** — the "S" in "ClaudeS" carries both "plural" (multiple
accounts) and "more than just that" (the Claude ecosystem as a whole, not
just one IDE).

Future directions already raised (not committed, not in the MVP):

- **Other integration points beyond the VS Code extension**: Claude Desktop
  (official Electron app — `kevinchau/claude-switcher`, see Kanban, is a
  reference for how another project already tackles that domain
  specifically), a browser extension for claude.ai, any other IDE that gets
  an official Claude extension in the future.
- **More metrics, extracted from what we already collect**: API cost (tokens
  spent) per project and per account, chat volume per project/account, and
  other metrics derived from the usage data monitoring already reads.
- **Usage forecasting**: projecting the current consumption rate to estimate
  when a window will run out — not just the reactive threshold (75%/90%) that
  already exists, but a proactive alert ("at this rate, it runs out in X",
  "open another session/account now"). Inspired by the forecasting system of
  `kevinchau/claude-switcher` (see Kanban), adapted to our model.
- **Native macOS widgets** showing usage without opening the panel.

This shapes name/icon/visual identity decisions now (not waiting for the
ecosystem to grow before adjusting the brand), but doesn't force any
premature architecture decision — each direction above only becomes real
work once it enters the backlog with detail.

## Architectural decisions made

| Decision | Choice | Why |
|---|---|---|
| App stack | Native Swift/SwiftUI (menu bar `NSStatusItem`) | Native access to Keychain/Accessibility/AppleScript, no heavy resident runtime |
| VS Code profiles | Eliminated. `CLAUDE_CONFIG_DIR` set via `.vscode/settings.json` per project | A single profile, no duplicating installed extensions |
| Official extension patch | Vendor `patch-core.js` + `patch-regexes.js` from the `leog/claude-code-config-dir-patcher-vscode` project (MIT) and run them via macOS's native `JavaScriptCore` | Reuses the logic (actively maintained by the author) without reimplementing fragile regex or depending on Node being installed |
| Chat sync | "Sync on switch": copies `projects/<path-hash>/*.jsonl` from the source account to the destination, only for the project being switched | Global symlink was discarded — risk of race conditions between accounts and loss of per-project granularity |
| Expiry detection | Direct Keychain read (`Claude Code-credentials*`), `expiresAt`/`refreshTokenExpiresAt` field in epoch ms | Doesn't depend on any network call |
| Usage (quota) per account | Open — no confirmed usage API yet. See `specs/06-usage-expiry-monitoring` | Avoid guessing: needs validation before designing the tabs UI |

*(Note: the "VS Code profiles" and "Chat sync" rows above describe an early
design later superseded — see `specs/02` and `specs/04` for what actually
shipped. Left as originally written, not rewritten here, since this table
is itself a point-in-time historical record.)*

## Known cross-cutting risks

- **Patch fragility**: the official Anthropic extension may change the
  minified bundle and break the vendored regexes. Mitigation: a verification
  script (adapted from leog's `check-upstream-patchability.mjs`) runs before
  applying.
- **Versioned `.vscode/settings.json`**: if the project is shared across a
  team, we can't write `CLAUDE_CONFIG_DIR` (a path local to the user's
  machine) into a committed file. See `specs/02-vscode-integration-without-profiles`.
- **Keychain secrets**: any credential read must stay in memory as briefly as
  possible and never be logged/persisted outside the Keychain.

## Phases (roughly, refine in the kanban)

1. Foundation: account discovery + reading expiry via Keychain.
2. VS Code integration: writing `.vscode/settings.json` + vendored patch.
3. Status bar app: list accounts, list open VS Code windows, switch account per project.
4. Session sync (sync on switch).
5. Usage monitoring (depends on API validation) + expiry popup.
