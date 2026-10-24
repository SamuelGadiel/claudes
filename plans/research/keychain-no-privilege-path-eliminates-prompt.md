# No privilege path eliminates the Keychain prompt

There is no legitimate way, at any layer investigated, for ClaudeS to read
the `Claude Code-credentials` Keychain item (created by Anthropic's
`claude` CLI) without an authorization prompt in a **durable** way: macOS
Keychain Services ties its ACLs to the **requesting process's code-signing
identity** (Designated Requirement/CDHash), a layer orthogonal to the Unix
UID, to `sudo`/root privileges, and to the TCC system — and an Apple DTS
engineer confirmed in writing that trying to use the Keychain to
differentiate root processes "will definitely cause problems"
([Apple Developer Forums #737888](https://developer.apple.com/forums/thread/737888)).
Running as root, creating a privileged LaunchDaemon, migrating the item to
the System Keychain, or declaring any Keychain Sharing entitlement are all
**UNVIABLE** for this scenario, because all of them assume ClaudeS
controls the item or shares Anthropic's Team ID — neither condition is
true, and ClaudeS, being ad-hoc signed, doesn't even have a real Team ID
to put in any entitlement. The only technically functional path outside
the official model — Accessibility-based click automation on the
`SecurityAgent` dialog — isn't an ACL bypass, it's automating the human's
response to the prompt, historically associated with malware techniques
(Patrick Wardle/Objective-See), and replaces N Keychain prompts with one
TCC prompt plus fragility across macOS versions. The documented root cause
of the problem isn't on the reader's side: the `claude` CLI itself
rewrites the item on every OAuth token renewal and, in that rewrite,
discards the granted ACL/partition list — behavior empirically confirmed
in this research and logged as an open bug in the `anthropics/claude-code`
repository (#77697, #81707, #94491). The defensible strategy for ClaudeS
isn't "work around the prompt", it's drastically reducing how often it
directly reads the third-party item, following the pattern already adopted
by analogous tools (CodexBar, Uzzy, Codenotch).

## Privilege, entitlement and the ACL API: every door closes on the same wall

The most intuitive hypothesis — "run with more privilege and the system
lets it through" — doesn't hold up in any variant tested. The "App X wants
to access the key..." prompt is resolved by `securityd` based on the
item's **trusted-application list / partition list**, tied to the calling
binary's Designated Requirement/CDHash, not to the Unix UID running it
([TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html);
[Apple Developer Forums #737888](https://developer.apple.com/forums/thread/737888)).
This means a root daemon different from the process that created the item
is treated exactly like any other unlisted requester — gets the same
prompt, or a silent failure with "user interaction not allowed" when
there's no UI session
([Apple Developer Forums #759976](https://developer.apple.com/forums/thread/759976)).
The only documented exploit that actually read the Keychain with no prompt
even with SIP enabled and ACLs configured was **KeySteal
(CVE-2019-8526)**, a zero-day fixed by Apple in 10.14.4
([LinusHenze/Keysteal](https://github.com/LinusHenze/Keysteal)) — its very
existence as a "security finding" is evidence that, outside of a bug, not
even root gets around the barrier.

Migrating the item to the **System Keychain** (writable only by root)
doesn't help because the item is created and maintained by Anthropic's
CLI, not by ClaudeS: even there, the per-item ACL would still be tied to
`claude`'s code signature, and System Keychain's "no prompt" only applies
to whoever created it or was explicitly listed with `-T` at creation time
([scriptingosx.com](https://scriptingosx.com/2021/04/get-password-from-keychain-in-shell-scripts/)).
`security unlock-keychain` and `security -i` also change nothing: the
first only unlocks the keychain as a whole (equivalent to entering the
login password), and the second is just an execution mode that avoids
exposing the password in `argv`/history — neither touches per-item ACL
evaluation
([keith.github.io man page](https://keith.github.io/xcode-man-pages/security.1.html)).
And running the **whole GUI app as root** has never been supported by
Apple: "There's no supported way to run an app as root, where app is
defined as something with a GUI that the user launches from the Finder" —
the official recommendation is to isolate privileged operations in a
separate helper, keeping the GUI with normal privileges
([Apple Developer Forums #708295](https://developer.apple.com/forums/thread/708295);
[#772674](https://developer.apple.com/forums/thread/772674)).

At the entitlement level, `com.apple.security.keychain-access-groups` and
`com.apple.security.application-groups` only work **between apps of the
same Team ID**, enforced by provisioning profiles signed by Apple itself:
"Keychain items can be shared only between apps from the same developer"
([Keychain Access Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups)).
Since ClaudeS is ad-hoc signed, it doesn't even have a valid Team ID to
declare in that entitlement — the path is doubly closed: Anthropic
wouldn't cooperate, and even if it did, ClaudeS would need a paid
developer account, which contradicts the ad-hoc scenario. In the API, the
`SecTrustedApplication`/`SecAccess`/`SecKeychainItemSetAccess` family that
would let a process insert itself as a trusted app is **deprecated since
macOS 10.15, with no modern replacement**: "There is no direct replacement
for `SecTrustedApplicationCreateFromPath`. The problem is that this entire
concept is deprecated", and even when still functional, "there's no way
for an app from one team to 'donate' a keychain item to an app from
another team... without triggering user authentication" (an Apple DTS
engineer,
[Apple Developer Forums #129911](https://developer.apple.com/forums/thread/129911)).
The `security add-generic-password -T`/`-A` command only sets the trust
list **at the moment a new item is created**; for an already-existing
item, any change via `-U -T` or `set-generic-password-partition-list`
triggers a mandatory password/Touch ID prompt, and this was empirically
reproduced in this research (`SecKeychainItemSetAccess: User canceled the
operation` in a non-interactive context) and confirmed by an identical
real case: a manual workaround with `set-generic-password-partition-list
-S apple-tool:,apple:,teamid:NKUJUXUJ3B` worked once, but "this fix is
overwritten when Claude Code rewrites the credential"
([anthropics/claude-code #81707](https://github.com/anthropics/claude-code/issues/81707)).

## Anthropic's token rewrite is the root cause, not the reader's defense

This research empirically reproduced the exact ACL-reset mechanism on a
Darwin 24.6.0 (macOS Sequoia) machine, and the result contradicts the
community's most common hypothesis: `security add-generic-password -U`
**without** `-T` preserves the ACL/trusted-application list unchanged —
tested directly, with `cdat` (creation date) identical before and after,
confirming an in-place update with no reset. What actually resets the ACL
to "only the creator is trusted" is **deleting and recreating the item**,
or explicitly calling `SecKeychainItemSetAccess` (via `-U -T`, which in
turn requires authorization). This distinction is independently
corroborated by the `99designs/keyring` library (used by Snowflake's Go
driver), whose code contains the literal comment "*Don't call SetAccess()
as this will cause multiple prompts on update*" — meaning its own
maintainers empirically discovered the same pattern and deliberately
avoided calling the ACL API on updates
([snowflakedb/gosnowflake #1847](https://github.com/snowflakedb/gosnowflake/issues/1847)).

Applied to the real `claude` CLI case, two distinct mechanisms (not just
one) explain the recurring prompts documented in the
`anthropics/claude-code` repository. The first, issue **#77697**, shows the
item being rewritten with no trusted-app list: "'Always Allow' does not
help: Claude Code rewrites/recreates the item, and the new item again has
an empty trusted-application list, discarding the granted ACL" —
consistent with a delete+recreate on the write path, not a plain `-U`. The
second, issue **#81707** (closed on 2026-08-15 with no fix confirmed
visible), shows a mechanically different mechanism: the item's own ACL is
permissive (`applications: <any>`, `don't-require-password`), but the
**partition list** — a separate gate, before the ACL evaluation and
invisible in the Keychain Access UI — is pinned to a Team ID that matches
neither the `security` CLI (`apple-tool:`) nor Claude Code's real signing
Team ID (`Q6L2SF6YDW`), blocking every read until the user manually
reapplies `set-generic-password-partition-list`, a grant that "is
overwritten when Claude Code rewrites the credential". A third issue,
**#94491**, reinforces with timestamp evidence that it's an in-place
rewrite (not delete+recreate): `cdat` stays unchanged while `mdat`
changes, and yet the ACL is discarded — suggesting that, in this specific
case, it's the ACL/partition-list call itself (not the data rewrite) that
zeroes out the grant on every refresh. Three open issues (`#77697`,
`#81707`, `#94491`) address exactly this problem with no definitive fix as
of this research's date (2026-10-13), and the most practically impactful
conclusion is: **no mitigation on the reader's side can protect an ACL
grant from being overwritten by the process that actually owns and
rewrites the item** — the only real fix is upstream, in Anthropic's code.

Worth noting that `kSecUseAuthenticationUISkip` (the modern replacement for
`kSecUseAuthenticationUIFail`) doesn't offer a middle ground: it instructs
`SecItemCopyMatching` to fail deterministically with
`errSecInteractionNotAllowed` instead of showing the dialog, but never
returns the secret without authorization — useful for controlling the
failure experience (e.g. not hanging the UI), not for "reading anyway"
([Apple Developer Forums #103380](https://developer.apple.com/forums/thread/103380)).

## Accessibility can automate the click, but it replicates a malware technique

There's an indirect, technically real path today that doesn't change the
ACL but automates the human's response to it: using Accessibility
permission to fire synthetic clicks that press "Always Allow" on the
`SecurityAgent` dialog, via AppleScript/System Events (`tell window 1 of
process "SecurityAgent" to click button "Always Allow" of group 1`,
documented in automation discussions —
[Keyboard Maestro Forum](https://forum.keyboardmaestro.com/t/pressing-the-always-allow-button-on-keychain-permission-dialogs/26903)).
TCC (Accessibility, Apple Events, Full Disk Access) is formally a
permission system **independent** of Keychain Services — there's no
`kTCCService*` equivalent to "Keychain ACL", and granting Full Disk Access
doesn't cover Keychain access
([HackTricks: macOS TCC Credential & Data Theft](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-tcc/macos-tcc-credential-and-data-theft.html))
— so this route isn't a "permission overlap", it's UI automation. Patrick
Wardle (Objective-See) has historically documented that "macOS
accessibility features include the ability to make mouse-clicks without
actually touching the mouse through software", exploited by malware to
click on security dialogs
([Speaker Deck — Wardle](https://speakerdeck.com/patrickwardle/the-mouse-is-mightier-than-the-sword)).
In practice, this doesn't eliminate authorization friction: it turns N
manual Keychain prompts into 1 manual Accessibility (TCC) prompt followed
by automated clicks — and it's structurally fragile, since it depends on
`SecurityAgent` window/process names that Apple can change between macOS
versions, plus the reputational risk of replicating a technique
historically classified as an attack. That's why the classification is
**PARTIALLY VIABLE**: it works today, but it isn't a solid engineering
foundation for a long-term product, and it wasn't empirically validated in
this research against the current macOS Sequoia.

## The industry's winning pattern is avoiding the third-party item, not accessing it

Looking at how real tools solve exactly this problem, a clear pattern of
two groups emerges. Credential managers that **are the origin** of the
secret — `aws-vault` (its own Keychain, temporary credentials via STS,
[99designs/aws-vault](https://github.com/99designs/aws-vault)) and the
`gh` CLI (its own OAuth token under `gh:github.com`,
[cli/cli #13330](https://github.com/cli/cli/issues/13330)) — never need
this problem, because they create and control their own item from the
first write. Third-party observers that **read another program's state**
— the group structurally closest to ClaudeS — converge on minimizing or
eliminating direct touching of the item, instead of trying to beat the
prompt. **Uzzy** reads via `/usr/bin/security find-generic-password`
instead of `SecItemCopyMatching` directly from its own binary, because
that system binary is already in the item's `apple-tool:` partition in
most cases, avoiding a prompt without opening a new access path — the
author himself acknowledges the trade-off: "there is no explicit consent
step anymore... Any process of the user can already read the item this
way; Uzzy does not open a new path"
([aka-cronos/uzzy #89](https://github.com/aka-cronos/uzzy/issues/89)).
**Codenotch** goes further and avoids the Keychain entirely when the local
`claude` CLI responds to a status command equivalent to `claude /usage`,
reserving Keychain reads only for accounts with no CLI installed
([vinzdg/codenotch #129](https://github.com/vinzdg/codenotch/issues/129)).
**CodexBar**, for its part, documented a permanent failure after a token
rotation because it deliberately disabled most interactive prompts
(`allowKeychainPrompt=false`) and started accepting "not found" instead of
repeatedly interrupting the user
([steipete/CodexBar #4257](https://github.com/steipete/CodexBar/issues/4257))
— evidence that even mature apps found no better solution than "tolerate
failure, don't insist on the prompt".

For ClaudeS, the most robust combination the sources support is three
layers: first, prefer — when available — a local `claude` command that
returns status without needing the Keychain, analogous to Codenotch's
`claude /usage`, as the primary source; second, when that path doesn't
exist, read via `/usr/bin/security` (Uzzy's pattern) instead of
`SecItemCopyMatching` in our own binary, since the system binary is
usually pre-authorized; third, cache the result obtained in ClaudeS's
**own** Keychain item (the aws-vault/gh pattern) to reduce how often the
third-party item gets re-read. None of these layers eliminates the prompt
when a read of the original item actually has to happen after an
Anthropic token refresh — that remains outside ClaudeS's control as long
as the upstream bugs (`#77697`, `#81707`, `#94491`) aren't fixed. Anthropic's
official documentation also confirms a plain-text file fallback
(`~/.claude/.credentials.json`, mode `0600`), but it's **automatic**
(activated when the Keychain rejects the write, e.g. over SSH) and not an
option ClaudeS can deliberately force; real issues show this file **not
being consulted preferentially** even when valid, making it a fragile
dependency and, being plain text, readable by any process under the same
UID with no Touch ID/signature verification — a real security regression
([anthropics/claude-code #77697](https://github.com/anthropics/claude-code/issues/77697);
[code.claude.com/docs/en/authentication](https://code.claude.com/docs/en/authentication)).
The documented and stable path to avoid the Keychain entirely is
`claude setup-token` + the `CLAUDE_CODE_OAUTH_TOKEN` variable, but it
solves a different problem (non-interactive authentication with a token
manually generated by the user, valid for 1 year, with no
connectors/scheduling), not reading the state of an already-authenticated
`claude` session via `/login` — which is what ClaudeS needs to observe.

## Consolidated classification table

| Path investigated | Classification | Short justification |
|---|---|---|
| Running the app/daemon as root or with `sudo` | **UNVIABLE** | The ACL is per code signature (CDHash), not per UID; Apple DTS confirms root gets no special treatment ([#737888](https://developer.apple.com/forums/thread/737888)) |
| The whole GUI app as root | **UNVIABLE** | Never supported by Apple; the official recommendation is to isolate privilege in a separate helper ([#708295](https://developer.apple.com/forums/thread/708295)) |
| Privileged LaunchDaemon/XPC + cross-Team-ID Keychain Sharing | **UNVIABLE** | `keychain-access-groups`/App Groups only work within the same Team ID, enforced by an Apple-signed provisioning profile ([entitlement doc](https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups)) |
| Keychain Sharing entitlement with Anthropic's cooperation | **UNVIABLE** | Would require a real Team ID (ClaudeS is ad-hoc) and Anthropic's explicit cooperation, which won't happen |
| `SecTrustedApplication`/`SecAccess`/`SecKeychainItemSetAccess` API for self-registration | **UNVIABLE** | Deprecated since macOS 10.15 with no replacement; even if functional, any cross-identity ACL change requires user authentication ([#129911](https://developer.apple.com/forums/thread/129911)) |
| `security -U -T` or `set-generic-password-partition-list` on an already-existing item | **UNVIABLE** (no prompt) | Empirically reproduced: triggers `SecKeychainItemSetAccess`, which requires authorization; the grant is ephemeral because Anthropic rewrites the item |
| `security -T` when **creating** a new item (ClaudeS's own) | **VIABLE** | Works with no subsequent prompt, but only applies to an item ClaudeS itself creates and controls, not Anthropic's item |
| `kSecUseAuthenticationUISkip`/`Fail` | **UNVIABLE** (as a bypass) | Avoids the dialog but fails with `errSecInteractionNotAllowed` instead of returning the secret — not a silent read |
| Migrating/reading via the System Keychain | **UNVIABLE** (in this scenario) | Would only solve it if ClaudeS controlled the item's creation; since Anthropic is the one writing it, the per-item ACL stays tied to it |
| `security unlock-keychain` / `security -i` | **UNVIABLE** | Only affects the whole keychain's locked/unlocked state, not the per-item ACL |
| Accessibility/TCC — formal overlap with the Keychain's ACL | **UNVIABLE** | Fully independent permission systems; no `kTCCService*` covers "Keychain ACL" |
| Accessibility — synthetic click automating "Always Allow" | **PARTIALLY VIABLE** | Technically functional today, but shifts the prompt (1 TCC approval + automation), is fragile across macOS versions, and replicates a historical malware technique (Wardle) |
| `~/.claude/.credentials.json` fallback (plain text) | **PARTIALLY VIABLE, not recommended** | Exists but is automatic/not forceable on demand, proven inconsistent in precedence, and exposes the token with no Touch ID/signature verification |
| `claude setup-token` + `CLAUDE_CODE_OAUTH_TOKEN` | **VIABLE, but solves a different problem** | Documented and stable, but requires a token manually generated and pasted by the user (1 year, no connectors/scheduling) — not a read of an already-authenticated `claude` session |
| Reading via `/usr/bin/security` instead of our own binary (Uzzy's pattern) | **PARTIALLY VIABLE** | Avoids the prompt in practice because the system binary is already in `apple-tool:`, but isn't controlled by ClaudeS and may stop working if the partition list changes |
| Preferring a local status CLI over the Keychain (Codenotch's pattern) | **PARTIALLY VIABLE** | Eliminates the need to read at the source when available, but depends on the CLI being installed and maintaining that undocumented output contract |
| ClaudeS's own Keychain item as a cache (aws-vault/gh pattern) | **PARTIALLY VIABLE** | Reduces how often the third-party item is read, but doesn't eliminate the prompt when a real read of the original item happens after a token refresh |
| Contributing an upstream fix in `anthropics/claude-code` | **VIABLE in the medium term, outside immediate control** | The only fix that would resolve the root cause; there are already 3 open issues (#77697, #81707, #94491) with no confirmed fix as of 2026-10-13 |

## Conclusion

The search for a configuration — privilege, entitlement or API — that
makes reading Anthropic's item silent and permanent is, by Apple's design,
closed: every path tested reduces to zero the difference between "ClaudeS
reads with sudo" and "ClaudeS reads without sudo", because the trust
evaluation never looks at the UID. This research's most actionable insight
isn't a bypass technique, but pinpointing the exact root cause: the
`claude` CLI rewriting the item on every token refresh (empirically
confirmed as either a delete+recreate or an explicit `SetAccess`/
partition-list call, never a plain `-U`) is what tears down any ACL grant,
and that's a behavior in Anthropic's code, not a design gap ClaudeS can
compensate for on the reader's side. This reframes the problem from "how
to read with no prompt" to "how to minimize how many times the real read
has to happen" — via a local CLI as the primary source (Codenotch), a read
through `/usr/bin/security` when the CLI isn't available (Uzzy), and a
cache in our own Keychain item (aws-vault/gh) — combined with reporting or
following the open issues in the `anthropics/claude-code` repository
(#77697, #81707, #94491), since the only structural fix depends on
Anthropic stopping the ACL/partition list reset on every renewal.
