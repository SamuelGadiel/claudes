# Spec: the `cs` CLI as a terminal gateway

Resolves: a scope expansion requested during the session — replacing the
manual aliases (`claude`/`claudew`) with a single binary that decides the
account, directly inspired by the `fvm` (Flutter Version Management)
pattern.

## Mapping against fvm (confirmed by investigating `fvm --help` and a real `.fvmrc`)

| `cs` | `fvm` equivalent |
|---|---|
| `cs list` | `fvm list` |
| `cs add --name <name> [--dir] [--slug] [--default]` | `fvm install` |
| `cs remove <slug>` | `fvm remove` |
| `cs set <slug>` (at the project root) | `fvm use <version>` |
| `cs default <slug>` | `fvm global <version>` |
| `cs <slug> [args...]` | `fvm flutter [args...]` — pure gateway |
| `cs` (alone) | resolves project → default → native |
| `.clauderc` with `{"account": "<slug>"}` | `.fvmrc` with `{"flutter": "<version>"}` |

## Central decision: `.clauderc` writes the logical name, not the path

Unlike `.vscode/settings.json` (spec 02), which needs the absolute path
because it's Anthropic's official extension that reads it — and is
therefore always local/`.gitignore`d — `.clauderc` only writes the
account's **slug** (`{"account": "work"}`). This is safe to commit: each
person on the team resolves "work" against their own local `accounts.json`.
`cs set` writes both files: `.clauderc` (the portable source of truth) and
`.vscode/settings.json` (a derived projection, just so the extension works).

## Account resolution (order)

1. The current directory's `.clauderc`, **walking up directories** until
   one is found (same as `.git` resolution, implemented in
   `ClauderFile.find`).
2. The account marked as default in `accounts.json` (`defaultAccountSlug`).
3. No `CLAUDE_CONFIG_DIR` set (native behavior, same as running `claude`
   without the tool) — only happens before any account has been registered.

**User's decision**: starting from the first account created, a default
should *always* exist. The first account registered via `cs add` is
automatically promoted to default; `cs add --default` allows choosing
another one at creation time; `cs remove`ing the default account
automatically promotes the next one (if any remain).

## Data model

`RegisteredAccount` gained a `slug` field (a stable technical identifier,
with no spaces/accents/case changes — used in `cs <slug>`, `cs set`,
`cs remove`), distinct from `name` (display only). `accounts.json` went
from a plain array to `AccountsFile { accounts: [...], defaultAccountSlug: String? }`.
Automatic migration from the old format implemented in
`AccountsConfig.load()` (generates a slug from the name, promotes the
first account to default).

## Slug

`Slug.make(from:)`: folds accents (`folding(.diacriticInsensitive)`),
lowercases, replaces any run of non-alphanumeric characters with a single
`-`, no `-` at either end. Tested with "Cliente Teste Ã" → `cliente-teste-a`.

## Reserved words

`list`, `add`, `remove`, `set`, `default`, `help`, `-h`, `--help`, `-v`,
`--version` can't be an account slug (validated in `cs add`) — avoids a
collision between the command namespace and the account namespace in the
`cs <first-argument>` gateway.

## Process gateway

`ClaudeGateway` resolves the real `claude` binary via `/usr/bin/env`
(never hardcoded, never via a shell alias — `Process` doesn't inherit
aliases anyway). stdio inherited directly (no `Pipe`) to preserve the TTY
and Claude Code's interactive mode. Exit code always propagated.

**Validated end to end**: `cs work auth status` returns the work account's
email (`samuel.gadiel@branef.com.br`), `cs personal auth status` returns
the personal email — confirms `CLAUDE_CONFIG_DIR` correctly reaches
Claude Code's real process in both cases. `cs auth login` is a pure
pass-through to the native `claude auth login` command (confirmed via
`claude auth --help`) — we don't implement any authentication logic
ourselves.

## `cs add` flow

1. Validates name/slug (not empty, not reserved, not duplicated).
2. Resolves `configDir` (an explicit `--dir`, or `~/.claude-<slug>` by default).
3. Creates the directory (`mkdir -p`) — doesn't create the internal
   structure, that's Claude Code's own job on its first run.
4. Registers it in `accounts.json`; promotes it to default if it's the
   first account or if `--default` was passed.
5. Interactively asks whether to log in now; if so, runs
   `claude auth login` for real with the new account's `CLAUDE_CONFIG_DIR`
   (inherited stdio — the user sees the real login flow, including a
   browser opening if that's the case).

## Tested edge cases

- A name with an accent/space → correctly normalized slug.
- `cs remove` on the default account → automatically promotes the next one.
- `.clauderc` resolved from a subfolder of the project (walks up until it finds one).
- An account registered with no Keychain credential yet → `cs list` shows
  "no credential found" instead of crashing.
- `claude auth status` with no login returns `loggedIn: false` and a
  non-zero exit code — correctly propagated by the gateway (not a bug of
  ours).

## Swift Package architecture (preparing for the status bar app)

The package now has two targets: `ClaudeSCore` (a library — all the logic:
Keychain, accounts, `.clauderc`, settings.json, sync, gateway,
installation) and `cs` (an executable — only argument parsing + prints).
The future status bar app (spec 05) will be a third target depending on
the same `ClaudeSCore`, with no duplication. Core never prints directly
(`AccountsConfig.load()` returns `(file, messages)` instead of calling
`print()`) — the consumer always decides how to display it (the CLI today,
the GUI later).

**Important by design**: `cs` never depends on the status bar app being
running. There's no IPC between the two — both read `accounts.json` and
the Keychain directly. Any future IPC (e.g. the app notifying something
when `cs` switches accounts) must be best-effort and optional, never
blocking.

## Installing it on PATH (`ShellInstall` / `cs install-cli`)

Creates (or updates) a symbolic link to the running `cs` binary inside a
directory already on PATH — the same pattern as VS Code's "Install 'code'
command in PATH". Resolves the executable's path **at runtime**
(`CommandLine.arguments[0]`, resolving symlinks), never hardcoded — that's
why it works identically today (`swift run`/`.build/debug/cs`) and later,
once `cs` is bundled inside a `.app`
(`~/Applications/ClaudeS.app/...` or `/Applications/...`).

Order of directories tried: `/usr/local/bin` first (macOS's historical
convention), `~/.local/bin` as a fallback with no sudo. **Validated on
this machine**: `/usr/local/bin` wasn't writable without sudo (permission
denied), automatically fell back to `~/.local/bin` (already on the user's
real PATH) and worked — `~/.local/bin/cs list`/`cs personal --version`
confirmed working as if it were already installed.

Plan for `.app` distribution (spec 05, not yet implemented):
1. `cs` compiled in release mode and bundled inside, at
   `Contents/Resources/bin/cs`.
2. On the app's first launch, it calls the same `ShellInstall.install()`
   logic (it's already testable and reusable — doesn't need to be
   rewritten for the GUI).
3. If no candidate directory is writable, the GUI shows the manual
   instructions (the same message the CLI already prints) instead of
   failing silently.

## Out of scope (for now)

- Actually packaging the `.app` (bundle, icon, signing/notarization,
  distribution via GitHub Releases) — that's spec 05.
- Forwarding signals (Ctrl+C) was observed working by default (same
  process group as the terminal), but wasn't exhaustively tested with
  long-running/`--bg` sessions.
