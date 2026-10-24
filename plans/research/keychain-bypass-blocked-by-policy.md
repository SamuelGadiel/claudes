# A technical bypass exists, but Anthropic blocks it by policy

There is no **durable and legitimate** way for ClaudeS to read the
`Claude Code-credentials` Keychain item with no native macOS prompt ever
firing — but the most important reason from this round of research isn't
purely technical anymore. Of the four paths re-evaluated, the `-k`/
partition-list with the keychain password is **partially viable** only in
theory, since it depends on a property of the item (the `change_acl` ACL
accepting a password as a credential) that the modern `SecItemAdd`/
`SecItemUpdate` pattern the `claude` CLI likely uses probably doesn't have;
storing the macOS login password is **technically possible but unviable
as a solution**, because it neither attacks the prompt's root cause nor
differs from a behavior pattern indistinguishable from malware documented
in 2026; biometrics/Secure Enclave is **structurally unviable**, since a
Keychain item's ACL is tied to the designated requirement of whoever
created it, with no API to "attach" biometric control to someone else's
item after the fact. The most sophisticated path — ClaudeS minting its own
OAuth session with Anthropic (its own or reused client_id, including via
`claude setup-token`) — is the only one that would solve the Keychain
problem by construction (a token the CLI never writes can't suffer the
ACL reset the CLI itself causes), but it's **blocked by Anthropic's Terms
of Service policy since 2/19/2026, with active server-side technical
enforcement since 1/9–27/2026** — OAuth tokens from Free/Pro/Max/Team
accounts used outside Claude Code/claude.ai are rejected by the inference
API itself, already publicly affecting tools like OpenClaw and OpenCode.
This is this research's critical finding: even the most elegant solution
from an engineering standpoint is barred by a layer no technique on
ClaudeS's side can work around, definitively repositioning the problem
onto policy, not architecture — and reinforcing that the only structural
fix depends on Anthropic itself, across the three already-open issues
(`#77697`, `#81707`, `#94491`).

## The keychain password only helps when the item's ACL accepts a password — and the real item probably doesn't

This research's empirical test confirmed that
`security set-generic-password-partition-list -k <password>` **does
actually avoid the graphical dialog**, with no hang and no prompt, when
the item's `change_acl` ACL entry doesn't require a specific app
identity — behavior reproduced in a controlled way on a disposable
keychain, with `exit=0` and 0 seconds of execution time even when the
item's data entry was restricted to an app different from the calling
process. The `security` tool, when given `-k`, doesn't fire a prior prompt
and consumes the password directly in a call equivalent to
`SecKeychainItemSetAccessWithPassword`, a password-based authentication
path distinct from `SecKeychainItemSetAccess` (which always requires a
GUI). This is exactly the pattern the industry uses in CI/CD — fastlane,
GitHub's official `apple-actions/import-codesign-certs` Action, and
Jenkins pipelines all run `create-keychain` → `import -T <apps>` →
`set-key-partition-list -S ... -k <password>` in the same session where
they create the item, never to reopen trust on a pre-existing item created
by another process.

