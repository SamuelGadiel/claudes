# Spec: Shared chats between accounts

Resolves: P4

> **Revised decision.** This spec's original version (sync-on-switch, a
> one-off copy per project) was replaced after real use exposed its
> problems: duplication (a chat continued on account B never comes back to
> account A), and the initial copy only grabbed `.jsonl`, losing the
> per-session subfolders (`subagents/`, `tool-results/`). The symlink
> decision was reopened and revised with concrete evidence — see below.

## Decision: every account shares the same `projects/`, via a symlink

`<CLAUDE_CONFIG_DIR>/projects` stops existing as each account's own
directory — it's always a symlink pointing at `SharedSessionsDirectory`
(`~/.claude-shared-chats`, `Sources/ClaudeSCore/SharedSessionsDirectory.swift`).
Chats now belong to the **project**, not to whichever account was logged in
when they were written — no matter which account is active, any project's
full history is always there.

### Why a symlink, revisited

The original spec rejected a symlink for two reasons. Re-evaluated:

1. **"Unwanted scope: unifies every project across accounts."** Conscious
   decision now: that's the desired behavior, not a side effect. Mitigated
   by a control tool: per-project "Clear Chat History" (see below) — not
   real isolation between accounts, but it gives the user an explicit way
   to avoid letting a specific project's history pile up indefinitely.
2. **"Risk of concurrency in `sessions/`."** The original spec itself
   already acknowledged this risk was specifically about
   `~/.claude/sessions/` (process locks, `<pid>.json`), not about
   `projects/` — it only avoided everything out of general caution.
   `projects/` still doesn't have this problem. Two accounts writing the
   same session at the same time is a rare scenario, and Claude Code itself
   already warns when it detects this ("If another Claude Code process
   still has the conversation open..." — confirmed in the official docs).
   Not handled now; revisit if it ever becomes a real problem.

**Confirmed with real evidence, not an assumption**: the technique of
symlinking `projects/` across `CLAUDE_CONFIG_DIR`s is used by multiple
community projects (not officially documented/supported by Anthropic, but
reported working in production). Also validated by our own test: a
directory containing a symlink, removed recursively, leaves the link's
target intact — `removeAccount` needed no change at all for "remove the
account, keep the chats" to work.

### Why not "our own" folder with custom logic on top

Considered and discarded: technically equivalent to a direct symlink
(Claude Code always looks for `projects/` relative to the active
`CLAUDE_CONFIG_DIR`, so a folder "managed by us" would still need to be
symlinked back) — same technical risks, more code of our own on top with
no real gain.

## Design

### `SharedSessionsDirectory.adopt(configDir:accountSlug:)`

Called on every `addAccount` (creating a new account and the future import
of an existing one — same code, same guarantee). Never reads or interprets
a `.jsonl`/session's content — every file is treated as an opaque blob:

1. If `projects/` is already the right symlink: no-op.
2. If nothing exists yet (a new account): creates the symlink directly.
3. If a real folder with sessions already exists (an account used before
   adopting the symlink, or imported from outside): merge per project, then
   per item inside each project (a `.jsonl` file or a whole session
   subfolder):
   - No name conflict: move it.
   - Conflict, identical content (hash): drop the duplicate, nothing lost.
   - Conflict, different content: **never overwrite, never discard**. The
     larger one (heuristic: more complete/more recently continued) keeps
     the original name, stays normally resumable by its ID. The smaller
     one is preserved alongside it with a `.conflict-from-<origin>` suffix.
4. Removes the original `projects/` (now empty) and creates the symlink.

### `SharedSessionsDirectory.clearHistory(forProjectPath:)`

Deletes the whole `<shared>/<dirName>/` — only that project, no other is
touched. Irreversible; the UI confirms before calling it. Triggered by
"Clear Chat History…" on each project's row in the panel.

### `cs migrate-to-shared-sessions`

Runs `adopt` for every already-registered account — not just for this
one-off migration: it also serves anyone updating from a version before
this model, with accounts already registered before `projects/` became a
symlink.

## Validated

Tested in disposable directories (`/tmp`), not on real data, before
running in production:
- A new account with no sessions: symlink created directly.
- Two accounts with non-overlapping projects: moved with no conflict.
- The same project in two accounts, one identical file in both: duplicate
  dropped with no loss.
- Same project, same session name, different content: both preserved, the
  larger one kept the original name, the smaller one got a conflict suffix.
- `cs remove` on an account with a symlinked `projects/`: the account's
  directory and Keychain credential removed, shared content intact.

## Out of scope (for now)

- Resolving real concurrency between two active accounts writing the same
  session at the same time.
- Real isolation between accounts (e.g. a work account never seeing
  personal projects' history) — today the only tool is the manual
  per-project "Clear Chat History".
- Existing-account import UI (a folder picker) — the backend logic
  (`addAccount` with a custom `dir` + `adopt`) already supports this via
  the CLI (`cs add --dir <existing-folder>`); only the equivalent graphical
  UI is missing.
