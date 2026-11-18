import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui as Ui

Ui.Button {
    id: row
    required property var deployment
    required property double now
    property bool ongoing: false
    property string dateLocale: "en"
    signal openDeployment
    width: parent ? parent.width : Style.space(360)
    implicitHeight: labels.implicitHeight + Style.space(20)
    focusable: true
    onClicked: openDeployment()
    function elapsed() {
        var start = Date.parse(deployment.started_at || deployment.created_at);
        var finish = ongoing ? now : Date.parse(deployment.finished_at || deployment.updated_at);
        if (!isFinite(start) || !isFinite(finish))
            return "—";
        var seconds = Math.max(0, Math.floor((finish - start) / 1000));
        return seconds < 60 ? seconds + "s" : Math.floor(seconds / 60) + "m " + seconds % 60 + "s";
    }
    Row {
        anchors.fill: parent
        anchors.margins: Style.space(10)
        spacing: Style.space(12)
        Label {
            width: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            text: row.ongoing ? "◌" : (row.deployment.status === "finished" ? "✓" : (row.deployment.status === "failed" ? "×" : "−"))
            font.pixelSize: Style.font.title
            color: row.deployment.status === "failed" ? Commons.Color.urgent : Commons.Color.foreground
            SequentialAnimation on opacity {
                running: row.ongoing && Style.duration(1000) > 0
                loops: Animation.Infinite
                NumberAnimation {
                    to: 0.35
                    duration: Style.duration(700)
                }
                NumberAnimation {
                    to: 1
                    duration: Style.duration(700)
                }
            }
        }
        Column {
            id: labels
            width: parent.width - Style.space(32)
            spacing: Style.space(4)
            Label {
                width: parent.width
                text: row.deployment.application_name || "Coolify"
                font.bold: true
                maximumLineCount: 1
                elide: Text.ElideRight
            }
            Label {
                width: parent.width
                text: row.deployment.status.replace(/_/g, " ").replace(/-/g, " ") + "  ·  " + row.elapsed() + (row.deployment.environment ? "  ·  " + row.deployment.environment : "")
                opacity: 0.65
                font.pixelSize: Style.font.caption
                maximumLineCount: 2
                elide: Text.ElideRight
            }
            Label {
                width: parent.width
                visible: !row.ongoing
                text: {
                    var date = new Date(row.deployment.finished_at || row.deployment.updated_at);
                    return isFinite(date.getTime()) ? date.toLocaleString(Qt.locale(row.dateLocale), "ddd, d MMM · HH:mm") : "";
                }
                opacity: 0.65
                font.pixelSize: Style.font.caption
            }
            Label {
                visible: !!row.deployment.commit && row.deployment.commit !== "HEAD"
                text: (row.deployment.commit || "").substring(0, 7)
                opacity: 0.45
                font.pixelSize: Style.font.caption
            }
        }
    }
}
