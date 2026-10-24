# root/sudo and TCC/Accessibility as a bypass for Keychain prompts (macOS)

## Is the "App X wants to access the key..." prompt decided by code signature or by UID? Does running as root change this for login-keychain items?

### Takeaway
The Keychain Services ACL model is grounded on the **requesting
process's code-signing identity** (Designated Requirement / CDHash,
stored in the item's "trusted-application list" / partition list),
**not the Unix UID**. Running as root doesn't change this evaluation: an
Apple DTS engineer explicitly confirmed the Keychain wasn't designed to
differentiate/grant special access to root processes, and that trying to
use the Keychain for that purpose "will definitely run into issues".
Classification: **UNVIABLE** as a legitimate bypass.

### Cited Findings
- "The designated requirement is an explicitly specified designated
  requirement for the signed code... any code that meets this
  requirement is considered to be the 'same' for various purposes... if
  the app saves a password in your keychain, the designated requirement
  is stored for access control." —
  [Apple Developer: Code Signing Requirement Language / TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
- "The program that initially sets up the keychain items must include
  other programs in its ACL using... SecTrustedApplication." Code
  signing is verified via `SecTrustedApplication`/`SecACL`, and
  `securityd` consults the requesting app's entitlements/signature. —
  [Apple Developer Forums: SecTrustedApplicationCreateFromPath removed](https://developer.apple.com/forums/thread/118479);
  [WWDC 2013 Session 709: "Protecting Secrets with the Keychain"](https://docs.huihoo.com/apple/wwdc/2013/session_709__protecting_secrets_with_the_keychain.pdf)
- "The item's ACL partition list is bound to binary CDHashes, not the
  signing certificate — dumps show only cdhash: entries." This confirms
  the granularity is per hash/signed-code identity of the requesting
  binary, not per Unix user. —
  [Apple Developer Forums discussion on keyring providers and ACL](https://developer.apple.com/forums/thread/761930)
- A direct reply from an Apple DTS engineer, when asked whether a root
  process can selectively access a keychain item with no prompt via ACL:
  *"The keychain isn't really intended to be used for this task, and
  you'll definitely run into issues trying to use it for that."* He
  explains the Keychain applies permissions per process boundary (the
  calling process's identity), not per UID, and that even if it were
  configurable, it wouldn't solve the underlying security problem. —
  [Apple Developer Forums: "Access to a keychain item for process running as root" (thread 737888)](https://developer.apple.com/forums/thread/737888)
- "macOS keychain access control binds 'Always Allow' to a binary's code
  signature, and an ad-hoc signature gives the binary no stable identity
  to match against" — reinforces that the "always allow" decision is
  tied to the signature, not to the user/UID running the process. —
  [GitHub Issue DataDog/pup #542](https://github.com/DataDog/pup/issues/542)

### Inferences
- Since the ACL is resolved by the calling binary's Designated
  Requirement/CDHash (at the signed-code level), running the same
  unsigned/ad-hoc binary as root or as a normal user produces exactly the
  same ACL-evaluation result — root doesn't "skip" the signature-check
  step, because that step doesn't depend on the UID.
- A root process different from the process that originally created the
  item (e.g. a third-party root daemon) is treated by `securityd` as an
  *unlisted* requester on the item's trusted-application list — so it
  still gets the prompt (or silently fails if there's no UI session, see
  the next section), exactly like any other unauthorized process.

### Gaps
- There's no official Apple documentation formally stating "Keychain
  Services evaluates ACLs based on code signature and never on UID" as a
  single sentence; the conclusion is inferred by combining the
  Designated Requirement/TN2206 documentation, the DTS forum reply, and
  multiple consistent technical reports about the CDHash/partition list.
  No source contradicted this conclusion.

---

## Is there any documented, legitimate (not an exploit) case of a root process reading another user's/app's login-keychain item with no prompt?

### Takeaway
I found no **legitimate, documented** case of root silently reading
another user's/app's login-keychain item without being on the item's
trusted-application list. The only documented case of broad, silent
keychain reading with no prompt is the **KeySteal** exploit
(CVE-2019-8526), a zero-day vulnerability Apple fixed — not a supported
root permission. Classification: **UNVIABLE** (via a legitimate
mechanism).

### Cited Findings
- KeySteal: "A macOS <= 10.14.3 Keychain exploit... allows you to access
  passwords inside the Keychain without a user prompt... Neither root
  access nor administrator privileges are required, and no password
  prompts are generated... capable of extracting passwords from the
  Login and System keychains... works even if System Integrity
  Protection is enabled, or Access Control Lists are set up." Vulnerability
  tracked as CVE-2019-8526, fixed by Apple in 10.14.4. —
  [GitHub: LinusHenze/Keysteal](https://github.com/LinusHenze/Keysteal);
  [BetaNews: KeySteal huge macOS vulnerability](https://betanews.com/article/macos-keysteal-keychain-vulnerability/)
- A crucial point: the exploit's own author (Linus Henze) demonstrates
  exactly that this behavior **isn't the normal/supported behavior** —
  it's a flaw Apple had to fix, confirming that, outside the
  vulnerability, the signature/trusted-application ACL model works as a
  barrier even against root.
- A root LaunchDaemon trying to access the user's login keychain finds,
  instead of a bypass, "user interaction not allowed" errors when there's
  no UI session, or follows the same ACL rules as any other process:
  "A daemon launched by 'launchd' is only able to access the System
  Keychain... not the user's login keychain" (with no special session
  configuration). —
  [Apple Developer Forums: "System Keychain not available from a Daemon" (759976)](https://developer.apple.com/forums/thread/759976);
  [Apple Developer Forums: "Launch Daemon is not able to access login keychain entries" (656000)](https://developer.apple.com/forums/thread/656000)

### Inferences
- The KeySteal case is strong indirect evidence that, *without* a
  vulnerability, not even root can read another app's/user's keychain
  items with no prompt — otherwise the exploit wouldn't be reported as a
  significant "0-day" and wouldn't have required an Apple fix.

### Gaps
- It wasn't possible to confirm the current (2023-2026) state of
  KeySteal-equivalent exploits on modern versions (Ventura/Sonoma/
  Sequoia) — it's presumed fixed with no known public replacement, but
  the research didn't cover recent CVEs specifically about Keychain
  ACL bypass in 2024-2026.

---

## Does the System Keychain have a different trust model? Can root processes write/read there with no prompt? Would that help an item migrated there?

### Takeaway
The System Keychain (`/Library/Keychains/System.keychain`) **is writable
only by root** at the file level, and root scripts/daemons can routinely
add/read items there programmatically with no UI prompt (a common
pattern in MDM/enterprise deployments) — but **this only matters if the
process creating/managing the item is root/you controlling the item
itself**. Since the research brief makes clear the item today is created
and managed by a **third-party CLI outside your control**, migrating to
the System Keychain wouldn't solve anything: you can't force the
third-party CLI to write there, and even if it did, that item's
ACL/trusted-application list would still be tied to the third-party
CLI's code signature, not yours. Classification: **PARTIALLY VIABLE in
theory, UNVIABLE in your concrete scenario** (third-party dependency).

### Cited Findings
- "The System keychain file is only writable by root, and if you're
  running a LaunchDaemon without specifying the user, it runs as root." —
  [Apple Developer Forums: "System keychain from daemon access requires root?" (657874)](https://developer.apple.com/forums/thread/657874)
- A documented automation flow:
  `sudo security add-trusted-cert -d -p basic -k
  /Library/Keychains/System.keychain` and
  `security add-generic-password -a <account> -s <service> -w
  <password>` are standard commands used by admin scripts (Jamf, MDM) to
  populate the System Keychain with no user interaction, when run as
  root/via MDM. —
  [ss64.com: Security Command reference](https://ss64.com/mac/security.html);
  [Jamf Community: "Pulling Passwords from Keychain with Script"](https://community.jamf.com/t5/jamf-pro/pulling-passwords-from-keychain-with-script/m-p/77624)
- Even in this flow, "to avoid prompts, an ACL naming the runtime binary
  is needed so reads don't prompt" / using `-T /usr/bin/security` to
  grant trusted access to a specific binary at item creation time — i.e.,
  the "no prompt" part only works for the item's original creator (or
  whoever it explicitly authorizes), reinforcing that the signature-based
  ACL model applies equally inside the System Keychain. —
  [scriptingosx.com: "Get Password from Keychain in Shell Scripts"](https://scriptingosx.com/2021/04/get-password-from-keychain-in-shell-scripts/)
- On certificate trust in the System Keychain: "In macOS Big Sur 11 and
  later... Running as the root user alone is no longer sufficient to
  modify certificate trust" for trust settings — indicating Apple has
  been **restricting**, not expanding, root privileges over the System
  Keychain in modern versions. —
  [derflounder.wordpress.com / related discussion](https://discussions.apple.com/thread/253433465)

### Inferences
- The System Keychain's "advantage" for root is only file-level (Unix
  permission to open the keychain file), not an exemption from the
  Security framework's code-signature-based ACL layer — the two layers
  (keychain file access vs. individual item ACL) are independent, and the
  second still applies inside the System Keychain.
- Since the item in question is created by a third-party CLI, even
  physically migrating it to the System Keychain, ClaudeS's process would
  still not be on that specific item's trusted-application list — the
  prompt would reappear, just potentially asking for administrator
  authentication instead of a user password, depending on the setup.

### Gaps
- No Apple documentation was found confirming whether the System
  Keychain, by default, still triggers the "App X wants to use the
  key..." prompt for individual items the same way the login keychain
  does, or whether the prompt behavior for the System Keychain is
  strictly disabled outside a UI session (daemons with no session
  generally fail with "user interaction not allowed" instead of
  prompting). This exact distinction (prompt vs. silent failure) wasn't
  confirmed with a single primary source.

---

## Do "unlock-keychain" and "security -i" (interactive mode) running as root change anything?

### Takeaway
Neither of them works around the code-signature ACL model.
`security unlock-keychain` only unlocks the keychain (equivalent to
entering the login password), which is a necessary but **not sufficient**
precondition — individual items still have their own per-item ACLs
requiring a prompt if the requesting process isn't on the trusted-
application list. `security -i` is just a command-execution mode (avoids
exposing the password in argv/history), with no effect at all on ACL
evaluation. Classification: **UNVIABLE**.

### Cited Findings
- "This doesn't bypass macOS Keychain security, but rather just prompts
  you once per SSH session, the same as if you'd unlocked it locally." —
  about `security unlock-keychain` via SSH/scripts. —
  [MacInCloud Support: "How to Unlock Mac Keychain through the Command Line"](https://support.macincloud.com/support/solutions/articles/8000089857-how-to-unlock-mac-keychain-through-the-command-line)
- `security -i` "puts security into an interactive mode: it reads
  commands from stdin, one per line, and dispatches them in-process. No
  fork, no exec, no new process whose argv includes the password" — i.e.,
  it's protection against credential exposure in `ps`/shell history, not
  an additional authorization mechanism. —
  [keith.github.io: security(1) man page](https://keith.github.io/xcode-man-pages/security.1.html)
- There's discussion of using
  `sudo security authorizationdb write com.apple.trust-settings.admin
  allow` to work around prompts specifically **for certificate trust
  settings** (not generic keychain items) — and even this mechanism was
  restricted by Apple starting with Big Sur, requiring an administrator
  password regardless of running as root. — a related search result; see
  the System Keychain section above.

### Inferences
- Unlocking the keychain (unlock-keychain) only resolves the "locked/
  unlocked" state of the keychain as a whole; the per-item ACL (who can
  read that specific entry with no prompt) is evaluated at a separate,
  later layer, regardless of who unlocked the keychain or under which UID.

### Gaps
- No source directly addresses "root + `security -i`" as a specific
  combination; the conclusion is inferred from the `-i` command's own
  documentation (which doesn't mention any UID/root interaction)
  combined with the general understanding of the signature-based ACL
  model.

---

## Do Accessibility/TCC, Automation, Full Disk Access affect Keychain ACL evaluation? Is there overlap, including the "click Allow via Accessibility" path?

### Takeaway
TCC (Accessibility, Automation/Apple Events, Full Disk Access) is a
**completely independent permission system** from the Keychain Services
ACL model — there's no overlap in the ACL decision itself. However,
there's an indirect, technically possible path, already documented by
security researchers (Patrick Wardle): using **Accessibility to generate
synthetic clicks** that press "Always Allow" on the SecurityAgent
dialog — this doesn't "officially" change the ACL, it just automates the
human response to the prompt, and historically relied on flaws (synthetic
events not filtered) Apple has already partially mitigated.
Classification of the formal overlap: **UNVIABLE**. Classification of the
"synthetic click via Accessibility" path: **PARTIALLY VIABLE**
(technically possible, but a hack, fragile, macOS-version-dependent, and
ethically/architecturally inadvisable — not an elegant solution, nor its
original purpose).

### Cited Findings
- "Keychain access and Full Disk Access are separate services - granting
  Full Disk Access does not cover keychain access." — [a TCC overview /
  consolidated research, confirmed by HackTricks and TCC.db analyses] —
  [HackTricks: macOS TCC Credential & Data Theft](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-tcc/macos-tcc-credential-and-data-theft.html)
- Full lists of `kTCCService*` (kTCCServiceAccessibility,
  kTCCServiceAppleEvents, kTCCServiceSystemPolicyAllFiles for Full Disk
  Access, etc.) include no service equivalent to "Keychain ACL" —
  confirming the Keychain's "Always Allow" decision doesn't go through
  the TCC.db database. —
  [Rainforest QA: "A deep dive into macOS TCC.db"](https://www.rainforestqa.com/blog/macos-tcc-db-deep-dive)
- Patrick Wardle (a researcher, ex-NSA, Objective-See) demonstrated that
  "macOS accessibility features include the ability to make
  mouse-clicks without actually touching the mouse through software" and
  that this could be abused by malware to automatically click security
  prompts, including authorization dialogs — "an unpatched flaw can be
  exploited to virtually click objects and gain access to password
  protected areas." —
  [Speaker Deck: "The Mouse is Mightier than the Sword" — Patrick Wardle](https://speakerdeck.com/patrickwardle/the-mouse-is-mightier-than-the-sword);
  [Tom's Guide: "Hackers Can Hijack Macs with Fake Mouse Clicks"](https://www.tomsguide.com/us/mac-mouse-hack-defcon26,news-27796.html)
- A technical recipe documented by users (the Keyboard Maestro forum) to
  automate clicking the Keychain dialog's button via System Events/
  Accessibility, targeting the `SecurityAgent` process:
  `tell window 1 of process "SecurityAgent" to click button "Always
  Allow" of group 1` — confirms this path is technically viable today
  via AppleScript + Accessibility, as long as the automating process has
  been granted Accessibility permission by the user. —
  [Keyboard Maestro Forum: "Pressing the 'Always Allow' button on Keychain permission dialogs"](https://forum.keyboardmaestro.com/t/pressing-the-always-allow-button-on-keychain-permission-dialogs/26903)
- "Apple Events and Accessibility are distinct TCC services and
  generally require their respective user approvals. Once the user
  clicks Allow, future requests from the same source to the same target
  are allowed until the entry is reset." — confirms even this automation
  path **still requires the user to manually approve** the
  Accessibility/Apple Events permission once (it isn't a total, silent,
  from-scratch bypass — there's a TCC prompt first, which then automates
  subsequent Keychain prompts). — [a consolidated research result about
  AppleScript and TCC]

### Inferences
- The "Accessibility clicks Allow" path doesn't eliminate the Keychain
  prompt — it replaces it with a TCC (Accessibility) prompt that needs
  manual approval once, and then automates the response to the Keychain
  prompt from then on. I.e., it turns N manual Keychain prompts into 1
  manual Accessibility prompt + automated clicks — it isn't a "bypass" in
  the sense of eliminating all user-authorization friction, it just
  shifts it and reduces it to a single approval.
- This path is structurally fragile: it depends on `SecurityAgent`'s
  window/process names (which Apple can change between macOS versions),
  requires handling asynchronous dialog timing, and replicates exactly
  the technique security researchers use to describe malware "attacks" —
  a high reputational and maintenance risk for a legitimate product.

### Gaps
- It wasn't possible to confirm whether, on current macOS Sequoia/Sonoma
  (2024-2026), Apple added additional protections (e.g. requiring real
  human attention / "Pointer events" vs. synthetic CGEvent) that would
  invalidate this automated click specifically for SecurityAgent dialogs
  — Wardle's research is mostly from 2017-2019 (synthetic click bugs that
  were partially fixed). Direct empirical validation is recommended
  before relying on this technique in production.

---

## Is running a whole GUI app as root on modern macOS supported/recommended by Apple, or are there technical restrictions that practically prevent it?

### Takeaway
It isn't supported. Apple formally and repeatedly confirms (DTS, via
official forums) that **running a GUI app as root has never been
supported**, and recommends isolating only the privileged operations in a
separate process (a daemon/helper) running as root, keeping the GUI at
normal user privileges. Classification: **UNVIABLE** (not officially
supported) for the "whole GUI app as root" approach; the supported
approach is the root-helper / user-GUI separation.

### Cited Findings
- "Running GUI apps as root has never been supported... Apple
  recommends that you factor the privileged operations out of your GUI
  app into a separate program and run just that program as root." —
  attributed to Quinn "The Eskimo!" (Apple DTS) on an official forum
  thread about Ventura. —
  [Apple Developer Forums: "Ventura OS: Cannot run app with admin privilege" (708295)](https://developer.apple.com/forums/thread/708295)
- "There's no supported way to run an app as root, where app is defined
  as something with a GUI that the user launches from the Finder" —
  additional confirmation from an Apple DTS engineer in another thread. —
  [Apple Developer Forums (consolidated from search on the topic)](https://developer.apple.com/forums/thread/772674)
- Additional technical restrictions in recent versions: "After upgrading
  to macOS Sequoia, LaunchDaemons no longer work for certain operations
  like screen recording, and only work when using a LaunchAgent
  instead" — indicating Apple is progressively restricting what root/
  LaunchDaemon processes can do relative to UI sessions/TCC, not
  expanding it. —
  [Apple Developer Forums: "Problems with macOS apps launching since Sequoia 15.1 (spawn constraints failure)"](https://developer.apple.com/forums/thread/767509)
- Apple's standard referenced architectural recommendation: factor
  privileged logic into a separate helper tool (historically via
  `SMJobBless`, currently via `SMAppService`/`SMPrivilegedExecutable`),
  never run the UI surface as root. —
  [Apple Developer Forums: "Privileged daemon using SMAppService in macOS Sequoia" (756846)](https://developer.apple.com/forums/thread/756846)

### Inferences
- Even if it were technically possible (via `sudo open -a AppName` or
  similar tricks), Apple's recommendation and hardening trend
  (progressively stricter per-session TCC, LaunchServices and
  LaunchDaemons with less and less power over UI sessions in Sequoia)
  make this approach increasingly unstable and prone to breaking in
  future macOS updates — not a solid architectural foundation for a
  long-term product.
- This restriction is consistent with, and reinforces, the first
  question's conclusion: even if you managed to run the GUI as root, that
  wouldn't change the Keychain's ACL evaluation (which is per code
  signature, not per UID) — so the effort of running as root wouldn't
  bring the desired benefit even if technically viable.

### Gaps
- No current numbered Technical Note (e.g. a TN2083 replacement) was
  found addressing exactly this topic for Ventura/Sonoma/Sequoia; the
  available citations are DTS forum replies, which are authoritative but
  not a single, stable reference document.

---

## Consolidated conclusion (synthesis across the sections above)

None of the paths investigated — running as root/sudo, a privileged
LaunchDaemon, migrating to the System Keychain, `unlock-keychain`/
`security -i`, or exploiting Accessibility/TCC — legitimately and
sustainably eliminates the native "App X wants to access the key..."
prompt. The root cause is architectural: macOS Keychain Services ties its
ACLs to the requesting process's **code-signing identity (Designated
Requirement/CDHash)**, a layer orthogonal to the Unix UID and to the TCC
system. The only technically functional path found (a synthetic click via
Accessibility on the SecurityAgent dialog) isn't an ACL bypass — it's
automation of the human response to the prompt, requires a prior manual
Accessibility approval, is fragile across macOS versions, and replicates
a technique historically associated with malware (Patrick Wardle/
Objective-See), which makes it unsuitable as a product solution.
