import QtQuick
import PdM.Core

/* Small state chip: a dot and a word, coloured by tone. */
Rectangle {
    id: pill
    property string text: ""
    property string tone: "neutral"   // success | warning | danger | recording | neutral
    property bool pulse: false

    readonly property color toneColor:
          tone === "success"   ? Theme.success
        : tone === "warning"   ? Theme.warning
        : tone === "danger"    ? Theme.danger
        : tone === "recording" ? Theme.recording
                               : Theme.textSecondary
    readonly property color toneSoft:
          tone === "success"   ? Theme.successSoft
        : tone === "warning"   ? Theme.warningSoft
        : tone === "danger"    ? Theme.dangerSoft
        : tone === "recording" ? Theme.recordingSoft
                               : Theme.surfaceVariant

    implicitWidth: row.implicitWidth + 22
    implicitHeight: 30
    radius: height / 2
    color: toneSoft

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 7

        Rectangle {
            width: 8; height: 8; radius: 4
            anchors.verticalCenter: parent.verticalCenter
            color: pill.toneColor
            SequentialAnimation on opacity {
                running: pill.pulse
                loops: Animation.Infinite
                NumberAnimation { to: 0.25; duration: 620 }
                NumberAnimation { to: 1.0;  duration: 620 }
            }
        }
        Text {
            text: pill.text
            color: pill.toneColor
            font.pixelSize: Theme.fontSmall
            font.weight: Font.DemiBold
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
