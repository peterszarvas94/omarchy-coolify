# Coolify Deployments for Omarchy

Ongoing deployments and the last finished result, in your Omarchy bar. A read-only community plugin for Coolify Cloud and self-hosted Coolify.

Uses Omarchy's native panel, controls, typography, theme colors, keyboard focus and reduced-motion preference. The Coolify mark follows your bar color; a pulsing badge indicates activity and a warning badge indicates failure or a connection error.

![Deployment status and connection settings with demo data](preview.png)

Full-size screenshots: [Deployments](docs/screenshots/readme-deployments.png) · [Connection settings](docs/screenshots/readme-settings.png).

## Install

Requires current Omarchy with its Quickshell plugin system (`qs.Ui.KeyboardPanel`, `PanelHero`, `Button`, and `Commons.Translations`), Go 1.23 or later, `flock` from util-linux, and libnotify (`notify-send`). No Coolify CLI or extra Go dependencies are needed.

```sh
omarchy plugin add https://github.com/peterszarvas94/omarchy-coolify.git --enable
```

The helper compiles into `$XDG_CACHE_HOME/omarchy-coolify` on first use and after source updates. Initial launch may take a few seconds. Build artifacts stay outside the checkout. Keep Go installed for updates. No prebuilt binaries are downloaded or executed.

## Update and remove

```sh
omarchy plugin update io.github.peterszarvas94.coolify
```

Updates follow the repository default branch through Omarchy's normal git-based updater. The connection credentials live outside the plugin checkout and survive updates.

Before removing the plugin, open its connection settings and select **Disconnect** to remove the saved URL and token from this computer. Then run:

```sh
omarchy plugin remove io.github.peterszarvas94.coolify
```

Removal does not revoke the API token in Coolify. If you remove the plugin without disconnecting first, the private connection file remains at the path documented below. The compiled helper cache may also remain in `~/.cache/omarchy-coolify`; it contains no token.

## Connect

1. Click the Coolify icon and enter your instance URL, such as `https://coolify.example.com`, or `https://app.coolify.io` for Coolify Cloud.
2. Enable API access in Coolify and create a token under **Keys & Tokens → API tokens**, granting **read** only. The panel's token link opens that page; select the permission in Coolify.
3. Paste the token into the password field and select **Save & connect**.

Only connect to an instance you trust: your token is sent to that URL. HTTPS with valid TLS is required, except HTTP on localhost for development. Redirects are rejected. A trailing `/api/v1` is removed automatically.

The token sees its selected team and resources. Deployment, write, root and sensitive-read permissions are unnecessary. Coolify's API uses bearer tokens; no account password or OAuth login is needed.

Credentials live in `$XDG_CONFIG_HOME/omarchy-coolify/connection.json` (default `~/.config/omarchy-coolify/connection.json`), with directory mode `0700` and file mode `0600`. This is a private local file, **not encrypted storage**. Tokens never enter `shell.json`, process arguments, the repository or logs; setup passes them over stdin. Exclude this file from public dotfile sync. Disconnect removes the local file; revoke the token in Coolify separately when needed.

Connection settings let you change the URL or token. A blank token retains the current token only when the URL is unchanged. Failed validation preserves the old connection.

## Use

- **Ongoing:** running and queued deployments, elapsed time and environment when available.
- **Last finished:** the latest completion across watched applications, including failures, cancellations and skipped deployments. Selected by completion time, with `updated_at` as a fallback on older Coolify versions.
- Click a deployment to open its details. Links outside the configured instance fall back to its homepage.
- Middle-click the icon or use **Refresh** for an immediate check.
- Tab/Shift+Tab moves between controls, Enter/Space activates, Escape closes, and the mouse wheel scrolls long lists.

Background refresh defaults to every 30 seconds while idle and every 5 seconds while deploying. History is cached for up to 30 seconds while the queue is unchanged; queue transitions and manual refresh check it immediately. Use the header switch to disable background refresh and check only on opening or manual refresh. Connection failures back off to 60 seconds and preserve the last known result with a stale-data message.

In Omarchy's widget settings, **Watched application UUIDs** accepts a comma-separated list. Empty watches all visible applications. Credentials are shared across this computer's monitors; each monitor owns its panel state.

## Deployment notifications

Notifications are enabled by default. Change **Deployment notifications** in the connection settings or Omarchy widget settings. The header switch continues to control background refresh separately: automatic notifications require background refresh; manual refresh can detect transitions too.

A deployment entering `in_progress` sends a start notification. Finished, failed, cancelled and skipped deployments send their corresponding result, with duration when available. Click a notification to open that deployment in Coolify. Failures use critical urgency; other events use normal urgency. Omarchy controls delivery and quiet-mode behavior. No per-deployment notification is sent just for entering the queue. A fast deployment that starts and finishes between checks sends its result without inventing a start alert.

The first successful check after startup, connection changes, notification re-enabling, or a failed check establishes a silent baseline. Checks more than 90 seconds apart also reset the baseline to avoid replaying an outage backlog. Notifications are deduplicated across monitors using a private ledger in `/omarchy-coolify` (default `~/.local/state/omarchy-coolify`). It stores hashed connection identifiers, deployment UUIDs, statuses and timestamps, not API tokens, application names or notification bodies. Entries are bounded and aged out on later checks.

`notify-send` is provided by libnotify and normally ships with Omarchy. There are no extra Go module dependencies. The purple notification icon is derived from the same licensed Coolify mark.

## Limits and troubleshooting

This tracks **application deployments**, including Docker Compose applications exposed by Coolify's deployment API. One-click services and databases do not have equivalent application deployment history.

History is bounded to the newest 2,000 deployments per application, with a visible warning beyond that. At most 200 applications and 100 ongoing deployments are supported. Four history requests run concurrently, each with a 12-second timeout and 8 MiB response limit; refresh has a 45-second deadline. Partial history failures show a warning, and the last result reflects accessible history. Narrow the token or watched UUIDs for large instances.

For access errors, check API access, read permission, team/resources and allowed IPs. For connection errors, check TLS, networking and the base URL; disabling certificate verification is unsupported. For helper errors, check `go version`, `flock`, and executable permissions. From the checkout, run `bin/coolify-status` and send `{"action":"info"}` on stdin for a token-free configuration check.

English translations are included and follow Omarchy's fallback system. Additional languages can be added under `i18n/`. Status codes and helper diagnostics currently use English.

## Development

```sh
go test -race ./...
go vet ./...
bash -n bin/coolify-status
omarchy plugin validate .
```

For QML linting, expose host modules under the `qs` namespace:

```sh
mkdir -p /tmp/omarchy-coolify-imports/qs
ln -sfn /usr/share/omarchy/shell/Commons /tmp/omarchy-coolify-imports/qs/Commons
ln -sfn /usr/share/omarchy/shell/Ui /tmp/omarchy-coolify-imports/qs/Ui
/usr/lib/qt6/bin/qmllint -I /tmp/omarchy-coolify-imports -I /usr/lib/qt6/qml Panel.qml DeploymentRow.qml Label.qml CoolifyIcon.qml
```

Lint may report dynamic `Style.font` and `bar.shell` members as unknown; these are supplied by the host. Copy fresh source into the installed plugin directory, run `omarchy restart shell`, and confirm `omarchy-shell shell ping`. Never edit packaged Omarchy files.

See [manual verification](docs/verification.md) for screenshots and release checks.

MIT licensed. The Coolify mark's upstream Apache-2.0 license and source notice are in `assets/`. This independent plugin is not affiliated with or endorsed by Coolify.
