# Privacy and usage statistics

Your usage history is read from each tool's own files and never leaves your Mac. SwiftUsage does send anonymous statistics to its developer, through [PostHog](https://posthog.com), to count how many people use it, see which providers they use, and fix crashes and limit readings that break. Nothing it sends names you or an account, or says how much you used.

## Always sent

- **A daily check-in** (`app_daily_active`), once a local day, as soon as the app has read your history:
  - a random install ID the app makes for itself, which nothing ties to your Mac, to you or to an account
  - the app's version and build, the macOS version, and whether the Mac has Apple silicon or Intel
  - which providers are turned on in Customize, which have history on this Mac, which were used in the last 30 days, and which have an account whose limits were read
  - which limits are pinned to the menu bar, by provider and limit (`claude/session`), never by account
  - what the menu bar shows (today's tokens, cost, limits as used or left), how often limits are read, whether the app opens at login and checks for updates, and whether Help Improve SwiftUsage is on
- **Crash reports** (`$exception`): when SwiftUsage crashes, the report goes out the next time it opens. It holds the crash's stack trace, the binaries that were loaded and the versions above. Your home folder is replaced with `~` in its paths.

## Sent unless you turn it off

Help Improve SwiftUsage in Customize → General, which is on to begin with, also sends each day's counts once the day is over:

- `app_usage_daily`: how many times the panel opened.
- `provider_limits_daily`, one for each provider whose limits were read: how many readings worked and how many failed, counted by kind: login expired, access to the login needed, login gone, no limits for this account, couldn't reach the provider, provider limiting requests or unavailable, HTTP 4xx or 5xx, or an answer the app doesn't understand. The problem's own wording is never sent, since it can name an account.

Turning it off stops these and drops what was counted that day. The check-in and crash reports go out either way.

## Never sent

- Account names, email addresses, organizations, plans or IDs, or anything from a login
- Tokens, messages, sessions, costs, limits or any other amount of usage
- Models, projects, prompts, transcripts or file paths, apart from the app's own in a crash report
- Error messages

## What PostHog sees besides

PostHog's SDK adds the Mac's model (such as MacBook Pro), the system language and the time zone to each event. SwiftUsage takes out the screen size and network type it would also add, turns off the events it would make up itself (app opened, screens, clicks, feature flags) and keeps no profiles of people. Like any server, PostHog sees the IP address a request comes from: SwiftUsage asks it not to work out a location from it, and the project's settings drop it from every event. The events go to PostHog's EU cloud.

## Builds from source

A build from source sends nothing, unless `SWIFTUSAGE_POSTHOG_TOKEN` is set to the key of a project in PostHog's EU cloud, for trying the statistics out against a project of your own.

The app's other requests (each provider's limits, renewing a login that has run out, Cursor's usage events, the price list and the update check) are described in the [README](../README.md); none of them carries anything about your usage.
