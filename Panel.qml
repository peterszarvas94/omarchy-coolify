pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui
import "Coolify.js" as Coolify

Ui.Panel {
    id: root
    moduleName: "io.github.peterszarvas94.coolify"
    manageIpc: false
    property Item anchorItem: null
    property Item hostWidget: null
    property var state: ({
            configured: false,
            url: "",
            active: [],
            last: null,
            warning: "",
            checked: ""
        })
    property var connection: null
    property var run: null
    property bool busy: false
    property bool editing: false
    property string error: ""
    property string saving: ""
    property string pendingSave: ""
    property double now: Date.now()
    // Notifications stay silent until this instance has a baseline for the current connection.
    property bool primed: false
    property string notifyKey: ""
    property bool notifyWasEnabled: false
    readonly property var active: state.active || []
    readonly property bool notificationsEnabled: setting("notifications", true)
    readonly property bool autoRefresh: setting("backgroundRefresh", true)
    readonly property string filter: String(setting("applicationUUIDs", ""))
    readonly property bool failed: !!state.last && state.last.status === "failed"
    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy-coolify"
    readonly property string iconPath: Qt.resolvedUrl("assets/coolify-notification.svg").toString().replace(/^file:\/\//, "")
    Commons.Translations {
        id: strings
        directory: Qt.resolvedUrl("i18n")
    }
    function t(key) {
        return strings.t(key);
    }
    function emptyState(configured) {
        return {
            configured: configured,
            url: root.connection ? root.connection.url : "",
            active: [],
            last: null,
            warning: "",
            checked: ""
        };
    }
    function message(err) {
        return err.arg === undefined ? t(err.key) : t(err.key).arg(err.arg);
    }
    function stopRun() {
        if (run)
            run.cancel();
        run = null;
        busy = false;
        runTimeout.stop();
    }
    function startRun(next) {
        run = next;
        runTimeout.restart();
    }
    function refresh(force) {
        if (busy || !connection)
            return;
        var conn = connection;
        var watched = filter;
        busy = true;
        error = "";
        startRun(Coolify.refresh(conn, watched, force !== false, function (err, next) {
            root.stopRun();
            if (err) {
                root.error = root.message(err);
                root.primed = false;
                return;
            }
            root.state = next;
            root.notify(conn, watched, next);
        }));
    }
    function loadConnection(text) {
        var data = null;
        try {
            data = JSON.parse(text);
        } catch (e) {}
        var normalized = data ? Coolify.normalizeUrl(data.url) : {};
        if (!normalized.url || !Coolify.validToken(data.token)) {
            stopRun();
            connection = null;
            primed = false;
            state = emptyState(false);
            if (opened)
                editing = true;
            return;
        }
        if (connection && connection.url === normalized.url && connection.token === data.token)
            return;
        stopRun();
        connection = {
            url: normalized.url,
            token: data.token
        };
        primed = false;
        error = "";
        state = emptyState(true);
        if (autoRefresh || opened)
            Qt.callLater(root.refresh);
    }
    function connect(urlText, tokenText) {
        if (busy)
            return;
        var normalized = Coolify.normalizeUrl(urlText);
        if (normalized.error) {
            error = t(normalized.error);
            return;
        }
        var token = String(tokenText || "").trim();
        if (!token && connection && connection.url === normalized.url)
            token = connection.token;
        if (!Coolify.validToken(token)) {
            error = t("errorToken");
            return;
        }
        var conn = {
            url: normalized.url,
            token: token
        };
        busy = true;
        error = "";
        startRun(Coolify.verify(conn, function (err) {
            root.stopRun();
            if (err) {
                root.error = root.message(err);
                return;
            }
            root.save("connect", JSON.stringify(conn) + "\n");
        }));
    }
    function forget() {
        if (!busy)
            save("forget", "");
    }
    // The file is created owner-only first; FileView then writes in place, so the
    // token never appears in a process argument and the permissions are kept.
    function save(kind, content) {
        // FileView skips writing unchanged text, so there would be no saved signal.
        if (connectionFile.loaded && connectionFile.text() === content) {
            saving = kind;
            pendingSave = content;
            saveFinished(true);
            return;
        }
        busy = true;
        saving = kind;
        pendingSave = content;
        prepare.running = true;
    }
    function saveFinished(ok) {
        if (!saving)
            return;
        var kind = saving;
        var content = pendingSave;
        saving = "";
        pendingSave = "";
        busy = false;
        if (!ok) {
            error = t("errorSave");
            return;
        }
        if (kind === "connect") {
            editing = false;
            tokenInput.text = "";
        }
        // Apply what was written; other bar instances pick it up through the file watch.
        loadConnection(content);
    }
    function notify(conn, watched, next) {
        var key = conn.url + "\n" + conn.token + "\n" + watched;
        var silent = !primed || notifyKey !== key || !notifyWasEnabled || !notificationsEnabled || !!next.warning;
        primed = !next.warning;
        notifyKey = key;
        notifyWasEnabled = notificationsEnabled;
        var events = Coolify.transitions(key, next, silent);
        for (var i = 0; i < events.length; i++)
            showNotification(events[i]);
    }
    function showNotification(d) {
        var titles = {
            "finished": "notificationSucceeded",
            "failed": "notificationFailed",
            "cancelled-by-user": "notificationCancelled",
            "skipped": "notificationSkipped"
        };
        var body = d.application_name + (d.environment ? " · " + d.environment : "");
        var took = Coolify.terminal(d.status) ? Coolify.duration(d) : "";
        if (took)
            body += "\n" + t("notificationDuration").arg(took);
        notifier.createObject(root, {
            link: d.deployment_url,
            command: ["notify-send", "--app-name=Coolify Deployments", "--urgency=" + (d.status === "failed" ? "critical" : "normal"), "--action=default=" + t("notificationOpen"), "--icon=" + iconPath, "--", Coolify.escapeMarkup(t(titles[d.status] || "notificationStarted")), Coolify.escapeMarkup(body)]
        });
    }
    function updateSetting(name, value) {
        if (!root.bar || !root.bar.shell)
            return;
        var entry = {
            id: root.moduleName
        };
        for (var key in root.settings)
            entry[key] = root.settings[key];
        entry[name] = value;
        root.bar.shell.updateEntryInline(root.moduleName, entry);
    }
    function toggleBackground() {
        if (root.state.configured)
            root.updateSetting("backgroundRefresh", !root.autoRefresh);
    }
    function moveFocus(direction) {
        var current = keyCatcher.Window.window ? keyCatcher.Window.window.activeFocusItem : keyCatcher;
        var next = (current || keyCatcher).nextItemInFocusChain(direction > 0);
        if (next)
            next.forceActiveFocus(Qt.TabFocusReason);
    }
    function activateFocus() {
        var current = keyCatcher.Window.window ? keyCatcher.Window.window.activeFocusItem : null;
        if (!current || !current.enabled)
            return;
        if (typeof current.clicked === "function")
            current.clicked();
        else if (typeof current.toggled === "function" && current.interactive)
            current.toggled();
    }
    function switchPanel(direction) {
        return root.bar && typeof root.bar.switchPanelFrom === "function" ? root.bar.switchPanelFrom(root.hostWidget || root, direction) : false;
    }
    function openLink(link) {
        if (link)
            Qt.openUrlExternally(link);
    }
    onOpenedChanged: {
        if (opened) {
            if (!state.configured) {
                editing = true;
                connectionFile.reload();
            } else if (!busy)
                refresh();
        } else
            tokenInput.text = "";
    }
    onFilterChanged: refresh()
    Component.onDestruction: stopRun()
    FileView {
        id: connectionFile
        path: root.configDir + "/connection.json"
        watchChanges: true
        atomicWrites: false
        printErrors: false
        onLoaded: root.loadConnection(text())
        onLoadFailed: root.loadConnection("")
        onFileChanged: reload()
        onSaved: root.saveFinished(true)
        onSaveFailed: root.saveFinished(false)
    }
    Process {
        id: prepare
        command: ["sh", "-c", "umask 077 && mkdir -p \"$1\" && chmod 700 \"$1\" && touch \"$2\" && chmod 600 \"$2\"", "sh", root.configDir, connectionFile.path]
        onExited: function (code) {
            if (code === 0)
                connectionFile.setText(root.pendingSave);
            else
                root.saveFinished(false);
        }
    }
    Component {
        id: notifier
        Process {
            id: notification
            property string link: ""
            running: true
            stdout: SplitParser {
                onRead: function (line) {
                    if (line.trim() === "default" && notification.link)
                        Qt.openUrlExternally(notification.link);
                }
            }
            onExited: notification.destroy()
        }
    }
    Timer {
        id: runTimeout
        interval: 30000
        onTriggered: if (root.run)
            root.run.abort()
    }
    Timer {
        interval: 1000
        repeat: true
        running: root.opened
        onTriggered: root.now = Date.now()
    }
    Timer {
        interval: root.error ? 60000 : (root.active.length > 0 ? 5000 : 30000)
        repeat: true
        running: root.state.configured && root.autoRefresh && !root.editing
        onTriggered: root.refresh(false)
    }
    Ui.KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher

        contentWidth: fittedContentWidth(Style.space(390))
        contentHeight: fittedContentHeight(column.implicitHeight + footer.implicitHeight + Style.space(12), Style.space(640))
        Ui.PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: urlInput.activeFocus || tokenInput.activeFocus
            onCloseRequested: root.close()
            onTabRequested: function (direction) {
                root.moveFocus(direction);
            }
            onMoveRequested: function (dx, dy) {
                root.moveFocus(dy || dx);
            }
            onActivateRequested: root.activateFocus()
            QQC.ScrollView {
                id: scroll
                anchors.fill: parent
                anchors.bottomMargin: footer.implicitHeight + Style.space(12)
                contentWidth: availableWidth
                clip: true
                Column {
                    id: column
                    width: scroll.availableWidth
                    spacing: Style.space(12)
                    Ui.PanelHero {
                        width: parent.width
                        title: "Coolify"
                        meta: root.editing ? root.t("connection") : (root.active.length ? root.t("deploying") : root.t("deployments"))
                        iconComponent: Component {
                            CoolifyIcon {
                                width: Style.space(32)
                                height: width
                            }
                        }
                        trailingControl: Component {
                            Ui.ToggleSwitch {
                                id: refreshToggle
                                anchors.verticalCenter: parent.verticalCenter
                                checked: root.autoRefresh
                                interactive: root.state.configured
                                activeFocusOnTab: true
                                hasCursor: activeFocus
                                onToggled: root.toggleBackground()
                                Keys.onSpacePressed: root.toggleBackground()
                                Keys.onReturnPressed: root.toggleBackground()
                                Accessible.name: root.t("background")
                                Ui.PanelToolTip {
                                    visible: refreshToggle.containsMouse
                                    text: root.t("background") + "\n" + root.t("pollHelp")
                                }
                            }
                        }
                    }
                    Row {
                        id: instanceRow
                        visible: root.state.configured
                        width: parent.width
                        spacing: Style.space(8)
                        Label {
                            width: parent.width - connectionButton.width - parent.spacing
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.state.url || ""
                            maximumLineCount: 1
                            elide: Text.ElideMiddle
                            opacity: 0.55
                            font.pixelSize: Style.font.caption
                        }
                        Ui.PanelActionButton {
                            id: connectionButton
                            iconText: "󰒓"
                            tooltipText: root.t("connection")
                            focusable: true
                            onClicked: {
                                root.editing = !root.editing;
                                urlInput.text = root.state.url || "";
                                tokenInput.text = "";
                            }
                        }
                    }
                    Label {
                        width: parent.width
                        visible: !!root.error
                        text: root.error + (root.state.checked ? "\n" + root.t("stale") : "")
                        color: Commons.Color.urgent
                    }
                    Column {
                        visible: root.editing || !root.state.configured
                        width: parent.width
                        spacing: Style.space(10)
                        Label {
                            width: parent.width
                            text: root.t("setupHelp")
                            opacity: 0.7
                        }
                        Ui.TextField {
                            id: urlInput
                            Keys.onEscapePressed: root.close()
                            width: parent.width
                            placeholderText: "https://coolify.example.com"
                            text: root.state.url || ""
                            enabled: !root.busy
                            maximumLength: 2048
                        }
                        Ui.TextField {
                            id: tokenInput
                            Keys.onEscapePressed: root.close()
                            width: parent.width
                            placeholderText: root.state.configured ? root.t("keepToken") : root.t("apiToken")
                            password: true
                            maximumLength: 4096
                            enabled: !root.busy
                            onAccepted: connectButton.clicked()
                        }
                        Label {
                            width: parent.width
                            text: root.t("privacy")
                            font.pixelSize: Style.font.caption
                            opacity: 0.55
                        }
                        Row {
                            id: connectionActions
                            width: parent.width
                            spacing: Style.space(8)
                            Ui.Button {
                                id: connectButton
                                width: root.state.configured ? (connectionActions.width - connectionActions.spacing) / 2 : connectionActions.width
                                text: root.t("connect")
                                bordered: true
                                focusable: true
                                enabled: !root.busy && !!urlInput.text.trim()
                                onClicked: if (enabled)
                                    root.connect(urlInput.text, tokenInput.text)
                            }
                            Ui.Button {
                                width: connectButton.width
                                height: connectButton.height
                                bordered: true
                                text: root.t("forget")
                                visible: root.state.configured
                                enabled: !root.busy
                                focusable: true
                                onClicked: {
                                    tokenInput.text = "";
                                    root.forget();
                                }
                            }
                        }
                        Ui.Button {
                            text: root.t("createToken")
                            focusable: true
                            onClicked: {
                                var u = urlInput.text.trim().replace(/\/$/, "");
                                if (/^https:\/\/[^\s]+$/.test(u))
                                    root.openLink(u + "/security/api-tokens");
                            }
                        }
                        Ui.Toggle {
                            width: parent.width
                            label: root.t("notifications")
                            description: root.t("notificationsHelp")
                            checked: root.notificationsEnabled
                            onClicked: root.updateSetting("notifications", !root.notificationsEnabled)
                        }
                    }
                    Column {
                        width: parent.width
                        visible: root.state.configured && !root.editing
                        spacing: Style.space(10)

                        Ui.PanelSeparator {
                            width: parent.width
                        }
                        Ui.PanelSectionHeader {
                            text: root.t("ongoing")
                        }
                        Label {
                            width: parent.width
                            visible: root.active.length === 0
                            text: root.t("noActive")
                            opacity: 0.6
                        }
                        Repeater {
                            model: root.active
                            DeploymentRow {
                                required property var modelData
                                deployment: modelData
                                now: root.now
                                ongoing: true
                                dateLocale: Commons.I18n.formatLocale
                                onOpenDeployment: root.openLink(modelData.deployment_url || root.state.url)
                            }
                        }
                        Ui.PanelSeparator {
                            width: parent.width
                        }
                        Ui.PanelSectionHeader {
                            text: root.t("lastFinished")
                        }
                        DeploymentRow {
                            visible: !!root.state.last
                            deployment: root.state.last || ({
                                    status: "",
                                    application_name: ""
                                })
                            now: root.now
                            dateLocale: Commons.I18n.formatLocale
                            onOpenDeployment: root.openLink(deployment.deployment_url || root.state.url)
                        }
                        Label {
                            width: parent.width
                            visible: !root.state.last
                            text: root.t("noHistory")
                            opacity: 0.6
                        }
                        Label {
                            width: parent.width
                            visible: !!root.state.warning
                            text: root.state.warning ? root.t(root.state.warning) : ""
                            opacity: 0.7
                            font.pixelSize: Style.font.caption
                        }
                        Ui.PanelSeparator {
                            width: parent.width
                        }
                        Label {
                            width: parent.width
                            text: root.state.checked ? root.t("checked").arg(new Date(root.state.checked).toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "HH:mm:ss")) : root.t("notChecked")
                            opacity: 0.45
                            font.pixelSize: Style.font.caption
                        }
                    }
                }
            }
            Row {
                id: footer
                width: parent.width
                anchors.bottom: parent.bottom
                spacing: Style.space(8)
                Ui.Button {
                    id: refreshButton
                    width: (footer.width - footer.spacing) / 2
                    height: Math.max(implicitHeight, openButton.implicitHeight)
                    text: root.t("refresh")
                    iconText: "󰑓"
                    bordered: true
                    focusable: true
                    enabled: !root.busy && root.state.configured
                    onClicked: root.refresh()
                }
                Ui.Button {
                    id: openButton
                    width: refreshButton.width
                    height: refreshButton.height
                    bordered: true
                    text: root.t("openCoolify")
                    focusable: true
                    enabled: root.state.configured
                    onClicked: root.openLink(root.state.url)
                }
            }
        }
    }
}
