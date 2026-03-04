# Codex Account Switcher

macOS menu bar app for managing multiple Codex ChatGPT OAuth accounts, switching the active account quickly, and viewing per-account usage windows.

## Why this exists

Codex (desktop + CLI) reads auth from `~/.codex/auth.json`. This app keeps multiple authenticated accounts ready, then swaps the active auth file in one click.

## Features

- Keep 5+ accounts saved and ready to switch.
- Add accounts via full ChatGPT OAuth login flow (`codex app-server` based).
- One-click active account switch (rewrites `~/.codex/auth.json` atomically).
- Per-account subscription badge beside account email.
- Email dropdown menu (chevron) per account with `Remove Account`.
- Usage visualization per account:
  - 5-hour window
  - weekly window
  - shown as `% remaining` (green -> yellow -> red as remaining drops)
- Historical local usage graphs per account with selectable ranges (`1h`, `5h`, `12h`, `24h`, `7d`, `30d`).
- Top-level menu actions include:
  - Add account via ChatGPT OAuth
  - Open automatically at startup (toggle row)
- Quick actions:
  - start/restart Codex desktop app (auto-adapts to running state)
  - open new Codex CLI terminal session

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 15+ is sufficient)
- `codex` CLI installed and available on `PATH`
- A ChatGPT account that can authenticate through Codex OAuth

## Quick start

```bash
git clone https://github.com/naveenshaji/codex-account-switcher.git
cd codex-account-switcher
swift run CodexAccountSwitcherApp
```

Or build once:

```bash
swift build
swift run CodexAccountSwitcherApp
```

## Usage

1. Open the menu bar icon (`person.2.circle`).
2. Add accounts from `Add Account`.
3. Select an account as active from the account list.
4. Use the account email dropdown (chevron) to remove an account when needed.
5. Restart Codex app and open a new CLI session for switched auth to take effect in running processes.

## How switching works

- App stores profile data on disk:
  - `~/.codex/account-switcher/profiles.json`
- On switch, app writes selected account tokens to:
  - `~/.codex/auth.json`
- Write is atomic via temp file + move, with restrictive file permissions.

## Migration from older Keychain builds

- On first launch after upgrading, if `~/.codex/account-switcher/profiles.json` does not exist, the app attempts a one-time migration from the legacy Keychain entry.
- After successful migration, legacy Keychain data is deleted.

## Security and privacy notes

- Credentials are stored in a local user file with restrictive permissions (`600`).
- Usage requests are made with account access tokens to official ChatGPT backend endpoints used by Codex.

## Current limitations

- Existing Codex app/CLI sessions do not hot-reload auth; restart/new session is required.
- Assumes Codex uses file-backed auth (`~/.codex/auth.json`).
- Historical graphs use locally sampled data (no official ChatGPT/Codex historical timeline API); quality improves as samples accumulate.

## Project layout

```
Sources/CodexAccountSwitcherApp/
  AppState.swift          # app state + active profile reconciliation
  CodexAuthStore.swift    # read/write ~/.codex/auth.json
  CodexOAuthService.swift # OAuth flow via codex app-server JSON-RPC
  KeychainStore.swift     # disk profile store + legacy keychain migration
  LaunchAtLoginManager.swift # startup toggle integration
  Models.swift            # profile + usage models
  UsageService.swift      # usage endpoint client
  Views.swift             # menu bar UI (accounts + top-level actions)
```
