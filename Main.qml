import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import PdM.Core
import PdM.DataCollection

/*
 * The standalone window, and nothing else.
 *
 * This file is not used when Maestro pulls the repository in -- the shell owns
 * the only ApplicationWindow in the merged process, and DataCollectionPage goes
 * straight into a tab. Everything that used to be here is in that page now;
 * what remains is the handful of properties that only mean something to a
 * window.
 */
ApplicationWindow {
    id: appWindow

    visible: true

    /* Bigger by default. The old 1100x800 with 9-14px type meant the file list
       and the graph controls were both cramped and hard to read. */
    width: 1400
    height: 950
    minimumWidth: 1000
    minimumHeight: 700
    title: qsTr("Motor Data Recorder")
    color: Theme.background

    DataCollectionPage {
        anchors.fill: parent
    }
}
