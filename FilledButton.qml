import QtQuick
import QtQuick.Controls
import PdM.Core

/*
 * A Material 3 button.
 *
 * The app's buttons were each hand-rolled, and no two agreed: some went accent
 * on hover and accent again on press (so pressing showed no feedback at all),
 * some changed their border instead, disabled states ranged over three
 * different greys. This is the one place that decides, with the four standard
 * variants:
 *
 *   filled    solid accent, for the primary action
 *   tonal     soft accent, for a secondary action that still matters
 *   outlined  hairline outline, for the ordinary case
 *   text      no container, for the quietest actions
 *
 * Material draws interaction as a translucent "state layer" over the container
 * rather than by swapping the fill -- 8% on hover, 12% pressed -- which is why
 * one accent colour is enough to express every state, and why a filled button
 * still visibly reacts when hover and press would otherwise both be "accent".
 *
 * Painted here rather than left to the Material style because
 * Material.background set on a window propagates into every Button beneath it
 * and overrides the accent fill.
 *
 * Deliberately no MultiEffect for the elevation shadow: that is Qt 6.5+, and
 * this has to build on 6.2. Two offset rectangles, as in AppCard.
 */
Button {
    id: control

    /* "filled" | "tonal" | "outlined" | "text" */
    property string variant: "filled"

    /* The accent this button is drawn in. Set it to Theme.danger for a
       destructive action and every state follows. */
    property color accent: Theme.primary

    /* Kept so existing call sites that set fill/fillHover/textColor still
       work; when fill is set it wins over the variant's container colour. */
    property color fill: "transparent"
    property color fillHover: "transparent"
    property color textColor: "transparent"

    readonly property bool _isFilled:   variant === "filled"
    readonly property bool _isTonal:    variant === "tonal"
    readonly property bool _isOutlined: variant === "outlined"

    readonly property color _container:
          fill.a > 0            ? fill
        : _isFilled             ? accent
        : _isTonal              ? Theme.primarySoft
                                : "transparent"

    readonly property color _label:
          textColor.a > 0       ? textColor
        : !enabled              ? Theme.textDisabled
        : _isFilled             ? "#ffffff"
                                : accent

    implicitHeight: 44
    implicitWidth: Math.max(88, label.implicitWidth + 48)
    font.pixelSize: Theme.fontSmall
    font.weight: Font.DemiBold
    hoverEnabled: true

    background: Item {
        implicitHeight: control.implicitHeight

        /* Elevation, filled only, and only while resting -- Material drops a
           button flat to the surface while it is held. */
        Rectangle {
            anchors.fill: parent
            anchors.topMargin: 2
            radius: height / 2
            color: Theme.dark ? "#0d0f15" : "#d6dae4"
            opacity: control._isFilled && control.enabled && !control.down ? 0.7 : 0
            Behavior on opacity { NumberAnimation { duration: 110 } }
        }

        Rectangle {
            id: container
            anchors.fill: parent
            /* Fully rounded: the Material 3 button shape. */
            radius: height / 2
            color: control.enabled ? control._container
                                   : (control._isFilled || control._isTonal
                                      ? Theme.surfaceVariant : "transparent")
            border.width: control._isOutlined ? 1 : 0
            border.color: control.enabled ? Qt.rgba(control.accent.r, control.accent.g,
                                                    control.accent.b, 0.45)
                                          : Theme.outline
            clip: true

            /* State layer: the accent (or white, over a filled container) at
               low opacity. One layer expresses hover and press without the
               container colour having to change. */
            Rectangle {
                anchors.fill: parent
                radius: parent.radius
                color: control._isFilled ? "#ffffff" : control.accent
                opacity: !control.enabled ? 0
                       : control.down     ? 0.16
                       : control.hovered  ? 0.08
                                          : 0
                Behavior on opacity { NumberAnimation { duration: 110 } }
            }

            /* Ripple, from where the pointer actually went down. */
            Rectangle {
                id: ripple
                property real cx: 0
                property real cy: 0
                x: cx - width / 2
                y: cy - height / 2
                width: 0; height: width
                radius: width / 2
                color: control._isFilled ? "#ffffff" : control.accent
                opacity: 0

                ParallelAnimation {
                    id: rippleAnim
                    NumberAnimation {
                        target: ripple; property: "width"
                        from: 0; to: Math.max(container.width, container.height) * 2.2
                        duration: 380; easing.type: Easing.OutCubic
                    }
                    SequentialAnimation {
                        NumberAnimation { target: ripple; property: "opacity"
                                          from: 0.30; to: 0.30; duration: 60 }
                        NumberAnimation { target: ripple; property: "opacity"
                                          to: 0; duration: 320 }
                    }
                }
            }
        }
    }

    contentItem: Text {
        id: label
        text: control.text
        font: control.font
        color: control._label
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    onPressed: (mouse) => {
        ripple.cx = mouse.x
        ripple.cy = mouse.y
        rippleAnim.restart()
    }
}
