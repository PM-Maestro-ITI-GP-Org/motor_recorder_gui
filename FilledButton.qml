import QtQuick
import QtQuick.Controls

/*
 * A button that actually shows its accent colour.
 *
 * Material.background set on an ApplicationWindow or ToolBar propagates down
 * to every Button inside it and overrides the accent fill, so the styled
 * buttons came out the same colour as the bar they sat on. Painting the
 * background here takes that decision back.
 */
Button {
    id: control

    property color fill: Theme.accent
    property color fillHover: Theme.accentHover
    property color textColor: "#ffffff"

    implicitHeight: 44
    leftPadding: Theme.spacing
    rightPadding: Theme.spacing
    font.pixelSize: Theme.fontSmall
    font.weight: Font.DemiBold

    background: Rectangle {
        radius: Theme.radiusSmall
        color: !control.enabled ? Theme.surfaceAlt
             : control.down     ? Qt.darker(control.fillHover, 1.1)
             : control.hovered  ? control.fillHover
                                : control.fill
        Behavior on color { ColorAnimation { duration: 110 } }
    }

    contentItem: Text {
        text: control.text
        font: control.font
        color: control.enabled ? control.textColor : Theme.textDisabled
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
}
