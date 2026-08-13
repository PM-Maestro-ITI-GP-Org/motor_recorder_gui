import QtQuick

/*
 * A surface with a soft shadow.
 *
 * The shadow is two offset rectangles rather than layer.effect + MultiEffect.
 * A layered item whose shader the backend cannot run renders as *nothing* --
 * not as an unshadowed card -- so on a machine without working shader support
 * the whole panel silently disappears. Two rectangles always draw.
 */
Item {
    id: root

    property int  elevation: 1
    property int  padding: Theme.spacing
    property color color: Theme.surface
    property color borderColor: Theme.border
    property int  radius: Theme.radius

    default property alias content: inner.data

    implicitWidth:  inner.implicitWidth  + padding * 2
    implicitHeight: inner.implicitHeight + padding * 2

    Rectangle {
        anchors.fill: parent
        anchors.topMargin: root.elevation * 2
        radius: root.radius
        color: Theme.dark ? "#0d0f15" : "#dfe3ec"
        opacity: 0.55
        visible: root.elevation > 0
    }
    Rectangle {
        anchors.fill: parent
        anchors.topMargin: root.elevation
        radius: root.radius
        color: Theme.dark ? "#11131a" : "#eaedf4"
        opacity: 0.7
        visible: root.elevation > 0
    }

    Rectangle {
        anchors.fill: parent
        radius: root.radius
        color: root.color
        border.color: root.borderColor
        border.width: 1

        Item {
            id: inner
            anchors.fill: parent
            anchors.margins: root.padding
        }
    }
}
