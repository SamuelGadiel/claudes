<div align="center">
  <h1>
    <img src="assets/ClaudeS-rounded.png" width="120" height="120" alt="ClaudeS icon"><br>
    ClaudeS
  </h1>
  <p><strong>Multiple Claude Code accounts, shared chat history, live usage tracking — in the terminal and in VS Code.</strong></p>

  ![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue?style=flat-square)
  [![Release](https://img.shields.io/github/v/release/SamuelGadiel/claudes?style=flat-square)](https://github.com/SamuelGadiel/claudes/releases/latest)
  [![CI](https://img.shields.io/github/actions/workflow/status/SamuelGadiel/claudes/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/SamuelGadiel/claudes/actions/workflows/ci.yml)
  [![License: MIT](https://img.shields.io/github/license/SamuelGadiel/claudes?style=flat-square)](LICENSE)
</div>

<br>

<p align="center">
  <a href="https://buymeacoffee.com/samuelgadiel"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png"  height="36" alt="Buy Me a Coffee"></a>
  &nbsp;
  <a href="https://ko-fi.com/samuelgadiel"><img src="https://ko-fi.com/img/githubbutton_sm.svg" height="36" alt="Ko-fi"></a>
  &nbsp;
  <a href="https://github.com/sponsors/SamuelGadiel"><img src="https://img.shields.io/badge/-Sponsor%20via%20GitHub-181717?style=for-the-badge&logo=github&logoColor=white" height="36" alt="GitHub Sponsors"></a>
  &nbsp;
  <a href="https://donate.stripe.com/eVqeVcfNDd30aDK4iE0oM00"><img src="https://img.shields.io/badge/-Donate%20via%20Stripe-635BFF?style=for-the-badge&logo=stripe&logoColor=white" height="36" alt="Donate via Stripe"></a>
</p>

<br>

<p align="center">
  <img src="assets/screenshots/panel.png" width="340" align="top" alt="ClaudeS menu bar panel showing open VS Code projects and account usage">
  <img src="assets/screenshots/panel-high-usage.png" width="340" align="top" alt="ClaudeS panel with session usage above 75%, shown in orange">
  <img src="assets/screenshots/notifications.png" width="380" align="top" alt="Native notifications for an expired session and usage crossing 75%">
</p>

## Why

If you use Claude Code for both a personal and a work account — or more than one of either — you already know the pain: `claude /login` is one credential at a time, VS Code Profiles don't share your extensions or settings between them, and juggling `CLAUDE_CONFIG_DIR` by hand across terminals and editor windows gets old fast.

It gets worse the moment you actually hit a rate limit mid-task: switch accounts the usual way and the new one has no idea what you were just talking about, because each `CLAUDE_CONFIG_DIR` keeps its own session history. The "fix" is copying chat files between folders by hand just to keep working. And seeing it coming in the first place meant opening the usage page in a browser, or running a status command and reading through the output, account by account — something you'd only think to do once you were already rate-limited.

ClaudeS sits in your menu bar, keeps every account's credentials isolated, and makes each project remember which account it uses — not just in the terminal, but inside VS Code's own Claude extension too, with zero manual setup per project. Accounts also share the same session history, so running out of quota on one and switching to another never costs you the conversation you were in the middle of. One click on the menu bar icon shows every account's usage, live — no browser, no command to run.

## Installation

```sh
brew install --cask samuelgadiel/casks/claudes
```

Open ClaudeS once from Launchpad — it installs the `cs` command for your shell automatically. No manual PATH setup.

<details>
<summary>Manual installation</summary>

Download the latest `ClaudeS-*.zip` from [Releases](https://github.com/SamuelGadiel/claudes/releases/latest), unzip it, and move `ClaudeS.app` to `/Applications`.

</details>

## Features

- **Multiple accounts, fully isolated** — each one gets its own `CLAUDE_CONFIG_DIR` and its own Keychain credential. Add a brand-new account, import one you already have, or remove one — all from the panel.
- **Per-project account, automatically applied** — switch a project's account once from the panel; a `.clauderc` file remembers it, and VS Code's Claude extension picks it up with no restart or manual config needed. No VS Code Profiles, no shared-extension headaches.
- **Chat history isn't account-bound** — every account shares the same session storage, so switching a project to a different account never loses the conversation history already there. Pick up exactly where you left off, no copying files around.
- **One default account** for every project that hasn't picked one yet.
- **Live usage bars** — 5-hour and weekly rate-limit windows per account, with reset times, right in the panel.
- **Usage notifications** — a native notification fires when an account crosses 75% or 90% of a window, and again once an exhausted window is available again — even with the panel closed, so you're not caught mid-task.
- **Log in without a terminal** — ClaudeS drives `claude auth login` in the background: it waits for the prompt and lets you paste the code right in the panel, no terminal involved.
- **Reliable login status** — backed by `claude auth status`, not fragile direct Keychain reads, so you're not ambushed by a password prompt. A notification fires when a session expires, and you can log back in from the same panel.
- **A full CLI, not an afterthought** — see [Command line](#command-line) below.
- **Launches at login, installs its own CLI** — open the app once and `cs` is on your `PATH`; no `brew link`, no extra step.
- **Native and small** — Swift + SwiftUI, no Electron, no background daemon you didn't ask for.
- English and Portuguese (BR).

<p align="center">
  <img src="assets/screenshots/accounts-menu.png" width="400" alt="Add, import, or remove an account right from the panel">
  <img src="assets/screenshots/menu.png" width="400" alt="ClaudeS menu bar right-click menu">
</p>
<p align="center">
  <img src="assets/screenshots/add-account.png" width="400" alt="Adding a new account, with its name and slug">
  <img src="assets/screenshots/account-pending-login.png" width="400" alt="A newly added account that hasn't logged in yet, with its Log In button">
</p>
<p align="center">
  <img src="assets/screenshots/patch-verified.png" width="400" alt="VS Code extension patch verification result">
</p>

## Command line

ClaudeS isn't just a menu bar panel — `cs` is a complete CLI on its own, installed automatically the first time you open the app.

```sh
cs                             # runs claude with the current project's account (or the default one)
cs work auth login             # runs claude under a specific account, args passed straight through

cs list                        # registered accounts, login status, usage
cs add --name "Personal"       # registers a brand-new account
cs import --dir ~/.claude-work --name "Work"   # registers an account you already had set up
cs remove work                 # deregisters an account (asks for confirmation)
cs default personal            # account used by projects with no .clauderc

cs set work                    # sets this project's account (.clauderc)
cs status                      # every open VS Code project and terminal session, with its account

cs usage                       # rate-limit usage for every account
cs usage work                  # just one
```

Run `cs help` for the full reference.

## How it works

- **The `cs` CLI** runs `claude` with the right account's `CLAUDE_CONFIG_DIR` set, resolved from the current project's `.clauderc` or the default account.
- **Inside VS Code**, the official `anthropic.claude-code` extension doesn't natively support per-project accounts. ClaudeS applies a small, reversible patch to the extension's bundle (kept in sync across extension updates) that teaches it to check `.clauderc` first — see [`ClaudeExtensionJSPatcher`](Sources/ClaudeSCore/ClaudeExtensionJSPatcher.swift) for exactly what it changes and why.
- **Credentials** live in the macOS Keychain, one entry per account, exactly how the official `claude` CLI already stores them — ClaudeS doesn't invent a new credential format.
- **Session history** lives in a single shared directory (`~/.claude-shared-chats`) that every account's `projects/` folder symlinks into — chats belong to the project, not to whichever account happened to be active when they were written.

## Contributing

ClaudeS is a young project — the architecture is still taking shape, and that's as much an invitation as it is a disclaimer. If you want to help define conventions, propose a structure, or just fix something that bugs you, issues and PRs are welcome.

To build it locally:

```sh
git clone https://github.com/SamuelGadiel/claudes.git
cd claudes
swift build              # library + CLI, for quick iteration
scripts/build-app.sh      # assembles the real .app bundle into dist/
open dist/ClaudeS.app
```

No Xcode project — it's a plain Swift Package (`swift-tools-version:5.9`), so any recent Xcode or standalone Swift toolchain works.

`plans/` has the project's specs, research notes, and backlog (`plans/KANBAN.md`) — worth a skim before diving into a change, especially [`plans/specs/03-vscode-extension-patch`](plans/specs/03-vscode-extension-patch/spec.md) if you're touching the VS Code integration.

## License

[MIT](LICENSE)
