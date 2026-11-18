# Changelog

## 0.2.0 — Unreleased

- Add desktop notifications for deployment start, success, failure, cancellation and skipped results.
- Add an independent notification setting, click-through deployment actions and duplicate suppression across monitors.
- Keep startup and reconnects silent instead of replaying old deployment history.

## 0.1.0 — 2026-11-18

Initial public release.

- Native Omarchy bar widget with a theme-aware Coolify mark and compact deployment panel.
- Running and queued deployments, plus the last finished, failed, cancelled or skipped deployment.
- Coolify Cloud or self-hosted URL and token setup using read-only API requests and private local credential storage.
- Application filtering, adaptive background refresh, deployment links and stale-data handling.
- Header refresh switch, URL-row connection settings, aligned footer actions and light/dark rendering.

Requires current Omarchy, Go 1.23 or later, and util-linux `flock`.
