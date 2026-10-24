# Spec: VS Code integration without profiles

Resolves: P2, P12 (a single VS Code profile), P7 (switching a project's account)

## Update: final decision — `.vscode/settings.json` stopped being written

After exploring the alternatives to the "Critical risk" described below in
depth (a separate workspace file, an environment variable injected when
launching VS Code, native VS Code profiles — all discarded, see
`plans/KANBAN.md`), the final decision was different: **stop writing
`claudeCode.environmentVariables` into `.vscode/settings.json` entirely**,
instead of accepting the risk and just warning about it.

This was only possible by reverting the scope patch `specs/03` described
(`"machine"` → `"window"`) — without it, the extension goes back to
accepting that setting only globally (the original, never-modified
behavior), and `.vscode/settings.json` never carries anything
account-specific again. In exchange, a new patch (`"clauderc"`, see
`specs/03`) teaches the extension to read `.clauderc` directly — that
becomes the single source of truth per project, both for our app and for
the extension.

`VSCodeSettings.setConfigDir` (Core) and the `JSONSettingsFile` module it
used were removed — they have no caller left. `GitRisk.warnings` (the
"versioned file" warning) was also removed for the same reason: with no
writing to `.vscode/settings.json`, there's nothing left there to warn
about. `GitRisk.ensureIgnored` remains in use, now only by `ClauderFile`.

The rest of this document (Design, Critical risk, Functional requirements,
"Implemented and validated") is historical — it describes the earlier
approach and why it wasn't enough on its own. Preserved without edits so as
not to rewrite the past; doesn't reflect current behavior.

## Goal

Eliminate the need for duplicated VS Code profiles. The account used in a
project is decided by that project's `.vscode/settings.json`, written and
maintained by our app — not manually by the user.

## Design

- Key used: `claudeCode.environmentVariables`, in the format the official
  extension already accepts:
  ```json
  "claudeCode.environmentVariables": [
    { "name": "CLAUDE_CONFIG_DIR", "value": "/Users/samuelgadiel/.claudew" }
  ]
  ```
- Our app **merges**, never overwrites: reads the existing `settings.json`,
  only updates/inserts the `CLAUDE_CONFIG_DIR` entry inside the
  `claudeCode.environmentVariables` array, preserving any other user config
  and any other environment variables already there.
- Switching a project's account = rewriting that value. **Validated by
  reading the official extension's `extension.js` (2.1.281, not via visual
  testing):** a reload is **not necessary** on the normal path. The
  extension registers `watchEnvironmentVariablesSetting()`, which listens to
  `workspace.onDidChangeConfiguration` specifically for
  `claudeCode.environmentVariables` and, on detecting a change, calls
  `refreshEveryHost` — invalidates the config cache, refreshes every open
  webview and every active session. VS Code fires that event by itself on
  detecting the write to `.vscode/settings.json`, with no need for the
  window to have focus. (There's one caveat, only for the FILE watcher of
  `CLAUDE_CONFIG_DIR` itself — detecting a login/logout done outside the
  window within the same config dir — which falls back to "only after a
  reload" if the fs.watch fails; not our case, which changes the setting's
  own value.)

## Critical risk: versioned `.vscode/settings.json` in team projects

`CLAUDE_CONFIG_DIR` is a path local to the user's machine. If this file gets
committed (common in company monorepos), we leak one machine's directory
structure to the team and, worse, force one person's account setup onto
everyone else who opens the project.

Options (need a decision, don't assume which one to use — ask when we get
to this point in the implementation):

1. **Detect whether `.vscode/settings.json` is versioned** (`git check-ignore`)
   before writing. If it is, use `.vscode/settings.json` anyway but warn the
   user, or prefer an alternative.
2. **VS Code multi-root workspace file** (`*.code-workspace`) outside
   version control, with the environment config at the workspace level.
3. **Non-versioned folder-level settings** — check whether VS Code has
   native support for something equivalent to ".env.local" for settings (it
   doesn't natively; it would have to be `.vscode/settings.json` in a local
   `.git/info/exclude`, which is fragile because it doesn't travel with the repo).

Recommendation to validate with the user before implementing: first check
whether the project has `.vscode/` in `.gitignore`; if so, use it normally;
if not, ask the user before writing (don't decide silently).

## Functional requirements

1. Given a project path + a target `CLAUDE_CONFIG_DIR`, write/update
   `.vscode/settings.json` doing a safe merge (JSON parse, not regex).
2. Before writing, check whether `.vscode/settings.json` (or `.vscode/`) is
   under version control and flag it per the risk above.
3. Read the current state (which account a project is using) directly from
   `settings.json`, with no need for another duplicated source of truth.

## Update: `.vscode/settings.json` is now a "derived projection"

Since spec 07 (the `cs` CLI), the source of truth for "which account does
this project use" became `.clauderc` (writes the account's **slug**, not
the path — which is why it's safe to commit). `.vscode/settings.json` keeps
existing and being written by `cs set` (via `VSCodeSettings.setConfigDir`),
but only because Anthropic's official extension requires it — it's always
local, always `.gitignore`d, never the source of truth. The versioning risk
described below remains valid for it specifically.

## Update: why this wasn't enough on its own (and what was missing)

Writing `claudeCode.environmentVariables` into `.vscode/settings.json` never
had any real effect: that setting is declared with `"scope": "machine"` in
the official extension's `package.json`, and settings of that scope can
only be defined in *user*/*remote* settings — VS Code silently ignores any
value in workspace settings. See `specs/03-vscode-extension-patch` for the
fix (`VSCodeExtensionPatcher`/`VSCodeExtensionWatcher`, which changes that
scope to `"window"` in the installed `package.json`). With that fix, the
mechanism described below actually starts working.

## Implemented and validated

`VSCodeSettings.setConfigDir` (in `Sources/ClaudeSCore/VSCodeSettings.swift`)
does the merge via `JSONSerialization` (not regex), always writes
`CLAUDE_CONFIG_DIR` **expanded to an absolute path** (never `~`, because the
process reading the env var doesn't expand `~` on its own — that's the
shell's job, which isn't in the path here). `GitRisk.swift` implements
option 1 listed below (checking `.gitignore`/tracking before writing) —
decision made: always write and warn, never block silently, so as not to
hold up the user's flow over a decision that's theirs to make.

Tested in three scenarios: (a) merge preserving `editor.tabSize` and another
already-existing `claudeCode.environmentVariables` entry, (b) a file with
JSONC comments (loss explicitly warned about), (c) a file already committed
with no `.gitignore` (fires a "WARNING" alert).

**Known limitation**: JSONC comments in the existing `settings.json` are
lost on save (the parser falls back to "strip comments" just to be able to
read it; the final write is always plain JSON). Acceptable for the MVP;
revisit with a real JSONC parser if this becomes annoying in practice.

## Edge cases

- `.vscode/settings.json` with malformed JSON → don't blindly overwrite;
  warn the user and abort the write.
- `claudeCode.environmentVariables` already has other variables besides
  `CLAUDE_CONFIG_DIR` → preserve all of them, only replace the entry with
  `name == "CLAUDE_CONFIG_DIR"`.
- A project with no `.vscode/` folder yet → create it.

## Out of scope

- Any logic to patch the official extension (see `specs/03-vscode-extension-patch`).
