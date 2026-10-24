# The app's own credential/certificate (biometrics, Secure Enclave, login password) to eliminate the Keychain prompt

## Confirmed context of the real problem

### Takeaway
The scenario described in the brief is exactly the publicly documented bug
in Anthropic's own `claude` CLI: the `Claude Code-credentials` Keychain
item is written **with no trusted-application list**, and the
delete-and-recreate pattern used to update the token discards any
ACL/"Always Allow" the user has granted, causing a recurring prompt
(reports range from every 3-4 min, to every ~1h45 after a manual
mitigation). This is a bug on **the item writer's side** (the CLI), not
something a third-party helper app (ClaudeS) can fix from outside without
rewriting the item.

### Cited Findings
- The public issue "macOS: Keychain item written without
  trusted-application list -> auth prompt on every credential read"
  describes the item being created with no `-T` (trusted app) and
  recreated via delete+add on every token update, discarding the previous
  ACL —
  [anthropics/claude-code#77697](https://github.com/anthropics/claude-code/issues/77697)
- A manual mitigation tested by the community: recreating the item with
  `security add-generic-password ... -T /usr/bin/security` reduces the
  prompt's frequency, but the fix isn't permanent because the next token
  rewrite goes back to omitting the trusted-app list —
  [anthropics/claude-code#77697](https://github.com/anthropics/claude-code/issues/77697)
- `security set-generic-password-partition-list -S
  apple-tool:,apple:,teamid:...` is cited as a "partition ID" mitigation
  (a code-signing team-ID trust mechanism), but with limited effect if the
  item gets recreated without it —
  [anthropics/claude-code#77697](https://github.com/anthropics/claude-code/issues/77697)
- The permanent fix suggested in the issue itself is for the CLI to attach
  the trusted-application list on write, or to update the item in place
  instead of delete-and-recreate — there's no mention of any mechanism
  where a third-party app solves this "from outside" —
  [anthropics/claude-code#77697](https://github.com/anthropics/claude-code/issues/77697)

### Inferences
- The problem is structural in how the CLI writes the item, not a lack of
  "transparent reauthentication"; so any solution that doesn't touch how
  the CLI writes the item (trusted-app list / update-in-place) doesn't fix
  the root cause — it only mitigates symptoms.

### Gaps
- Nothing in the material researched contains an official Anthropic
  statement about whether/when this bug will be fixed in the `claude` CLI
  itself.

---

## Question 1 — Does LocalAuthentication/Touch ID allow transparent reauthentication for an item owned by someone else (created by the `claude` CLI)?

### Takeaway
**Confirmed: NO.** `SecAccessControlCreateWithFlags` with
`kSecAccessControlBiometryCurrentSet` can only be set **at the moment an
item is created**, by the process creating it (`SecItemAdd`), and a
Keychain item's "owning" identity is tied to the **designated requirement
(DR)** of whoever created it's code signature — there's no API to attach
biometric control to an already-existing item created by another
process/app.

### Cited Findings
- On macOS's file-based keychain, "the file-based keychain uses the
  caller's designated requirement to track ownership" — a statement from
  Quinn "The Eskimo!" (Apple DTS Engineer) on an official forum, pointing
  to TN3127 for the designated-requirement mechanism —
  [Apple Developer Forums thread 738571](https://developer.apple.com/forums/thread/738571)
- Changing how the binary is signed (e.g. packaging it in a bundle)
  already changes the DR, and the system starts treating the new binary
  as a different "owner", causing `errSecInvalidOwnerEdit` when trying to
  modify old items — even though it's literally the same app, evolved —
  [Apple Developer Forums thread 738571](https://developer.apple.com/forums/thread/738571)
- "If you have a keychain item where the ACL isn't set up correctly,
  there is no way to change the ACL without user approval" — Quinn
  "The Eskimo!", about modifying an already-existing Keychain item's ACL —
  [Apple Developer Forums thread 747366](https://developer.apple.com/forums/thread/747366)
- Every Keychain item is born with a default ACL that already requires
  user interaction to change; the only way to avoid this barrier is to
  create the item with the correct ACL from the start — citation from
  Apple documentation/forum on the topic —
  [Apple Developer Forums (synthesis)](https://developer.apple.com/forums/thread/809701)
- The documented usage pattern for `kSecAttrAccessControl`/biometrics is
  always in the dictionary passed to `SecItemAdd` at the moment the item
  is created, never as a separate "upgrade" operation on a pre-existing
  item —
  [200oksolutions.com - Securely Managing User Details in the Keychain Part 3](https://200oksolutions.com/blog/ios-keychain-secaccesscontrol-security/)

### Inferences
- For ClaudeS to apply `kSecAccessControlBiometryCurrentSet` to ANY item,
  it would need to be the process creating that item from scratch (via
  `SecItemAdd`) — i.e., it would have to effectively **take over
  ownership** of the item (delete the `claude` CLI's item and recreate it
  as its own). This (a) would fall outside the original question's scope
  ("transparent reauthentication for an item owned by someone else") and
  (b) would break compatibility with the `claude` CLI, which probably
  expects to locate/write its own item with its own DR and would recreate
  it anyway on the next token update — reintroducing the same bug.
- Even if ClaudeS created its own COPY of the credentials protected by
  Touch ID, that would only solve ClaudeS's access to its own copy — it
  wouldn't eliminate the native prompt that appears when the `claude` CLI
  accesses ITS OWN item (whose ACL keeps getting reset by the
  delete-and-recreate pattern described in bug #77697).

### Gaps
- No documented case was found (Apple forum, Stack Overflow, WWDC) of an
  API or workaround that lets you "attach" `SecAccessControl` to a
  pre-existing Keychain item without recreating it. The active search for
  this workaround returned no positive result — reinforcing the
  conclusion of unviability.

---

## Question 2 — Is there a "delegated credential" via the Secure Enclave (the app's own key pair) that satisfies another process's item's ACL evaluation?

### Takeaway
**Confirmed: NO.** A Keychain item's ACL evaluates the **requesting
process's identity via code signature (designated requirement / cdhash /
team ID)**, it doesn't accept cryptographic proof from an arbitrary key
generated by the requesting app. A Secure Enclave key generated by ClaudeS
only proves the identity/possession of *ClaudeS's own keys* — it isn't a
"pass" mechanism accepted by third-party items' ACL evaluator.

### Cited Findings
- A Keychain item's ACL entry can contain `kSecACLAuthorizationPartitionID`,
  used to identify the calling process's teamid/apple/cdhash: "If the
  teamid is specified, the application must have the same teamid to
  access the entry value without a prompt. If the apple is specified,
  then the app needs to be signed by Apple. If the cdhash is indicated,
  then the app must have the specific cdhash" —
  [HackTricks - macOS Keychain](https://hacktricks.wiki/en/macos-hardening/macos-red-teaming/macos-keychain.html)
- "The file-based keychain uses the caller's designated requirement to
  track ownership" (same source as question 1) confirms the evaluation is
  about the calling code's identity, not a presented key/certificate —
  [Apple Developer Forums thread 738571](https://developer.apple.com/forums/thread/738571)
- Sharing Secure Enclave keys between distinct apps is only documented via
  **keychain access groups** with apps signed under the **same
  provisioning profile/team**, i.e., it's still a trust relationship based
  on a code signature shared between apps from the same developer — not a
  generic "proof" any app could present to someone else's item —
  [Apple Developer Forums thread 810676](https://developer.apple.com/forums/thread/723516)

### Inferences
- Even if ClaudeS generated a key pair in the Secure Enclave and the user
  "approved" that key once via Touch ID, that approval only authenticates
  ClaudeS to access **ClaudeS's own items** in the Keychain — it isn't a
  token the `claude` CLI's item's ACL evaluator (of a different DR/
  signature) would ever consult or accept. There's no "trust bridge" in
  Keychain Services that lets an app import/delegate another process's
  trust.

### Gaps
- No primary Apple source (developer.apple.com/documentation) was accessed
  with full content about `SecAccessControlCreateWithFlags`, since the
  page returned content the fetch tool couldn't extract (blocked/
  JS-rendered); the confirmation here rests on DTS engineers' replies in
  official Apple forums and third-party documentation, which are
  consistent with each other, but ideally would be reinforced with the
  full official doc.

---

## Question 3 — What would the app actually be able to do with a stored macOS login password, and would it solve the original problem?

### Takeaway
Storing the macOS login password would let ClaudeS run operations that
**require the account's password** (e.g. `security unlock-keychain -p
<password>`, elevation via `sudo -S`), but this **doesn't solve the
reported problem**: the prompt that appears when the `claude` CLI accesses
its Keychain item is a **per-item ACL** confirmation ("Always Allow" /
trusted-application), not a locked keychain — unlocking the login
keychain (which is usually already unlocked since the user's login)
doesn't interfere with the ACL evaluation of a specific item that doesn't
have ClaudeS on its trusted-app list.

### Cited Findings
- `security unlock-keychain [-p password] [keychain]` unlocks the keychain
  (by default the login keychain) using the password supplied via `-p` —
  [DssW - security tool reference](https://www.dssw.co.uk/reference/security/)
- Using `-p` to pass the password is described as insecure because the
  password gets exposed in the system's process table; `security` has no
  other non-interactive way to receive a password besides the command
  line —
  [netmeister.org - Using the OS X Keychain](https://www.netmeister.org/blog/keychain-passwords.html)
- The login keychain is usually already unlocked during the user's
  session, so any process running under that user's (or a superuser's)
  privileges can potentially access secrets stored in it — a risk already
  cited even with no additional password involved —
  [netmeister.org - Using the OS X Keychain](https://www.netmeister.org/blog/keychain-passwords.html)
- The real bug's recurring-prompt cause (#77697) is the item's lack of a
  trusted-application list (a per-item ACL), fixable only by whoever
  writes the item with `-T` or via an in-place update — not by unlocking
  the keychain —
  [anthropics/claude-code#77697](https://github.com/anthropics/claude-code/issues/77697)

### Inferences
- Possessing the login password does NOT give ClaudeS the power to
  "pre-approve" the ACL of an item belonging to another process (the
  `claude` CLI) — per-item ACL and unlocking the keychain are distinct
  mechanisms. The password would only help with adjacent scenarios
  (unlocking the keychain if it's locked, or operations requiring
  `sudo`), not with the brief's central scenario.
- This is a critical product finding: even ignoring the security risks,
  the idea of storing the macOS password **wouldn't attack the reported
  prompt's cause**. The real fix for the reported symptom is on the item
  writer's side (the `claude` CLI), via a trusted-app list/partition-list
  or an in-place update — outside ClaudeS's control as a separate app.

### Gaps
- It wasn't possible to confirm with a direct technical test (outside this
  researcher's scope) whether there's any indirect path — e.g., ClaudeS,
  having the password, could run `security` commands with privileges that
  would change ANOTHER process's item's trusted-app list with no prompt.
  Per the documented general rule ("no way to change the ACL without user
  approval" — thread 747366), the expectation is that this would also
  require user approval the first time, but no source tests this specific
  case (another DR's item's ACL + the account password in hand). I
  recommend a technical tester confirm this point empirically.

---

## Question 4 — Risks of a third-party app storing the macOS login password, and how serious tools handle this

### Takeaway
Storing the macOS login password in a third-party app is classified by
the security community as a **classic anti-pattern**: it creates a single
point of failure where compromising the app's storage exposes the entire
system account (not just the app's own data), and it's exactly the attack
vector used by real malware documented in 2026 that fakes a system
password prompt to steal the user's Keychain. No reputable market tool
(password manager or MDM agent) stores the OS login password for the
purpose of silently reauthenticating something else — all of them use the
OS's own mechanisms (Keychain/Secure Enclave, system Touch ID) without
ever retaining the password in a text or reversible format.

### Cited Findings
- A documented anti-pattern: using the Mac account's password to protect
  stored credentials (instead of a dedicated master password) creates a
  vulnerability where anyone with the Mac password (a technician, an
  administrator, a remote attacker) accesses everything the app stores —
  [MacRumors forum discussion - "Why Apple's Passwords app is huge security risk"](https://forums.macrumors.com/threads/why-apples-passwords-app-is-huge-security-risk.2446906/)
- Real malware documented in 2026 ("CrashStealer") disguises itself as
  Apple's CrashReporter component, shows a **fake macOS password prompt**
  the user expects, and uses the captured password to unlock the Keychain
  and extract secrets from browsers, password managers, crypto wallets
  and the Keychain — confirming that asking for the system password
  outside Apple's native flow is the attack pattern used by malware,
  making any legitimate app doing something similar indistinguishable
  from malware in the eyes of the user and security tools —
  [Malwarebytes - "This fake Apple app can unlock your Mac's password vault"](https://www.malwarebytes.com/blog/threat-intel/2026/07/this-fake-apple-app-can-unlock-your-macs-password-vault)
- A widely repeated security rule: "Most legitimate apps do not require
  admin permissions. Never give an unknown program your admin password" —
  [Malwarebytes - "This fake Apple app can unlock your Mac's password vault"](https://www.malwarebytes.com/blog/threat-intel/2026/07/this-fake-apple-app-can-unlock-your-macs-password-vault)
- The login keychain is usually already unlocked during the active
  session; any process under the user's privileges can access secrets in
  it — i.e., additionally storing the password creates extra exposure
  with no technical need in most normal usage scenarios —
  [netmeister.org - Using the OS X Keychain](https://www.netmeister.org/blog/keychain-passwords.html)
- 1Password, a reference tool in password management, solved the
  reauthentication-friction problem by **integrating with the system's
  native unlock** (opening alongside the system's Face ID/Touch ID/PIN/
  password unlock) — i.e., riding the OS's own authentication event,
  without ever storing or handling the system account's password inside
  its own storage —
  [9to5mac - "1Password MDM Support comes to macOS"](https://9to5mac.com/2022/11/26/1password-mdm-support/);
  [1Password blog - MDM/MSI/PKG installers](https://blog.1password.com/mdm-msi-pkg-installers/)
- A widely accepted security best practice (OWASP): sensitive data should
  be stored using the OS's own native Keychain/Keystore mechanisms —
  "Failing to use secure keychain or keystore mechanisms provided by the
  OS is a risky practice. Use Android Keystore and Apple Keychain for
  credential storage" — no source consulted recommends capturing and
  retaining the OS account's own password as a convenience mechanism —
  [SecureLayer7 - OWASP M9: Insecure Data Storage](https://blog.securelayer7.net/owasp-m9-insecure-data-storage/)

### Inferences
- ClaudeS storing the macOS password would turn it into a high-value
  target: compromising that storage (via malware, exfiltration, memory
  dump, insecure backup) would compromise the user's entire Mac account —
  login, Keychain, FileVault indirectly, sudo — far beyond the scope of
  "managing Claude credentials". ClaudeS's security-failure blast radius
  would become equivalent to the blast radius of losing the whole Mac
  password.
- There's no precedent of a reputable consumer product doing this; the
  only behavior pattern found that resembles "asking for the system
  password outside the native flow" is, specifically, malware. This alone
  is the strongest warning sign found in this research: the total absence
  of a legitimate precedent, combined with the existence of an identical
  malicious precedent in behavior, is direct evidence of a market
  anti-pattern — not just a theoretical one.

### Gaps
- No documented, named case was found of a consumer (non-corporate/MDM)
  app that asked for and stored the OS login password and was publicly
  exposed for it (e.g. press/security coverage naming the product). The
  research found the anti-pattern described in general terms and the
  disguised-malware case, but no named "scandal" of a legitimate app doing
  exactly this — which is consistent with the conclusion that no
  reputable player has tried it.

---

## Question 5 — Apple's App Review policy on requesting/storing the system account's password

### Takeaway
No literal, specific clause was found in the App Store Review Guidelines
forbidding "storing the user's macOS account/Apple ID password" (and, in
any case, this is technically out of scope for apps distributed outside
the Mac App Store, as is ClaudeS's case). However, Apple itself publicly
and consistently communicates, as an institutional security principle,
that it **never asks for the password, device passcode, recovery key or
verification code** — a principle any third-party app would violate by
asking for the equivalent.

### Cited Findings
- "Apple will never ask you for your Apple Account password, verification
  codes, device passcode, recovery key or any account security details"
  and "Apple will never ask you to log in to any website, or to tap
  Accept in the two-factor authentication dialog, or to provide your
  password, device passcode, or two-factor authentication code" —
  [Apple Support - Security and your Apple Account](https://support.apple.com/en-us/102614)
- The App Store Review Guidelines reviewed in the searches address
  accounts WITHIN the app (the app's own login, demo accounts for review)
  and the principle of minimizing collection of personal data not
  essential to the main function (guideline 5.1.1), but no source
  consulted cites an explicit, named clause about "the operating system
  account's password" —
  [AppFollow - iOS App Store Review Guidelines 2026](https://appfollow.io/blog/app-store-review-guidelines)

### Inferences
- The absence of a specific textual clause doesn't imply neutrality: the
  general data-minimization principle (5.1.1) and Apple's own
  institutional communication pattern against asking for the system
  password/passcode (even if aimed at phishing, not legitimate apps) make
  this practice incompatible with the security posture Apple asks of
  developers, even outside the Mac App Store. For an app like ClaudeS,
  which isn't under App Review, the absence of an explicit ban doesn't
  reduce the reputational or security risk — it only removes a regulatory
  barrier, not a best-practice one.

### Gaps
- It wasn't possible to access and read the full, current text of the App
  Store Review Guidelines directly from Apple
  (developer.apple.com/app-store/review/guidelines) in this research; the
  information comes from a secondary source (AppFollow) summarizing the
  document. If the decision is critical, I recommend validating sections
  5.1.1 and 2.3.1 directly against Apple's primary source before
  formalizing any claim like "Apple forbids X" or "Apple doesn't forbid X".

---

## Final classification of the two ideas

- **Idea 1 — LocalAuthentication/Secure Enclave to "approve once" and
  reuse on someone else's item (created by the `claude` CLI): UNVIABLE.**
  Confirmed by multiple sources (Apple DTS, third-party documentation)
  that `SecAccessControl`/biometrics only applies to items created by the
  app itself, with the ACL tied to the designated requirement of whoever
  created the item; there's no API to "attach" that control to a
  pre-existing item from another process without recreating it (which
  would change ownership and fall outside the question's scope).
- **Idea 1b — a Secure Enclave key as "proof of identity" accepted by
  someone else's item's ACL: UNVIABLE.** The ACL evaluates the calling
  process's code signature (DR/cdhash/team ID), it doesn't accept
  arbitrary cryptographic keys as proof.
- **Idea 2 — storing the macOS login password for silent
  reauthentication: technically VIABLE** (the password can be used via
  `security -p`/`sudo -S` for operations requiring it), **but with severe
  security risk, no reputable market precedent, and — an additional
  critical finding — even so it wouldn't solve the reported problem**,
  because the #77697 bug's prompt is a per-item ACL confirmation, not a
  keychain lock the password would unlock. Final classification:
  **UNVIABLE as a solution to the reported problem, and even as a
  standalone idea it would be severely risky and with no legitimate
  market precedent.**
