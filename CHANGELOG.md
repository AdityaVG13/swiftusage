# Changelog

## 1.0.0

The first release. SwiftUsage needs macOS 26 or later, on Apple silicon or Intel.

- Usage history from Codex, Claude Code, Cursor, Grok, OpenCode, Antigravity, Muse Code, Pi and Devin, read locally from each tool's own files: sessions, messages, tokens, cost at API rates, active days, peak hour, favorite model and an activity heatmap, for all time, 30 days or 7 days, per provider or all together.
- The Models tab: tokens per day stacked by model, and each model's tokens, cost and share.
- The Limits tab: each signed-in account's session, weekly and per-model limits with reset countdowns and pace, balances and credits, and what was spent today, yesterday and over 30 days.
- Codex and Claude limit resets: how many an account has, and Use a Reset… to spend one.
- Pinned limits in the menu bar, with today's tokens and cost; Customize picks the providers, accounts and what the menu bar shows.
- `swiftusage --limits` and `--dump` print the limits and the numbers in the terminal, with `--json` for scripts.
- Signed with a Developer ID and notarized by Apple.
