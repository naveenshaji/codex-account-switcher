# Codex Account Switcher

macOS menu bar app for managing multiple Codex ChatGPT OAuth accounts, switching the active account quickly, and viewing per-account usage windows.

## Why this exists

Codex (desktop + CLI) reads auth from `~/.codex/auth.json`. This app keeps multiple authenticated accounts ready, then swaps the active auth file in one click.

## Features

- Keep 5+ accounts saved and ready to switch.
- Full ChatGPT OAuth login flow from the app (`codex app-server` based).
- Import current active account from `~/.codex/auth.json`.
- One-click active account switch (rewrites `~/.codex/auth.json` atomically).
- Usage visualization per account:
  - 5-hour window
  - weekly window
  - shown as `% remaining` (green -> yellow -> red as remaining drops)
- Active account badge in menu/manage views.
- Quick actions:
  - restart Codex desktop app
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
2. Click `Manage`.
3. Add accounts:
   - `Add account via ChatGPT OAuth` (recommended), or
   - `Import current ~/.codex/auth.json`.
4. Select `Switch` on any non-active account.
5. Restart Codex app and open a new CLI session for the switched account to take effect in running processes.

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
- No automatic periodic refresh yet; usage updates happen on app refresh actions.

## Project layout

```
Sources/CodexAccountSwitcherApp/
  AppState.swift          # app state + active profile reconciliation
  CodexAuthStore.swift    # read/write ~/.codex/auth.json
  CodexOAuthService.swift # OAuth flow via codex app-server JSON-RPC
  KeychainStore.swift     # disk profile store + legacy keychain migration
  Models.swift            # profile + usage models
  UsageService.swift      # usage endpoint client
  Views.swift             # menu bar + management UI
```
