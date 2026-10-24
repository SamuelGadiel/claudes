# Alternative strategies to read another process's credentials on macOS with no repeated Keychain prompts

## kSecUseAuthenticationUI: `Allow` vs `Skip` vs `Fail` — exact effect on SecItemCopyMatching

### Takeaway
`kSecUseAuthenticationUISkip` (and the old equivalent,
`kSecUseAuthenticationUIFail`) isn't a way to "read with no
authorization": it's a mode to fail deterministically, with no dialog,
exactly when the read would require user interaction. The Security
framework has no third mode that reads the secret with no authorization
and no error — the key question's hypothesis is correct.

### Cited Findings
- `kSecUseAuthenticationUI` accepts three possible values:
  `kSecUseAuthenticationUIAllow`, `kSecUseAuthenticationUIFail`
  (deprecated) and `kSecUseAuthenticationUISkip` —
  [developer.apple.com/documentation/security/ksecuseauthenticationui](https://developer.apple.com/documentation/security/ksecuseauthenticationui)
  (the official page exists and was located; WebFetch couldn't render the
  page body — probably JS-rendered — so the full text couldn't be
  literally quoted from this primary source).
- `kSecUseAuthenticationUISkip` instructs Keychain Services to **skip/
  ignore items that would require an authentication prompt** instead of
  showing the dialog —
  [swift-keychain-kit issue #2](https://github.com/sinoru/swift-keychain-kit/issues/2);
  confirmed by a search synthesis about the official doc —
  [WebSearch summary citing developer.apple.com](https://developer.apple.com/documentation/security/ksecuseauthenticationui).
- `kSecUseAuthenticationUISkip` is accepted by `SecItemCopyMatching`, but
  is **rejected with `errSecParam`** by `SecItemUpdate`/`SecItemDelete` —
  [Apple Developer Forums thread #103380](https://developer.apple.com/forums/thread/103380).
- `kSecUseAuthenticationUIFail` is the older/deprecated form of the same
  behavior (failing instead of prompting); recent third-party library PRs
  explicitly migrate from `Fail` to `Skip` because `Fail` is deprecated —
  [tonypine/job-search-hub PR #19](https://github.com/tonypine/job-search-hub/pull/19).
- With no `kSecUseAuthenticationUIFail`/`Skip`, the default behavior
  (`Allow`) is blocking: the system shows the authentication dialog and
  the `SecItemCopyMatching` call hangs until the user responds —
  [Apple Developer Forums thread #103380](https://developer.apple.com/forums/thread/103380).

### Inferences
- For ClaudeS's case: if the `Claude Code-credentials` item requires
  authentication (because the ACL/partition list doesn't cover the
  calling process), using `kSecUseAuthenticationUISkip` would avoid the
  prompt, but the read would return `errSecInteractionNotAllowed` (or
  equivalent) instead of the secret — i.e., the app would have to handle
  "no access right now", not "access silently obtained". This is
  consistent with the pattern observed in the third-party apps researched
  below (CodexBar, Uzzy, Codenotch), all of which report exactly this
  failure behavior when trying to avoid the prompt.

### Gaps
- It wasn't possible to extract the literal text from Apple's official
  page (JS rendering blocked WebFetch); the confirmation comes from
  mutually consistent secondary sources (Apple's own forums and
  third-party library issues), not the verbatim primary text.

---

## A privileged daemon (LaunchDaemon) + XPC + Keychain Sharing — does it work between apps from different developers?

### Takeaway
Keychain Sharing via `keychain-access-groups` only works **within the
same Team ID** (all apps signed by the same developer certificate). Since
the `Claude Code-credentials` item is written by the `claude` process
signed by Anthropic (its own Team ID, confirmed in the issues below), a
LaunchDaemon/XPC from a different Team ID (ClaudeS's) **doesn't
automatically gain access** through this mechanism — the item's ACL
remains the decisive factor, not the XPC architecture.

### Cited Findings
- "Sharing is restricted to a single development team — apps from
  different developer teams cannot share keychain items through access
  groups. Access groups are prefixed by your team identifier" —
  [Sybr Consulting, iOS Keychain Access Groups: Security Implications and Best Practices](https://sybr.ca/ios-keychain-access-groups-security-implications-and-best-practices/).
- The access group is built with the `$(AppIdentifierPrefix)` prefix,
  which resolves at signing time to the Team ID; the same
  `AppIdentifierPrefix` needs to match between the app and the
  extension/daemon to share —
  [swift-security-skill, keychain-sharing.md](https://github.com/ivan-magda/swift-security-skill/blob/main/swift-security-expert/references/keychain-sharing.md).
- When the two sides don't share the same Team ID, every keychain write
  fails with `errSecMissingEntitlement` —
  [swift-security-skill, keychain-sharing.md](https://github.com/ivan-magda/swift-security-skill/blob/main/swift-security-expert/references/keychain-sharing.md);
  a documented real case
  [opencarwings-ios PR #1 "Fix keychain sharing for builds signed by a different team"](https://github.com/developerfromjokela/opencarwings-ios/pull/1).
- The real `Claude Code-credentials` item on macOS has its Team ID
  recorded in the ACL's **partition list** (not the classic iOS access
  group), and real community issues show two different Team IDs involved
  depending on the build (standalone CLI vs. the Claude Desktop sidecar):
  `Q6L2SF6YDW` (Developer ID Application: Anthropic PBC, the signed
  binary) and `NKUJUXUJ3B` appearing in the partition list the item
  records —
  [anthropics/claude-code issue #81707](https://github.com/anthropics/claude-code/issues/81707).
  This shows that even within Anthropic itself there's partition-list
  inconsistency between builds, which makes the scenario even more closed
  for a third party.
- Real third-party tools (CodexBar, Uzzy, Codenotch) found the item gets
  recreated/rewritten by the `claude`/`security` CLI on every token
  refresh, resetting the partition list to only
  `teamid:<Anthropic's or another team>` or `apple-tool:` — never
  including the third-party app's Team ID —
  [anthropics/claude-code #77697](https://github.com/anthropics/claude-code/issues/77697),
  [steipete/CodexBar #4257](https://github.com/steipete/CodexBar/issues/4257),
  [aka-cronos/uzzy #89](https://github.com/aka-cronos/uzzy/issues/89),
  [vinzdg/codenotch #129](https://github.com/vinzdg/codenotch/issues/129),
  [anthropics/claude-code #87348](https://github.com/anthropics/claude-code/issues/87348).

### Inferences
- A ClaudeS-owned LaunchDaemon/XPC wouldn't fix the underlying problem:
  the barrier isn't "ClaudeS doesn't have a privileged daemon", it's "the
  item belongs to Anthropic's Team ID and its ACL/partition list doesn't
  (stably) include either ClaudeS's Team ID or `apple-tool:` persistently".
  A root daemon doesn't work around this — keychain authorization by Team
  ID is "same-team" by design, not "root privilege beats app ACL".
- The only exploit observed in practice that **actually** avoids the
  prompt (not a daemon, but a distinct technique) is reading the item
  through the `/usr/bin/security` binary, which is already listed in the
  item's `apple-tool:` ACL/partition in most cases — see the uzzy issue
  below. This isn't "keychain sharing" in the formal sense, it's "using a
  reader the item already authorizes".

### Gaps
- I found no official Apple documentation specifically addressing
  LaunchDaemon + XPC as a formal "keychain sharing" vector (this pattern
  typically exists for App Groups/extensions within the same app, not for
  third-party privileged brokers); the conclusion above is inferred from
  the access-group/Team-ID rules, which are the same regardless of
  whether the process is a daemon or a foreground app.

**Classification: UNVIABLE** (when the item belongs to a different Team
ID, as is the case here — Anthropic vs. ClaudeS).

---

## Does the `claude` CLI have an alternative, documented and configurable storage mode besides the Keychain?

### Takeaway
There's a fallback to a text file (`~/.claude/.credentials.json`, mode
`0600`) but it's **automatic fallback behavior** (activated when the
Keychain rejects the write, e.g. over SSH), not a configurable option the
user or a third-party app can deliberately force to avoid the Keychain in
normal use. There's no `CLAUDE_CODE_USE_KEYCHAIN` environment variable or
documented equivalent. And, critically, real issues show this file **isn't
reliable as a bypass strategy**: the Keychain keeps getting recreated and
takes precedence, making the file stale/obsolete.

### Cited Findings
- Official documentation (code.claude.com/docs/en/authentication,
  "Credential management" section): "On macOS, credentials are stored in
  the encrypted macOS Keychain. When the Keychain rejects the write, such
  as when it's locked in an SSH session, Claude Code stores your login in
  `~/.claude/.credentials.json` with file mode `0600` instead, the same
  storage it uses on Linux." —
  [code.claude.com/docs/en/authentication](https://code.claude.com/docs/en/authentication).
- The same page documents `CLAUDE_CONFIG_DIR`: "If you've set the
  `CLAUDE_CONFIG_DIR` environment variable, Claude Code keeps the
  `.credentials.json` file under that directory instead, including the
  file the macOS fallback writes, and keys the macOS Keychain entry to
  that directory too" —
  [code.claude.com/docs/en/authentication](https://code.claude.com/docs/en/authentication).
  This is a way to have *multiple* accounts/credentials, not a way to
  disable the Keychain for the default account.
- There's no mention, in the official authentication doc, of a flag/
  variable to force plain-text mode on macOS outside the automatic
  SSH/lock fallback. The doc also doesn't mention
  `CLAUDE_CODE_USE_KEYCHAIN`.
- There's an official, documented mechanism to completely avoid reading
  the Keychain in non-interactive scenarios: `claude setup-token`
  generates a long-lived (1-year) OAuth token the user manually exports
  as `CLAUDE_CODE_OAUTH_TOKEN`; the doc explicitly states this command
  "does not save the token anywhere; copy it and set it as the
  `CLAUDE_CODE_OAUTH_TOKEN` environment variable" —
  [code.claude.com/docs/en/authentication](https://code.claude.com/docs/en/authentication).
  This bypasses the Keychain, but requires the user to manually generate
  and paste the token into a location ClaudeS trusts (mechanism "b" in
  the industry-patterns section below), it isn't a read of the CLI's
  storage.
- There's also `apiKeyHelper`, a shell script configurable via settings
  that returns an API key — another documented way to supply credentials
  with no touching the CLI's Keychain, but aimed at an API key, not the
  subscription OAuth token —
  [code.claude.com/docs/en/authentication](https://code.claude.com/docs/en/authentication).
- A real issue confirms that, in practice, the `.credentials.json` file
  **isn't consulted preferentially** over the Keychain on macOS, even
  when valid: "With a valid credentials file in place, the keychain item
  was deleted. Claude Code recreated it on its own (fresh `cdat`), again
  with no trusted-application list, and prompting resumed. The file is
  not consulted in preference to the keychain, contrary to what several
  community workarounds assume." —
  [anthropics/claude-code issue #77697](https://github.com/anthropics/claude-code/issues/77697).
- Another issue shows the opposite also breaking: a stale
  `.credentials.json` "wins" over a valid Keychain in certain conditions,
  i.e., the precedence behavior is unstable/contradictory between
  reports —
  [edonadei/caliper issue #180](https://github.com/edonadei/caliper/issues/180)
  *(not verified via `gh`; treat as unconfirmed, see Gaps)*.
- An issue shows another risk of the text file: setting
  `CLAUDE_CODE_OAUTH_TOKEN` can, in some builds, trigger silently deleting
  the Keychain entry when the process exits, due to a "cleanup" logic in
  the backend combiner (primary Keychain → plain-text fallback) —
  [anthropics/claude-code issue #37512](https://github.com/anthropics/claude-code/issues/37512)
  (a secondary source/the issue author's reverse engineering, not
  confirmed as a bug Anthropic acknowledges).

### Risks (a technical analysis of the risks of having the token in plain text)
- `~/.claude/.credentials.json` with mode `0600` restricts reading to the
  owning UID via POSIX permissions — but **any process running under
  that same UID** (i.e., any app, script, or malware the user runs, with
  no sandboxing and with no additional system authorization required)
  can read the file directly with a simple `open()`/`read()` call.
  There's no prompt, no Touch ID/Face ID, no code-signature verification
  of the reading process — unlike the Keychain, which (when the ACL is
  correct) validates the calling process's identity/signature before
  releasing the secret.
- Compared to the Keychain, which encrypts the item at rest and ties
  unlocking to the user's login session (or Touch ID/Face ID when
  configured), the plain-text file on disk is readable immediately after
  the user logs in, with no dependency on the Keychain being unlocked —
  this eliminates a defense-in-depth layer (e.g. a disk mounted by
  another process, a backup including this plain-text file, sync/
  indexing tools accidentally capturing the content).
- This is exactly the same risk model already used by the Linux fallback
  and macOS's SSH fallback — i.e., not a hypothetical risk, it's the real
  model already in production for those scenarios, officially documented
  by Anthropic itself.

### Inferences
- For ClaudeS: there's no "official, supported, stable mode" to
  deliberately read another `claude` session's state via the plain-text
  file, outside the automatic fallbacks (SSH/lock) or the manual
  `setup-token` flow. Depending on the `.credentials.json` fallback would
  mean depending on behavior *not documented as a stable contract* and,
  per the issues, **actively inconsistent/broken** (not consulted with
  priority; can go stale; there are reports of the Keychain item being
  unexpectedly deleted).

### Gaps
- I found no changelog/release notes for the `@anthropic-ai/claude-code`
  npm package explicitly mentioning a behavior change in the macOS
  credential fallback (I didn't get to open the repository's
  CHANGELOG.md directly due to time/call-budget constraints).
- `edonadei/caliper #180` wasn't verified via `gh` (only via a search
  summary); treat as an unconfirmed lead, not a fact.
- There's no official Anthropic confirmation (changelog, doc, or
  maintainer reply) about the bug reported in `#37512` (the Keychain item
  getting deleted when using `CLAUDE_CODE_OAUTH_TOKEN`) — it's a user
  issue with the author's own reverse-engineering analysis, not an
  Anthropic confirmation.

**Classification: PARTIALLY VIABLE, and not recommended.** The file
fallback exists and is real, but (1) it isn't documented as an on-demand-
activatable mechanism for this purpose, (2) it's demonstrably unstable
regarding Keychain-vs-file precedence in the community's issues, and (3)
it introduces the plain-text exposure risk described above. The
documented, stable path to avoid the Keychain is `claude setup-token` +
`CLAUDE_CODE_OAUTH_TOKEN`, but that's a credential *generated and
manually pasted by the user*, not a read of an already-logged-in
`claude` interactive session's storage — i.e., it solves a different
problem (non-interactive auth), not ClaudeS's problem (observing the
status of a session already authenticated via `/login`).

---

## How do other popular macOS tools handle this in practice?

### Takeaway
The dominant pattern among real apps that need Claude Code's status/usage
(CodexBar, Uzzy, Codenotch) is pattern (c) described in the key question:
using a path that **avoids touching the Keychain** whenever a functional
alternative exists (the local `claude /usage` CLI, or a read via
`/usr/bin/security`, which is already on the item's ACL), and treating the
Keychain as a last resort or secondary source — not (a) "accept the
prompt as a normal cost" nor (b) "duplicate the credential in the user's
own pasted item". "Serious" credential tools like aws-vault and gh, on the
other hand, solve the problem at the root because they **are the
credential's origin**: they create their own item from the start, with
their own ACL, instead of reading another process's item.

### Cited Findings
- **CodexBar** (a menu bar app showing Claude Code's usage) has an
  explicit-consent model (`"Allow reading Claude Code's credentials"`,
  its own toggle) and a configurable "prompt mode" (`always`, etc.), but
  still reports a permanent failure after an Anthropic token rotation
  because every internal call site passes `allowKeychainPrompt=false` —
  i.e., the app itself deliberately disabled most interactive prompts and
  accepts failing/"not found" instead of repeatedly interrupting the
  user —
  [steipete/CodexBar issue #4257](https://github.com/steipete/CodexBar/issues/4257).
- **Uzzy** documented that the prompt reappears because the item's
  *partition list* gets reset by the Claude CLI on every token refresh,
  and proposed as a fix reading the item via
  `/usr/bin/security find-generic-password` — already in the item's
  `apple-tool:` partition and therefore triggering no prompt — instead of
  reading via `SecItemCopyMatching` directly from the app's own binary
  (which would require being on the ACL/partition, something Anthropic
  constantly resets). The author is explicit about the trade-off: "there
  is no explicit consent step anymore... Any process of the user can
  already read the item this way; Uzzy does not open a new path." —
  [aka-cronos/uzzy issue #89](https://github.com/aka-cronos/uzzy/issues/89).
- **Codenotch** went further: the requested fix isn't about the
  Keychain, it's about **avoiding the Keychain entirely** when the local
  `claude` CLI answers `claude /usage` — in that case the app uses the
  CLI as the source of truth and doesn't even try to read/renew via the
  Keychain for that account, eliminating the prompt at the source. It
  keeps the Keychain path only as a fallback for accounts with no CLI
  installed (e.g. Claude Desktop only) —
  [vinzdg/codenotch issue #129](https://github.com/vinzdg/codenotch/issues/129).
- **aws-vault**: doesn't read another process's credential — it **is**
  the primary storage. Long-lived IAM credentials are kept in its own
  Keychain (customizable, including a dedicated keychain separate from
  the login one), and aws-vault generates temporary credentials via STS
  (`GetSessionToken`/`AssumeRole`) that it exposes to the shell/apps —
  never reading a keychain item created by another third-party
  application —
  [99designs/aws-vault README](https://github.com/99designs/aws-vault),
  [tekumara notes/macos-keychain.md](https://github.com/tekumara/notes/blob/main/macos-keychain.md).
- **gh (GitHub CLI)**: stores its own OAuth token (`gho_*`) in the macOS
  Keychain (or libsecret/Secret Service on Linux, Wincred on Windows),
  also being the origin/creator of the item, not a reader of a
  third-party credential —
  [x-cmd.com/pkg/gh](https://www.x-cmd.com/pkg/gh/), confirmed by an issue
  about the lack of a visible indication of the item: "gh stores its
  OAuth token (gho_*) silently in the system Keychain under
  gh:github.com" —
  [cli/cli issue #13330](https://github.com/cli/cli/issues/13330).
- Extensions/third parties that want `gh`'s token use the official
  `gh auth token` command, which prints the token via stdout — a
  **documented exposing command**, analogous to Claude Code's
  `claude setup-token`/`apiKeyHelper`, instead of reading the Keychain
  item directly —
  [linuxcommandlibrary.com/man/gh-auth](https://linuxcommandlibrary.com/man/gh-auth);
  a risk the community itself acknowledges: "gh extension install runs
  someone else's Go program with your gh credentials in scope and should
  be vetted like any dependency" —
  [honnibal.dev, Restricting Coding Agents' CLI GitHub Write Access](https://honnibal.dev/blog/locking-down-gh).
- On Linux, when no keyring (Secret Service) is available, `gh` itself
  admits plain text and explicitly warns the user: the message
  "Authentication credentials saved in plain text" —
  [GitHub discussion #8980](https://github.com/cli/cli/discussions/8980)
  (see the reliability note below).
- A Raycast extension pattern: they generally use their own OAuth flow or
  a PAT pasted by the user, stored in the app/extension's own Keychain
  (pattern "b" in the key question) — "Raycast extensions communicate
  with third party services directly through OAuth protocol or personal
  access tokens, with credentials stored securely in your Keychain" —
  [raycast.com/faq](https://www.raycast.com/faq); a concrete example: the
  "Password Store" extension lets you save in the macOS Keychain or
  inside the extension itself —
  [raycast.com/afok/password-store](https://www.raycast.com/afok/password-store).

### Inferences
- In practice there are **two distinct groups** of tools, with
  correspondingly different strategies: (1) credential managers that *are
  the source* (aws-vault, gh, Raycast extensions with their own OAuth) —
  pattern (b), they create and control their own item from creation,
  never needing to read another program's item; (2) third-party
  observers that *read another program's state* (CodexBar, Uzzy,
  Codenotch — the group closest to ClaudeS's case) — none of these
  accept (a) "normal cost"; all converge on minimizing/eliminating the
  need to touch the other program's item, preferring an exposing CLI/
  command when available, and treating a direct read of a third party's
  Keychain as a fragile last resort subject to recurring prompts that
  can't be durably eliminated on the reading app's side.
- For ClaudeS, the strongest precedent is Codenotch: if the `claude` CLI
  is installed and answers a status-read command (equivalent to
  `claude /usage`), preferring that path over the Keychain eliminates the
  prompt at the root, at the cost of depending on the CLI being
  installed/functional and maintaining that command-output "contract"
  (not officially documented, but observable).

### Gaps
- The content of GitHub discussion #8980 was obtained via WebFetch (an AI
  summary of the page), not verified line by line like the issues I
  confirmed via `gh issue view`; treat the quote about "Authentication
  credentials saved in plain text" as plausible but not audited as
  rigorously as the others.
- I didn't investigate the specific case of the 1Password CLI (`op`) nor
  VS Code extensions sharing authentication (e.g. the GitHub Pull
  Requests extension reading `gh`'s token) due to call budget — both
  remain a gap. Based on the general pattern observed, the (unconfirmed)
  expectation is that they follow the same (b)/exposing-command pattern,
  but that's inference, not a cited fact.

---

## Viability of ClaudeS creating its own Keychain item to cache status

### Takeaway
It's a technically sound strategy aligned with pattern (b) observed in
the industry (aws-vault, gh, Raycast with their own OAuth) — it reduces
how often the third-party item is read — but doesn't eliminate the prompt
when a read of the original item actually has to happen, exactly as the
key question itself anticipates. It also doesn't solve the root cause
observed in the real issues (Anthropic rewrites/resets the item's
ACL/partition list on every token refresh), so the prompt can return
every few hours regardless of the cache.

### Cited Findings
- The pattern of an app's own Keychain item, created by the app from the
  start with ACL/trusted-application controlled by it, is exactly what
  apps like aws-vault and Raycast extensions do with their own secrets —
  [99designs/aws-vault](https://github.com/99designs/aws-vault),
  [raycast.com/afok/password-store](https://www.raycast.com/afok/password-store).
  An item created this way, with `-T` pointing at the app itself, doesn't
  suffer the problem reported in Claude Code's issues, because the writer
  and the reader are the same application/Team ID — consistent with the
  `keychain-access-groups` (same Team ID) explanation cited above.
- In the real issues (CodexBar, Uzzy, Codenotch), the source of the
  recurring prompt isn't a lack of caching — it's the fact that, whenever
  a real read of the `Claude Code-credentials` item happens, its
  ACL/partition list may have already been reset by the last rewrite the
  `claude`/sidecar did —
  [anthropics/claude-code #77697](https://github.com/anthropics/claude-code/issues/77697),
  [#81707](https://github.com/anthropics/claude-code/issues/81707),
  [#87348](https://github.com/anthropics/claude-code/issues/87348). A
  ClaudeS cache would reduce how often that read actually happens, but
  every read that happens after an Anthropic token refresh is still
  subject to the same prompt risk.
- Codenotch shows a concrete way to drastically reduce the need to read
  the Keychain: using the local `claude` CLI (when present) as the
  primary source of status, reserving the Keychain read only for accounts
  with no CLI installed —
  [vinzdg/codenotch #129](https://github.com/vinzdg/codenotch/issues/129).
  This complements caching in its own Keychain item: first avoid the
  read, then cache whatever result is obtained.

### Inferences
- For ClaudeS, the most robust combination observed in the research would
  be: (1) prefer, when available, a local `claude` command/CLI that
  returns status without needing the Keychain (analogous to Codenotch's
  `claude /usage`) as the primary source; (2) when that path doesn't
  exist or fails, cache the result obtained from the Keychain in
  ClaudeS's own item (its own Team ID, ACL controlled from creation) so
  as not to need to reread the third-party item on every poll; (3)
  explicitly accept, and communicate to the user, that the periodic,
  unavoidable read of Anthropic's original item will keep being subject
  to a prompt whenever its ACL/partition list is reset by a token
  refresh — behavior outside ClaudeS's control, documented as an open,
  unfixed bug in several reports (`#77697` open, `#87348` open) as of
  this research's date (2026-10-13).

### Gaps
- I found no third-party report of having implemented and publicly
  confirmed the specific "cache in own Keychain item" pattern for the
  Claude Code case (CodexBar, Uzzy and Codenotch describe the problem and
  propose fixes in their own repositories, but don't explicitly document
  having adopted an "own cache item" as an already-deployed solution) —
  the recommendation above is an inference by analogy with the general
  industry pattern (aws-vault/gh), not direct confirmation that this
  specific combination already proven works for the
  `Claude Code-credentials` item.

**Classification: PARTIALLY VIABLE.** It reduces frequency/exposure and
would be good practice anyway (less coupling to the third party's
Keychain timing), but doesn't eliminate the recurring prompt's root
cause, which lies in how Anthropic itself rewrites the item's
ACL/partition list on every token refresh — a problem outside ClaudeS's
control until there's an official fix (see open issues `#77697` and
`#87348`).
