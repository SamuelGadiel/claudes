# Granting "Always Allow" (ACL/partition-list) via the CLI with no SecurityAgent dialog, using the login keychain's password

## Overall classification (executive summary)

**PARTIALLY VIABLE, with a clear structural limit — not a general bypass.**

- For items whose `change_acl` ACL entry **doesn't require a specific app
  identity** (an "open" ACL: `applications (0)` / unrestricted, or one that
  accepts a password as a satisfying credential), supplying the keychain
  password via `-k` to `security set-generic-password-partition-list` /
  `set-key-partition-list` **avoids the graphical dialog** and the
  operation is non-interactive, confirmed both in the industry (CI/CD) and
  empirically in this test.
- For items whose ACL was deliberately restricted to specific app
  identities **with no password fallback** (the scenario the `claude`
  CLI's Keychain item appears to use, judging by the reports), the
  keychain password **isn't a valid substitute** for per-app approval —
  because Apple deliberately separates "proof that you own the keychain"
  from "explicit approval that THIS app may access/change THIS item".
  There's no flag, environment variable or documented API that supplies
  that second proof with no UI.
- The "window" for setting up trust with no prompt is, in the pattern
  observed in CI/CD, the moment the item is **created/imported** (when the
  ACL doesn't exist yet or is still in an "owner-only"/no-per-app-
  restriction state) — after that, if an external process rewrites the
  item with a more restrictive ACL (as the `claude` CLI apparently does on
  every token renewal), reopening trust for another app again requires
  consent via the GUI, unless that specific item's `change_acl` entry was
  left with no app-identity requirement (which is uncommon/undesirable for
  sensitive credential items).

---

## Key question 1: What exactly is the `-k <password>` flag for? Does it replace the SecurityAgent dialog, or does it only unlock the keychain (with the ACL dialog firing separately)?

### Takeaway
`-k` supplies the **target keychain's password** as the credential for the
ACL/partition-list change operation itself (it isn't a separate prior
unlock) — it's the documented way to avoid the prompt, but it only works
when the relevant ACL entry (`change_acl`, or the protected data entry)
accepts a password as valid proof. If the entry requires a specific app
identity with no password fallback, `-k` doesn't avoid the dialog.

### Cited Findings
- The man page (`security(1)`) for `set-generic-password-partition-list`
  and `set-key-partition-list`: "You must present the keychain's password
  to change a partition list." —
  [DssW security(1) mirror](https://www.dssw.co.uk/reference/security/)
- `--help` output from the `security` binary itself on this machine
  (macOS 15.6.1, build 24G90), obtained locally:
  `-k  The password for the keychain (required)` and
  `Use of the -k option is insecure. Omit it to be prompted.` — confirms
  that, without `-k`, the tool attempts a prompt (text or GUI, depending
  on the context — see Question 4).
- A real CI usage report (fastlane): "The working solution is to call:
  `security set-key-partition-list -S apple-tool:,apple: -s -k
  keychainPass keychainName`" and "Fastlane checks if the security
  command supports partition lists and adds the partition IDs to prevent
  keychain access prompts." —
  [fastlane/fastlane issue #13564](https://github.com/fastlane/fastlane/issues/13564)
- Apple's official GitHub Action (`apple-actions/import-codesign-certs`)
  uses exactly `security set-key-partition-list -S
  apple-tool:,apple:,codesign: -s -k <password> build.keychain` after the
  import, confirmed by multiple secondary sources (blogs, other derived
  Actions) —
  [Localazy blog](https://localazy.com/blog/how-to-automatically-sign-macos-apps-using-github-actions);
  an Apple thread confirming this is "the correct way" and that the
  official GitHub Action does the same —
  [Apple Developer Forums #666107](https://developer.apple.com/forums/thread/666107)
- A documented error when the password passed via `-k` is wrong:
  `security: SecKeychainItemSetAccessWithPassword: The user name or
  passphrase you entered is not correct.` — this shows that, internally,
  the `security` tool uses the private/semi-documented
  `SecKeychainItemSetAccessWithPassword` API when `-k` is supplied, instead
  of `SecKeychainItemSetAccess` (which triggers a GUI) —
  [fastlane/fastlane issue #27590](https://github.com/fastlane/fastlane/issues/27590)

### Inferences
- `-k` isn't "an early unlock that still separately triggers the ACL
  dialog later" — it's consumed directly by the internal call equivalent
  to `SecKeychainItemSetAccessWithPassword`, a password-based
  authentication path dedicated to that specific operation. This
  contradicts the hypothesis that unlock and ACL-grant are completely
  decoupled at the CLI layer — in practice `-k` directly participates in
  the ACL-change call.
- Even so, this password path is only valid when the entry's ACL allows
  "password" as a satisfying credential for that specific authorization
  (`change_acl` or the protected data authorization). This is a property
  **of the item**, set at the moment its ACL was created — not a general
  property of the `security` command.

### Gaps
- There's no official public Apple documentation (beyond the minimal man
  page) detailing the exact rules for when an ACL entry accepts a password
  vs. requires an app identity. Apple itself describes this as poorly
  documented territory ("dark art") — see Question 3.

---

## Key question 2: Via the API (SecKeychainUnlock, SecAccessCreate, SecTrustedApplicationCreateFromPath, SecACLCreateWithSimpleContents, SecKeychainItemSetAccess), is there any way to authenticate as the keychain's owner + add an app to the trust list fully with no UI?

### Takeaway
No. Apple itself (via a DTS engineer) states that this "whole concept" —
an app from one team donating/extending a keychain item's trust to an app
from another team or the system — is **deprecated and has no programmatic
substitute without user authentication**. `SecTrustedApplicationCreateFromPath`
was removed/deprecated with no equivalent replacement API.

### Cited Findings
- A reply from Quinn "The Eskimo!" (Apple DTS Engineer) in an Apple
  Developer Forums thread about `SecTrustedApplicationCreateFromPath`:
  "There is no direct replacement for
  `SecTrustedApplicationCreateFromPath`. The problem is that this entire
  concept is deprecated. In recent macOS releases, there's no way for an
  app from one team to 'donate' a keychain item to an app from another
  team, or the system, without triggering user authentication." —
  [Apple Developer Forums #129911](https://developer.apple.com/forums/thread/129911)
- `SecTrustedApplicationCreateFromPath` was deprecated starting with
  macOS 10.15, and developers reported surprise that it was removed with
  no year of warning and no recommended alternative API — [GitHub search
  aggregating multiple threads/issues about the deprecation, incl. Apple
  Developer Forums #118479]
- The alternatives identified in the same thread are only stopgaps: (a)
  calling the `/usr/bin/security import -T` binary itself (i.e.,
  delegating to the same CLI tool, subject to the same limitations), or
  (b) creating a `SecAccess` with `trustedApplicationList = nil`
  (unrestricted access to any app — giving up the ACL restriction
  entirely, which is a security trade-off, not a selective bypass).
- Apple documentation (behavior of `SecKeychainItemSetAccess`): "Changing
  an ACL (Access Control List) almost always results in a keychain
  authorization dialog. This is particularly important if you're working
  with a daemon, since this authorization dialog isn't going to work in a
  daemon environment." The official recommendation is to set up the ACL
  **at the moment the item is created**, since changing it later always
  triggers the authorization dialog — [Apple Developer Forums, aggregated
  from a search about SecKeychainItemSetAccess]

### Inferences
- `SecAccessCreate` / `SecACLCreateWithSimpleContents` only avoid the
  dialog when used **at the moment the process itself is creating the
  item** (i.e., the process creating the item sets its own initial ACL,
  with no need for third-party approval, because it's the initial
  "owner"). Once the item already exists with an ACL set by another
  process, modifying that ACL to include a new app requires, by design,
  the owner's explicit approval (via the GUI) — there's no API call
  equivalent to "proof of keychain password → I approve app X" for
  already-existing items with an app-identity-restrictive ACL.
- This is consistent with the `security` command's own behavior (Question
  1): when the ACL entry accepts a password, there's no dialog; when it
  requires an app identity with no password fallback, the only call that
  would resolve it (`SecKeychainItemSetAccess` with no password) requires
  the dialog — and there's no API variant that forces that path with no UI.

### Gaps
- No documentation was found explicitly describing the behavior difference
  of `SecACLSetAuthorizations`/`SecACLSetContents` (the more modern ACL-
  manipulation APIs, part of `SecAccess`) regarding whether they require a
  password or not — documentation of these APIs at the open-source/Apple
  level is scarce, as Apple itself acknowledges ("the docs are kinda
  minimal").

---

## Key question 3: "Authenticating the item" (reading the secret) vs. "modifying the ACL" (adding an app to the trusted list) — is the keychain password enough for the second one, or does Apple deliberately separate the two levels of proof?

### Takeaway
They're distinct mechanisms, and Apple separates them **deliberately per
item**, not universally: each entry in an item's ACL carries its own
combination of (a) a trusted-app list, and (b) whether or not it requires a
password (`require-password` vs. `don't-require-password`). The keychain
password only "suffices" for the `change_acl` authorization when that
entry's own ACL was configured to accept a password; when the entry
depends only on app identity (with no that fallback), the keychain
password has no effect on that specific authorization — confirmed both in
documentation and empirically (Question 4).

### Cited Findings
- A real ACL dump of an item created via `security add-generic-password`
  (this report's empirical test, see Question 4): the `change_acl`
  authorization entry showed up as `applications (0)` +
  `don't-require-password` — i.e., with no specific-app or password
  requirement, **even when the data entry (`decrypt`/`derive`/etc.) was
  restricted to a specific app** (`/System/Applications/Calculator.app`).
  This shows that, in this item format, "reading the secret" and
  "changing the ACL" are authorizations with completely independent
  policies within the same item.
- A real issue reporting exactly this decoupling in the `claude` CLI's
  item: "Even when 'Always Allow' is clicked with the password field, it
  edits the ACL, not the partition list, so the partition-list gate keeps
  blocking. There is no fix available through the Keychain Access UI
  since the partition list isn't shown there." —
  [Lcharvol/Claude-God issue #48](https://github.com/Lcharvol/Claude-God/issues/48)
  (aggregated via search; the terminology confirms "partition list" is an
  ACL layer distinct even from the "visible" ACL in Keychain Access.app)
- Issue anthropics/claude-code #96385 documents the exact lifecycle of the
  user's problem: on every OAuth token rotation, the external process
  (`claude`) rewrites the item and **resets the `partition_id` ACL to
  contain only `apple-tool:`**, removing any `teamid:<other-app>` that had
  been granted before. Literal text from the issue: "Updating the OAuth
  credential value should preserve the existing Keychain item's
  user-configured ACL and partition list. The preferred implementation
  would update only `kSecValueData` on the existing exact item using
  `SecItemUpdate` ... without supplying a replacement `kSecAttrAccess`." —
  [anthropics/claude-code issue #96385](https://github.com/anthropics/claude-code/issues/96385)

### Inferences
- The root cause of the user's problem (the partition list resetting on
  every renewal) is consistent with the external process calling
  `SecItemUpdate`/`SecItemAdd` supplying a new `kSecAttrAccess` (or letting
  the system generate a default based on the writing process's cdhash),
  which **entirely replaces** the previous ACL — different from an update
  that preserves the existing ACL/partition list. This is a recognized bug
  pattern (and would be fixable on the side of the app writing the item,
  not on the reader's side), but it isn't something the user can work
  around from outside in a fully headless way if the resulting ACL is of
  the "app identity only, no password" type.
- "Unlocking the keychain" (`unlock-keychain -p`) and "granting an app
  trust for an item" are, in fact, technically distinct mechanisms: a
  keychain can be unlocked and a specific operation on a specific item can
  still ask for the per-app authorization dialog, because the keychain's
  lock state is a necessary but not sufficient precondition — the per-item
  ACL is evaluated afterward, regardless of the lock state. This is
  consistent with reports in issue #81707, where
  `security unlock-keychain -p` solved the problem for one user but not
  others ("Thank you - off all the suggestions this one seems to have been
  the most effective for me" vs. multiple reports of the bug recurring
  even after that action) —
  [anthropics/claude-code issue #81707](https://github.com/anthropics/claude-code/issues/81707)

### Gaps
- It wasn't possible to confirm programmatically (with no access to the
  real `claude` CLI binary or a real ACL dump of one of its items) whether
  the `Claude Code-credentials` item's `change_acl` entry is of the "no
  password, no app restriction" type (like our test item) or "restricted
  to a specific app, with no password fallback". This distinction is
  exactly what would determine whether
  `security set-generic-password-partition-list -k <login.keychain
  password>` would durably and fully headlessly solve the user's problem.
  GitHub reports (e.g. Kaitiak in #77697) suggest that running this
  command (without `-k`, interactively) "ran without error" but don't
  confirm whether it required a password/GUI entry during execution.

---

## Key question 4: Controlled empirical test (a disposable keychain in /tmp, never in the search list, always cleaned up via a trap)

### Takeaway
Empirically confirmed, on macOS 15.6.1 (build 24G90): when an item's
`change_acl` ACL entry doesn't require a specific app identity (the
observed default for items created via `security add-generic-password`),
`security set-generic-password-partition-list -k <correct password>` runs
**instantly, with no dialog, even when the calling process isn't on the
trusted-apps list for the item's data**. Without `-k` and with stdin
redirected to `/dev/null` (simulating a non-interactive environment), the
tool falls back to a **text** prompt (`password to unlock ...:`) instead
of directly opening the graphical SecurityAgent — no graphical dialog was
ever triggered in any of the tests.

### Cited Findings (from this report's own test, methodology below)
- Methodology: a `/tmp/kctest-<random hex>.keychain-db` keychain, never
  added to the search list (`security list-keychains` confirmed without
  the entry), every command involved wrapped in a `run_with_timeout`
  wrapper (equivalent to `timeout`, implemented via `& + sleep N + kill
  -9` because the GNU `timeout`/`gtimeout` utility isn't installed on
  this machine) with a 4-6s watchdog, and `trap cleanup EXIT` calling
  `security delete-keychain` + `rm -f` on the `.keychain-db` and
  `.keychain-db-lock` files on every exit path (success, error, or
  timeout).
- **Test A** — an item created with no `-T`/`-A` (the `security` CLI's
  default ACL), attempting
  `set-generic-password-partition-list -S "apple-tool:,codesign:org.fake.testapp" -k <password>`:
  `exit=0`, `elapsed=0s`. No sign of a hang/GUI.
- An ACL dump (`security dump-keychain -a`) of the item created via the
  CLI (with no `-T`), showing the real structure of the 3 authorization
  entries:
  ```
  entry 0: authorizations: decrypt derive export_clear export_wrapped mac sign
           applications (1): /usr/bin/security (OK)
  entry 1: authorizations: encrypt
           applications: <null>
  entry 2: authorizations: change_acl
           applications (0):
  ```
  All three entries had `don't-require-password`.
- **Test B1 (decisive)** — an item created with
  `-T "/System/Applications/Calculator.app"` (explicitly restricting data
  access — `decrypt`/`derive`/etc. — to an app that is NOT the calling
  process, simulating an item whose data ACL excludes the caller). The ACL
  dump confirms: `entry 1 (decrypt...): applications (1):
  /System/Applications/Calculator.app (OK)`; however `entry 2
  (change_acl): applications (0)` remained **unrestricted** even on this
  item. Running `set-generic-password-partition-list -k <correct password>
  -S "apple-tool:,codesign:org.fake.testapp"` against this item: `exit=0`,
  `elapsed=0s`, no hang, no dialog.
- Contrast without `-k`, with `stdin < /dev/null` (simulating a
  non-interactive/CI/SSH session with no TTY): the tool printed a
  **plain text** prompt on stdout (`password to unlock
  /tmp/kctest-....keychain-db: `) instead of directly invoking the
  graphical SecurityAgent, and the operation returned `exit=0` with no
  hang (the keychain was already unlocked in the current session since
  its creation, which made this text-based reauthentication effectively a
  no-op in this specific scenario).
- In none of the tests was a process observed running for a time ≥ the
  watchdog's timeout (4s), which would be the expected sign of an attempt
  to open the graphical SecurityAgent waiting for a human response.
- An important test limitation: in no ACL dump (`dump-keychain -a`), on
  this macOS/version of `security`, did a literal "partition_id" text
  field appear (unlike the format reported in GitHub issues, e.g.
  `partition_id description: apple-tool:, teamid:...`). This prevents
  visually confirming, via this binary/version, that the partition list's
  content was actually written (only that the command returned success
  with no dialog). It's possible this output-formatting difference is
  specific to this `security`/macOS version, or that items created by the
  legacy `security add-generic-password` CLI use a different ACL
  representation than items created via modern `SecItemAdd` (which is,
  presumably, the path the `claude` CLI uses).

### Inferences
- The observed behavior (an unrestricted `change_acl` ACL by default on
  items created via `security add-generic-password`) is **a characteristic
  of this specific creation path**, not a general macOS rule. It can't be
  generalized that every keychain item has an unrestricted `change_acl` —
  that depends on how the item was originally created/written (the legacy
  CLI vs. modern `SecItemAdd` with an explicit `kSecAttrAccess`).
- The fact that the `claude` CLI resets `partition_id` to only
  `apple-tool:` on every renewal (per issue #96385) strongly suggests the
  item is written via the modern framework's `SecItemUpdate`/`SecItemAdd`,
  whose default ACL policy tends to be more restrictive by design (tied to
  the writing process's code signature) — unlike the "open" test item we
  got via the legacy CLI. This means Test B1's result **can't be safely
  extrapolated** to the real `Claude Code-credentials` item — it would be
  necessary to inspect that specific item's real ACL
  (`security dump-keychain -a ~/Library/Keychains/login.keychain-db`,
  filtered by the service, WITHOUT using `-d`) to know whether its
  `change_acl` entry accepts a password or requires an app identity.

### Gaps
- It wasn't possible (nor would it be safe/appropriate in this test) to
  inspect the real ACL of the production `Claude Code-credentials` item in
  the user's login.keychain-db, nor to exactly replicate how the `claude`
  CLI writes that item (it probably uses a native binding to
  `SecItemAdd`/`SecItemUpdate`, not the `security` CLI). As a safe next
  step, it's recommended to just run
  `security dump-keychain -a ~/Library/Keychains/login.keychain-db | grep -B30 "Claude Code-credentials"`
  (a pure read operation, no `-d`, nothing changed) to get that specific
  item's real ACL structure before attempting any
  `set-generic-password-partition-list` automation against it.

---

## Key question 5: How does CI/CD (GitHub Actions macOS, fastlane match, Jenkins) run headlessly with no dialog — what's the exact pattern, and does it confirm the window is only at creation/import time?

### Takeaway
The universal industry pattern is: **create your own temporary keychain**
(not the user's/runner's login.keychain) with a known password,
**import** the key/certificate immediately with `-T` pointing at the
tools that will need it (`codesign`, `security`), and **right after that**
(still in the same session/script) run `set-key-partition-list -S
apple-tool:,apple:,codesign: -k <password> <keychain>`. This confirms the
"no-prompt" window is the moment when the process that imported the item
is also the one setting its initial ACL — there's no report of an
equivalent pattern reliably working to reset/widen trust for a
**pre-existing** item, created by another process, after the fact.

### Cited Findings
- A documented pattern (fastlane): "Starting with macOS Sierra, users
  receive keychain permission prompts regardless of whether the keychain
  is unlocked ... The working solution is to call: `security
  set-key-partition-list -S apple-tool:,apple: -s -k keychainPass
  keychainName`." —
  [fastlane/fastlane issue #13564](https://github.com/fastlane/fastlane/issues/13564)
- fastlane's `setup_ci` action: creates a dedicated temporary keychain for
  CI and injects the password automatically to avoid prompts —
  [docs.fastlane.tools/actions/setup_ci](https://docs.fastlane.tools/actions/setup_ci/)
- Apple's official GitHub Action (`apple-actions/import-codesign-certs`)
  follows the same sequence: create a keychain → import a certificate with
  `-T` → `set-key-partition-list -S apple-tool:,apple:,codesign: -s -k
  <password> build.keychain`, confirmed by an engineer who compared
  implementations: "Yes, seems like that's the correct way. At least the
  GitHub Action for apple-actions/import-codesign-certs does the same." —
  [Apple Developer Forums #666107](https://developer.apple.com/forums/thread/666107)
- The technical reason documented by Apple itself (DTS) for needing
  `set-key-partition-list`: "If you'd like to run /usr/bin/codesign with
  the key, 'apple:' must be an element of the partition list ... The
  codesign tool makes an IPC request to securityd to sign data and can
  become blocked waiting for a response if the keychain item's ACL has
  triggered a user authorization request." — aggregated from an Apple
  thread on the topic —
  [Apple Developer Forums #666107](https://developer.apple.com/forums/thread/666107) /
  [Apple Developer Forums #756171](https://developer.apple.com/forums/thread/756171)
- An explicit Apple confirmation that this ACL layer's documentation is
  incomplete by design/history: "Keychain partitions are a bit of a dark
  art because they were added to the file-based keychain long after it was
  initially introduced. Thus, they have no APIs and the docs are kinda
  minimal." — Apple DTS Engineer,
  [Apple Developer Forums #756171](https://developer.apple.com/forums/thread/756171)
- The same thread points to Apple's long-term direction being the "data
  protection keychain" (replacing the file-based keychain model),
  referencing the official technical note TN3137 "On Mac keychain APIs and
  implementations" — TN3137's full content wasn't read in this research
  (a gap).

### Inferences
- The reason the CI pattern works reliably with no prompt is that, at the
  moment of `import`/`add-generic-password`, **the process creating the
  item is the first one to set its own ACL** (analogous to our Test A) —
  there isn't yet a third party's restrictive ACL to "beat". This is
  structurally different from the user's scenario, where the item already
  exists and had its ACL rewritten by an external process (the `claude`
  CLI) that doesn't necessarily leave the `change_acl` entry open.
- No report was found, in any of the sources consulted (fastlane, Apple
  Developer Forums, GitHub Actions), of someone using this pattern to
  **re-add trust to a pre-existing item created by a third-party
  process** with no dialog — the entire documented pattern assumes full
  control over the item's creation/import. This corroborates the answer
  to the user's central question: the "window" is creation, not a later fix.

### Gaps
- It wasn't possible to confirm, from the public sources consulted,
  whether there's any documented exception case (e.g. some specific
  macOS version where Apple relaxed this rule for pre-existing items). No
  source consulted mentions such an exception; the absence of reports is,
  by itself, evidence (though not definitive proof) that the exception
  doesn't exist.
- Technical Note TN3137 ("On Mac keychain APIs and implementations")
  wasn't read in full — it may contain additional details about the "data
  protection keychain" roadmap and whether that new model will change this
  behavior in the future. A dedicated read is recommended if the user
  wants an answer about Apple's future roadmap in this area.
