# Changelog

## 1.2.0

- Anonymous statistics, sent through PostHog: a daily check-in with the app's version and which providers are on and in use, crash reports, and, unless Help Improve SwiftUsage is turned off in Customize → General, each day's count of panel openings and of limit readings that worked or failed, by kind. None of it names a person or an account or says how much anyone used; `docs/privacy.md` lists every field.
- Cursor's tokens are counted: they come from the usage events Cursor's dashboard lists, asked for with the login Cursor keeps, with the cost Cursor priced each request at. The first fetch reads the whole history; later ones the last two days.
- Claude Code's and Codex's usage is read from every config folder, as their limits are: `~/.claude_personal`, `~/.config/claude` and other Claude Code folders, and Codex homes such as `~/.codex-work`. When `CLAUDE_CONFIG_DIR` or `CODEX_HOME` is set, only that folder is read.
- Claude Code responses through a gateway that gives every response the same ID count once each, rather than all together as one.
- A Codex subagent's own work counts when its turns don't carry the time they started (`rollout-5`, a task inside a turn), where it was left out. History a fork replays under such a turn counts once, under its parent.
- A Codex usage snapshot sent again later in a rollout no longer counts as another response.
- A Codex rollout written out in one go, with every line stamped when its thread started, counts on the days its turns ran.
- A Codex Desktop thread whose early history was rewritten down to its compaction markers counts that history again, from the total Codex kept, spread over the compactions.
- A Codex response logged before its turn names the model takes that turn's model, so it's priced instead of listed as unknown.
- Claude Desktop's login no longer shows as a card named "Claude Desktop". An account a Claude Code folder is signed in to keeps its one card, which Desktop's login fills in when Claude Code's can't be read, and Desktop's expired login or missing permission no longer adds a second one. An account only Desktop has is named after its organization or email, and keeps that name when Desktop's login later expires or can't be read.
- The first launch reads Claude Code's and Codex's history again to apply these; summaries of deleted transcripts are kept.

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
