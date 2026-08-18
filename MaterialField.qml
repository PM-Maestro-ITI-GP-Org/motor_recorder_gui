import QtQuick
import QtQuick.Controls
import PdM.Core

/*
 * A Material 3 "filled" text field.
 *
 * The fields it replaces had a separate Text label above them AND a
 * placeholderText, and the Material style turns placeholderText into a
 * floating label -- so each field showed its caption twice, and the floating
 * one animated up onto the custom background's 1px border and sat across it,
 * because a hand-drawn Rectangle background has no notch for a label to rise
 * into.
 *
 * The filled variant sidesteps that by construction: the label floats inside
 * the container's own top area, and there is no outline for it to collide
 * with. One caption, in the place Material puts it.
 *
 * Use `label` for the caption and `hint` for a placeholder that should only
 * appear once the label has floated up and the field is empty.
 */
Item {
    id: root

    property alias text: input.text
    property alias validator: input.validator
    property alias inputMethodHints: input.inputMethodHints
    property alias echoMode: input.echoMode
    property alias readOnly: input.readOnly
    property string label: ""
    property string hint: ""

    /* True once the label should be small and raised: either the field is
       focused, or it already holds something. */
    readonly property bool raised: input.activeFocus || input.text.length > 0

    implicitHeight: 60
    implicitWidth: 200

    Rectangle {
        id: container
        anchors.fill: parent
        /* Material's filled field: rounded top, square bottom, sitting on its
           indicator line. */
        radius: Theme.radiusSmall
        color: input.activeFocus ? Theme.primarySoft : Theme.surfaceVariant
        Behavior on color { ColorAnimation { duration: 120 } }

        /* Bottom indicator: thin at rest, thick and accented when focused. */
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: input.activeFocus ? 2 : 1
            color: input.activeFocus ? Theme.primary : Theme.outline
            Behavior on height { NumberAnimation { duration: 120 } }
            Behavior on color { ColorAnimation { duration: 120 } }
        }

        Text {
            id: floatLabel
            text: root.label
            color: input.activeFocus ? Theme.primary : Theme.textSecondary
            x: Theme.spacingTight + 4
            /* Raised: tucked under the top edge. Resting: vertically centred,
               where the value will appear. */
            y: root.raised ? 8 : (container.height - height) / 2 - 2
            font.pixelSize: root.raised ? Theme.fontTiny : Theme.fontBody
            Behavior on y { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            Behavior on font.pixelSize { NumberAnimation { duration: 120 } }
            Behavior on color { ColorAnimation { duration: 120 } }
        }

        TextInput {
            id: input
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Theme.spacingTight + 4
            anchors.rightMargin: Theme.spacingTight + 4
            /* Sits below the raised label, not under it. */
            y: 24
            height: container.height - 30
            verticalAlignment: Text.AlignVCenter
            color: Theme.textPrimary
            font.pixelSize: Theme.fontBody
            selectByMouse: true
            clip: true

            /* Only once the label is out of the way and there is nothing to
               show -- otherwise it would sit on top of the resting label. */
            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.hint
                color: Theme.textDisabled
                font.pixelSize: Theme.fontBody
                visible: root.raised && input.text.length === 0 && root.hint !== ""
            }
        }
    }

    /* Clicking anywhere in the container focuses the input, not just the
       one-line-tall text area inside it. */
    MouseArea {
        anchors.fill: parent
        onClicked: input.forceActiveFocus()
        /* Let the input keep its own I-beam and selection behaviour. */
        propagateComposedEvents: true
        cursorShape: Qt.IBeamCursor
    }
}
