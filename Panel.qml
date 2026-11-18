import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

Ui.Panel {
    id: root
    moduleName: "io.github.peterszarvas94.coolify"
    ipcTarget: moduleName
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    property var state: ({
            configured: false,
            active: [],
            last: null
        })
    property bool busy: false
    property bool editing: false
    property bool initialized: false
    property string error: ""
    property string pending: ""
    property double now: Date.now()
    readonly property var active: state.active || []
    readonly property bool notificationsEnabled: setting("notifications", true)
    readonly property bool autoRefresh: setting("backgroundRefresh", true)
    readonly property string filter: String(setting("applicationUUIDs", ""))
    readonly property bool failed: state.last && state.last.status === "failed"
    readonly property string helper: Qt.resolvedUrl("bin/coolify-status").toString().replace(/^file:\/\//, "")
    Commons.Translations {
        id: strings
        directory: Qt.resolvedUrl("i18n")
    }
    function t(key) {
        return strings.t(key);
    }
    function send(action, url, token) {
        if (busy)
            return;
        busy = true;
        error = "";
        pending = JSON.stringify({
            action: action,
            url: url || "",
            token: token || "",
            filter: filter,
            notifications: notificationsEnabled,
            notificationLabels: {
                notificationStarted: t("notificationStarted"),
                notificationSucceeded: t("notificationSucceeded"),
                notificationFailed: t("notificationFailed"),
                notificationCancelled: t("notificationCancelled"),
                notificationSkipped: t("notificationSkipped"),
                notificationDuration: t("notificationDuration"),
                notificationOpen: t("notificationOpen")
            }
        }) + "\n";
        if (worker.running) {
            worker.write(pending);
            pending = "";
        } else
            worker.running = true;
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
    function refresh() {
        send("refresh");
    }
    function openLink(link) {
        if (link)
            Qt.openUrlExternally(link);
    }
    onOpenedChanged: {
        if (opened) {
            if (!busy)
                refresh();
            if (!state.configured)
                editing = true;
        } else
            tokenInput.text = "";
    }
    onFilterChanged: if (initialized)
        refresh()
    Component.onCompleted: {
        initialized = true;
        send("info");
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
        onTriggered: root.send("poll")
    }
    Process {
        id: worker
        command: [root.helper]
        stdinEnabled: true
        onStarted: {
            write(root.pending);
            root.pending = "";
        }
        stdout: SplitParser {
            onRead: function (line) {
                try {
                    var next = JSON.parse(line);
                    root.busy = false;
                    root.error = next.error || "";
                    if (!next.error) {
                        root.state = next;
                        if (next.saved) {
                            root.editing = false;
                            tokenInput.text = "";
                        }
                        if (!next.checked && next.configured && root.autoRefresh)
                            Qt.callLater(root.refresh);
                    }
                } catch (e) {
                    root.busy = false;
                    root.error = root.t("invalidResponse");
                }
            }
        }
        stderr: StdioCollector {}
        onExited: function (code, status) {
            if (root.busy) {
                root.busy = false;
                root.error = root.t("helperError");
            }
        }
    }
    Ui.BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        iconComponent: Component {
            CoolifyIcon {
                anchors.centerIn: parent
                width: Style.bar.iconSize
                height: width
                foreground: root.barForeground
                status: root.error ? "offline" : (root.active.length ? "active" : (root.failed ? "failed" : "idle"))
            }
        }
        foreground: root.failed || root.error ? Commons.Color.urgent : root.barForeground
        labelText: root.active.length ? String(root.active.length) : ""
        fixedWidth: vertical ? -1 : Style.bar.iconSlot + (labelText ? Style.space(18) : 0)
        onPressed: function (code) {
            if (code === Qt.MiddleButton)
                root.refresh();
            else
                root.toggle();
        }
    }
    Ui.KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: root.editing ? urlInput : refreshButton
        contentWidth: fittedContentWidth(Style.space(390))
        contentHeight: fittedContentHeight(column.implicitHeight + footer.implicitHeight + Style.space(12), Style.space(640))
        Item {
            anchors.fill: parent
            Keys.onEscapePressed: root.close()
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
                            width: parent.width
                            placeholderText: "https://coolify.example.com"
                            text: root.state.url || ""
                            enabled: !root.busy
                            maximumLength: 2048
                        }
                        Ui.TextField {
                            id: tokenInput
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
                                    root.send("connect", urlInput.text, tokenInput.text)
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
                                    root.send("forget");
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
                            text: root.state.warning || ""
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
