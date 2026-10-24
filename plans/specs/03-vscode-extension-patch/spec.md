# Spec: Official VS Code extension patch

Resolves: P1 (improper account fallback), P13 (incorporating leog's fix)

## Update: a second, more critical problem found later

Besides the `process.env` problem described below, there's a separate and
more fundamental root cause: `claudeCode.environmentVariables` is declared
in the extension's `package.json` with `"scope": "machine"` — per
Microsoft's official documentation, that scope can only be defined in
*user*/*remote* settings, never in *workspace*. VS Code silently ignores
any value for that setting written to a project's `.vscode/settings.json`.
**This was the real reason account switching never had an effect, even with
leog's patch applied and the window reloaded** — confirmed by testing in
real VS Code after changing the scope to `"window"` in the installed
`package.json`.

Unlike the problem below (which requires rewriting minified JS code via
regex), this one is editing a field of a static JSON — **already
implemented**: `VSCodeExtensionPatcher` (`Sources/ClaudeSCore`) and
`VSCodeExtensionWatcher` (`Sources/ClaudeSApp`, reapplies by itself via
`DispatchSource` when the extension updates). See the kanban for the full
summary of the investigation.

## Original problem (resolved — see "Final decision" below)

The `anthropic.claude-code` extension has internal *storage helpers* that
read `process.env.CLAUDE_CONFIG_DIR` directly, while
`claudeCode.environmentVariables` (set via `.vscode/settings.json`, see
spec 02) is only applied to the environment of processes the extension
*launches* (terminal/subprocess), not to the extension's own process
running inside VS Code. Result: the extension could keep reading the wrong
credential (the default `CLAUDE_CONFIG_DIR`'s) even with the correct config
in the project — this is the root cause of the reported "falls back to
personal account" (original P3).

## Original decision: vendor via JavaScriptCore (superseded)

The original decision was to vendor `patch-core.js`/`patch-regexes.js` from
`leog/claude-code-config-dir-patcher-vscode` as JS files and run them via
`JavaScriptCore`. Reason at the time: thinking the logic was too complex to
port without duplicating maintenance.

## Final decision: reimplemented natively in Swift, not vendored

Motivation for the change: the `leog.claude-code-config-dir-patcher`
extension stayed **a whole day out of date** after an official extension
update, leaving the user unable to switch accounts until the author fixed
his patch. Depending on a third party's schedule to react to changes in
Anthropic's bundle isn't acceptable for the app's main flow.

Reading `patch-core.js`/`patch-regexes.js` with that goal in mind: the
logic is just two pure regex transformations on a string (`analyze` +
`applyPatch`/`source.replace`), with no state, no I/O — trivially portable
to `NSRegularExpression` (ICU regex, supports the same backreferences and
capture groups used in the original patterns). The real complexity was all
in the I/O layer around it (retry against reads during an update in
progress, a transient lock when writing), which was also faithfully ported.

**Implemented**: `ClaudeExtensionJSPatcher` (pure logic, a 1:1 port of the
regexes) + `ClaudeExtensionJSPatchRunner` (I/O: locate, read with retry,
backup, write with retry) + `ClaudePatchCoordinator` (combines this patch
with the scope one in a single call, used by `VSCodeExtensionWatcher` and
the "Reapply patch" menu item). Credits and MIT license in
`ATTRIBUTIONS.md` — discovering the regex patterns and the problem itself
is leog's work, even though the implementation is ours.

**Validated**: applying our patch to the original `extension.js` produces
output byte-for-byte identical to leog's patch (the exact same size). Our
`analyze()` correctly recognizes the format his patch had already produced
(read compatibility preserved, useful while the two coexist on the same
machine). Tested end to end via real I/O (restoring the original
`extension.js`/`package.json` and reapplying), including idempotency.

**Consequence**: the `leog.claude-code-config-dir-patcher` extension is no
longer a required dependency — it can be uninstalled. When to do that is
the user's call.

## Update: scope removed, replaced by a third patch ("clauderc")

Reverted decision: the scope patch (`package.json`, `"machine"` →
`"window"`) is no longer applied. Reason — discussed in depth with the user
before deciding: it unlocked the whole `claudeCode.environmentVariables`
setting at the folder/project level, not just `CLAUDE_CONFIG_DIR` — any
per-project config in that setting could then be defined in
`.vscode/settings.json`, a file typically shared/versioned by the team
(see the risk in specs/02). Instead of accepting that risk and just
warning about it, the extension goes back to accepting that setting only
globally (`"machine"`, the original, never-modified behavior) —
`.vscode/settings.json` is never touched by our app for this purpose again
(see specs/02).

In exchange, a third patch (**"clauderc"**) was added to the same
`extension.js`, at the exact point where "env" already acts (the function
that builds the environment object from the setting, before propagating it
into the global `process.env.CLAUDE_CONFIG_DIR`). Before using the
setting's value, that point now first tries to resolve `.clauderc` (walking
up directories from the open workspace folder, via
`vscode.workspace.workspaceFolders` — called directly inside the injected
code itself, with no need for a new parameter at the ~11 places that call
this function) and uses the `claudeCode.environmentVariables` block from
inside it, if present — the same shape the setting already uses, read
directly from the file, with no VS Code API involved. Final priority:
`.clauderc` (per project) → VS Code's global setting → the system's plain
environment variable (the original behavior).

Why a single point is enough (investigated in depth before implementing):
the function that reads the setting is the ONLY one that propagates the
resolved value into `process.env.CLAUDE_CONFIG_DIR` — everything else in
the extension's code (several distinct points, confirmed by reading the
real bundle) only consults that global variable, never the setting
directly. Changing where that single point looks for the value is enough;
there's no need to touch the other points.

**Consequence for `cs`/`AccountResolver`/the panel**: none. Since
per-project config no longer goes through `.vscode/settings.json` at all,
the Swift side of the app still only needs to know about `.clauderc` +
the default account — it didn't need to learn any VS Code format.

**`.clauderc` format change** (see `ClauderFile.swift`): the `account`
field was renamed to `claude_account` (the same naming convention as
`settings.json`), and a new `claudeCode.environmentVariables` field — the
exact same shape as the extension's setting — is written alongside it,
resolved locally on every account switch. No automatic migration of old
files (the user's deliberate decision, the project isn't launched yet):
any `.clauderc` with the old `account` key stops being recognized until
it's rewritten (via `cs set`/the panel, or manually).

## Patch application flow

1. Locate the official extension's installation via
   `VSCodeExtensionLocator.locateExtensionDir()` (glob over
   `~/.vscode/extensions/anthropic.claude-code-*`, keeps the highest
   version if there's more than one). macOS only — doesn't support
   Cursor/other forks nor Windows/Linux.
2. Backup (`extension.js.claudes-js-patch.bak`) before the first write —
   covers all three sub-patches (env/ide/clauderc), a single copy of the
   original file.
3. `ClaudeExtensionJSPatcher.analyze()` decides, per sub-patch, whether it's
   already patched, patchable, or the needle doesn't match (an unrecognized
   version — throws `ClaudeExtensionJSPatchError.envPatchPointNotFound`
   only for "env", the most critical one; "clauderc" with no needle
   recognized simply doesn't get applied, reported as "skipped" — never
   tries an alternative heuristic).
4. If patchable and not yet patched: applies, writes, confirmed idempotent
   in the tests (reapplying changes nothing) — validated against the real
   installed `extension.js` (before/after analysis, syntax check via
   `node --check`, and an isolated semantic test of the injected
   `__claudesResolveAccountEnv` function, mocking
   `vscode.workspace.workspaceFolders`, against 4 scenarios: `.clauderc` at
   the root, `.clauderc` in a folder above the open one, no workspace
   folder open at all, and no `.clauderc` present).
5. Reapplied automatically via `VSCodeExtensionWatcher` (`DispatchSource`
   over `~/.vscode/extensions`, reactive — see specs 02) every time the
   extension updates. The "Reapply Patch to Claude Extension" menu item now
   shows two rows — "`.clauderc` check" and "Env propagation fix" — each
   with a real check against the `extension.js`'s current state, never a
   static flag.

## Compatibility check (avoiding a silent break)

No preventive checker against future builds was implemented (equivalent to
leog's `scripts/check-upstream-patchability.mjs`, which downloads builds
from the Marketplace). Today the failure is visible right away:
`envPatchPointNotFound` throws an explicit error (logged by
`VSCodeExtensionWatcher`, or shown in the "Reapply patch" item's
`NSAlert`), it doesn't fail silently. Consider that preventive checker as a
future improvement, not a blocker.

## Edge cases

- Needle not found (`envPatchable == false` and `envPatched == false`) →
  the official extension's version changed incompatibly — explicit error,
  never an alternative heuristic.
- `extension.js` empty/partial during an update in progress → detected and
  handled with retry/backoff (`ClaudeExtensionJSPatchRunner`), never throws
  in that case (would be a false positive).
- The user restores/reinstalls the official extension → the patch is lost;
  `VSCodeExtensionWatcher` detects the change in the directory and reapplies.
- `extension.js` from a different platform (leog mentions win32 differs
  from the rest) → not relevant, the project is macOS only.

## Out of scope

- Telemetry/Sentry from leog's project — never relevant, not reimplemented.
- Support for Cursor/other VS Code forks, Windows, Linux.
