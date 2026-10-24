# Spec: Usage (quota) monitoring per account

Resolves: P6

## Resolved — no longer research, now an implementation plan

Confirmed by investigating the source code (MIT) of two open source apps
already doing exactly this —
[`LunaParker/claude-macos-menu-usage`](https://github.com/LunaParker/claude-macos-menu-usage)
and `hamed-elfayome/Claude-Usage-Tracker`, both Swift/SwiftUI — and the
public issue [`anthropics/claude-code#31021`](https://github.com/anthropics/claude-code/issues/31021).

There's a real endpoint that Claude Code itself uses to feed its own status bar:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
Accept: application/json
```

Not publicly documented as an official API, but it's the same mechanism
Claude Code uses internally — not a secret endpoint we discovered via our
own network traffic, it's knowledge already public/replicated by other MIT
projects.

## API response — confirmed against the two real accounts

Implemented and tested end to end (`cs usage <slug>`) against the real
Personal and Work accounts. The real format differs a bit from what the
reference project documented (the API has evolved since then):

- `five_hour` / `seven_day` / `seven_day_opus`: each one
  `{ utilization: Double? (0-100), resets_at: Date? }` — the session (5h)
  and weekly progress bars. `resets_at` comes back `null` when
  `utilization` is 0 (the window hasn't started counting yet).
- **Dates come as ISO 8601 with microseconds and a `+00:00` offset**
  (`"2026-10-12T08:59:59.551118+00:00"`), not in the format
  `JSONDecoder().dateDecodingStrategy = .iso8601` accepts by default
  (which rejects a fractional second). Implemented a custom parse with
  fallback (`UsageDateParsing` in `UsageClient.swift`): tries
  `ISO8601DateFormatter` with `.withFractionalSeconds`, falls back to no
  fraction if that fails.
- `extra_usage`: `{ is_enabled, monthly_limit, used_credits, utilization }`
  modeled (the real response also carries `currency`, `decimal_places`,
  `disabled_reason`, `daily`, `weekly`, etc. — ignored for now, not needed
  for the panel's bars). **Decision**: render it as a third, conditional
  bar (only when `is_enabled == true`).
- The real response carries a large number of extra fields with internal
  Anthropic code names (`tangelo`, `iguana_necktie`,
  `omelette_promotional`, `nimbus_quill`, etc.) — all `null` on the two
  tested accounts, probably feature flags/experiments. Not declared in the
  model — `Codable` silently ignores any unmapped key, no special handling
  needed.
- Removed from the model (not essential for the MVP, the real format
  doesn't match what the reference project documented — it was
  `scope.model.display_name`, in practice we observed `{kind, group,
  percent, severity, resets_at, is_active}`): the `limits[]` array of
  per-model quotas. Revisit if a user on a Max plan needs that granularity.

## Scope change: we now read the `accessToken`

Up to here (`specs/01-account-management-storage`), we deliberately never
read `accessToken`/`refreshToken` from the Keychain — only the expiry
metadata. To call this endpoint, we need the real `accessToken`. Rule kept:
it stays **in memory only**, never logged, never written to a file — used
exclusively to build the request's `Authorization` header, immediately.

## Resilience (copied from `claude-macos-menu-usage`'s real experience)

The endpoint has an aggressive rate limiter and easily returns a
persistent 429 (confirmed by issue #31021 on the Claude Code repo itself):

- Background poll: an interval between 2 and 5 minutes, never more
  frequent.
- **Conditional poll**: only fires when there's a sign of real account
  usage — at least one open VS Code project (`storage.json`) or at least
  one standalone `claude` process running (see the process-detection
  section below). With neither, the timer stays up but doesn't hit the
  network — avoids spending the endpoint's rate-limit budget needlessly.
- **Forced refresh when opening the panel**: clicking the icon always
  triggers an immediate fetch, ignoring the poll interval — the user
  shouldn't see a number up to 5 minutes stale the moment they decide to
  look. The 15s debounce still exists, but only for the degenerate case of
  opening/closing the panel repeatedly in under 15s (never for the first
  opening after a while idle).
- On a 429: respects `Retry-After` if present; otherwise, a default 5-minute
  backoff, with a 60s minimum floor (never less, even if the header comes
  back zeroed/invalid).
- Credentials read from the Keychain are cached in memory, to avoid
  repeating the read (and the risk of an authorization re-prompt) on every
  poll.

## Detecting `claude` sessions running in a terminal

Validated on this machine, with no special permission at all (neither
Accessibility nor Screen Recording — just standard process APIs, same
user):

- `sysctl` with `KERN_PROCARGS2` gives access to the full `argv`/`envp` of
  any process owned by the same user. Tested against a real `claude`
  process: read `CLAUDE_CONFIG_DIR=/Users/.../.claude` from its
  environment — the **real** value that process is using, not an
  inference.
- `proc_pidinfo` with `PROC_PIDVNODEPATHINFO` gives the process's real cwd.
  Tested: returned the exact path it was launched from.
- **Telling it apart from VS Code extension processes** (which are also
  `claude` running): the extension always passes flags like
  `--output-format stream-json --input-format stream-json
  --permission-prompt-tool stdio` — no manual terminal use passes these.
  Filters by these flags to avoid duplicating entries already covered by
  the VS Code projects list (section above, via `storage.json`).
- If `CLAUDE_CONFIG_DIR` is absent from the process's environment, the
  account in use is the system default (`~/.claude`) — resolves normally
  against the accounts registered by `configDir`.
- Result: the panel gets a "Terminal Sessions" section next to "Open
  Projects (VS Code)", each able to switch accounts the same way (see
  `specs/05-app-status-bar`).

## Renewing an expired access token

Confirmed (we already saw this in spec 01: it's normal for the access
token to be expired and for Claude Code to renew it by itself in the
background) — but **to force that renewal under our control** before
calling the usage endpoint, the technique validated by the reference
project is:

- Run `claude mcp list` (not plain `claude` — requires a TTY; not
  `claude auth status` — it only reports cached state, **never hits an
  authenticated endpoint**, so it never actually triggers an OAuth
  refresh).
- Via the user's login shell with `-i -l` (`$SHELL -i -l -c "claude mcp
  list"`) — necessary because a GUI app launched by Finder/LaunchServices
  doesn't inherit the terminal's PATH (unlike our `cs`, which already runs
  inside a terminal with the correct PATH). This is a new note for
  `specs/07-cli-gateway`/`05-app-status-bar`: the current `ClaudeGateway`
  (`/usr/bin/env claude`) only works well when called from inside a
  terminal; called from the GUI it will need to resolve the user's login
  shell.
- `cwd` fixed to `/tmp` (avoids triggering TCC prompts from accessing
  `~/Desktop`/`~/Documents`/etc. that `claude mcp list` might touch).
- **Never send SIGTERM** to the process — a SIGTERM in the middle of
  writing credentials makes Claude Code move the credential out of the
  Keychain (a finding straight from the reference code). Use a timeout +
  let the process run its course, never kill it.

## Final architecture: the Claude Agent SDK's control protocol (not HTTP)

Two approaches were tried and discarded before landing on the correct one
— logged here because the path to the right answer matters as much as the
answer itself:

1. **Direct HTTP endpoint `/api/oauth/usage`** (`UsageAPIClient`, still
   exists in the code): consistently failed for the Personal account
   (recurring 401, then 429) while claude.ai, the CLI and the VS Code
   extension always worked. Kept only as a reference/manual-debug piece
   (`cs usage <slug>` switched to the new mechanism, not this one).
2. **statusLine hook** (`code.claude.com/docs/en/statusline`): Claude Code
   pushes `rate_limits` via stdin on every API response, with no extra HTTP
   call — technically worked, but **rejected by the user**: it only
   populated after an interaction in the session, never "on demand" like
   the extension's "Account & Usage" screen, which shows usage instantly
   when opening a new chat, without sending anything. Removed entirely
   (code and config on both accounts).

**The real mechanism, discovered by reading the extension's own code
(`extension.js`)**: the "Account & Usage" screen doesn't hit any HTTP
endpoint directly — it sends a **control_request** over the Claude Agent
SDK's `stream-json` protocol to the already-authenticated `claude` process
(`usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET` → `{"subtype":
"get_usage"}`), and it's the official binary itself that fetches the real
data. This explains everything: by delegating the call to the official
binary (which knows how to authenticate/call correctly), the per-account
behavior difference disappears — tested and confirmed working perfectly
for both Personal and Work.

`UsageControlClient.fetch(configDir:)` (`Sources/ClaudeSCore/`)
implements this: spawns `claude --input-format stream-json --output-format
stream-json -p` with the account's `CLAUDE_CONFIG_DIR`, writes
`{"type":"control_request","request_id":"...","request":{"subtype":
"get_usage"}}` to stdin, reads stdout line by line until it finds the
`control_response` with the matching `request_id`, decodes
`response.response.rate_limits` (the same `UsageWindow`/`ExtraUsage`
structure already used by the HTTP client). The process is ended with
`terminate()` — safe here because it's a read, not a credential renewal in
the middle of a write (unlike `CredentialRefresher`, which never kills the
process).

**Result**: works on demand, at any time, with no active session or prior
interaction required — exactly what the extension's screen does. Validated
via `cs usage personal`/`cs usage work`: both return real, correct data,
with no error.

The `statusline-command.sh` the user had previously set up on the Personal
account wasn't restored — confirmed with him he no longer uses it.

## Real cause of the persistent rate limit on the Personal account (history — mitigated, wasn't the whole root cause)

After a whole day unable to see the Personal account's usage via the
panel — while claude.ai, the CLI and the VS Code extension always showed
it normally — it became clear that "endpoint instability" alone wasn't a
sufficient explanation: if that were the whole story, it would work
sometimes, not never.

Two causes identified, the second much more likely to be the real root cause:

1. **A different `rateLimitTier` per account**: confirmed by reading the
   Keychain — Personal uses `default_claude_ai`, Work uses
   `default_raven`. It's plausible Anthropic applies tighter limits to
   this endpoint for that specific tier (individual Pro plans vs.
   Team/Enterprise).
2. **The poll ran in the background all day, even with the panel
   closed** — our bug. `startPolling()` was called once in
   `PanelViewModel`'s `init()` and never stopped, making an attempt every
   3min for hours, continuously consuming the (probably low, because of
   the tier) budget of the Personal account with no chance for it to ever
   recover. This is consistent with "Work always worked" (a tier without
   that restriction) and "Personal never worked" (a small budget,
   constantly zeroed out by our own poll).

**Fixed**: the poll now only runs while the popover is actually visible on
screen — `PanelViewModel` is created and owned by `StatusBarController`
(no longer by `PanelView` via `@StateObject`), which calls
`startPolling()`/`stopPolling()` in the same gesture of opening/closing
the popover (`togglePopover()`), reinforced by `onAppear`/`onDisappear` on
the view. Before, the ViewModel lived and polled forever from the moment
the view was first created, regardless of whether the popover was visible.

## Implemented: conditional poll, debounce and last-result cache

- Background poll every 3 min (within the 2–5min range), only fires a
  fetch if there's at least one open VS Code project or an active terminal
  session — without either, it doesn't hit the endpoint for nothing.
- 15s debounce: switching tabs or reopening the panel doesn't trigger a new
  fetch if the last successful one was less than 15s ago.
- A "Try Again" button (an explicit user action) always bypasses the debounce.
- On error, the panel preserves and keeps showing the last successful
  result (`lastUpdated`), with a discreet orange warning instead of
  replacing everything with an error screen — the endpoint is unstable
  (see below), a one-off error shouldn't wipe out valid data.

## Instability confirmed in real use (panel vs. CLI)

Testing the same account (Personal) minutes apart between the SwiftUI
panel and `cs usage personal`: the CLI got a 401 → renewed → 429 (rate
limit); the panel, run right after, got a 401 → renewed → **401 again**
(not 429). Same account, close time window, different result — confirms
the endpoint is genuinely unstable (not our own bug trying to reproduce a
deterministic result). Design implications:

- The UI should never treat a post-renewal 401 as "your session expired,
  log in again" — the real session may be perfectly active (e.g. the user
  themselves chatting with Claude Code on the same account, at the same
  time, as happened in the test). Correct message: temporary endpoint
  instability, try again later.
- Every error state in the panel has a "Try Again" button — the user never
  ends up on a screen with no possible action when a fetch fails.

## Validated end to end (`cs usage <slug>`)

- Work account: `200 OK`, `five_hour.utilization=0`,
  `seven_day.utilization=76` with `resets_at` correctly converted to local
  time. Confirms correct request/headers/parsing.
- Personal account: a revoked access token (`"OAuth access token has been
  revoked"`, not just "expired") → triggered `CredentialRefresher` →
  renewal completed within the timeout → the second attempt got
  **429 with `Retry-After: 3600`**. Consistent with issue #31021: the rate
  limiter is per account/token, and this very session was already
  consuming that same account's budget (a real Claude Code session
  running in parallel on it, in this very conversation). Proof that the
  backoff documented above isn't theoretical — it's the real expected
  behavior in normal use.

## UI: where this fits in the panel (see `specs/05-app-status-bar`)

Three progress bars per account (5h, weekly, extra if any), with a
percentage label and reset time, inside that account's tab in the custom
panel.

## Out of scope

- Any way to "predict" usage before the API confirms it (e.g. estimating
  from local `.jsonl` files) — discarded: the official API (even if
  undocumented) already gives the exact number Anthropic uses for
  throttling, with no need to replicate per-model weighting logic.
