pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

Ui.BarWidget {
    id: root
    moduleName: "io.github.peterszarvas94.coolify"

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened : false
    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing : false
    readonly property var deployments: panelLoader.item ? panelLoader.item.active : []
    readonly property bool failed: panelLoader.item ? panelLoader.item.failed : false
    readonly property string error: panelLoader.item ? panelLoader.item.error : ""
    readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function open() {
        if (panelLoader.item)
            panelLoader.item.open();
    }
    function close() {
        if (panelLoader.item)
            panelLoader.item.close();
    }
    function toggle() {
        if (panelLoader.item)
            panelLoader.item.toggle();
    }
    function refresh() {
        if (panelLoader.item)
            panelLoader.item.refresh();
    }
    function closeForPopoutSwitch() {
        if (panelLoader.item)
            panelLoader.item.closeForPopoutSwitch();
    }
    function injectPanel() {
        if (!panelLoader.item)
            return;
        panelLoader.item.bar = Qt.binding(function () {
            return root.bar;
        });
        panelLoader.item.settings = Qt.binding(function () {
            return root.settings;
        });
        panelLoader.item.anchorItem = button;
        panelLoader.item.hostWidget = root;
    }

    Loader {
        id: panelLoader
        active: true
        visible: false
        source: Qt.resolvedUrl("Panel.qml")
        onLoaded: root.injectPanel()
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
                foreground: root.foreground
                status: root.error ? "offline" : (root.deployments.length ? "active" : (root.failed ? "failed" : "idle"))
            }
        }
        foreground: root.failed || root.error ? Commons.Color.urgent : root.foreground
        labelText: root.deployments.length ? String(root.deployments.length) : ""
        fixedWidth: vertical ? -1 : Style.bar.iconSlot + (labelText ? Style.space(18) : 0)
        onPressed: function (code) {
            if (code === Qt.MiddleButton)
                root.refresh();
            else
                root.toggle();
        }
    }
}
