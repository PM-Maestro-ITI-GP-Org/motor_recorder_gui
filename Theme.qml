/*
 * `pragma Singleton` is REQUIRED here, and this line is load-bearing.
 *
 * It pairs with the C++ side:
 *
 *     qmlRegisterSingletonType(QUrl("qrc:/Theme.qml"), "App", 1, 0, "Theme")
 *
 * Registering a QML file as a singleton and omitting the pragma is not a
 * tolerated mismatch, it is fatal:
 *
 *     qrc:/Theme.qml: qmldir defines type as singleton, but no pragma
 *     Singleton found in type App/Theme
 *
 * and since main.qml imports Theme, the whole file fails to load and the app
 * exits with no window at all. Removing it was tried, on the theory that older
 * Qt might reject having both; the opposite is true.
 */
pragma Singleton
import QtQuick

/*
 * One place for colour, type and spacing.
 *
 * The old UI spelled its colours inline, as literals, in about two hundred
 * places -- "#1a1a2e" and friends -- so the palette could not be changed
 * without a careful read of 1700 lines, and light mode was not expressible at
 * all. Everything visual now resolves through here.
 *
 * Note the hex order: Qt reads 8-digit literals as #AARRGGBB, alpha FIRST.
 * Writing them the CSS way (#RRGGBBAA) compiles fine and renders the wrong
 * colour at the wrong transparency, which is a genuinely hard thing to spot.
 */
QtObject {
    id: theme

    property bool dark: false

    /* ---- surfaces ---- */
    readonly property color background:  dark ? "#12141c" : "#f6f7fb"
    readonly property color surface:     dark ? "#1b1e29" : "#ffffff"
    readonly property color surfaceAlt:  dark ? "#232735" : "#f0f2f8"
    readonly property color border:      dark ? "#2f3444" : "#e2e6ef"

    /* ---- text ---- */
    readonly property color textPrimary:   dark ? "#eef1f7" : "#161a23"
    readonly property color textSecondary: dark ? "#9aa3b6" : "#5b6478"
    readonly property color textDisabled:  dark ? "#5d6577" : "#a2aab9"

    /* ---- accents ---- */
    readonly property color accent:      "#2f6df6"
    readonly property color accentHover: "#2559d6"
    readonly property color accentSoft:  dark ? "#1d2b4d" : "#e7efff"

    readonly property color success:     "#1a9d5a"
    readonly property color successSoft: dark ? "#12301f" : "#e3f6ea"
    readonly property color warning:     "#c77700"
    readonly property color warningSoft: dark ? "#33260c" : "#fdf1de"
    readonly property color danger:      "#d13b3b"
    readonly property color dangerSoft:  dark ? "#3a1a1a" : "#fce9e9"

    /* Recording is its own state and reads as "live", not as an error. */
    readonly property color recording:     "#e0245e"
    readonly property color recordingSoft: dark ? "#3d1424" : "#fde8ef"

    /* ---- type ----
       Every size is up from the original, which was 10-12px throughout and
       genuinely hard to read on a high-DPI panel. */
    readonly property int fontTiny:    12
    readonly property int fontSmall:   14
    readonly property int fontBody:    16
    readonly property int fontTitle:   20
    readonly property int fontDisplay: 28
    readonly property string monoFamily: "DejaVu Sans Mono"

    /* ---- spacing ---- */
    readonly property int spacingTight: 8
    readonly property int spacing:      16
    readonly property int spacingWide:  24
    readonly property int radius:       12
    readonly property int radiusSmall:  8
}
