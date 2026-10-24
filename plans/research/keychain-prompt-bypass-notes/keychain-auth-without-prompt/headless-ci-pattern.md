# Headless macOS CI patterns for code signing with no Keychain prompt

## What is the EXACT sequence of commands fastlane `match`/`create_keychain`/`import_certificate` uses, and why is each step necessary?

### Takeaway
The official sequence — confirmed in fastlane's source code and
replicated almost literally in GitHub Actions' official documentation —
is: `create-keychain` → `set-keychain-settings` → `unlock-keychain` →
`import ... -T <app1> -T <app2> ...` → `set-key-partition-list -S
apple-tool:,apple:,codesign: -s -k <pwd> <keychain>` → `list-keychains`.
Every step, with no exception, happens on a keychain the pipeline itself
created from scratch, in the same process that later imports the
certificate.

### Cited Findings
- fastlane's `create_keychain.rb` assembles the commands, in order:
  `security create-keychain -p #{escaped_password} #{keychain_path}`
  (only if the keychain doesn't already exist); optionally
  `security default-keychain` / `security default-keychain -s
  #{keychain_path}`; optionally `security unlock-keychain -p
  #{escaped_password} #{keychain_path}`; always
  `security set-keychain-settings` (with `-t <timeout>`, `-l`, `-u` per
  the parameters) ending in `#{keychain_path}`; and, if
  `add_to_search_list`, `security list-keychains -s
  #{keychains.shelljoin}` —
  [fastlane/create_keychain.rb](https://github.com/fastlane/fastlane/blob/master/fastlane/lib/fastlane/actions/create_keychain.rb)
- `match`/`import_certificate` delegates the real import to
  `FastlaneCore::KeychainImporter.import_file`, whose command template is:
  `security import #{path.shellescape} -k #{keychain_path.shellescape} -P
  #{certificate_password.shellescape} -f #{certificate_format.shellescape}
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild -T
  /usr/bin/productsign` —
  [fastlane_core/keychain_importer.rb](https://github.com/fastlane/fastlane/blob/master/fastlane_core/lib/fastlane_core/keychain_importer.rb)
- Right after a successful `import` (and unless
  `skip_set_partition_list: true`), the same file runs:
  `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k
  #{keychain_password.shellescape} #{keychain_path.shellescape}` —
  [fastlane_core/keychain_importer.rb](https://github.com/fastlane/fastlane/blob/master/fastlane_core/lib/fastlane_core/keychain_importer.rb)
- GitHub Actions' official documentation ("Installing an Apple certificate
  on macOS runners for Xcode development") prescribes exactly the same
  sequence, with different variable names:
  `security create-keychain -p "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH` →
  `security set-keychain-settings -lut 21600 $KEYCHAIN_PATH` →
  `security unlock-keychain -p "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH` →
  `security import $CERTIFICATE_PATH -P "$P12_PASSWORD" -A -t cert -f
  pkcs12 -k $KEYCHAIN_PATH` → `security set-key-partition-list -S
  apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH` →
  `security list-keychain -d user -s $KEYCHAIN_PATH` —
  [GitHub Docs](https://docs.github.com/en/actions/use-cases-and-examples/deploying/installing-an-apple-certificate-on-macos-runners-for-xcode-development)
- Since macOS Sierra, the keychain asks for permission regardless of
  being "unlocked", which motivated introducing `set-key-partition-list`;
  fastlane's own issue confirms `match` already runs this command
  internally for each imported certificate, making external calls
  redundant in most cases —
  [fastlane/fastlane#13564](https://github.com/fastlane/fastlane/issues/13564)
- Community threads (not officially confirmed by Apple) state that, for
  `codesign` to access the key with no prompt, `apple:` necessarily needs
  to be present in `set-key-partition-list`'s `-S` list —
  [Apple Developer Forums #666107](https://developer.apple.com/forums/thread/666107)

### Inferences
- The order is strict due to functional dependency: you can't
  `unlock-keychain` before `create-keychain` (the file doesn't exist), you
  can't `import` into a locked keychain, and you can't
  `set-key-partition-list` on an item that hasn't been imported yet (the
  item doesn't have a partition list to edit yet).
- The `-T` on `import` and the later `set-key-partition-list` aren't
  redundant: the first sets the classic "trusted applications" list
  (a simple ACL, the old `SecTrustedApplicationCreateFromPath`/
  `SecAccessCreate` API); the second adjusts the partition field
  (`kSecACLAuthorizationPartitionID`), which became the mechanism
  `codesign`/the Security Agent actually checks starting with macOS
  Sierra. Mature tools (fastlane, apple-actions) do both for safety/
  compatibility across macOS versions.

### Gaps
- I found no official Apple explanation (DTS/documentation) detailing the
  exact relationship between the classic "trusted application list" and
  the "partition list" — the Apple forum thread (#666107) got no official
  Apple reply, only community confirmation that the pattern works.

## Does `-T` at import time only work because it happens at the moment the item is created/imported? Would it never work to ADD trust to an already-existing item?

### Takeaway
Confirmed by multiple independent sources (an official Apple forum, the
Jamf community, and a real case nearly identical to the user's problem):
**there's no silent/scriptable path to grant trust to a Keychain item
that already exists and was created by another process.** The only fully
headless way is to control the item's creation (or its recreation via
delete+reimport). Any attempt to edit an already-existing item's ACL
triggers a prompt — even as root.

### Cited Findings
- On Apple's developer forum, a developer tried adding a new
  `SecTrustedApplicationRef` to an **already-existing** keychain item's
  (the login keychain) ACL via `SecItemCopyMatching` →
  `SecKeychainItemCopyAccess` → `SecACLCreateWithSimpleContents` →
  `SecItemUpdate`. The result was `errSecSuccess`, but the new app didn't
  show up in Keychain Access's "Access Control" list, and the operation
  still triggered a password prompt. Apple's DTS engineer (Quinn
  "The Eskimo!") gave no public solution, only asked for more context and
  recommended opening a **paid technical support (DTS) incident** — a
  sign there's no publicly documented solution —
  [Apple Developer Forums #691160](https://developer.apple.com/forums/thread/691160)
- In the Jamf community, administrators trying to grant ACL access to
  **already-imported** keychain items (for VPN clients like GlobalProtect)
  concluded "it's always necessary for the end user to authorize the
  change... It's a security matter, to prevent applications from
  granting themselves access to keychain items without the user's
  knowledge". The only viable solution found was to **export and
  reimport** the certificate/private key, supplying the correct `-T`
  already at import time —
  [Jamf Community](https://community.jamf.com/t5/jamf-pro/keychain-acl-s-scriptable/m-p/83220)
- A case nearly identical to the user's scenario: issue
  `anthropics/claude-code#77697` describes exactly the problem of a
  Keychain item (`Claude Code-credentials`) created with **no**
  trusted-apps list, causing a prompt on every read (every 3-4 minutes of
  use). The suggested fix isn't "grant trust afterward" — it's for the
  tool itself that creates the item to **recreate it with `-T` already at
  write time** (`security add-generic-password -T /usr/bin/security`), or
  else **update the item instead of deleting and recreating it**, to
  preserve the ACL the user manually granted via "Always Allow". This
  confirms that even an "Always Allow" the user manually granted is lost
  if the item is deleted and recreated — the ACL lives on the item, not
  in some global policy —
  [GitHub anthropics/claude-code#77697](https://github.com/anthropics/claude-code/issues/77697)
- The `-U` (update) flag of `security add-generic-password`/`import`
  allows updating an existing item including `-T`, but per community
  reports this operation **always** requires interactive user
  authorization, even run as root, and there's no documented way to
  suppress this prompt — [a finding consolidated from searches about
  `security add-generic-password -U -T`, with no single definitive
  primary source, see Gaps]

### Inferences
- Apple's security architecture treats granting trust as an act that can
  only happen (a) at the moment the process that's already the item's
  "owner"/creator sets its initial ACL, or (b) via explicit human
  interaction (a prompt) at any later moment. There's no silent third way
  to change an item's ACL that another process already owns.
- For the user's scenario (a third-party app needs to repeatedly read a
  Keychain item IT DIDN'T CREATE and that's periodically recreated by
  another process), the only way to solve it with no prompt would be:
  (1) the third-party app takes over as the item's creator/reimporter
  (controls the write), or (2) the original process starts including the
  third-party app in its `-T` list at the moment it itself creates/
  recreates the item — i.e., cooperation from the writing side, not a
  unilateral technique from the reading side.

### Gaps
- I found no primary source (Apple documentation or source code)
  describing with certainty the exact behavior of
  `security add-generic-password -U -T <app>` on a pre-existing item
  headlessly (with `sudo`/root, no UI session) — the reports are from
  community forums, not tested official documentation. If this turns out
  to be a relevant path for the product, I recommend a controlled
  empirical test (a root script, with no active GUI) before definitively
  ruling it out.
- I found no documentation about modern Keychain Services APIs
  (`kSecUseDataProtectionKeychain`, `SecAccessControl`) offering a
  different path for "upgrading" an ACL with no prompt; Apple appears to
  have deprecated the old model (`SecTrustedApplicationCreateFromPath`)
  with no equivalent replacement for file-based keychains (not the Data
  Protection Keychain) — see the "SecTrustedApplicationCreateFromPath
  replacement" thread (no conclusive answer in the search results).

## Is there any documented case of CI needing to grant access to an item created by ANOTHER process/tool outside its control?

### Takeaway
I found no documented case of a CI pipeline granting access to a
pre-existing Keychain item created by another tool. The universal pattern
observed across every source (fastlane, GitHub Actions, Jenkins, DevOps
blogs) is the opposite: CI always creates its own ephemeral keychain from
scratch and imports/creates every item inside it, precisely to avoid this
problem.

### Cited Findings
- The recommended, universally documented practice for CI (GitHub
  Actions, Jenkins, custom scripts) is: create a temporary keychain in
  `$RUNNER_TEMP`, unlock it, set the partition list, and delete it in an
  `always()` step at the end of the job — never reuse or inherit a
  keychain/login keychain already populated by another process —
  [GitHub Actions runner-images discussions](https://github.com/actions/runner-images)
  (via aggregated search, see the Gaps note)
- On GitHub-hosted runners, the whole VM is destroyed at the end of the
  job, so certificates and keychains used in the job are destroyed along
  with it — there's no concept of a "keychain inherited from a previous
  run" needing authorization — [confirmed via a search about GitHub
  Actions' ephemeral runners]
- The article "Developers need to handle macOS binary signing" (Anchore
  Engineering) and the "Code Signing on CI" guide describe the same
  pattern: the CI tool is always the one creating and populating the
  keychain from scratch before signing, never inheriting a third party's
  item —
  [Anchore Engineering](https://medium.com/anchore-engineering/developers-need-to-handle-macos-binary-signing-how-we-automated-the-solution-part-2-ad1e08caff0f)
- Jenkins on macOS agents follows the same model: build scripts do
  `create-keychain` → `unlock-keychain` → `import` →
  `set-keychain-settings` → `set-key-partition-list`, with the Jenkins
  pipeline itself controlling creation end to end — there's no report of
  Jenkins "inheriting" certificates from other software already installed
  on the agent — [findings aggregated from multiple Apple Developer
  Forums threads about Jenkins/SSH/keychain, e.g. #126148, #705723]

### Inferences
- The total absence of a documented case of "granting trust to a
  third-party item" in the CI/DevOps literature is, by itself, a strong
  signal: the industry solved this problem by structurally avoiding it
  (controlling creation), not by finding a technique to work around it
  when creation isn't controlled. This is consistent with the previous
  question's answer (Apple offers no silent path for this).

### Gaps
- I specifically searched for "CI inheriting keychain from another tool"
  and "authorizing an item managed by other software already installed"
  and found no report, neither positive nor a documented failure — the
  gap here is the absence of data, not a definitive negative finding.
  There may be reports in private/internal company forums that Google
  doesn't index.

## How do GitHub Actions macOS runners handle the ephemeral keychain? Is there an API/MDM/profile that suppresses Keychain dialogs globally?

### Takeaway
There's no documented API, runner setting or MDM profile that suppresses
Keychain dialogs "globally". What exists is: (a) the VM being fully
destroyed on every job (hosted runners), making the problem irrelevant by
restart, and (b) the manual practice of creating/destroying an ephemeral
keychain per job (self-hosted/persistent runners). No policy mechanism
replaces the need for the create→import→partition-list pattern.

### Cited Findings
- GitHub-hosted runners (`macos-latest`, etc.) are isolated VMs
  automatically destroyed at the end of the job's run — there's no
  keychain state persistence between jobs by definition, and no special
  config is needed to "reset" the keychain, since the whole image is
  discarded — [GitHub Actions runner-images discussions, aggregated
  findings]
- For self-hosted (persistent) runners or builds within the same job, the
  recommendation GitHub documents is the same manual ephemeral-keychain
  technique (previous section) — there's no runner flag or
  `actions/runner` environment variable that disables Keychain Services
  prompts — [GitHub Docs on installing Apple certificates](https://docs.github.com/en/actions/use-cases-and-examples/deploying/installing-an-apple-certificate-on-macos-runners-for-xcode-development)
- Registering a runner with the `--ephemeral` flag (from `actions/runner`
  v2.337.0 on) makes the runner auto-deregister after a single job, but
  that's a job-orchestration property of Actions, not a Keychain-
  prompt-suppression policy — [finding aggregated from
  actions/runner-images and actions/runner discussions]

### Inferences
- "Headless" on GitHub Actions runners doesn't mean "a special technique
  suppresses the dialogs" — it means "the dialog would never have a
  reason to appear because the item never existed before that job and no
  real interactive user session ever accesses that keychain outside the
  script". It's effectively the same "control the creation" pattern, just
  combined with the whole VM being destroyed.

### Gaps
- I found no mention of a proprietary GitHub runner (`actions/runner`)
  API or environment variable related to Keychain Services — the absence
  of results strongly suggests this API doesn't exist, but it isn't
  definitive proof of nonexistence.

## Is there an MDM profile / managed configuration to pre-authorize apps to access keychains with no prompt (even outside CI, e.g. corporate laptops)?

### Takeaway
There's a real but narrow institutional exception: MDM configuration
profiles that **install certificates/identities via a certificate
payload** (e.g. PKCS#12, ACME, AD Cert) support the `AllowAllAppsAccess`
key (macOS 10.10+), which lets any app access the private key with no
prompt. This only applies to keychain items created by the MDM's own
profile-installation mechanism — it isn't a generic mechanism to
authorize access to an arbitrary Keychain item created by a third-party
app.

### Cited Findings
- Apple's configuration-profile reference defines, for certificate
  payloads (`com.apple.security.pkcs12` and variants like ACME/AD Cert),
  the `AllowAllAppsAccess` key: "If true, the system allows apps access
  to the private key" (macOS 10.10+) —
  [Apple Device Policy Explorer — Certificate PKCS#12](https://appledevicepolicy.tools/policy-explorer/detail?type=com.apple.security.pkcs12&branch=release)
- The same documentation defines `KeyIsExtractable` (macOS 10.15+): if
  `false`, the private key isn't marked extractable in the keychain; this
  is an additional policy setting, orthogonal to `AllowAllAppsAccess` —
  [findings aggregated from a search on certificate payloads]
- An important, specific observation: `AllowAllAppsAccess` only works for
  ACME payloads when `HardwareBound` is `false` — i.e., it doesn't work
  with hardware-bound keys (Secure Enclave) —
  [Apple Developer Forums #746030 — ACME Managed Device Attestation Payload](https://developer.apple.com/forums/thread/746030)
- Jamf community participants confirmed the same pattern on AD (Active
  Directory) certificate payloads: there's "a checkbox to make the
  private key accessible to all apps", but it's configured at the moment
  the MDM installs the certificate via a profile — not afterward, and not
  for items that already exist outside that install flow —
  [Jamf Community](https://community.jamf.com/t5/jamf-pro/keychain-acl-s-scriptable/m-p/83220)

### Inferences
- `AllowAllAppsAccess` is structurally the same principle as
  `security import`'s `-T`/partition-list: a flag set **at the moment the
  installer creates the item** (in this case, the MDM daemon processing
  the profile), never a way to edit an already-existing item's ACL. This
  reinforces — from a completely different source (device management,
  not CI) — the same structural conclusion from question 2.
- This mechanism doesn't apply to the user's scenario: it isn't a common
  consumer app with no MDM, and even if it were, `AllowAllAppsAccess` only
  applies to items the MDM itself creates via a certificate payload, not
  to generic Keychain items ("generic password", for instance) created by
  an arbitrary third-party app.

### Gaps
- I found no profile key equivalent to `AllowAllAppsAccess` for "generic
  password" keychain items (e.g. OAuth tokens, app credentials like the
  user's case) — the documented key is specific to certificate/identity
  payloads. If an MDM payload for generic passwords exists, it didn't
  show up in any source consulted.

## Does `security authorizationdb` relate to suppressing Keychain dialogs, or is it a completely different system?

### Takeaway
Confirmed: they're completely distinct systems. `authorizationdb`/
Authorization Services controls **privilege elevation** rules (e.g. who
can run a tool as root, `sudo`-like policies,
`AuthorizationExecuteWithPrivileges`), and has no ACL mechanism over
individual Keychain items. Keychain Services (per-item ACL,
trusted-application list, partition list) is the layer that actually
controls the "App X wants to access..." prompts.

### Cited Findings
- `authorizationdb` defines rules about who can run which privileged
  tasks on macOS; the `security authorizationdb read/write` command lets
  any user read, but writing requires root — it's a policy about
  authorizing system actions, not about Keychain items —
  [krypted.com — authorizationdb Defaults](https://krypted.com/utilities/authorizationdb-defaults-macos-10-14/)
  and
  [HackTricks — macOS Authorizations DB & Authd](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-authorizations-db-and-authd.html)
- `AuthorizationExecuteWithPrivileges` is an API (deprecated since macOS
  10.7) for running an external tool with root privileges, historically
  used by installers; Apple's current recommendation is to use a
  privileged helper managed by `launchd` with XPC — none of this relates
  to Keychain item ACLs —
  [Apple Developer Documentation — AuthorizationExecuteWithPrivileges](https://developer.apple.com/documentation/security/authorizationexecutewithprivileges)
- There's one specific integration point between the two systems: since
  macOS 10.15, the `authorizationhost` process started using an XPC
  helper to access system keychain items, responsible for running
  third-party authorization plugin code — but this is an internal
  implementation detail of `authorizationhost` itself, not a path for
  third-party apps to suppress Keychain prompts via `authorizationdb` —
  [finding aggregated from search, see the reliability note in Gaps]

### Inferences
- These are two macOS security subsystems with orthogonal purposes:
  Authorization Services = "who can do what with elevated privilege";
  Keychain Services (ACL/trusted-app-list/partition-list) = "who can
  read/use this specific Keychain item with no prompt". There's no
  functional overlap that would let you use `authorizationdb` as a
  shortcut for the user's Keychain-prompt problem.

### Gaps
- The detail about `authorizationhost`/the XPC helper in macOS 10.15+
  comes from an aggregated search result with no clear, specific primary
  source located in this research; I treat it as low-confidence context,
  not a central finding of the answer.

---

## Consolidated classification for the user's scenario

**Scenario:** a third-party app needs to repeatedly read a Keychain item
**it doesn't create** and that's periodically created/recreated by
**another process**, never triggering the authorization prompt.

- **VIABLE** — no technique found satisfies this scenario with no change
  to the process creating/recreating the item.
- **PARTIALLY VIABLE** — if the third-party app can influence/cooperate
  with the creating process (e.g. the creating process starts including
  the third-party app in its `-T` list at creation time, or the two
  processes are reconciled so the third-party app is the one actually
  writing the item), the CI pattern (`-T` at creation/import) becomes
  applicable. This stops being "granting trust to a pre-existing item"
  and becomes "controlling the next creation", which is exactly the
  pattern validated by fastlane/GitHub Actions/Jenkins.
- **UNVIABLE** — as a unilateral technique on the reading side only, with
  no control over or change to the creating process's write behavior: all
  evidence collected (Apple Developer Forums #691160, the Jamf community,
  and the analogous `anthropics/claude-code#77697` case) indicates there's
  no scriptable, headless way to add an app to an already-existing
  Keychain item's ACL with no interactive prompt — even as root. The only
  documented "escape" is deleting and reimporting the item with the
  correct `-T` already baked into the creation command, which requires
  owning the item's lifecycle (or convincing whoever does).
