# ClaudeS's own OAuth setup with Anthropic (independent of the `claude` CLI)

## What OAuth architecture does `claude auth login` use (client_id, PKCE, endpoints)?

### Takeaway
The `claude` CLI uses a standard **Authorization Code + PKCE (S256)**
flow with a **public, fixed client_id embedded in the binary**
(`9d1c250a-e61b-44d9-88ed-5944d1962f5e` in production), with no client
secret — technically replicable by any app, but this doesn't imply
permission to use it (see next section).

### Cited Findings
- Direct reverse engineering of the locally installed `claude` binary
  (`/opt/homebrew/Caskroom/claude-code/2.1.273/claude`, `strings -a` over
  the arm64 Mach-O) found, in the production environment config object:
  `CONSOLE_AUTHORIZE_URL:"https://platform.claude.com/oauth/authorize"`,
  `CLAUDE_AI_AUTHORIZE_URL:"https://claude.com/cai/oauth/authorize"` (or,
  in the generic templated form, `${CLAUDE_AI_ORIGIN}/oauth/authorize`
  with `CLAUDE_AI_ORIGIN:"https://claude.ai"`),
  `TOKEN_URL:"https://platform.claude.com/v1/oauth/token"`,
  `CLIENT_ID:"9d1c250a-e61b-44d9-88ed-5944d1962f5e"`,
  `DESIGN_CLIENT_ID:"59637612-477b-4836-a601-b0589eda7704"` — [local
  binary analysis, scratch file `/tmp/claude_strings.txt`] (this
  research's own primary finding, no public URL).
- The same binary contains a parallel "staging/local" environment with
  `CLIENT_ID:"22422756-60c9-4084-8eb7-27705fd5cf9a"`,
  `OAUTH_FILE_SUFFIX:"-local-oauth"`, and a third "custom" environment
  with `OAUTH_FILE_SUFFIX:"-custom-oauth"` — confirms the production
  client_id isn't the only one that exists, but it's the only one end
  users use — [local binary analysis].
- The binary uses classic PKCE parameters: `code_challenge`,
  `code_challenge_method` (fixed to `"S256"`), `code_verifier`, `state`,
  `response_type=code` — [local binary analysis].
- `MANUAL_REDIRECT_URL` in production is
  `"https://platform.claude.com/oauth/code/callback"`, used when the flow
  can't open a local callback server (`http://localhost:{port}/callback`)
  — typical over SSH/containers, where the user manually copies a code
  shown on the page — [local binary analysis].
- A revocation endpoint exists: `POST ${TOKEN_URL}/revoke` with `token`,
  `token_type_hint:"refresh_token"`, `client_id` — [local binary analysis].
- An independent technical report (a third party, not affiliated with
  this researcher) confirms: "Authorization Endpoint:
  `https://claude.ai/oauth/authorize`; Token Endpoint:
  `https://console.anthropic.com/v1/oauth/token`; Client ID:
  `9d1c250a-e61b-44d9-88ed-5944d1962f5e`; PKCE: Yes, S256; minimal scopes
  `user:profile` and `user:inference`; access tokens expire in 8h; refresh
  tokens are rotating (each refresh invalidates the previous one and
  issues a new one)" —
  [Reverse Engineering Signin with Claude from Claude Code](https://akashmohan.com/writings/claude-code-oauth).
- The binary lists additional scopes used by the full browser login:
  `user:ccr_inference`, `user:file_upload`, `user:mcp_servers`,
  `user:office`, `user:plugins`, besides `user:profile` and
  `user:inference` — [local binary analysis].

### Inferences
- The difference between the token endpoint cited by the third party
  (`console.anthropic.com/v1/oauth/token`) and the one found in this
  analysis (`platform.claude.com/v1/oauth/token`) likely reflects an
  Anthropic domain rebrand/migration that happened between that article's
  time and the build 2.1.273 (Sep/2026) analyzed here — not an
  architecture divergence.
- The client_id is shared by **every** user of the official CLI (it isn't
  issued per install/user) — it's a classic "public client" for a
  native/CLI app, but that doesn't make it a client_id "open for
  third-party registration" (see the policy section).

### Gaps
- It wasn't possible to confirm, from the binary's text, whether the
  authorization endpoint accepts an arbitrary `redirect_uri` supplied by
  a third party (e.g. `http://localhost:PORT_CHOSEN_BY_CLAUDES/callback`)
  or whether there's a `redirect_uri` allowlist registered per client_id
  on the Anthropic server side — this isn't visible from the client side.

---

## Does Anthropic document third-party OAuth app registration, or would using the CLI's client_id be against the terms?

### Takeaway
**UNVIABLE by policy, regardless of technical viability.** Anthropic
offers no client_id registration process for third parties and, since
February 2026, explicitly forbids using OAuth tokens from Free/Pro/Max/
Team accounts in any product, tool or service other than the Claude Code
CLI itself or claude.ai — with server-side technical blocking already in
production.

### Cited Findings
- "Anthropic does not provide a way to register new client IDs for
  third-party projects" and "Their OAuth is exclusively reserved for
  Claude Code and Claude.ai" —
  [Anthropic OAuth (FAQ) - Moltis Docs](https://docs.moltis.org/anthropic-oauth.html).
- A literal quote attributed to Anthropic's documentation updated on
  02/19/2026: *"Using OAuth tokens obtained through Claude Free, Pro, or
  Max accounts in any other product, tool, or service, including the
  Agent SDK, is not permitted"* — consistently reproduced across multiple
  independent sources:
  [Anthropic Bans Claude Subscription OAuth in Third-Party Apps — Winbuzzer](https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/);
  a post on X quoting the same sentence
  ["Rob Zolkos on X"](https://x.com/robzolkos/status/2024125323755884919);
  discussion in a third-party project issue
  ["Anthropic's new 'Authentication and credential use' policy may prohibit Auto-Claude's OAuth-based authentication model" — GitHub Issue #1871](https://github.com/AndyMik90/Aperant/issues/1871).
- Technical (server-side) enforcement started on **January 9–27, 2026**,
  even before the documentation clarification of 02/19/2026 —
  [Winbuzzer](https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/);
  [Anthropic Halts Third-Party OAuth Access Across Claude Subscriptions — OpenTools](https://opentools.ai/news/anthropic-halts-third-party-oauth-access-across-claude-subscriptions).
- The error message returned by the API when a consumer-subscription
  OAuth token is used outside Claude Code/claude.ai: *"This credential is
  only authorized for use with Claude Code and cannot be used for other
  API requests"* —
  [Anthropic OAuth (FAQ) - Moltis Docs](https://docs.moltis.org/anthropic-oauth.html).
- Third-party tools affected and publicly reported as broken by this
  change: **OpenClaw** and **OpenCode** —
  [Winbuzzer](https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/);
  additional context in
  ["What Is the OpenClaw Ban?" — MindStudio](https://www.mindstudio.ai/blog/anthropic-openclaw-ban-oauth-authentication)
  and
  ["Anthropic Banned OpenClaw" — Natural20](https://natural20.com/coverage/anthropic-banned-openclaw-oauth-claude-code-third-party).
- The violation is described as breaching Anthropic's **Consumer Terms of
  Service**, not just an informal usage policy — [a search result
  aggregating multiple sources on "Usage Policy" / Consumer TOS,
  including a related issue
  ["OAuth token usage in usage-api.ts may violate Anthropic Consumer TOS" — GitHub Issue #287](https://github.com/jarrodwatts/claude-hud/issues/287)].
- The officially recommended alternative for third-party integrations is
  authentication via a **Claude Console API key** (billed by usage), not
  subscription OAuth —
  [Winbuzzer](https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/);
  [Moltis Docs](https://docs.moltis.org/anthropic-oauth.html).
- The exact official page (`anthropic.com/legal/...` or `claude.com/...`)
  hosting the quoted text wasn't found in this research; the attempt to
  read `https://www.anthropic.com/legal/aup` (Usage Policy) returned no
  section about third-party OAuth — [a direct read of
  `anthropic.com/legal/aup`, no matching section found].

### Inferences
- Since the block is enforced **on the inference API's server side** (not
  just a contractual clause), using the CLI's client_id/OAuth flow from
  ClaudeS would result, at minimum, in inference calls rejected by the
  API itself — making the approach **technically unviable in production**,
  on top of being contractually forbidden.
- This server-side block likely validates some attribute of the
  token/session (e.g. an internal "aud"/client context tied to the app
  that minted the token, or a specific header sent by the official CLI)
  and not just the client_id alone — since the client_id itself is shared
  by millions of legitimate CLI installs; Anthropic needs to
  differentiate "this is the official CLI making the call" from "this is
  something else using the same client_id to mint a token and then
  calling the API separately". This wasn't technically confirmed (see Gaps).

### Gaps
- It wasn't possible to locate and directly read Anthropic's official page
  containing the exact policy text (every citation of the sentence comes
  from secondary sources reproducing it) — the search for the primary page
  (`anthropic.com/legal/aup`, "Usage Policy" pages) didn't find the
  relevant section in this session; it may be on another page (e.g.
  specific Consumer Terms, not the general AUP) not located.
- It wasn't possible to confirm the exact technical mechanism of the
  server-side block (header validation, "app attestation", usage-
  pattern/IP, or some internal token claim) — the sources consulted only
  mention that the block exists and the returned error message, with no
  implementation detail.

---

## Collision risk: would a second ClaudeS authentication (same client_id, same account) invalidate the `claude` CLI's active session?

### Takeaway
No public documentation or technical report was found confirming or
refuting a collision between parallel OAuth sessions of the same
account/client_id — this point remains a research gap; the question is,
in any case, **subsumed** by the policy prohibition in the previous
section (even if there were no technical collision, the use itself is
already forbidden).

### Cited Findings
- The technical article on the CLI's OAuth architecture confirms refresh
  tokens are **rotating** ("each refresh request returns a new refresh
  token while invalidating the previous one"), but only addresses the
  refresh cycle within a single token chain/session, not collision
  between two independent authorizations of the same account —
  [Reverse Engineering Signin with Claude from Claude Code](https://akashmohan.com/writings/claude-code-oauth).
- The Claude Code CLI's official documentation addresses multiple
  accounts (a separate `CLAUDE_CONFIG_DIR` per account) but doesn't
  address multiple simultaneous OAuth authorizations of the **same**
  account from two different clients —
  [Authentication - Claude Code Docs](https://code.claude.com/docs/en/authentication).

### Inferences
- Since standard OAuth2 servers (including Auth0-based/similar ones,
  whose parameter names — `code_challenge`, `nonce`, `prompt`, error
  messages like `pkce_params_missing` — appeared in the binary analyzed,
  suggesting a generic OAuth stack underneath) usually treat each
  authorization (each "code exchange") as creating an independent token
  family, it's **architecturally expected** that two separate
  authorizations of the same account (e.g. phone + laptop, or CLI + a
  hypothetical ClaudeS) wouldn't automatically invalidate each other —
  but this is an inference from a market pattern, not a specific
  confirmation of Anthropic's implementation.
- This point is, in practice, irrelevant to ClaudeS's decision: even if
  there were no technical collision, the previous section already
  establishes that minting a subscription token outside the official CLI
  and using it for API calls is, by itself, a policy violation with
  active server-side blocking.

### Gaps
- No source found explicitly confirms the behavior of multiple
  simultaneous OAuth sessions (same client_id, same account, two
  different "apps") for Claude Pro/Max accounts — nor an active-session
  limit per account. There's no report of a third party specifically
  trying this scenario (most reports deal with apps that failed on the
  server-side "used outside Claude Code" validation, not refresh-token
  collision).

---

## Is `claude setup-token` automated by ClaudeS viable, independent of the CLI's Keychain item, and free of the ACL-reset problem?

### Takeaway
Technically, `claude setup-token` **never writes to the Keychain** — it
only prints the token in the terminal, making it, by construction, free
of the ACL-reset problem described in this research's context. However,
using that token outside the Claude Code CLI itself is the same policy
violation covered in the previous sections, and it has been **blocked on
the server** since January/2026 — so it's PARTIALLY VIABLE technically,
but UNVIABLE by policy/enforcement.

### Cited Findings
- Official documentation: *"The command opens the same browser
  authorization flow as `/login`, and the token prints to the terminal
  after you approve access in the browser. It does not save the token
  anywhere; copy it and set it as the `CLAUDE_CODE_OAUTH_TOKEN`
  environment variable wherever you want to authenticate"* —
  [Authentication - Claude Code Docs](https://code.claude.com/docs/en/authentication).
- Official documentation confirms a **one-year** validity, with no
  automatic renewal (the user needs to mint a new one when it expires):
  *"generate a one-year OAuth token with `claude setup-token`"* —
  [Authentication - Claude Code Docs](https://code.claude.com/docs/en/authentication).
- Official documentation confirms a restricted scope: *"This token
  authenticates with your Claude subscription and requires a Pro, Max,
  Team, or Enterprise plan. It can only make model requests, so it can't
  establish Remote Control sessions or fetch claude.ai connectors."* —
  [Authentication - Claude Code Docs](https://code.claude.com/docs/en/authentication).
- Local binary analysis confirms the expiry constant: `tz=31536000`
  seconds (exactly 365 days), used as the default `expiresIn` when the
  `setup-token` command runs with `inferenceOnly:true` — and confirms the
  effective scope is restricted to `user:inference` (text embedded in the
  binary: *"env-var and setup-token sessions default to user:inference
  only"*, in contrast to a full browser login, which can get
  `user:profile`, `user:office`, `user:ccr_inference`, `user:mcp_servers`,
  `user:plugins`) — [local binary analysis].
- Local binary analysis confirms the `setup-token` flow is treated as a
  **separate mode** from standard login in the CLI's state machine
  (strings like `mode:"setup-token"`, `inferenceOnly:P==="setup-token"`),
  and that the message shown to the user is explicitly:
  *"✓ Long-lived authentication token created successfully!"* followed by
  the literal text `"Store this token securely. You won't be able to see
  it again."` — confirming there's no automatic local persistence by the
  CLI — [local binary analysis].
- The same policy block and server-side enforcement described in the
  second section (the error *"This credential is only authorized for use
  with Claude Code and cannot be used for other API requests"*) applies
  to any consumer-account OAuth token, **including** those generated by
  `setup-token`/`CLAUDE_CODE_OAUTH_TOKEN`, since Anthropic's policy
  generically speaks of "OAuth tokens obtained through Claude Free, Pro,
  or Max accounts in any other product, tool, or service" —
  [Moltis Docs FAQ](https://docs.moltis.org/anthropic-oauth.html);
  [Winbuzzer](https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/).

### Inferences
- The separation between the `setup-token` flow (doesn't touch the
  Keychain) and the interactive `/login` flow (writes and rewrites the
  "Claude Code-credentials" item in the Keychain on every refresh — the
  root cause already confirmed by the previous research context)
  confirms the ACL-reset problem is **specific to the interactive login's
  persistence routine**, not something inherent to any Anthropic OAuth
  token. A token obtained via `setup-token` and manually stored by
  ClaudeS in its own Keychain item would never go through that rewrite
  routine, because the CLI never writes anything related to that token to
  disk/the Keychain — the CLI itself delegates that storage entirely to
  the external process using it.
- Since the official documentation doesn't mention any policy restriction
  directly on the authentication page (it describes `setup-token`/
  `CLAUDE_CODE_OAUTH_TOKEN` as a legitimate mechanism for "CI pipelines,
  scripts, or other environments" with no warning about a ban on use in
  third-party products), there's an **apparent tension between the
  technical documentation (which teaches how to generate and export the
  token for external use) and the usage policy (which forbids using it
  outside Claude Code/claude.ai)**. This suggests either Anthropic didn't
  update this specific page after the Feb/2026 policy change, or the
  documented intent ("scripts", "CI pipelines") is strictly interpreted
  as "still invoking the `claude` binary/Agent SDK under Claude Code's
  umbrella", not "any third-party app making API calls directly with
  that bearer token".

### Gaps
- It wasn't possible to confirm whether the Jan/2026 server-side block
  specifically rejects `setup-token` tokens when used to call the
  inference API via a custom header imitating the CLI, or whether it
  rejects any call not originating from the official binary (e.g. via
  User-Agent fingerprinting, a JWT claim, etc.) — no source consulted
  detailed the exact validation mechanism.
- No explicit confirmation was found of whether the "Generate a
  long-lived token" text at code.claude.com/docs was or wasn't updated
  after Feb/2026 to reflect the new policy — the page read in this
  research (current text, Oct/2026) doesn't mention the restriction.

---

## If ClaudeS stores the token in its own Keychain item (created by itself via `-T`), would that item suffer the same ACL-reset problem?

### Takeaway
No — by construction, a Keychain item is never rewritten/reset by a
process that never writes to it. The reset problem described in the
context is specific to the `claude` CLI's persistence routine, which
exclusively manages its own item ("Claude Code-credentials" /
`Claude Code${OAUTH_FILE_SUFFIX}...`); a separate item, created and
written only by ClaudeS, is out of that routine's reach.

### Cited Findings
- Local binary analysis confirms the construction formula for the
  Keychain item name the CLI itself uses:
  `` `Claude Code${Kt().OAUTH_FILE_SUFFIX}${n}${c}` ``, where
  `OAUTH_FILE_SUFFIX` varies by environment (`""` in production,
  `"-local-oauth"` in local dev, `"-custom-oauth"` in custom
  environments) — confirming the CLI has its own dedicated naming/
  writing routine for this specific item, not shared with any other
  mechanism — [local binary analysis].
- Official documentation confirms the CLI manages this file/item
  exclusively through the `/login` and `/logout` commands: *"Claude Code
  manages `.credentials.json` through `/login` and `/logout`"* (on
  Linux/fallback) and, by extension, the equivalent item in the Keychain
  on macOS —
  [Authentication - Claude Code Docs](https://code.claude.com/docs/en/authentication).

### Inferences
- Since the root cause (confirmed by the previous research context, not
  re-researched here) is the CLI recreating its **own** item on every
  refresh — resetting that specific item's ACL/partition list — a
  different Keychain item, with a different service name, created by
  ClaudeS with `security add-generic-password ... -T /path/to/ClaudeS`
  (or equivalent via the Keychain Services API with
  `kSecAttrAccessible`/`SecAccessControl` pointing only at ClaudeS) would
  never be touched by that routine — there's no plausible mechanism by
  which the official `claude` CLI would interact with a service item it
  didn't create and doesn't reference in its own code.
- This point is technically solid and low-risk **architecturally** — the
  real risk in this whole path lies entirely in the policy/ToS section
  (how to get the token to put in that item in the first place), not in
  the Keychain storage mechanics itself.

### Gaps
- No relevant gap identified for this specifically mechanical
  sub-question — it's a direct, well-supported consequence of the
  evidence above.

---

## Security/product risks of the ~1-year token (scope, revocation when logging out of the main account)

### Takeaway
The `setup-token`/`CLAUDE_CODE_OAUTH_TOKEN` token is **more restricted**
in scope than the full interactive login (only `user:inference`, no
Remote Control nor claude.ai connectors), but its 1-year validity is
independent of the main session's lifecycle — there's no documentary
confirmation that a `/logout` of the main session automatically revokes
previously issued `setup-token` tokens, which is a relevant residual
security risk (a "dangling" token).

### Cited Findings
- Restricted scope officially confirmed: the `setup-token`/
  `CLAUDE_CODE_OAUTH_TOKEN` token *"can only make model requests, so it
  can't establish Remote Control sessions or fetch claude.ai
  connectors"* —
  [Authentication - Claude Code Docs](https://code.claude.com/docs/en/authentication).
- Confirmed via the binary: the effective scope is exactly
  `["user:inference"]`, while a full browser login can get additional
  scopes (`user:profile`, `user:office`, `user:ccr_inference`,
  `user:mcp_servers`, `user:plugins`) — [local binary analysis].
- The official documentation treats `CLAUDE_CODE_OAUTH_TOKEN` as an
  **independent** credential source in the CLI's authentication
  precedence order (position 5 of 7, below `apiKeyHelper` and above
  Anthropic profiles/federation and standard `/login`), and notes that
  even running `/login` with the environment variable set, "Claude Code
  switches the current session to the new login, but reads the variable
  again in every new session until you remove it" — indicating the env
  var's token is **neither deleted nor invalidated** by the interactive
  session's `/login`/`/logout`; it's just deprioritized while the
  variable stays set —
  [Authentication - Claude Code Docs](https://code.claude.com/docs/en/authentication).
- Local binary analysis shows error messages treating the `setup-token`
  token as a separate recovery resource when the main credential
  expires: *"Mint a fresh token with `claude setup-token` and restart
  with it, or unset the variable and run /login"* — language that
  presents the two credentials (interactive login vs. `setup-token`
  token) as parallel, non-dependent alternatives — [local binary analysis].
- The Feb/2026 usage policy (see section 2) doesn't distinguish, in the
  text quoted by secondary sources, between interactive-login tokens and
  `setup-token` tokens — both are "OAuth tokens obtained through Claude
  Free, Pro, or Max accounts", so both are covered by the same
  prohibition —
  [Winbuzzer](https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/);
  [Moltis Docs](https://docs.moltis.org/anthropic-oauth.html).

### Inferences
- The absence of any mention, in the official documentation or the
  third-party sources consulted, of cascading revocation (logging out of
  the main session → revoking previously issued `setup-token` tokens)
  suggests, by omission, that these tokens are **not automatically
  revoked** along with the interactive session's logout — but this is an
  inference from absence of evidence, not a positive confirmation.
- Since the `user:inference` scope still allows making model requests on
  the user's behalf (consuming the Pro/Max subscription's quota/cost), a
  1-year "dangling" and forgotten token represents a relevant attack-
  surface risk for any architecture depending on it — even though
  technically limited (can't access profile, connectors or Remote
  Control).

### Gaps
- No source (official or third-party) was found explicitly describing the
  revocation behavior of `setup-token`/`CLAUDE_CODE_OAUTH_TOKEN` tokens
  when: (a) the user runs `/logout` on the CLI's main session; (b) the
  user revokes active sessions via claude.ai's web interface; or (c) the
  Pro/Max subscription expires/is canceled. This is a real gap only
  answerable by empirical testing or asking Anthropic support directly —
  it shouldn't be assumed as "automatic revocation" nor as "token always
  valid until the end of the 1 year" with no confirmation.
- There's no confirmation of a limit on how many `setup-token` tokens can
  exist simultaneously, active, for the same account.

---

## Synthesis note on viability (for the report writer)

Consolidated classification of the paths investigated:

- **Replicating the CLI's full OAuth flow (same client_id, browser, PKCE)
  for continuous use in ClaudeS**: technically **VIABLE to implement**
  (a public architecture via reverse engineering, with no client secret),
  but **UNVIABLE by policy and enforcement**: it violates Anthropic's
  Consumer Terms (an explicit prohibition documented since Feb/2026, with
  text cited by multiple independent sources) and suffers active
  server-side technical blocking since Jan/2026 (the "This credential is
  only authorized for use with Claude Code and cannot be used for other
  API requests" error).
- **Automating `claude setup-token` and storing the resulting token in
  ClaudeS's own Keychain item**: **PARTIALLY VIABLE** — technically it's
  the cleanest path from a Keychain/ACL standpoint (the command never
  writes to the Keychain, and an item of ClaudeS's own would never suffer
  a reset from another process), but it's subject to the **same policy
  prohibition and the same server-side block** from the previous section,
  since the generated token is, by the cited policy's own definition, an
  "OAuth token obtained through a Claude Free/Pro/Max account" — and its
  use in "any other product, tool, or service" (i.e., ClaudeS itself) is
  the explicitly forbidden conduct.
- **Officially registering ClaudeS's own client_id with Anthropic**:
  **UNVIABLE** — there's no third-party OAuth app registration process
  for subscription accounts (Free/Pro/Max/Team); the only documented
  "official" path for third-party integration is an API key via the
  Claude Console, billed by usage (doesn't draw on the user's Pro/Max
  subscription).

In short: the technical gap (architecture, Keychain, ACL) has a solid
solution and was confirmed in this research; the real, blocking gap is
entirely one of policy/ToS + server-side enforcement, not of engineering.