That's exactly where the user's hypothesis trips up: the "window" where
the password works with no prompt is the moment the item is **created** —
when the writing process itself is still defining its initial ACL — not a
later moment of editing an already-existing item owned by another
process. An Apple DTS engineer confirmed that the concept of an app
"donating" or extending trust in an item to another team is deprecated
with no programmatic substitute without user authentication, and that
`SecTrustedApplicationCreateFromPath` was removed with no equivalent
alternative
([Apple Developer Forums #129911](https://developer.apple.com/forums/thread/129911)).
The root cause documented in issue `anthropics/claude-code#96385` shows
that the `claude` CLI rewrites the item on every token renewal, resetting
`partition_id` to contain only `apple-tool:`, strongly suggesting the item
is written via modern `SecItemAdd`/`SecItemUpdate` — whose default ACL
policy tends to tie `change_acl` to the writing process's code identity,
with no password fallback, unlike the "open" item obtained in the test via
the legacy `security add-generic-password`. Without inspecting the real
ACL of `Claude Code-credentials` (something not done in this research out
of caution, but that would be a safe next step via `security
dump-keychain -a` in read mode), the empirical test's result can't be
extrapolated to the production item — and every source from CI/CD, Apple
Developer Forums and the Jamf community converges on the same conclusion:
there's no report of anyone using this pattern to regrant trust to a
pre-existing item created by a third party, only for items the script
itself creates from scratch.

## A custom OAuth setup is technically viable, but collides with a policy block already in production

Reverse-engineering the `claude` binary (build 2.1.273) confirmed an OAuth
Authorization Code + PKCE (S256) architecture with a public, fixed
`client_id` (`9d1c250a-e61b-44d9-88ed-5944d1962f5e` in production), with
no client secret — i.e., technically replicable by any app, with no secret
to protect. The `claude setup-token` command is particularly telling: the
official documentation confirms it **never writes to the Keychain**, it
just prints the token in the terminal for the user to copy and use via
`CLAUDE_CODE_OAUTH_TOKEN`
([Authentication - Claude Code Docs](https://code.claude.com/docs/en/authentication)),
making it immune by construction to the ACL-reset bug affecting the
interactive `/login` flow. From a purely mechanical standpoint, a token
obtained this way and stored by ClaudeS in its own Keychain item (created
with `-T` pointing only at ClaudeS) would never be touched by the CLI's
rewrite routine, because that routine only manages its own named item
(`Claude Code${OAUTH_FILE_SUFFIX}`) — the engineering solution to the
Keychain problem is, therefore, solved along this specific path.

The problem is something else entirely, and it's this round's most
important finding: since **February 19, 2026**, Anthropic's documentation
explicitly forbids *"using OAuth tokens obtained through Claude Free, Pro,
or Max accounts in any other product, tool, or service, including the
Agent SDK"* — and that prohibition isn't just contractual, it has had
**active server-side technical enforcement since January 9–27, 2026**,
even before the documentation clarified it
([Winbuzzer](https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/);
[Anthropic OAuth FAQ - Moltis Docs](https://docs.moltis.org/anthropic-oauth.html)).
The inference API explicitly returns *"This credential is only authorized
for use with Claude Code and cannot be used for other API requests"* when
a consumer-subscription OAuth token is used outside the expected context.
Third-party tools already publicly broken by this change include
**OpenClaw** and **OpenCode**
([MindStudio](https://www.mindstudio.ai/blog/anthropic-openclaw-ban-oauth-authentication);
[Natural20](https://natural20.com/coverage/anthropic-banned-openclaw-oauth-claude-code-third-party)).
The policy doesn't distinguish between a token obtained via interactive
`/login` and one obtained via `setup-token` — both are "OAuth tokens
obtained through a Claude Free/Pro/Max account", so both are covered by
the same ban, even though `setup-token`'s technical documentation page
hasn't been updated to warn about this restriction (a tension between
technical documentation and usage policy that this research itself
identified as a likely update gap, not a legitimate loophole). Registering
our own client_id with Anthropic is also a closed door: there's no
third-party OAuth app registration process for subscription accounts —
the only official integration path is an API key via the Claude Console,
billed by usage instead of drawing on the user's Pro/Max subscription
([Moltis Docs](https://docs.moltis.org/anthropic-oauth.html)). In short:
the engineering gap (Keychain, ACL, OAuth architecture) is solved; the
blocking gap is entirely one of policy and active enforcement.

## macOS login password: technically usable, but solves nothing and replicates a malware pattern

Storing the user's login password would give ClaudeS the power to run
`security unlock-keychain -p <password>` or `sudo -S` non-interactively —
that's technically true. But that capability **doesn't attack the
reported prompt's cause**: the prompt that appears when the `claude` CLI
accesses its item is a per-item ACL confirmation (trusted-application
list / partition list), not a locked-keychain block — the login keychain
is usually already unlocked throughout the user's active session
([netmeister.org](https://www.netmeister.org/blog/keychain-passwords.html)).
Unlocking something that's already unlocked doesn't give ClaudeS a spot on
the trusted-app list of an item belonging to another process. This is the
research's most counter-intuitive product finding: even ignoring the
security risk, the idea wouldn't solve the problem it's supposed to solve.

And the security risk is severe enough to end the discussion on its own.
The security community classifies using the system account's password to
protect or unlock other secrets as a classic anti-pattern, because it
creates a single point of failure where compromising one app's storage
exposes the user's whole account — login, Keychain, and indirectly
FileVault and `sudo`
([MacRumors forum](https://forums.macrumors.com/threads/why-apples-passwords-app-is-huge-security-risk.2446906/)).
Worse: the real malware **"CrashStealer"**, documented in 2026, disguises
itself as Apple's CrashReporter and shows exactly a fake macOS password
prompt to then use that password and extract the user's Keychain
([Malwarebytes](https://www.malwarebytes.com/blog/threat-intel/2026/07/this-fake-apple-app-can-unlock-your-macs-password-vault))
— making any legitimate app asking for the system password outside
Apple's native flow indistinguishable, to the user and to security tools
alike, from a real attack. No precedent was found of a reputable consumer
product doing anything similar; the only equivalent behavior pattern
found in the research was, specifically, malware. 1Password solves the
same friction problem in the opposite way — integrating with the system's
native unlock (Face ID/Touch ID/OS password) without ever storing or
handling the account password
([9to5mac](https://9to5mac.com/2022/11/26/1password-mdm-support/)). Apple
publicly and consistently communicates that it never asks for the account
password, the device passcode, or verification codes
([Apple Support](https://support.apple.com/en-us/102614)) — a principle
any third-party app would violate by asking for the equivalent, regardless
of whether there's a literal App Store Review Guidelines clause naming
this specific case.

## Biometrics and the Secure Enclave have no trust bridge to another process's items

The hypothesis of using `LocalAuthentication`/Touch ID or a Secure
Enclave-generated key as a "transparent authorization layer" fails at the
root of the Keychain's security model, not in some implementation detail.
`SecAccessControlCreateWithFlags` with `kSecAccessControlBiometryCurrentSet`
can only be set at the moment an item is created, by the process creating
it via `SecItemAdd` — and a file-based keychain item's "owning" identity is
tied to the **designated requirement** of whoever created it, as confirmed
by an Apple DTS engineer: *"the file-based keychain uses the caller's
designated requirement to track ownership"*
([Apple Developer Forums #738571](https://developer.apple.com/forums/thread/738571)).
There's no documented API to attach biometric control to an already-
existing item created by another process; the active search for this
workaround found no positive result in any source consulted.

A key generated by ClaudeS in the Secure Enclave suffers from the same
problem for an orthogonal reason: a Keychain item's ACL evaluates the
requesting process's identity via code signature (designated requirement,
cdhash, team ID via `kSecACLAuthorizationPartitionID`), it doesn't accept
an arbitrary cryptographic proof presented by a different app
([HackTricks - macOS Keychain](https://hacktricks.wiki/en/macos-hardening/macos-red-teaming/macos-keychain.html)).
Sharing Secure Enclave keys between apps is only documented via keychain
access groups between apps of the **same team ID** — still a trust
relationship based on a shared code signature, not a generic "bridge".
Even if the user approved a ClaudeS key via Touch ID, that approval would
only authenticate ClaudeS for its own items — the `claude` CLI's item's
ACL evaluator (of a different designated requirement) would never consult
or accept that proof. There is, at no layer of Keychain Services, a
trust-delegation mechanism between processes of different signatures.

## Summary of the four paths evaluated

| Path investigated | Classification | Decisive blocker |
|---|---|---|
| `-k <password>` in `set-generic-password-partition-list`/`set-key-partition-list` | **PARTIALLY VIABLE** | Only works if the item's `change_acl` accepts a password as a credential — a property set at creation, not editable afterward; the real item probably doesn't have this fallback |
| A custom OAuth setup (own/reused client_id, including `claude setup-token`) | **TECHNICALLY VIABLE, UNVIABLE by policy** | Forbidden in the Terms of Service since 2/19/2026 and technically blocked server-side since Jan/2026 (active error in production) |
| Storing the macOS login password for silent reauthentication | **UNVIABLE** | Doesn't solve the prompt's cause (a per-item ACL, not a locked keychain) and replicates a documented malware attack pattern |
| Biometrics/Secure Enclave as a transparent authorization layer | **UNVIABLE** | The ACL is tied to the designated requirement of whoever created the item; no API to attach biometric control to a pre-existing item owned by someone else |

All four paths in this round are direct continuations and deepenings of
what the previous research (`macOS Keychain prompt bypass options`) had
already established about root/sudo/entitlements being unviable due to
being tied to the code signature, not the UID — the additional focus here
is that even technically working around that barrier (via a password or a
parallel OAuth session), two new ceilings appear: a structural one (the
ACL is born and dies with the creating process) and a policy one
(Anthropic already blocks, in production, the use of subscription OAuth
tokens outside Claude Code/claude.ai). The three open issues in the
official repository —
[`anthropics/claude-code#77697`](https://github.com/anthropics/claude-code/issues/77697),
[`#81707`](https://github.com/anthropics/claude-code/issues/81707) and
[`#94491`](https://github.com/anthropics/claude-code/issues/94491) —
remain the only channel where the root cause (the ACL/partition-list reset
on every token renewal) could be definitively fixed, and none of this
round's four paths offers a shortcut that makes those issues irrelevant.

## Conclusion

This research's most actionable result is the priority inversion it
forces: before evaluating any bypass technique, the relevant question for
ClaudeS has become one of compliance, not engineering — because even the
technically cleanest path (ClaudeS's own OAuth token, never touching the
problematic Keychain) is closed by an active block on Anthropic's server,
not by a macOS limitation that more implementation effort could work
around. This rules out any path where ClaudeS mints, stores or reuses a
Free/Pro/Max subscription token outside the official CLI, leaving as the
only legitimate working surface an occasional, failure-tolerant read of
the existing item (the Uzzy/Codenotch pattern already described in the
previous research) combined with actively following the three open
issues — since Anthropic, and only Anthropic, controls both the root
cause of the ACL reset and the policy that blocks any parallel
authentication alternative.
