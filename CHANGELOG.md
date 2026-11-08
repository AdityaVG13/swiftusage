# Changelog

## 0.1.0

The first release. SwiftUsage needs macOS 26 or later, on Apple silicon or Intel.

- Usage history from Codex, Claude Code, Cursor, Grok, OpenCode, Antigravity, Muse Code, Pi, Devin and Droid, read locally from each tool's own files: sessions, messages, tokens, cost at API rates, active days, peak hour, favorite model and an activity heatmap, for all time, 30 days or 7 days, per provider or all together.
- Claude Code's and Codex's history is read from every config folder, as their limits are: `~/.claude_personal`, `~/.config/claude` and other Claude Code folders, and Codex homes such as `~/.codex-work`. When `CLAUDE_CONFIG_DIR` or `CODEX_HOME` is set, only that folder is read.
- Cursor's tokens come from the usage events Cursor's dashboard lists, asked for with the login Cursor keeps, with the cost Cursor priced each request at.
- The Models tab: tokens per day stacked by model, and each model's tokens, cost and share.
- The Limits tab: each signed-in account's session, weekly and per-model limits with reset countdowns and pace, balances and credits, and what was spent today, yesterday and over 30 days.
- Droid's 5-hour, weekly and monthly plan limits and extra-usage balance, read from the login its CLI seals in `~/.factory` with a key the keychain holds.
- Nous Portal, Z.AI and Kimi limits, read with the logins and keys Hermes and the Kimi CLI already keep: Nous Portal's daily, weekly and monthly usage windows and top-up credits, Z.AI's 5-hour and weekly tokens and monthly MCP allowance, and Kimi's 5-hour and monthly pools.
- Codex and Claude limit resets: how many an account has, and Use a Reset… to spend one.
- A login whose access token has run out (Claude Code, Codex, Grok) or is about to (Cursor) is renewed the way its tool renews it and saved back where the tool keeps it, under the tool's own lock where it takes one and never over a login signed in since, so a card doesn't read "Login expired" just because its tool hasn't run for a while. It's the only change the app makes to the tools' logins; every other read leaves them as they are.
- Pinned limits in the menu bar, with today's tokens and cost. Customize picks the providers, accounts and what the menu bar shows, how often the limits are read (one minute to an hour, five minutes to begin with) and whether the app opens at login.
- SwiftUsage updates itself: it downloads a new version in the background and asks before installing it.
- Anonymous statistics, sent through PostHog: a daily check-in with the app's version and which providers are on and in use, crash reports, and, unless Help Improve SwiftUsage is turned off in Customize → General, each day's count of panel openings and of limit readings that worked or failed, by kind. None of it names a person or an account or says how much anyone used; `docs/privacy.md` lists every field.
- `swiftusage --limits` and `--dump` print the limits and the numbers in the terminal; `--json` writes the limits, or one provider's numbers per day, as JSON for scripts.
- Signed with a Developer ID and notarized by Apple.
