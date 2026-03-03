# Project Understanding

- Generated: 2026-03-03T09:08:48.037223+00:00
- Project: Codex Account Switcher

## Summary
Codex Account Switcher is a macOS menu bar utility that helps heavy Codex users operate multiple authenticated ChatGPT/Codex accounts without manual auth file editing. It provides one-click switching, account management, and quick visibility into remaining quota windows.

## ICP
Power users, indie hackers, dev tool builders, and teams who run long Codex desktop/CLI sessions across multiple accounts and need quick, low-friction account switching.

## Problem
Switching Codex accounts manually is slow and error-prone because users have to edit ~/.codex/auth.json, track which account is active, and monitor remaining usage windows externally.

## Positioning
A focused operator tool that turns account switching into a one-click menu action and surfaces 5-hour/weekly remaining usage per account directly in the menu bar.

## Differentiators
- One-click account switch with atomic auth.json write
- In-app ChatGPT OAuth onboarding through codex app-server
- Per-account usage visibility for 5-hour and weekly windows
- Built specifically for Codex desktop + CLI workflows
- Open source and transparent implementation

## Launch Angles
- Stop editing auth files manually
- Run multiple Codex accounts without workflow breaks
- Menu bar command center for Codex account operations
- Build-in-public OSS utility for Codex power users

## Channel Strategy
- X posts targeting Codex/CLI/macOS productivity audiences
- Reddit participation in productivity/dev-tool subreddits with educational replies
- GitHub README-driven discovery and social proof
- Short demo clip/screenshot snippets to show before/after workflow

## Risks
- Community sensitivity to self-promotion in Reddit threads
- Security concerns around local token storage
- Mismatch between user expectations and Codex auth hot-reload limitations
- Claims must stay factual and avoid overpromising

## KPIs
- GitHub stars and repo visits
- README click-through from social posts
- Launch post engagement rate (likes/replies/reposts)
- Qualified inbound comments asking setup/security questions
- Weekly growth in users reporting successful setup

