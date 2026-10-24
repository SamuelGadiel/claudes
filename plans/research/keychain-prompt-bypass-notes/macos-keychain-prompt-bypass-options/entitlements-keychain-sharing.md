# Entitlements & Keychain Sharing Across Different Apple Developer Team IDs

## What is the Keychain sharing entitlement (keychain-access-groups / application-groups), and does it allow sharing between DIFFERENT Team IDs with no cooperation from the other developer?

### Takeaway
**UNVIABLE.** Both the `keychain-access-groups` entitlement
(`com.apple.security.keychain-access-groups`) and
`com.apple.security.application-groups` (App Groups) only work between
apps signed by the **same Team ID** (the same Apple developer account),
and this is enforced by provisioning profiles signed by Apple itself.
There's no entitlement mechanism that lets Team ID B gain access to a
keychain group belonging to Team ID A without A explicitly including B in
a provisioning profile/entitlement controlled by A. Since Anthropic won't
do this for ClaudeS, this path is closed regardless of any configuration
on ClaudeS's side.

### Cited Findings
- "Keychain items can be shared only between apps from the same
  developer." —
  [Keychain Access Groups Entitlement — Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups)
- "An app's effective keychain access group list is formed by
  concatenating the list from the `keychain-access-groups` entitlement
  (if any), the value of the `application-identifier` entitlement, and
  the list from the `com.apple.security.application-groups` entitlement
  (if any)" — all three components of this list are derived from
  entitlements signed under the **same** Team ID/provisioning profile —
  [Keychain Access Groups Entitlement — Apple Developer Documentation](https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups)
