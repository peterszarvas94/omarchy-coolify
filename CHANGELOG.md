# Changelog

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
