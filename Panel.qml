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
    property string expectedGeneration: ""
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
        if (busy || saving || !connection)
            return;
        var conn = connection;
        var watched = filter;
        busy = true;
        error = "";
        startRun(Coolify.refresh(conn, root.fetch, watched, force !== false, function (err, next) {
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
        if (busy || saving)
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
        generationFile.reload();
        var generation = generationFile.text().trim();
        var conn = {
            url: normalized.url,
            token: token
        };
        busy = true;
        error = "";
        startRun(Coolify.verify(conn, root.fetch, function (err) {
            root.stopRun();
            if (err) {
                root.error = root.message(err);
                return;
            }
            root.expectedGeneration = generation;
            root.save("connect", JSON.stringify(conn) + "\n");
        }));
    }
    function forget() {
        if (!busy && !saving)
            save("forget", "");
    }
    // GET over curl: redirects are refused, so the token never leaves the configured
    // origin, and responses are capped at 4 MiB. The token goes over stdin, never argv.
    function fetch(url, token, done) {
        var request = fetcher.createObject(root, {
            token: token,
            done: done,
            command: ["sh", "-c", root.fetchScript, "sh", url, Coolify.protocols(url)]
        });
        return {
            abort: function () {
                if (request)
                    request.cancel();
            }
        };
    }
    // The connection is written to a fresh owner-only temporary file and renamed over
    // connection.json, so an existing symlink or other file at that path is replaced,
    // never written through. Disconnecting removes the path itself.
    function save(kind, content) {
        busy = true;
        saving = kind;
        pendingSave = content;
        writer.running = true;
    }
    function saveFinished(ok) {
        if (!saving)
            return;
        var kind = saving;

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
        connectionFile.reload();
    }
    function notify(conn, watched, next) {
        var key = conn.url + "\n" + conn.token + "\n" + watched;
        var silent = !primed || notifyKey !== key || !notifyWasEnabled || !notificationsEnabled || !!next.warning;
        primed = !next.warning;
        notifyKey = key;
        notifyWasEnabled = notificationsEnabled;
        var events = Coolify.transitions(key, next, silent);
        if (!events.length || Coolify.alertPending)
            return;
        var event = events.find(function (d) { return d.status === "failed"; }) || events[0];
        showNotification(event);
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
        Coolify.alertPending = true;
        if (!notifier.createObject(root, {
            link: d.deployment_url,
            command: ["notify-send", "--wait", "--app-name=Coolify Deployments", "--urgency=" + (d.status === "failed" ? "critical" : "normal"), "--action=default=" + t("notificationOpen"), "--icon=" + iconPath, "--", Coolify.escapeMarkup(t(titles[d.status] || "notificationStarted")), Coolify.escapeMarkup(body)]
        }))
            Coolify.alertPending = false;
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
        printErrors: false
        onLoaded: root.loadConnection(text())
        onLoadFailed: root.loadConnection("")
        onFileChanged: reload()
    }
    FileView {
        id: generationFile
        path: root.configDir + "/generation"
        blockLoading: true
        printErrors: false
    }
    // $1 config directory, $2 connection file, $3 "forget" or "connect"; the connection is one line on stdin.
    readonly property string writeScript: "set -eu\numask 077\ndir=$1\nfile=$2\n[ ! -L \"$dir\" ]\nmkdir -p -- \"$dir\"\n[ -O \"$dir\" ]\nchmod 700 -- \"$dir\"\nexec 9< \"$dir\"\nflock -x 9\nif [ \"$3\" = forget ]; then\n    tmp=$(mktemp -- \"$dir/.generation.XXXXXX\")\n    trap 'rm -f -- \"$tmp\"' EXIT\n    cat /proc/sys/kernel/random/uuid > \"$tmp\"\n    mv -fT -- \"$tmp\" \"$dir/generation\"\n    rm -f -- \"$file\"\n    exit 0\nfi\ngeneration=\nif [ -e \"$dir/generation\" ]; then\n    IFS= read -r generation < \"$dir/generation\"\nfi\n[ \"$4\" = \"$generation\" ]\nIFS= read -r line\ntmp=$(mktemp -- \"$dir/.connection.XXXXXX\")\ntrap 'rm -f -- \"$tmp\"' EXIT\nprintf '%s\\n' \"$line\" > \"$tmp\"\nmv -fT -- \"$tmp\" \"$file\"\n"
    // $1 URL, $2 allowed protocol; the token is one line on stdin. -q skips ~/.curlrc,
    // which could otherwise turn redirects back on. Prints the body, then "<HTTP status> <curl exit>".
    readonly property string fetchScript: "IFS= read -r token || exit 1\n" + "printf 'Authorization: Bearer %s\\n' \"$token\" | curl -q -s --proto \"$2\" --max-redirs 0 --connect-timeout 10 --max-time 25 --max-filesize 4M -H @- -H 'Accept: application/json' -o - -w '\\n%{http_code}' -- \"$1\" 2>/dev/null\n" + "printf ' %s\\n' \"$?\"\n"
    Process {
        id: writer
        command: ["sh", "-c", root.writeScript, "sh", root.configDir, connectionFile.path, root.saving, root.expectedGeneration]
        stdinEnabled: true
        onStarted: if (root.pendingSave)
            write(root.pendingSave)
        onExited: function (code) {
            root.saveFinished(code === 0);
        }
    }
    Component {
        id: fetcher
        Process {
            id: request
            property string token: ""
            property var done: null
            property bool cancelled: false
            property bool streamDone: false
            property bool exitDone: false
            running: true
            stdinEnabled: true
            function cancel() {
                cancelled = true;
                if (running)
                    running = false;
                else
                    destroy();
            }
            function settle() {
                // A killed request may never finish its output stream.
                if (!exitDone || (!streamDone && !cancelled))
                    return;
                if (!cancelled) {
                    cancelled = true;
                    var result = Coolify.parseFetch(output.text);
                    done(result.exit, result.status, result.body);
                }
                destroy();
            }
            onStarted: {
                write(token + "\n");
                token = "";
            }
            stdout: StdioCollector {
                id: output
                onStreamFinished: {
                    request.streamDone = true;
                    request.settle();
                }
            }
            onExited: {
                exitDone = true;
                settle();
            }
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
            Component.onDestruction: Coolify.alertPending = false
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