- "The system constructs a virtual array of access groups for each app
  by concatenating keychain access groups from the
  `keychain-access-groups` entitlement and the application identifier,
  which is automatically generated as `TeamID.BundleID`... The Team ID
  prefix on every group identifier, enforced through code-signed
  provisioning profiles, prevents cross-team access." —
  [Sharing access to keychain items among a collection of apps — Apple Developer Documentation](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
  (via aggregated research; the source page is confirmed but the content
  was extracted from a search cache, see Gaps)
- "The `com.apple.security.application-groups` entitlement allows access
  to group containers that are shared among multiple apps **produced by
  a single development team**." —
  [Enabling App Sandbox — Apple Developer Documentation (Entitlement Key Reference)](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)
- "Third-party apps use access groups with a prefix allocated to them
  through the Apple Developer Program in their application groups" —
  confirming the group prefix is issued by Apple to the developer
  account, it isn't something another developer could simply claim —
  [Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- In the GitHub issue about Claude Code itself (#77697), a comment notes
  that the Nextcloud Desktop Client (Team ID `NKUJUXUJ3B`, different from
  Claude Code's Team ID `Q6L2SF6YDW`) managed to **overwrite** (not
  silently read via ACL) the `Claude Code-credentials` item by resetting
  its partition list — but this happened due to an **account/service
  name collision in the legacy file-based keychain**, not access-group
  sharing. This is a design flaw of the legacy item (any process with
  write access to the keychain can try to write an item with the same
  `-s`/`-a`), not an authorized silent-read mechanism —
  [macOS: Keychain item written without trusted-application list → auth prompt on every credential read · Issue #77697](https://github.com/anthropics/claude-code/issues/77697)

### Inferences
- Since ClaudeS is ad-hoc signed (no Developer ID, so no real Team ID
  issued by Apple), it wouldn't even have a valid Team ID to put in any
  access-group entitlement — this closes this path doubly: (1) Anthropic
  wouldn't cooperate, and (2) even if it did, ClaudeS would need a paid
  Team ID and a provisioning profile, which contradicts the ad-hoc
  signing scenario.
- The Nextcloud case shows an opposite and relevant risk vector for the
  project: any app with write access to the legacy keychain can
  **corrupt** (reset the partition list of) the `claude` CLI's item by
  name collision, even without being "trusted". This is a threat to
  mitigate, not a solution to exploit.

### Gaps
- It wasn't possible to fetch the full body of the official "Sharing
  access to keychain items among a collection of apps" page (WebFetch
  only returned the page title, apparently due to Apple's site blocking
  client-side rendering); the quote was reconstructed from the search
  engine's aggregated snippet, which cites the page as the source. Manual
  browser verification is recommended to confirm the exact text, though
  the content is consistent with the other official pages cited
  (Keychain Access Groups Entitlement, App Groups) that were successfully
  obtained.

## Is there an API (SecAccess/SecTrustedApplication/SecKeychainItemSetAccess or a modern equivalent) that lets a process add itself as a trusted app to an already-existing item, programmatically, with no prompt?

### Takeaway
**UNVIABLE by design.** The API family that allowed manipulating a
keychain item's ACL (`SecTrustedApplication`, `SecAccess`,
`SecKeychainItemSetAccess`) has been **deprecated since macOS 10.15**
with no modern replacement — Apple officially confirms the whole concept
was abandoned. Even when these APIs still work (legacy code), modifying
an item's ACL to include a new trusted application **always** triggers
user authentication when the requesting application isn't the one that
already holds modification rights — there's no condition (even being the
original "creator", in a cross-Team-ID case) that lets a process from
another Team ID silently self-insert.

### Cited Findings
- "There is no direct replacement for
  `SecTrustedApplicationCreateFromPath`. The problem is that this entire
  concept is deprecated." — a quote from Apple DTS engineer Quinn "The
  Eskimo!" on the official forum —
  [SecTrustedApplicationCreateFromPath replacement — Apple Developer Forums](https://developer.apple.com/forums/thread/129911)
- "In recent macOS releases, there's no way for an app from one team to
  'donate' a keychain item to an app from another team, or the system,
  without triggering user authentication." — same thread, same source —
  [Apple Developer Forums — thread 129911](https://developer.apple.com/forums/thread/129911)
- An alternative mentioned in the same thread: creating a `SecAccess`
  with a null `trustedApplicationList`, which makes the item accessible
  by **any application** (with no need to be on the list) — but this
  completely removes granular access control, an unacceptable security
  trade-off for a sensitive OAuth token, and it still doesn't solve
  already-existing items without rewriting them (which, in turn, triggers
  a prompt if done by a process that isn't the original "owner") —
  [Apple Developer Forums — thread 129911](https://developer.apple.com/forums/thread/129911)
- "If the application is not in the list of trusted applications, the
  user is prompted before access is allowed" — confirmation that absence
  from the trusted list implies a mandatory prompt, reinforcing that
  there's no silent bypass — aggregated from search results about
  `SecKeychainItemSetAccess`/`SecAccess` (see Gaps regarding the official
  `SecAccess` page)
- "Changing ACL after the fact will trigger a user authorisation dialog"
  — consistent with the behavior documented in the Claude Code issues
  analyzed in the following section — aggregated from search

### Inferences
- Even if, when creating the item, the `claude` CLI had initially put
  ClaudeS on the trusted-apps list (something that would require
  Anthropic's cooperation), any token renewal that rewrites the item (as
  the `claude` CLI actually does, see the next section) tends to reset
  that list — so even a one-off grant wouldn't be durable without a
  behavior change on Anthropic's side.
- `SecTrustedApplication`/`SecAccess` being deprecated with no modern
  replacement (the current `SecItem*`/`kSecAttrAccessControl` API doesn't
  expose "trusted-app-list" ACL manipulation between third-party
  processes) is, by itself, evidence that Apple deliberately closed this
  automation surface — it was used in keychain-dumping malware/attacks.

### Gaps
- It wasn't possible to obtain the full body of the official
  `developer.apple.com/documentation/security/secaccess` page (WebFetch
  only returned the title); the quote about "deprecated" is consistent
  with the known status documented in macOS 10.15's changelog and
  corroborated by the Apple engineer's official forum post (thread
  129911), but manual verification of the exact deprecation text on the
  page is recommended.

## Can `security add-generic-password -T` or `security set-generic-password-partition-list` add an app to an ALREADY-EXISTING item's trust list with no prompt?

### Takeaway
**PARTIALLY VIABLE only for creating a new item; UNVIABLE for an
already-existing item with no prompt.** The `security(1)` `-T` flag can
only set the trusted-apps list **at the moment** a new item is created.
For an item that already exists — as is the case with the `claude` CLI's
item, created and managed by another binary — both
`security add-generic-password -U -T` and
`security set-generic-password-partition-list` **always trigger a
user-password authorization prompt** when used to change an existing
item's ACL/partition list. Running with administrator privileges (`sudo`)
doesn't work around this, because the authentication required is the
user's keychain's (or Touch ID/login password), not a filesystem-level
root authorization.

### Cited Findings
- "The `-T` flag specifies an application which may access this item,
  and multiple `-T` options are allowed." And about updating an existing
  item: "when using the `-U` flag to update a keychain item with the
  `-T` flag, you get prompted in the GUI to allow the change and enter
  your password... The `security add-generic-password` command can't add
  in Access Control settings to an existing keychain entry. It can add
  ACL entries at the time it creates a new entry, but can't do so
  afterwards." — aggregated from Stack Overflow / the `security(1)` doc,
  cited from research —
  [security(1) — General Commands Manual](https://ss64.com/mac/security-password.html)
- Direct, concrete confirmation from a real case identical to the user's
  (a third-party app reading the `claude` CLI's item): "An external
  integration applied `security set-generic-password-partition-list -S
  apple-tool:,apple:` to an adapter-managed OAuth item so non-interactive
  `/usr/bin/security` readers could read the token without GUI prompts"
  — but "re-applying the grant requires the user's login password each
  time (`set-generic-password-partition-list` prompts), which cannot be
  automated safely" and "When a keychain item is updated, the partition
  list gets reset to a single `cdhash:<creating-binary>` entry, silently
  re-breaking external readers" —
  [keyring provider: macOS prompts for password after every secretspec upgrade · Issue #438 — cachix/secretspec](https://github.com/cachix/secretspec/issues/438)
- A case documented in Anthropic's own repository, involving exactly the
  `Claude Code-credentials` item: a temporary workaround works, but is
  destroyed on every rewrite the `claude` CLI does:
  `security set-generic-password-partition-list -S
  apple-tool:,apple:,teamid:NKUJUXUJ3B -s "Claude Code-credentials" -a
  <user>` — "This fix is overwritten when Claude Code rewrites the
  credential." —
  [macOS: Claude Code locks itself out of its own keychain credential → endless password prompts · Issue #81707](https://github.com/anthropics/claude-code/issues/81707)
- The same issue details the exact mechanism: "The partition list is a
  gating mechanism separate from the ACL... The ACL itself is permissive
  (`applications: <any>`, `don't-require-password`)... The partition
  list acts as a hard gate before the ACL is even evaluated... Clicking
  'Always Allow' in the prompt modifies the ACL only, not the partition
  list... The partition list is not visible in macOS Keychain Access
  UI." — [Issue #81707](https://github.com/anthropics/claude-code/issues/81707)
- An additional case confirming the reset-on-every-write/renewal pattern:
  "every OAuth token refresh rewrites the `Claude Code-credentials`
  keychain item in place and drops its ACL... the write operation
  doesn't preserve the existing `SecAccess` on update." Timestamp
  evidence: `cdat` (creation date) stays unchanged while `mdat`
  (modification date) changes, proving it's an in-place rewrite (not
  delete+recreate) and, even so, the ACL is discarded. —
  [macOS: token refresh rewrites Claude Code-credentials in place and drops its keychain ACL · Issue #94491](https://github.com/anthropics/claude-code/issues/94491)
- A related issue confirms a write collision between different
  third-party apps (reinforces the risk, not a solution): "macOS client
  modifies another app's keychain item on startup (sets partition list
  to `teamid:NKUJUXUJ3B`), breaking Claude Code" —
  [Issue #10976 — nextcloud/desktop](https://github.com/nextcloud/desktop/issues/10976)
- Another equivalent technical report in a different product (an MCP
  adapter), showing the problem isn't specific to the `claude` CLI but to
  the legacy keychain's general model: "coding-agent (MCP adapter):
  keychain secure-storage rewrites reset the item's partition list,
  wiping external silent-read grants" —
  [Issue #9562 — earendil-works/pi](https://github.com/earendil-works/pi/issues/9562)

### Inferences
- Even a one-off manual workaround run by the user (with the password
  prompt accepted) is ephemeral: the `claude` CLI's very first token
  renewal (which happens automatically, not something ClaudeS controls)
  rewrites the item and destroys the grant. So there's no sequence of
  `security` commands that permanently solves the problem without
  periodically repeating the prompt — directly contradicting the
  "no repeated prompt" requirement.
- `sudo`/admin privileges don't help: the authentication `securityd`
  requires to change the ACL/partition list is tied to the logged-in
  user's keychain session (login password or Touch ID), not the Unix
  user. Running as root doesn't eliminate this prompt.

### Gaps
- I found no official documentation (a full man page) explicitly stating
  `sudo` doesn't work around `security set-generic-password-partition-list`'s
  prompt; the inference is based on the consistent behavior reported
  across multiple real issues (no reporter managed to automate it via
  sudo) and the general knowledge that the user's keychain is protected
  by `securityd` independently of root privilege — but no source cited an
  explicit test with `sudo` failing.

## Is it technically possible, under any condition, for a third party to silently (with no prompt) read a keychain item managed by another developer, while respecting Apple's security model? If not, which layer prevents it, and why?

### Takeaway
**UNVIABLE, by design, at every layer investigated.** There's no
combination of entitlement, API or command-line tool that lets an app
from one Team ID (or with no Team ID, in the ad-hoc signing case) read,
with no prompt, a keychain item belonging to/managed by a binary from
another Team ID — not even one-off, because the `claude` CLI's item is
periodically rewritten (on every OAuth token renewal) and that rewrite
tears down any custom ACL/partition list previously granted via a prompt
the user accepted.

### Cited Findings
- Layer 1 — Access-group entitlements: barred by Team ID, enforced by an
  Apple-signed provisioning profile ("Keychain items can be shared only
  between apps from the same developer") —
  [Keychain Access Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups)
- Layer 2 — The (legacy) per-item ACL API: deprecated with no
  replacement, and even when functional requires user authentication for
  any modification crossing process identity —
  [Apple Developer Forums thread 129911](https://developer.apple.com/forums/thread/129911)
- Layer 3 — The `security(1)` tool: only sets trusted apps at item
  creation; post-creation changes (via `-U -T` or
  `set-generic-password-partition-list`) require a prompt —
  [ss64 security(1)](https://ss64.com/mac/security-password.html);
  confirmed in real cases —
  [Issue #438 cachix/secretspec](https://github.com/cachix/secretspec/issues/438)
- Layer 4 — Even when the user accepts the prompt once ("Always Allow"),
  that grant is stored in the ACL but the **partition list** (a separate
  gate, **evaluated before** the ACL and not shown in the Keychain Access
  UI) gets reset on every rewrite of the item by the owning process —
  making the grant ephemeral and reinstating the prompt on the next token
  refresh —
  [Issue #81707](https://github.com/anthropics/claude-code/issues/81707);
  [Issue #94491](https://github.com/anthropics/claude-code/issues/94491)
- An analyst's explicit answer about this exact scenario (a third-party
  app vs. the `claude` CLI's item): "A third-party app cannot add itself
  to a keychain item's trusted list without prompting the user." —
  a synthesis derived from reading Issue #77697 —
  [Issue #77697 anthropics/claude-code](https://github.com/anthropics/claude-code/issues/77697)

### Inferences
- The root cause, at every layer, is the same Apple design decision:
  **any cross-identity access grant between distinct code identities
  (Team ID, or no valid signature) requires explicit user confirmation**,
  and that confirmation isn't durably persisted when the protected item
  is rewritten by the owning process — which is exactly the `claude`
  CLI's behavior when renewing OAuth tokens.
- For ClaudeS's case (ad-hoc signed, no real Team ID), the situation is
  even more closed: even the few paths that depend on a Team ID (access
  groups) would require ClaudeS to have a paid developer account — a
  prerequisite ad-hoc signing doesn't meet.
- Practical implication for the ClaudeS project: any sustainable solution
  will have to avoid depending on directly reading the `claude` CLI's
  keychain item with no user intervention. Alternatives outside this
  research's scope (not investigated here) would include: (a) asking the
  user to accept the prompt and guiding them to run
  `security set-generic-password-partition-list` manually on every
  renewal (impractical in practice, since the reset is automatic and
  frequent), (b) not depending on the `claude` CLI's keychain item and
  using ClaudeS's own credential source (e.g. `claude setup-token` with a
  long-lived token, mentioned in Issue #94491, but with limitations:
  inference-only token, no connectors/scheduling/Remote Control, expires
  in 1 year), or (c) reporting/contributing an upstream fix in the
  `anthropics/claude-code` repository so the `claude` CLI preserves the
  ACL/partition list on rewrite — there are already 3 open issues in
  Anthropic's repository about exactly this problem (#77697, #81707,
  #94491).

### Gaps
- It wasn't possible to directly confirm, with an Apple primary source,
  whether the "partition list" is a publicly documented part of the
  modern Keychain Services API or an implementation detail of the legacy
  file-based keychain (`SecKeychainItemCreateFromContent` / the
  `security` tool) — the analysis strongly suggests it's the latter (the
  `claude` CLI uses the legacy, file-based keychain API, not the modern
  `SecItem`/data-protection keychain API), but there's no official Apple
  page documenting "partition ID" as a first-class concept; the best
  source found was a third-party article (mostlikelee.com) and the
  GitHub issues themselves, which describe the empirically observed
  behavior.
- This research didn't investigate whether there's some macOS Sequoia/26
  (2024-2026)-specific mechanism that changed this behavior — the
  research found no recent Apple changelog note reverting or altering
  this model; it's assumed the behavior has been stable since at least
  macOS 10.15 (Catalina) through the current versions (2026), but this
  wasn't confirmed with an official macOS 15/16 changelog source.
