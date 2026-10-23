# Changelog

## 1.1.0

- SwiftUsage updates itself: it downloads a new version in the background and asks before installing it.
- Customize has a General page: how often the limits are read (one minute to an hour; five minutes as before) and Open at Login.
- While the providers are being asked for their limits, after a click on Refresh or on the Limits tab, the footer says so instead of when the numbers were last read.
- Limits are read again just after a window resets, and a window that has reset reads as unused, so the menu bar no longer shows a limit as reached until the next reading.
- Codex's compressed rollouts are read without Homebrew: zstd's decoder is built in. The app no longer loads libraries from outside itself, so macOS's library validation is on again.
- The account each Antigravity and Pi login belongs to, and each Cursor login's plan, are remembered in the cache folder, so a reading that can't ask (an expired login, a provider that doesn't answer) still shows the right card.
- Reading Codex's history from scratch (the first launch, or Re-read All History) takes a third of the CPU it did: 31 GB of rollouts in 9 seconds instead of 25 on this Mac. A quiet refresh of an existing index takes half as long.
- The history index is saved in a compact binary form. For 31 GB of Codex rollouts it's half the size (27 MB), loads in a quarter of a second instead of more than one, saves in 40 ms instead of a second, and the app needs about 200 MB less memory. It's saved beside the JSON index earlier versions keep, which is read when there's no binary one yet and otherwise left for them.

## 1.0.0

The first release. SwiftUsage needs macOS 26 or later, on Apple silicon or Intel.

- Usage history from Codex, Claude Code, Cursor, Grok, OpenCode, Antigravity, Muse Code, Pi and Devin, read locally from each tool's own files: sessions, messages, tokens, cost at API rates, active days, peak hour, favorite model and an activity heatmap, for all time, 30 days or 7 days, per provider or all together.
- The Models tab: tokens per day stacked by model, and each model's tokens, cost and share.
- The Limits tab: each signed-in account's session, weekly and per-model limits with reset countdowns and pace, balances and credits, and what was spent today, yesterday and over 30 days.
- Codex and Claude limit resets: how many an account has, and Use a Reset… to spend one.
- Pinned limits in the menu bar, with today's tokens and cost; Customize picks the providers, accounts and what the menu bar shows.
- `swiftusage --limits` and `--dump` print the limits and the numbers in the terminal; `--json` writes the limits, or one provider's numbers per day, as JSON for scripts.
- Signed with a Developer ID and notarized by Apple.
