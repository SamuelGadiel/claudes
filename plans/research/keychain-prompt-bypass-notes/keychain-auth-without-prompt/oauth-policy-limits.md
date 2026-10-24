# Limits of Anthropic's policy on OAuth tokens from consumer accounts outside Claude Code

## 1. What is the current, literal wording of the policy — does it forbid ANY use of the token, or specifically inference?

### Takeaway
The CURRENT official policy (the `code.claude.com/docs/en/legal-and-compliance`
page, "Authentication and credential use" section, read live on 10/13/2026)
**has changed wording compared to the February/2026 version** and is
narrower today: it no longer says "using the OAuth token in any other
product/tool/service, including the Agent SDK, is not permitted". Instead,
it (a) recommends developers use an API key, (b) explicitly forbids only
three concrete things — offering Claude.ai login inside a third-party app,
routing requests with Free/Pro/Max credentials **on behalf of other
users** (intermediation/resale), and collecting/storing/intermediating
credentials or session tokens — and (c) contains a "doesn't restrict"
clause that appears to explicitly cover the "end user logs into the
unmodified official binary with their own subscription" pattern. Neither
the old nor the new version draws a textual distinction between "an
inference call" and "a metadata/usage call" — the policy never talks
about specific endpoints, it talks about "Claude's capabilities" and
"credentials" in generic terms.

