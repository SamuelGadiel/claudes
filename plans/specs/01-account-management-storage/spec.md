# Spec: Account management and storage

Resolves: P1 (multiple accounts), P5 (adding an account with no friction), P9 (expiry)

## Goal

Discover which Claude Code accounts exist on the machine, read their expiry
metadata with no network call at all, and allow registering a new account
without manually editing aliases/scripts.

## What we already know (validated on this machine)

- Each account corresponds to a `CLAUDE_CONFIG_DIR` (e.g. `~/.claude`, `~/.claudew`).
- The credential sits in the macOS Keychain, class `genp` (generic password),
  service `Claude Code-credentials` — and hash-suffixed variants
  (`Claude Code-credentials-<hash>`), one per non-default `CLAUDE_CONFIG_DIR`.
- The item's content is a JSON with `claudeAiOauth.{accessToken,refreshToken,
  expiresAt,refreshTokenExpiresAt,subscriptionType,rateLimitTier}` and also
  plugin MCP OAuth tokens (Atlassian, Figma, etc.) — **don't touch those
  fields**, they belong to other products.
- `expiresAt`/`refreshTokenExpiresAt` are epoch milliseconds.

## Keychain suffix rule — confirmed

`sha256(<absolute path of CLAUDE_CONFIG_DIR>)`, first 8 hex characters.
Validated on this machine: `/Users/samuelgadiel/.claude` → `c2f365e1`,
`/Users/samuelgadiel/.claudew` → `f7d651a4`. Keychain service = `"Claude
Code-credentials"` with no suffix when `CLAUDE_CONFIG_DIR` is the default
(`~/.claude`), or `"Claude Code-credentials-<hash8>"` for any other directory.

Note: there was a third suffix (`cc6319df`) on this machine that doesn't
match any known `CLAUDE_CONFIG_DIR` — likely a leftover from a test
directory used in the past. No action needed; account discovery (R1) only
considers `CLAUDE_CONFIG_DIR`s the user has explicitly registered, so an
orphaned suffix simply doesn't show up in the list.

## Functional requirements

1. List known `CLAUDE_CONFIG_DIR`s: the default (`~/.claude`) + any directory
   the user has explicitly registered in our config (see R3). Don't try to
   "guess" other directories by scanning the disk.
2. For each `CLAUDE_CONFIG_DIR`, locate the matching Keychain item and
   extract `expiresAt`/`refreshTokenExpiresAt`/`subscriptionType` — never
   persisting `accessToken`/`refreshToken` outside the Keychain.
3. Let the user "add an account": the app asks for a friendly name (e.g.
   "Work") and a `CLAUDE_CONFIG_DIR` (suggesting a new path like
   `~/.claude-<name>` if left empty). There's no login flow — the user logs
   in manually with `CLAUDE_CONFIG_DIR=<path> claude` once; our app only
   starts monitoring that directory afterward.
4. Persist the list of registered accounts (friendly name ↔ `CLAUDE_CONFIG_DIR`)
   in the app's own config file (e.g. `~/Library/Application
   Support/ClaudeS/accounts.json`), never as plain text with a secret.

## Reading the Keychain — how

Use `Security.framework` (via Swift, `SecItemCopyMatching`) filtering by
`kSecAttrService`. The first read of each item will trigger the native
macOS prompt asking for permission ("ClaudeS wants to access..."); this is
expected and should be communicated to the user on the first run.

## Edge cases

- No Keychain item found for a registered `CLAUDE_CONFIG_DIR` → "never
  logged in / credential removed" state, show this in the UI, don't hang.
- `expiresAt` (access token) in the past is **normal and shouldn't trigger
  an alert** — Claude Code automatically renews the access token via
  `refreshToken` in the background (confirmed: on this machine the Personal
  account has an expired access token and is working normally). The real
  expiry alert (consumed by `specs/05-app-status-bar`, P9) should watch
  `refreshTokenExpiresAt` — that's the one that forces a new manual login
  once it passes.
- Two `CLAUDE_CONFIG_DIR`s pointing at the same Keychain hash (collision) →
  warning log; shouldn't happen in practice but don't assume uniqueness
  without checking.

## Out of scope

- Validating the accessToken against the Anthropic API (that's network — see
  P9's "expiry popup", which can be purely client-side via `expiresAt`, with
  no round trip).
