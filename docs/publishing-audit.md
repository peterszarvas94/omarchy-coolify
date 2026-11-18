# Publishing audit

Audit target: [Develop a Custom Plugin](https://plugins.omarchy.org/develop.html) and its linked [official shell reference](https://github.com/omacom/omarchy/blob/quattro/shell/README.md).

## Repository and runtime contract

- Permanent ID: `io.github.peterszarvas94.coolify`, outside the reserved `omarchy.*` namespace.
- Root manifest, README, MIT license, asset notices and `preview.png` are present. There is no clone-only `omarchy.clonedFrom` field.
- The manifest declares only `bar-widget` and maps `entryPoints.barWidget` to the existing, case-correct `BarWidget.qml`.
- `BarWidget.qml` uses the native base, forwards panel lifecycle, and injects bar/settings/anchor/owner into its loaded panel.
- The nested panel is not separately registered. Its private IPC is disabled, avoiding duplicate handlers on multiple monitors.
- The popup uses `KeyboardPanel` and `PanelKeyCatcher`, with native form focus traversal and Escape handling.
- All source and installed files are user-owned; no packaged Omarchy file is modified and no symlink is shipped in the plugin.
- Runtime commands, local compilation, network behavior, credential storage and the lack of privileged actions/install hooks are documented in the README.

## Validation

`omarchy plugin validate`, the documented QML lint command, Go race tests, `go vet`, shell syntax and `git diff --check` pass. Informational QML messages for dynamically provided host properties remain visible.

## Manual lifecycle checks

The actual bar entry and panel were loaded on Asimov in the isolated test compositor. The checks covered entry-point open/close forwarding, the bar click handler, Escape, settings form traversal, popout-switch closing, destruction on disable and reconstruction on re-enable. The separate helper stopped with its panel and the re-created instance established a fresh baseline.

The test desktop is separate from the user's physical desktop and uses a private D-Bus session and demo connection. Its virtual keyboard remains connected while checking focus; disconnecting the only virtual keyboard removes the seat's keyboard focus and is not a valid Escape test.

The isolated preview checks the real Omarchy UI components and widget contract, not an entire logged-in Hyprland desktop. No automatic input was sent to the user's desktop.

Marketplace submission is a separate step and has not been performed. This audit is not a marketplace approval or a security certification.