### Cited Findings
- CURRENT full text (direct fetch on 10/13/2026) of the "Authentication
  and credential use" section: "OAuth authentication is intended
  exclusively for purchasers of Claude Free, Pro, Max, Team, and
  Enterprise subscription plans and is designed to support ordinary use
  of Claude Code and other native Anthropic applications." —
  [Legal and compliance — Claude Code Docs](https://code.claude.com/docs/en/legal-and-compliance)
- Same section: "Developers building products or services that interact
  with Claude's capabilities, including those using the Agent SDK, should
  use API key authentication through Claude Console or a supported cloud
  provider. Anthropic does not permit third-party developers to offer
  Claude.ai login into their own applications, or to route requests
  through Free, Pro, or Max plan credentials on behalf of their users.
  Moreover, developers may not collect, store, or intermediate Claude.ai
  credentials or session tokens — sign-in to a Claude account must
  complete through Anthropic's own flow." —
  [Legal and compliance — Claude Code Docs](https://code.claude.com/docs/en/legal-and-compliance)
- A non-restriction clause, same section: "This does not restrict how
  customers provision and manage their own API keys or third-party
  inference provider credentials... Nor does it prevent an end user from
  signing in to the unmodified Claude Code binary with their own Claude
  subscription, including where a platform hosts Claude Code as described
  under *Can customers offer Claude Code in their products?* above." —
  [Legal and compliance — Claude Code Docs](https://code.claude.com/docs/en/legal-and-compliance)
- "Anthropic reserves the right to take measures to enforce these
  restrictions and may do so without prior notice." —
  [Legal and compliance — Claude Code Docs](https://code.claude.com/docs/en/legal-and-compliance)
- A separate section, "Can customers offer Claude Code in their
  products?": "Unless we've mutually agreed otherwise, preinstalling or
  running Claude Code in your products or services (e.g. in hosted
  sandboxes or other agent infrastructure) requires agreeing to our
  Commercial Terms of Service" + "The Claude Code binary must not be
  modified" + "Customers may not pay for, resell, or intermediate Claude
  usage on their end users' behalf. Each end user must authenticate with
  their own Anthropic API key, Claude subscription plan credentials, or
  3P inference provider credential." —
  [Legal and compliance — Claude Code Docs](https://code.claude.com/docs/en/legal-and-compliance)
- The OLD wording (Feb/2026, consistently cited by multiple secondary
  sources, including an official-like post shared by devs and tech press
  articles, but I **couldn't access the archived primary snapshot** — see
  Gaps): "Using OAuth tokens obtained through Claude Free, Pro, or Max
  accounts in any other product, tool, or service — including the Agent
  SDK — is not permitted and constitutes a violation of the Consumer
  Terms of Service." — cited in
  [Rob Zolkos on X](https://x.com/robzolkos/status/2024125323755884919),
  [GitHub Issue AndyMik90/Aperant#1871](https://github.com/AndyMik90/Aperant/issues/1871),
  [The Register](https://www.theregister.com/software/2026/02/20/anthropic-clarifies-ban-on-third-party-tool-access-to-claude/5014546)
- Reporting pointing to the date of the wording change: "As of October 7,
  2026, Anthropic rewrote the authentication section of its Legal and
  Compliance page. The line about OAuth tokens and the Agent SDK is
  gone" — a search result aggregating multiple sources (not a quote from
  a single specific article, see Gaps)
- The Consumer Terms of Service (anthropic.com/legal/consumer-terms)
  contain a distinct, broader clause, outside the Claude Code page: "You
  may not share your Account login information, Anthropic API key, or
  Account credentials with anyone else" and "Except when you are
  accessing our Services via an Anthropic API Key or where we otherwise
  explicitly permit it, [you may not] access the Services through
  automated or non-human means, whether through a bot, script, or
  otherwise." — [Consumer Terms of Service](https://www.anthropic.com/legal/consumer-terms)

### Inferences
- The policy has NEVER made (neither before nor now) an explicit textual
  distinction between "inference" and "metadata/usage". The prohibition
  has always been phrased in terms of **credential** and **product/
  service** ("in any other product, tool or service" / "intermediate
  credentials"), not in terms of **the type of endpoint being called**.
  This means the safest reading is: there's no textual carve-out for
  "I'm only reading usage, it's not inference" — the official criterion is
  about WHO/WHAT is using the credential, not WHICH call is being made.
- The softening of the wording in October/2026 (removing the absolute
  phrase "including the Agent SDK is not permitted") is a relevant data
  point: it suggests Anthropic backed off from a generic ban on "any use
  outside Claude Code/claude.ai" to a ban focused on **resale/multi-tenant
  intermediation** and **offering embedded Claude.ai login**. This opens a
  more favorable reading for single-tenant tools (personal use, one
  account at a time, no resale) — but this is my own interpretive
  inference, not an explicit Anthropic statement saying "personal
  read-only tools are cleared".
- The Consumer Terms' "automated or non-human means... bot, script" clause
  (a separate legal document, broader than the Claude Code doc) is an
  independent additional risk: even if the Claude Code doc's reading is
  favorable, this consumer-contract clause, taken literally, covers
  "accessing the Services" via a script with no API key — which could be
  read as covering even the act of ClaudeS **invoking the official binary
  as a subprocess** (automated access), regardless of who actually makes
  the final HTTP call.

### Gaps
- I couldn't access an archived snapshot (Wayback Machine blocked in this
  environment) with the EXACT wording and EXACT publication date of the
  February/2026 text straight from Anthropic. Every citation of the old
  text comes from secondary sources (X posts, GitHub issues, press
  articles) consistently reproducing the same sentence — it's reasonable
  to treat this consistency across multiple independent sources as strong
  evidence the text is accurate, but it isn't confirmation from an
  archived primary source.
- I didn't find a version of the Anthropic Usage Policy
  (`anthropic.com/legal/aup`) with specific text about OAuth — only the
  cross-reference in the Claude Code doc. I didn't directly fetch the
  AUP; the findings about "automated access" come from the Consumer
  Terms, not the AUP.
- There's no official confirmation of the REASON for the October/2026
  change (a deliberate policy walk-back vs. editorial simplification vs.
  a reaction to some complaint/lawsuit). This is third-party speculation,
  not an Anthropic statement.

---

## 2. What is the EXACT technical mechanism of server-side enforcement?

### Takeaway
There's concrete, detailed technical evidence, from developers who
debugged the block in OpenCode and other tools: enforcement happens in at
least two layers — (1) in the OAuth token exchange itself, where the
wrong `User-Agent` triggers a blocking 429; and (2) in the inference call
(`POST /v1/messages`), where the server appears to validate the request's
full "shape" (a specific system prompt, tool set, headers, a
`metadata.user_id` field, the absence of `temperature`) — but this layer
2 is described by a third-party Hacker News comment, not confirmed by
Anthropic, and should be treated as community analysis, not established
fact.

### Cited Findings
- A universal error reproduced across multiple projects (Roo-Code,
  OpenCode, the official Claude Code with a misrouted credential):
  `400 | {"type":"error","error":{"type":"invalid_request_error","message":"This credential is only authorized for use with Claude Code and cannot be used for other API requests."}}` —
  [RooCodeInc/Roo-Code#10566](https://github.com/RooCodeInc/Roo-Code/issues/10566),
  [anthropics/claude-code#8060](https://github.com/anthropics/claude-code/issues/8060)
- In GitHub issue `anthropics/claude-code#8060`, the traceback shows the
  error surfacing both as a 400 (error body) and as a 403 in a
  transport-level AxiosError, with no comment from an Anthropic employee
  explaining the mechanism — the issue was auto-closed from inactivity,
  not from an official response. —
  [anthropics/claude-code#8060](https://github.com/anthropics/claude-code/issues/8060)
- In `anomalyco/opencode#18329`, the initial block identified was at the
  token-exchange endpoint ITSELF (`.../v1/oauth/token`), with a 429
  "Rate limited" and NO `Retry-After` header; the root cause the
  community identified was twofold: (a) an incorrect Content-Type
  (`application/json` instead of the `application/x-www-form-urlencoded`
  required by OAuth2 RFC 6749 §4.1.3) and (b) a generic `User-Agent`
  (`"anthropic"`) being "blanket-rejected" with a 429, while the expected
  `User-Agent` follows the `claude-cli/<version>` pattern. —
  [anomalyco/opencode#18329](https://github.com/anomalyco/opencode/issues/18329)
- A report from the OpenCode block's founder (via Hacker News) that
  "Anthropic deployed server-side checks on January 9, 2026 that began
  rejecting OAuth tokens from third-party tools" and that the error
  message received was the same "This credential is only authorized..."
  string —
  [Anthropic Explicitly Blocking OpenCode (HN)](https://news.ycombinator.com/item?id=46625918)
- A detailed technical comment in the same HN thread (non-Anthropic
  authorship, a third-party analysis) describes "request body
  fingerprinting on the server side" checking at least 5 criteria: (1) the
  system prompt must start with "You are a Claude agent, built on
  Anthropic's Claude Agent SDK"; (2) exactly 17 tools with PascalCase
  names identical to Claude Code's (e.g. "Bash", not "bash"); (3) specific
  headers including `anthropic-beta`, `x-app: cli` and a `User-Agent`
  following the `claude-cli` pattern; (4) a `metadata.user_id` field in a
  specific format; (5) the absence of the `temperature` parameter in the
  request. —
  [Anthropic Explicitly Blocking OpenCode (HN)](https://news.ycombinator.com/item?id=46625918)
  — **treat as a third-party hypothesis, not an official confirmation**
- Same thread: a user reports having worked around the block by creating
  a local proxy that captures the exact formatting of the official Claude
  Code's requests and replaces OpenCode's payload while preserving the
  required headers/metadata — which is indirect evidence (but not formal
  proof) that the barrier is, in fact, based on "request shape" and not
  on a cryptographic secret intrinsic to the binary. —
  [Anthropic Explicitly Blocking OpenCode (HN)](https://news.ycombinator.com/item?id=46625918)
- A statement attributed to an Anthropic engineer (Thariq Shihipar),
  quoted by The Register, about the block's motivation: "Third-party
  harnesses using Claude subscriptions create problems for users and are
  prohibited by our Terms of Service. They generate unusual traffic
  patterns without any of the usual telemetry that the Claude Code
  harness provides, making it really hard for us to help debug when they
  have questions about rate limit usage or account bans." —
  [The Register, 02/20/2026](https://www.theregister.com/software/2026/02/20/anthropic-clarifies-ban-on-third-party-tool-access-to-claude/5014546)

### Inferences
- Combining the two incidents (the token exchange blocked by the wrong
  User-Agent; the inference call blocked by payload fingerprinting)
  strongly suggests enforcement is NOT a single, centralized mechanism,
  but a sum of heterogeneous layers: User-Agent/header validation at some
  points, inference-payload-shape validation at another. There's no
  evidence of a cryptographic binary-attestation mechanism (see question
  4) — everything reproduced is workable around by replicating the same
  headers/payload, which is consistent with behavioral/structural
  fingerprinting, not with cryptographic proof of process identity.
- The Anthropic engineer's statement about "telemetry" and "unusual
  traffic patterns" suggests part of the enforcement (or at least the
  justification) is based on **usage-pattern/anomaly analysis**, not just
  a deterministic per-request check — reinforcing the "multiple layers"
  reading over "a single lock".

### Gaps
- There's no official Anthropic statement at all (documentation, blog,
  employee post) describing the internal technical enforcement mechanism
  in detail. Everything describing "how" comes from third-party reverse
  engineering (mainly an unverifiable HN comment). Confidence in the 5
  fingerprinting criteria listed above is MEDIUM-LOW — it's plausible and
  consistent with the errors observed, but not confirmed by a primary
  source.
- I found no equivalent technical report of the `/api/oauth/usage`
  (metadata/account) endpoint being blocked the same way `/v1/messages`
  (inference) was — see question 3.

---

## 3. Are metadata/account endpoints (usage/account) treated differently from inference endpoints?

### Takeaway
I found no source — official or third-party — describing the usage/
account endpoint (`GET /api/oauth/usage`) being ACTIVELY BLOCKED by the
server the way `/v1/messages` was. At the same time, I found a real,
direct precedent of a companion tool (`claude-hud`) that used this
metadata endpoint directly with the OAuth token, whose own maintainer
treated it as a compliance risk and migrated to an approach that doesn't
depend on calling Anthropic directly — i.e., the absence of documented
technical blocking for the usage endpoint doesn't imply the absence of
policy risk.

### Cited Findings
- `claude-hud` (a statusline plugin for Claude Code that shows rate-limit
  usage) had a `usage-api.ts` file (~1,100 lines) that read OAuth
  credentials directly from `~/.claude/.credentials.json` or the macOS
  Keychain and made `POST https://api.anthropic.com/api/oauth/usage` with
  `Authorization: Bearer <oauth_token>`. —
  [jarrodwatts/claude-hud#287](https://github.com/jarrodwatts/claude-hud/issues/287)
- The issue was opened explicitly citing the policy text ("OAuth
  authentication...is intended exclusively for Claude Code and
  Claude.ai. Using OAuth tokens...in any other product, tool, or
  service...is not permitted") as grounds for claiming that using the
  usage endpoint from a separate Node process (even if spawned as a
  subprocess of Claude Code) fell into a "gray zone or clear violation". —
  [jarrodwatts/claude-hud#287](https://github.com/jarrodwatts/claude-hud/issues/287)
- The maintainer replied "Looking into this!" and the fix, merged via PR
  #288 (03/23/2026), was migrating to consume the `rate_limits` data that
  already comes natively through stdin from Claude Code's official
  statusline API — i.e., stopping calling Anthropic directly and instead
  getting the data from what Claude Code already exposes to the child
  process. —
  [jarrodwatts/claude-hud#287](https://github.com/jarrodwatts/claude-hud/issues/287)
- In another similar project, `Maciek-roboblog/Claude-Code-Usage-Monitor`,
  issue #202 describes the same undocumented endpoint
  (`GET https://api.anthropic.com/api/oauth/usage`, with `Authorization:
  Bearer` and `User-Agent: claude-code/<version>`) being used via a
  DIRECT call (not through the official CLI) to get "authoritative window
  state" across devices — but this issue **contains no compliance/ToS
  discussion at all**; it was treated purely as a data-accuracy technical
  problem and closed as resolved via PR #221 with no mention of usage
  policy whatsoever. —
  [Maciek-roboblog/Claude-Code-Usage-Monitor#202](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor#202)

### Inferences
- The existence of this `/api/oauth/usage` endpoint being called directly
  by multiple community tools, with no report of active technical
  blocking (unlike what happened to `/v1/messages` in the OpenCode case),
  is circumstantial evidence that SERVER-SIDE enforcement, as of this
  research, appears concentrated on INFERENCE endpoints, not
  metadata/usage ones. This is consistent with Anthropic's stated
  motivation (the Thariq Shihipar quote) that the central concern is
  model consumption with no proper telemetry — usage/metadata doesn't
  consume model capacity.
- HOWEVER, this absence of documented technical blocking is an
  ENFORCEMENT data point, not a POLICY one. The policy text (sections 1
  and 3 above) makes no such distinction, and the `claude-hud` precedent
  shows at least one third-party tool maintainer proactively interpreting
  that the usage endpoint ALSO falls under the textual prohibition ("any
  other product, tool, or service"), even without having been technically
  blocked. In other words: the lack of active blocking on the usage
  endpoint may simply be a lack of enforcement priority so far, not tacit
  permission — and shouldn't be read as "the usage endpoint is cleared".

### Gaps
- No source (official or third-party) explicitly confirms or denies
  whether Anthropic intends to, in the future, extend the same
  fingerprinting/blocking used on `/v1/messages` to `/api/oauth/usage`.
  This is a non-quantifiable risk: the historical pattern (Feb-Mar/2026)
  shows Anthropic acting first against inference consumption (direct
  money/cost) — there's no guarantee the metadata endpoint stays
  unenforced indefinitely, especially after the October/2026 wording
  change broadens the language to "credentials or session tokens" in a
  generic way.
- I found no Anthropic statement (support, blog, or employee) directly
  answering the question "is reading usage via an OAuth token in a
  third-party tool permitted?". The claude-hud precedent is the
  interpretation of ONE third-party maintainer, made out of caution, not
  an Anthropic answer.

---

## 4. Does enforcement distinguish WHO is calling (the official binary vs. another process using the same token)? Is there binary attestation?

### Takeaway
There's no evidence at all of cryptographic binary attestation,
certificate pinning, or install verification. Every block reproduced and
documented was workable around by replicating headers/payload/User-Agent
— i.e., the enforcement observed so far is based on "request shape"
(behavioral/structural fingerprinting) and possibly usage-pattern
analysis, not on a rigid technical barrier per process/binary identity.

### Cited Findings
- The OpenCode case shows the initial block (token exchange, 429) was
  caused by HTTP implementation differences (the wrong Content-Type, a
  generic User-Agent) — fixing these details to IMITATE the official
  client, the community reported successfully performing the token
  exchange. —
  [anomalyco/opencode#18329](https://github.com/anomalyco/opencode/issues/18329)
- At the inference-level block, a user reported working around the
  restriction by creating a LOCAL PROXY that captures the official Claude
  Code's exact request formatting and reapplies it to OpenCode's payload
  — success reported in dodging the block by replicating the request's
  "appearance", with no additional secret credential exchanged. —
  [Anthropic Explicitly Blocking OpenCode (HN)](https://news.ycombinator.com/item?id=46625918)
- No source researched (GitHub issues, HN, press articles, X posts)
  mentions any app-attestation mechanism, server-verified binary
  signature, or Claude-Code-specific certificate pinning. The OAuth
  `client_id` is public and fixed (confirmed in this research's earlier
  context), which by itself is incompatible with any strong attestation
  scheme — if client identity were cryptographically verified, a public,
  shared client_id wouldn't serve as a differentiator.
- Engineer Thariq Shihipar's statement (via The Register) speaks of
  "unusual traffic patterns" and "telemetry" as the basis for
  detection/justification, pointing to behavioral/statistical analysis,
  not a deterministic per-request lock. —
  [The Register, 02/20/2026](https://www.theregister.com/software/2026/02/20/anthropic-clarifies-ban-on-third-party-tool-access-to-claude/5014546)

### Inferences
- The most technically defensible conclusion, with the available
  evidence, is: the server CANNOT (or at least hasn't demonstrated it
  can) cryptographically distinguish "this came from the official binary"
  from "this came from another process using the same token". The
  distinction is made by request-shape heuristics (headers, payload
  shape, user-agent) and possibly by usage-pattern/anomaly over time —
  both workable around, or, conversely, both capable of producing FALSE
  POSITIVES against legitimate use that doesn't "look" exactly like
  Claude Code's traffic.
- For ClaudeS's case in the CURRENT arrangement (spawning the official
  binary, which is actually the one assembling and signing the HTTP
  request, using its own internal header/payload logic): since it's the
  OFFICIAL binary itself, unmodified, generating the request byte for
  byte, it necessarily goes through any payload fingerprinting the same
  way it would if the user had run `claude` directly in the terminal —
  there's no "request shape" difference to detect, because there's no
  alternative HTTP request being forged. The only possible detection
  vector in this arrangement would be an anomalous USAGE PATTERN (e.g.
  multiple credential swaps/invocations in sequence that don't look like
  a single human interactive session) — a policy/ToS risk, not a
  "technical per-request blocking" risk.

### Gaps
- There's no confirmation that Anthropic will NEVER institute binary
  attestation (e.g. a nonce locally signed by the official binary, a
  header derived from a secret embedded in the official installer). The
  current absence of evidence isn't a guarantee of future absence — and
  the October/2026 wording change shows the policy and enforcement are
  actively in motion.

---

## 5. Is ClaudeS's CURRENT arrangement (never calling Anthropic directly, always spawning the official `claude` binary as a subprocess) inside or outside the policy?

### Takeaway
Based on the CURRENT (10/13/2026) wording of the official doc, the
arrangement has a strong favorable textual argument ("Nor does it prevent
an end user from signing in to the unmodified Claude Code binary with
their own Claude subscription"), but there are TWO important reservations
the sources don't resolve: (a) the "Can customers offer Claude Code in
their products?" section imposes the Commercial Terms framing whenever
someone "runs Claude Code inside their product/service", and it isn't
clear whether a personal local app (not hosted, not multi-user) counts as
"your product/service" in that sense; (b) the separate Consumer Terms
clause about "automated/scripted access" is written broadly and wasn't
designed with this specific case in mind, creating residual ambiguity.

### Cited Findings
- Text favoring ClaudeS: "Nor does it prevent an end user from signing in
  to the unmodified Claude Code binary with their own Claude subscription,
  including where a platform hosts Claude Code as described under *Can
  customers offer Claude Code in their products?* above." —
  [Legal and compliance — Claude Code Docs](https://code.claude.com/docs/en/legal-and-compliance)
- Same document, the explicit condition accompanying the "running Claude
  Code inside a product" scenario: "The Claude Code binary must not be
  modified. Claude Code must be installed and run as published by
  Anthropic, and customers may not remove, disable, or restrict any
  authentication method built into it" + "Customers may not pay for,
  resell, or intermediate Claude usage on their end users' behalf. Each
  end user must authenticate with their own Anthropic API key, Claude
  subscription plan credentials, or 3P inference provider credential." —
  [Legal and compliance — Claude Code Docs](https://code.claude.com/docs/en/legal-and-compliance)
- The same section opens with: "Unless we've mutually agreed otherwise,
  preinstalling or running Claude Code in your products or services (e.g.
  in hosted sandboxes or other agent infrastructure) requires agreeing to
  our Commercial Terms of Service" — the examples given ("hosted
  sandboxes", "agent infrastructure") are all MULTI-USER/hosted
  infrastructure for third parties, not a local tool for personal use —
  but the text doesn't explicitly restrict the scope to those examples. —
  [Legal and compliance — Claude Code Docs](https://code.claude.com/docs/en/legal-and-compliance)
- The policy does NOT contain, in any source found (neither the old nor
  the new version), any literal mention of "wrapping", "orchestrating" or
  "automating calls to Claude Code" as a category forbidden on its own —
  the textual concern is always around CREDENTIALS (who authenticates, on
  whose behalf, whether they're collected/stored/intermediated) and
  RESALE/INTERMEDIATION OF USE, not "calling the binary programmatically"
  as an isolated act.
- The `claude-hud` precedent (question 3) shows a companion-tool
  maintainer treating it as risky that his Node process made a direct,
  independent HTTP call to Anthropic — even running as a Claude Code
  subprocess — and fixing it to read the data that Claude Code ITSELF
  already exposes (stdin/rate_limits), instead of hitting Anthropic
  directly. This precedent points in the direction of "never call
  Anthropic directly, always get data through the official process"
  being seen by the technical community itself as the LOWER-risk stance. —
  [jarrodwatts/claude-hud#287](https://github.com/jarrodwatts/claude-hud/issues/287)

### Inferences
- ClaudeS's current arrangement — never extracting/using the OAuth token
  directly, only reading metadata already persisted locally (the
  Keychain) and asking the OFFICIAL binary itself, via its control
  protocol (`control_request get_usage`), to query usage — is
  structurally very similar to the fix `claude-hud` adopted (consuming
  data through the interface Claude Code itself exposes, instead of
  calling Anthropic directly). This is the strongest argument in favor of
  the current arrangement's compliance: Anthropic never sees an HTTP
  request from a client other than its own published, unmodified binary.
- The point of greatest uncertainty is whether ClaudeS, by orchestrating
  multiple accounts/instances of the official binary (a multi-account
  manager), could be framed as "agent infrastructure" or as a form of
  "intermediating" multiple users' usage — especially if, in the future,
  ClaudeS is used by more than one actual person on the same install or
  exposes third parties' accounts. For a single user managing THEIR OWN
  personal accounts, the more reasonable textual reading is that there's
  no "resale" nor "intermediation on behalf of other users" — but there's
  no explicit Anthropic confirmation about managers of multiple personal
  accounts of the same individual.
- The Consumer Terms' "automated or non-human means" clause is the
  residual risk hardest to safely rule out: it doesn't talk about
  "credential", it talks about "accessing the Services" via "bot,
  script, or other automated means" with no API key. An aggressive,
  literal reading could try to frame the act of ClaudeS invoking `claude`
  programmatically (even if the binary is official) as "automated
  access" to Anthropic's Services. I found no case, discussion or
  clarification from Anthropic applying this clause specifically against
  orchestrating a subprocess of Claude Code itself — it's a theoretical
  risk identified from the contract's wording, not a risk with real
  enforcement precedent found in this research.

### Gaps
- There's no public statement or case from Anthropic specifically about
  "multi-account managers" or "Claude Code subprocess orchestrators" that
  only read metadata. This is precisely the central gap of question 6
  below — there's no direct precedent, favorable or unfavorable,
  specifically about this pattern.
- It isn't clear, in any source, whether "your products or services" in
  the "Can customers offer Claude Code in their products?" section is
  meant to cover local, personal/individual-use tools (installed on the
  user's own machine, not hosted, no other users) or whether it's aimed
  exclusively at companies offering Claude Code as part of a hosted
  B2B/B2C offering. This is a scope ambiguity the research doesn't resolve.

---

## 6. Is there public precedent for "companion"/read-only dashboard tools (no inference) via a local Keychain or orchestrating the CLI as a subprocess?

### Takeaway
Yes — the `claude-hud` case is a direct, documented and quite relevant
precedent: a companion/statusline tool that read usage metadata via the
Keychain/credentials.json and called Anthropic directly was treated
PROACTIVELY by the maintainer himself as a ToS risk (not by Anthropic's
order) and fixed to stop calling Anthropic directly, switching to consume
the data Claude Code itself already exposes to the process. I found no
OFFICIAL Anthropic statement (favorable or unfavorable) explicitly
addressing this "read-only companion tool" category; the only precedent
is community self-regulation, not an Anthropic position.

### Cited Findings
- `jarrodwatts/claude-hud` issue #287: a statusline tool that read
  credentials from the Keychain/`~/.claude/.credentials.json` and called
  `POST https://api.anthropic.com/api/oauth/usage` directly; the
  maintainer himself concluded this was "gray zone or clear violation"
  and migrated, via PR #288, to reading the data natively exposed via
  stdin from Claude Code's statusline API — eliminating any direct call
  to Anthropic. —
  [jarrodwatts/claude-hud#287](https://github.com/jarrodwatts/claude-hud/issues/287)
- `Maciek-roboblog/Claude-Code-Usage-Monitor` issue #202: another
  usage-monitoring tool using the same endpoint directly, with no
  compliance discussion at all — showing that the practice of calling the
  usage endpoint directly (not through the official binary) CONTINUES in
  the community with no documented Anthropic intervention as of this
  research. —
  [Maciek-roboblog/Claude-Code-Usage-Monitor#202](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor#202)
- I found no official changelog post, no issue in
  `anthropics/claude-code` (I searched terms like "third party tool",
  "companion app", "wrapper", "oauth token restriction" but the relevant
  results redirected to the OpenCode/Roo-Code/claude-code#8060/#8042
  cases, all about INFERENCE use, not read-only companion tools), and no
  public Anthropic employee statement specifically addressing
  dashboards/companions that only read status/usage.

### Inferences
- The absence of any documented enforcement action against `claude-hud`
  or `Claude-Code-Usage-Monitor` (two tools that, at the time issue #287
  was opened, DID exactly what the user's question describes — calling
  the usage endpoint directly with the OAuth token) is (weak, by absence)
  evidence that Anthropic, in practice, hasn't prioritized enforcement
  against this specific pattern so far. This shouldn't be mistaken for
  permission: it's simply the absence of a known enforcement case, within
  the period researched.
- The `claude-hud` maintainer's behavior — voluntarily migrating to
  depend on the official binary instead of calling Anthropic — is the
  only "architecture precedent" found, and it points in the same
  direction as ClaudeS's current arrangement: the technical community has
  already converged, out of caution, on the pattern "never call Anthropic
  directly for account/usage data; get it through the official process".

### Gaps
- This is the question with the most significant evidence gap in the
  whole research: there's no direct Anthropic statement in the sources
  found — favorable or against — about companion/dashboard tools that
  read ONLY metadata/usage (no inference) via a local Keychain or by
  orchestrating the official CLI as a subprocess. All the analysis here
  is inference from community self-regulation precedents and the
  policy's general wording, not from a case Anthropic resolved or
  commented on.
- I found no issue or discussion in `github.com/anthropics/claude-code`
  (the official repository itself) addressing this category — the
  relevant issues there (#8060, #8042) are about 400/credential
  restriction errors happening in Claude Code's OWN official client (e.g.
  a user with the VS Code extension or official CLI getting the error
  from a bug/misconfiguration), not about third-party tools.

---

## Methodology note and overall confidence level

- **High confidence**: the CURRENT literal text of the official doc (read
  via a direct fetch on 10/13/2026) and the exact technical errors
  (`400`/`429` with the quoted messages) reproduced across multiple
  independent GitHub issues.
- **Medium confidence**: the EXACT wording of the February/2026 version
  (multiple secondary sources converge on the same sentence, but there
  was no confirmation via an archived primary snapshot) and the statement
  attributed to the Anthropic engineer via The Register (a journalistic
  source, not an official Anthropic communication).
- **Low confidence / speculative**: the 5 inference-payload fingerprinting
  criteria (an unverified third-party comment on Hacker News) and any
  inference about the MOTIVATION for the October/2026 wording change.
- **No evidence / confirmed gap**: existence of cryptographic binary
  attestation; an official Anthropic position on read-only companion
  tools specifically; whether the usage endpoint is or will be subject to
  the same enforcement as the inference endpoint; whether "products/
  services" in the sense of the Commercial Terms section includes local,
  single-account personal-use tools.
