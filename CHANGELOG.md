# Changelog

## 0.3.3 — 2026-11-18

- Limit deployment alerts to one outstanding notification across refreshes and monitors.

## 0.3.2 — 2026-11-18

- Each refresh reads at most 16 MiB of responses in total, besides the 4 MiB limit per response, and stops with an error when Coolify returns more.
- At most 100 projects and 500 environments are read for deployment links, 20 history entries per application are kept, and at most 50 recently finished deployments are kept for notifications.
- The README lint setup uses a private `mktemp -d` directory instead of a fixed path under `/tmp`.

## 0.3.1 — 2026-11-18

- API requests run through `curl` with redirects refused, so the token is never sent outside the configured Coolify origin.
- Responses over 4 MiB are rejected before they are parsed, and the deployment queue is capped.
- The connection file is written to a fresh owner-only temporary file and renamed into place, and Disconnect deletes it, so an existing symlink or other file at that path is never written through or re-permissioned. The config directory must be a real directory owned by you.
- The token reaches `curl` and the file writer on stdin, never in process arguments.

## 0.3.0 — 2026-11-18

- No more Go: the helper is rewritten in QML and JavaScript and runs inside the Omarchy shell. Nothing to install besides the plugin.
- Notifications are deduplicated across monitors in memory; the notification history file is gone.
- Shorter README.

## 0.2.0 — 2026-11-18

- Add desktop notifications for deployment start, success, failure, cancellation and skipped results.
- Add an independent notification setting, click-through deployment actions and duplicate suppression across monitors.
- Keep startup and reconnects silent instead of replaying old deployment history.
- Follow the documented Omarchy widget lifecycle: `BarWidget.qml` entry point, keyboard-native panel with Escape and panel switching, and no duplicate IPC handlers across monitors.
- Document runtime commands, dependencies and network behavior for marketplace publishing.

## 0.1.0 — 2026-11-18

Initial public release.

- Native Omarchy bar widget with a theme-aware Coolify mark and compact deployment panel.
- Running and queued deployments, plus the last finished, failed, cancelled or skipped deployment.
- Coolify Cloud or self-hosted URL and token setup using read-only API requests and private local credential storage.
- Application filtering, adaptive background refresh, deployment links and stale-data handling.
- Header refresh switch, URL-row connection settings, aligned footer actions and light/dark rendering.
