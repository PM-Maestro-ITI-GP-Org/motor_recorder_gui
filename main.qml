import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtQuick.Window
import Qt.labs.folderlistmodel
import MqttClient 1.0
import App 1.0

ApplicationWindow {
    id: window
    visible: true

    /* Bigger by default. The old 1100x800 with 9-14px type meant the file list
       and the graph controls were both cramped and hard to read. */
    width: 1400
    height: 950
    minimumWidth: 1000
    minimumHeight: 700
    title: "Motor Data Recorder"
    color: Theme.background

    /* Light by default, with a toggle. Material.background is deliberately NOT
       set on the window: it propagates to every Button inside and overrides
       their own fill, which is why FilledButton paints its own. */
    Material.theme: Theme.dark ? Material.Dark : Material.Light
    Material.accent: Theme.accent
    Material.primary: Theme.accent


    MqttClient {
        id: mqtt
        onLogMessage: (text, type) => logAppend(text, type)
        onConnectedChanged: {
            indicator.connected = mqtt.connected
            if (mqtt.connected) {
                btnConnect.text = "Disconnect"
                enableButtons("connected")
                logAppend("Connected to MQTT broker.", "success")
            } else {
                btnConnect.text = "Connect"
                enableButtons("disconnected")
                stopAll()
                logAppend("Disconnected from broker.", "error")
            }
        }
        onStatusReceived: (state, msg, raw) => {
            statusText.text = "Status: " + state
            logAppend("Recorder: " + state + " (" + msg + ")", "info")
            if (state === "recording") {
                enableButtons("recording")
                recTimerRunning = true
                recordingSecs = 0
                statusText.text = "Status: Recording"
                logAppend("Recording started.", "success")
            } else if (state === "stopped" || state === "idle") {
                enableButtons("stopped")
                recTimerRunning = false
                statusText.text = "Status: Stopped"
                logAppend("Recording stopped.", "success")
                parseMetadata(raw)
            } else if (state === "error" && downloadQueueIndex < downloadQueue.length) {
                setQueueStatus(downloadQueueIndex, "error")
                downloadQueueIndex++
                processDownloadQueue()
            }
        }
        onUploadProgress: (pct) => {
            if (downloadQueueIndex < downloadQueue.length)
                setQueueStatus(downloadQueueIndex, "uploading")
            window.uploadPct = pct
            uploadLabel.text = "Upload " + pct + "%"
            logAppend("Upload to server: " + pct + "%", "info")
            statusText.text = "Upload: " + pct + "%"
        }
        onDownloadProgress: (pct) => {
            window.downloadPct = pct
            downloadLabel.text = "Download " + pct + "%"
            if (downloadQueueIndex < downloadQueue.length && pct < 100)
                setQueueStatus(downloadQueueIndex, "downloading")
            if (pct >= 100) {
                downloadLabel.text = "Download 100%"
            }
        }
        onCommandTimeout: (cmd) => {
            logAppend("No response from recorder (" + cmd + ") - check connection.", "error")
            if (cmd === "start" || cmd.startsWith("start ")) {
                enableButtons("connected")
                recTimerRunning = false
            } else if (cmd === "stop") {
                enableButtons("recording")
                recTimerRunning = true
            } else if (cmd === "list") {
                fileListLoading = false
            } else if (cmd.startsWith("upload ")) {
                logAppend("Upload timed out.", "error")
                if (downloadQueueIndex < downloadQueue.length) {
                    setQueueStatus(downloadQueueIndex, "error")
                    downloadQueueIndex++
                    processDownloadQueue()
                }
            }
        }
        onDataReceived: (payload) => {
            var parts = payload.split(',')
            if (parts.length === 13) {
                for (var c = 0; c < 13; ++c)
                    dataModel.setProperty(c, "value", parts[c])
            }
        }
        onFileDownloaded: (csvData) => {
            window.uploadPct = 0
            window.downloadPct = 0
            uploadLabel.text = "Upload 0%"
            downloadLabel.text = "Download 0%"
            if (pendingSavePath !== "") {
                mqtt.saveStringToFile(pendingSavePath, csvData)
                var fname = pendingSavePath.split('/').pop()
                addDownloadedFile(fname, csvData)
                if (downloadQueueIndex < downloadQueue.length) {
                    setQueueStatus(downloadQueueIndex, "done")
                    downloadQueueIndex++
                }
                pendingSavePath = ""
                processDownloadQueue()
            } else {
                logAppend("Download complete.", "success")
                addDownloadedFile("motor_data.csv", csvData)
            }
        }
        onDownloadChunkReceived: (chunk, total, data) => {
            if (chunk === 0) {
                logAppend("Download started: " + total + " chunks", "info")
                downloadBuffer = ""
            }
            var pct = (chunk + 1) / total * 100
            window.downloadPct = pct
            downloadLabel.text = "Download " + pct.toFixed(0) + "%"
            downloadBuffer += data
            if (chunk + 1 >= total) {
                downloadLabel.text = "Download 100%"
                logAppend("Download complete (" + total + " chunks).", "success")
                if (pendingSavePath !== "") {
                    mqtt.saveStringToFile(pendingSavePath, downloadBuffer)
                    var fname = pendingSavePath.split('/').pop()
                    addDownloadedFile(fname, downloadBuffer)
                    pendingSavePath = ""
                    processDownloadQueue()
                } else {
                    addDownloadedFile("motor_data.csv", downloadBuffer)
                }
                downloadBuffer = ""
            }
        }
        onFileListReceived: (json) => {
            fileListLoading = false
            var obj = JSON.parse(json)
            fileListModel.clear()
            var files = obj.files
            for (var i = 0; i < files.length; ++i) {
                fileListModel.append({
                    fileName: files[i].name,
                    fileSize: files[i].size,
                    checked: false,
                    sizeStr: formatFileSize(files[i].size)
                })
            }
            if (files.length === 0)
                logAppend("No recording files found on recorder.", "warning")
            else
                logAppend("Found " + files.length + " file(s) on recorder.", "info")
        }
        onDeleteResult: (filename, success) => {
            if (success)
                logAppend("Deleted: " + filename, "success")
            else
                logAppend("Failed to delete: " + filename, "error")
        }
        onSingleFileDownloaded: (filename, localPath) => {
            logAppend("Saved: " + localPath, "success")
        }
    }

    ListModel { id: dataModel }
    ListModel { id: logModel }

    ListModel { id: fileListModel }

    ListModel { id: downloadedFilesModel }

    ListModel { id: graphFilesModel }

    function updateGraphFilesModel() {
        graphFilesModel.clear()
        // Add CSV files found in the download directory
        var localFiles = mqtt.listCsvFiles(downloadDir)
        for (var j = 0; j < localFiles.length; ++j) {
            var localName = localFiles[j].split('/').pop()
            graphFilesModel.append({
                displayName: localName,
                source: "local",
                index: j,
                filePath: localFiles[j]
            })
        }
        // Add downloaded files
        for (var i = 0; i < downloadedFilesModel.count; ++i) {
            var item = downloadedFilesModel.get(i)
            graphFilesModel.append({
                displayName: item.fileName + " (downloaded)",
                source: "downloaded",
                index: i,
                csvData: item.csvData
            })
        }
    }

    function loadSelectedFile(idx) {
        if (idx < 0 || idx >= graphFilesModel.count) return
        var item = graphFilesModel.get(idx)
        if (item.source === "downloaded") {
            // Load from downloaded files (stored as raw text — parse into rows)
            var data = downloadedFilesModel.get(item.index).csvData
            parseDownloadedCSV(data)
            graphStartRow = 0
            graphEndRow = csvTotalRows
            graphStartField.text = "0"
            graphEndField.text = csvTotalRows > 0 ? (csvTotalRows - 1).toString() : "0"
            chartCanvas.requestPaint()
        } else if (item.source === "local") {
            // Load from local file
            loadLocalCSV(item.filePath)
        }
    }

    function loadLocalCSV(filePath) {
        if (!filePath) return
        console.log("Loading local CSV:", filePath)
        var text = mqtt.readTextFile(filePath)
        if (text === "") {
            logAppend("Failed to read file: " + filePath, "error")
            return
        }
        csvData = []
        var lines = text.split('\n')
        if (lines.length < 2) {
            logAppend("No valid data rows in: " + filePath, "warning")
            return
        }
        var headerCols = lines[0].split(',')
        csvHeader = headerCols.slice()
        var friendly = []
        for (var k = 0; k < headerCols.length; ++k)
            friendly.push(friendlyColumnName(headerCols[k]))
        csvColumns = friendly
        initColumnStates()
        var nCols = csvColumns.length
        var dataCount = 0
        var step = Math.max(1, Math.floor((lines.length - 1) / maxPlotRows))
        for (var i = 1; i < lines.length; ++i) {
            var line = lines[i].trim()
            if (line === "") continue
            dataCount++
            if ((dataCount - 1) % step !== 0) continue
            var cols = line.split(',')
            if (cols.length >= nCols)
                csvData.push(cols)
        }
        if (dataCount === 0) {
            logAppend("No valid data rows in: " + filePath, "warning")
            return
        }
        csvTotalRows = dataCount
        csvStep = step
        graphStartRow = 0
        graphEndRow = csvTotalRows
        graphStartField.text = "0"
        graphEndField.text = csvTotalRows > 0 ? (csvTotalRows - 1).toString() : "0"
        logAppend("Loaded " + dataCount + " rows from " + filePath +
                  (step > 1 ? " (downsampled to " + csvData.length + ")" : ""), "success")
        chartCanvas.requestPaint()
    }

    function processDownloadQueue() {
        if (downloadQueueIndex >= downloadQueue.length) {
            downloadQueueActive = false
            downloadQueueIndex = 0
            logAppend("All downloads complete.", "success")
            return
        }
        var item = downloadQueue[downloadQueueIndex]
        var savePath = item.dir + "/" + item.file
        pendingSavePath = savePath
        item.status = "uploading"
        setQueueStatus(downloadQueueIndex, "uploading")
        logAppend("Uploading " + item.file + " from recorder...", "info")
        mqtt.uploadFile(item.file, savePath)
    }

    property string lastCmd: ""
    property string cmdStatus: ""
    property int recordingSecs: 0
    property bool recTimerRunning: false
    property bool fileListLoading: false
    property string downloadBuffer: ""
    property string pendingSavePath: ""
    property var downloadQueue: []
    property bool downloadQueueActive: false

    property string metaFile: ""
    property string metaSpan: ""
    property string metaRows: ""
    property string metaDrops: ""
    property string metaBlockDrops: ""
    property string metaStalled: ""

    function formatFileSize(bytes) {
        if (bytes < 1024) return bytes + " B"
        if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB"
        return (bytes / 1048576).toFixed(2) + " MB"
    }

    /* Resolve a log line's colour at paint time. Kept next to logAppend so the
       two cannot drift. */
    function logColorFor(type) {
        if (type === "success") return Theme.success
        if (type === "error")   return Theme.danger
        if (type === "warning") return Theme.warning
        return Theme.textSecondary
    }

    function logAppend(text, type) {
        /*
         * The model stores the KIND of message, not a colour.
         *
         * It used to store the colour, computed here -- and computed
         * inconsistently: the default was the JS string "#8888ff" while the
         * others were Theme values, which are QML color objects. Whichever
         * arrived first fixed the role's type, and every later line of the
         * other kind was rejected outright with
         *
         *     Can't assign to existing role 'textColor' of different type
         *
         * so a run's log came out in one colour regardless of severity.
         * Storing the type also means the log recolours when the theme is
         * toggled, instead of keeping whatever palette was current when each
         * line happened to be written.
         */
        var ts = new Date().toLocaleTimeString("en_US", {hour12: false})
        logModel.insert(0, {text: "[" + ts + "] " + text, logType: type || "info"})
        if (logModel.count > 200)
            logModel.remove(200, logModel.count - 200)
    }

    function enableButtons(state) {
        switch (state) {
            case "disconnected":
                btnConnect.enabled = true
                btnStart.enabled = false
                btnStop.enabled = false
                btnDownload.enabled = false
                btnGraphs.enabled = false
                break
            case "connected":
                btnConnect.enabled = true
                btnStart.enabled = true
                btnStop.enabled = false
                btnDownload.enabled = false
                btnGraphs.enabled = true
                break
            case "recording":
                btnConnect.enabled = false
                btnStart.enabled = false
                btnStop.enabled = true
                btnDownload.enabled = false
                btnGraphs.enabled = true
                break
            case "stopped":
                btnConnect.enabled = true
                btnStart.enabled = true
                btnStop.enabled = false
                btnDownload.enabled = true
                btnGraphs.enabled = true
                break
        }
    }

    function stopAll() {
        recTimerRunning = false
        recordingSecs = 0
        fileListLoading = false
        downloadQueue = []
        downloadQueueActive = false
    }

    function parseMetadata(rawJson) {
        try {
            var obj = JSON.parse(rawJson)
            metaFile = obj.file || obj.msg || ""
            metaSpan = obj.span_us ? formatSpan(Number(obj.span_us)) : ""
            metaRows = obj.rows !== undefined ? obj.rows : ""
            metaDrops = obj.drops !== undefined ? obj.drops : ""
            metaBlockDrops = obj.block_drops !== undefined ? obj.block_drops : ""
            metaStalled = obj.stalled_ms !== undefined ? obj.stalled_ms + " ms" : ""
            metadataPanel.visible = true
        } catch(e) {
            metaFile = rawJson
            metadataPanel.visible = false
        }
    }

    function formatSpan(us) {
        if (us < 1000) return us + " us"
        if (us < 1000000) return (us / 1000).toFixed(1) + " ms"
        return (us / 1000000).toFixed(2) + " s"
    }

    function addDownloadedFile(name, csvData) {
        for (var i = 0; i < downloadedFilesModel.count; ++i) {
            if (downloadedFilesModel.get(i).fileName === name) {
                downloadedFilesModel.set(i, {fileName: name, csvData: csvData})
                return
            }
        }
        downloadedFilesModel.append({fileName: name, csvData: csvData})
        updateGraphFilesModel()
        btnGraphs.enabled = true
        logAppend("Added '" + name + "' to local files. Ready for graphing.", "info")
    }

    Timer {
        id: recTimer
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            if (recTimerRunning)
                recordingSecs++
        }
    }

    Timer {
        id: autoStopTimer
        interval: 1000
        repeat: true
        onTriggered: {
            if (startRemainingSecs > 0) {
                startRemainingSecs--
                if (startRemainingSecs <= 0) {
                    autoStopTimer.stop()
                    startRemainingSecs = 0
                }
            }
        }
    }

    property int startRemainingSecs: 0

    property int downloadTotal: 0
    property int downloadIndex: 0
    property int downloadQueueIndex: 0
    property string downloadDir: ""

    Dialog {
        id: folderDialog
        title: "Select Download Directory"
        modal: true
        x: (parent.width - width) / 2
        y: (parent.height - height) / 3
        width: 520
        height: 460
        background: Rectangle { color: Theme.surface; radius: 8; border.color: Theme.border; border.width: 1 }

        header: Label {
            text: folderDialog.title
            color: Theme.textPrimary; font.pixelSize: Theme.fontTitle; font.bold: true; padding: 16
        }

        property url currentFolder: (downloadDir ? "file://" + downloadDir : "file://" + mqtt.getDownloadDir()) + "/"
        property string selectedPath: ""

        onOpened: {
            if (!downloadDir)
                currentFolder = "file://" + mqtt.getDownloadDir() + "/"
            console.log("FolderDialog opened, folder:", currentFolder)
        }

        FolderListModel {
            id: folderListModel
            folder: folderDialog.currentFolder
            showFiles: false
            sortCaseSensitive: false
            nameFilters: ["*"]
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                TextField {
                    id: pathEdit
                    Layout.fillWidth: true
                    Layout.preferredHeight: 28
                    text: folderDialog.currentFolder.toString().replace("file://", "")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSmall
                    selectByMouse: true
                    leftPadding: 6
                    verticalAlignment: Text.AlignVCenter
                    placeholderText: "/path/to/folder"
                    placeholderTextColor: Theme.textSecondary
                    background: Rectangle { color: Theme.background; radius: 4; border.color: Theme.border; border.width: 1 }
                    onAccepted: {
                        var p = text.trim()
                        if (p === "") return
                        var u = p
                        if (!u.startsWith("file://")) u = "file://" + u
                        if (!u.endsWith("/")) u += "/"
                        folderDialog.currentFolder = u
                    }
                }

                Button {
                    text: "Up"
                    implicitWidth: 36; implicitHeight: 28
                    enabled: folderDialog.currentFolder.toString() !== "file:///"
                    onClicked: {
                        var url = folderDialog.currentFolder.toString()
                        if (url.endsWith("/")) url = url.slice(0, -1)
                        var idx = url.lastIndexOf("/")
                        folderDialog.currentFolder = url.slice(0, idx + 1)
                    }
                    contentItem: Text { text: "\u2191"; color: Theme.textPrimary; font.bold: true; font.pixelSize: Theme.fontBody; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.hovered ? Theme.accent : Theme.surfaceAlt; radius: 4; border.color: Theme.border; border.width: 1 }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: Theme.background
                radius: 6
                border.color: Theme.border
                clip: true

                ListView {
                    id: folderListView
                    anchors.fill: parent
                    anchors.margins: 4
                    model: folderListModel
                    spacing: 2
                    currentIndex: -1

                    delegate: Rectangle {
                        width: parent ? parent.width : 0
                        height: 32
                        color: ListView.isCurrentItem ? "#301f6feb" : mouseArea.containsMouse ? "#151f6feb" : "transparent"
                        radius: 4

                        property string filePath: {
                            var url = folderDialog.currentFolder.toString()
                            if (!url.endsWith("/")) url += "/"
                            return url + model.fileName
                        }

                        MouseArea {
                            id: mouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                folderListView.currentIndex = index
                                if (model.fileIsDir) {
                                    folderDialog.currentFolder = filePath + "/"
                                }
                            }
                            onDoubleClicked: {
                                if (model.fileIsDir) {
                                    folderDialog.currentFolder = filePath + "/"
                                }
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8

                            Text {
                                text: model.fileIsDir ? "\u25B6" : "\u25CB"
                                color: Theme.textSecondary; font.pixelSize: Theme.fontSmall
                            }

                            Text {
                                text: model.fileName
                                color: Theme.textPrimary; font.pixelSize: Theme.fontSmall
                                Layout.fillWidth: true; elide: Text.ElideRight
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: "(empty folder)"
                        color: Theme.textSecondary; font.pixelSize: Theme.fontBody
                        visible: folderListModel.count === 0
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Button {
                    text: "Select This Folder"
                    Layout.fillWidth: true
                    onClicked: {
                        folderDialog.selectedPath = folderDialog.currentFolder.toString().replace("file://", "")
                        folderDialog.accept()
                    }
                    contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: Theme.fontBody }
                    background: Rectangle { color: parent.down ? Theme.accent : parent.hovered ? Theme.success : Theme.success; radius: 6 }
                    implicitHeight: 34
                }

                Button {
                    text: "Cancel"
                    Layout.fillWidth: true
                    onClicked: folderDialog.reject()
                    contentItem: Text { text: parent.text; color: Theme.textPrimary; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: Theme.fontBody }
                    background: Rectangle { color: parent.hovered ? Theme.accent : Theme.surfaceAlt; radius: 6; border.color: Theme.border; border.width: 1 }
                    implicitHeight: 34
                }
            }
        }

        onAccepted: {
            console.log("FolderDialog accepted, path:", selectedPath)
            downloadDir = selectedPath
            downloadDirInput.text = downloadDir
            updateGraphFilesModel()
        }
        onRejected: console.log("FolderDialog rejected")
    }

    /* 0-100, drives both progress bars by binding. */
    property int uploadPct: 0
    property int downloadPct: 0

    property bool showGraph: false

    property int graphFileIndex: -1
    property int graphStartRow: 0
    property int graphEndRow: 0
    property var csvData: []
    property var csvHeader: []
    property var csvColumns: []
    property var traceColors: ["#888888","#ff0000","#0066ff","#ffd500","#00cc00","#ff00ff","#00cccc","#ff8c00","#9900ff","#ff3399","#00b8a8","#b3ff00","#e6e6e6"]
    property var checkedColumns: []
    property int graphMaxPoints: 2000
    property int maxPlotRows: 4000
    property int csvTotalRows: 0
    property int csvStep: 1

    function friendlyColumnName(name) {
        var map = {
            "current_0": "Current_0",
            "current_1": "Current_1",
            "current_2": "Current_2",
            "current_3": "Speed_volt_cmd",
            "current_4": "Volt_0",
            "current_5": "Volt_1",
            "current_6": "Volt_2",
            "current_7": "DC_bus_volt"
        }
        return map[name] !== undefined ? map[name] : name
    }

    function initColumnStates() {
        var n = csvColumns.length
        if (n === 0) { checkedColumns = []; return }
        var prev = checkedColumns
        var arr = []
        for (var i = 0; i < n; ++i)
            arr.push(i >= prev.length ? (i === 1 ? true : false) : prev[i])
        checkedColumns = arr
    }

    function parseDownloadedCSV(raw) {
        /*
         * The order of operations here is the whole cost.
         *
         * It used to trim() every line and only then decide, from the
         * decimation step, whether to keep it -- so on a file of 200k rows
         * displayed as 2k, it allocated 200k trimmed strings to throw away 198k
         * of them. trim() on the whole file was a second full copy on top. The
         * work now happens only for rows that survive: the skip test is first,
         * and split() runs about `maxPlotRows` times instead of once per line.
         *
         * Emptiness is tested without allocating. Lines are never
         * whitespace-only in practice -- the recorder writes them -- but a file
         * saved with CRLF leaves a stray '\r', so that one case is handled
         * explicitly rather than by trimming everything defensively.
         */
        if (!raw || raw.length === 0) { csvData = []; csvTotalRows = 0; csvStep = 1; return }

        var lines = raw.split('\n')
        if (lines.length < 2) { csvData = []; csvTotalRows = 0; csvStep = 1; return }

        function isBlank(s) {
            return s.length === 0 || (s.length === 1 && s.charCodeAt(0) === 13)
        }

        var headerCols = lines[0].replace(/\r$/, "").split(',')
        csvHeader = headerCols.slice()
        var friendly = []
        for (var k = 0; k < headerCols.length; ++k)
            friendly.push(friendlyColumnName(headerCols[k]))
        csvColumns = friendly
        initColumnStates()
        var nCols = csvColumns.length

        /* One pass to count, so the step is right before anything is kept.
           Counting is a length check per line -- no allocation. */
        var total = 0
        var i
        for (i = 1; i < lines.length; i++)
            if (!isBlank(lines[i])) total++

        var step = Math.max(1, Math.floor(total / maxPlotRows))

        var rows = []
        var kept = 0
        var seen = 0
        for (i = 1; i < lines.length; i++) {
            var line = lines[i]
            if (isBlank(line)) continue
            /* Decide BEFORE paying for trim/split. */
            if (seen++ % step !== 0) continue
            if (line.charCodeAt(line.length - 1) === 13)
                line = line.substring(0, line.length - 1)
            var cols = line.split(',')
            if (cols.length >= nCols) { rows.push(cols); kept++ }
        }

        csvTotalRows = total
        csvStep = step
        csvData = rows
    }

    function loadGraphData(idx) {
        if (idx < 0 || idx >= downloadedFilesModel.count) return
        graphFileIndex = idx
        var data = downloadedFilesModel.get(idx).csvData
        parseDownloadedCSV(data)
        graphStartRow = 0
        graphEndRow = csvTotalRows
        graphStartField.text = "0"
        graphEndField.text = csvTotalRows > 0 ? (csvTotalRows - 1).toString() : "0"
        chartCanvas.requestPaint()
    }

    function setQueueStatus(idx, status) {
        if (idx >= 0 && idx < downloadQueue.length)
            downloadQueue[idx].status = status
        var dq = downloadQueue.slice()
        downloadQueue = []
        downloadQueue = dq
    }

    Item {
        anchors.fill: parent

        RowLayout {
            id: mainView
            anchors.fill: parent
            anchors.margins: 16
            visible: !showGraph
            spacing: 12

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true

                    Text {
                    text: "Motor Data Recorder"
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontDisplay
                    font.bold: true
                }

                Text {
                    id: recTimerText
                    color: recTimerRunning ? Theme.success : Theme.textDisabled
                    font.pixelSize: Theme.fontDisplay
                    font.bold: true
                    font.family: Theme.monoFamily
                    text: {
                        if (recordingSecs <= 0) return "00:00"
                        var m = Math.floor(recordingSecs / 60)
                        var s = recordingSecs % 60
                        return ("0" + m).slice(-2) + ":" + ("0" + s).slice(-2)
                    }
                    leftPadding: 16
                }

                Text {
                    text: startRemainingSecs > 0 ? "auto-stop: " + startRemainingSecs + "s" : ""
                    color: Theme.warning
                    font.pixelSize: Theme.fontBody
                    leftPadding: 4
                }

                Item { Layout.fillWidth: true }

                Rectangle {
                    color: indicator.connected ? "#183fb950" : "#18f85149"
                    radius: 6
                    border.color: indicator.connected ? Theme.success : Theme.danger
                    border.width: 1
                    implicitHeight: 30
                    Layout.preferredWidth: connectedBadgeRow.implicitWidth + 16

                    RowLayout {
                        id: connectedBadgeRow
                        anchors.centerIn: parent
                        spacing: 6

                        Rectangle {
                            id: indicator
                            width: 8; height: 8; radius: 4
                            property bool connected: false
                            color: connected ? Theme.success : Theme.danger
                        }
                        Text {
                            text: indicator.connected ? "Connected" : "Disconnected"
                            color: indicator.connected ? Theme.success : Theme.danger
                            font.pixelSize: Theme.fontSmall
                            font.bold: true
                        }
                    }
                }

                /* Light is the default; this is the way back to dark for anyone
                   who was used to it. */
                ToolButton {
                    text: Theme.dark ? "☀" : "☾"
                    font.pixelSize: Theme.fontTitle
                    implicitWidth: 44
                    implicitHeight: 44
                    onClicked: Theme.dark = !Theme.dark
                    ToolTip.visible: hovered
                    ToolTip.text: Theme.dark ? "Switch to light theme"
                                             : "Switch to dark theme"
                }
            }

            Rectangle {
                id: metadataPanel
                Layout.fillWidth: true
                visible: false
                Layout.preferredHeight: 48
                color: Theme.surface
                radius: 8
                border.color: Theme.border

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 2

                    GridLayout {
                        columns: 12
                        rowSpacing: 0
                        columnSpacing: 8

                        Text { text: "File:"; color: Theme.textSecondary; font.pixelSize: Theme.fontSmall }
                        Text { text: metaFile; color: Theme.textPrimary; font.pixelSize: Theme.fontSmall; Layout.fillWidth: true; elide: Text.ElideMiddle; Layout.maximumWidth: 200 }
                        Text { text: "Duration:"; color: Theme.textSecondary; font.pixelSize: Theme.fontSmall }
                        Text { text: metaSpan; color: Theme.textPrimary; font.pixelSize: Theme.fontSmall }
                        Text { text: "Rows:"; color: Theme.textSecondary; font.pixelSize: Theme.fontSmall }
                        Text { text: metaRows; color: Theme.textPrimary; font.pixelSize: Theme.fontSmall }
                        Text { text: "Drops:"; color: Theme.textSecondary; font.pixelSize: Theme.fontSmall }
                        Text { text: metaDrops; color: Theme.textPrimary; font.pixelSize: Theme.fontSmall }
                        Text { text: "Block:"; color: Theme.textSecondary; font.pixelSize: Theme.fontSmall }
                        Text { text: metaBlockDrops; color: Theme.textPrimary; font.pixelSize: Theme.fontSmall }
                        Text { text: "Stalled:"; color: Theme.textSecondary; font.pixelSize: Theme.fontSmall }
                        Text { text: metaStalled; color: Theme.textPrimary; font.pixelSize: Theme.fontSmall }
                    }
                }
            }

            GridLayout {
                columns: 5
                columnSpacing: 8
                rowSpacing: 0
                Layout.fillWidth: true
                Layout.topMargin: 4

                FilledButton {
                    id: btnConnect
                    variant: "filled"
                    accent: mqtt.connected ? Theme.danger : Theme.success
                    text: "Connect"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48
                    onClicked: {
                        if (mqtt.connected)
                            mqtt.disconnectFromBroker()
                        else
                            mqtt.connectToBroker()
                    }
                }

                FilledButton {
                    id: btnStart
                    variant: "filled"
                    accent: Theme.accent
                    text: "Start"
                    enabled: false
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48
                    onClicked: startDialog.open()
            }

            FilledButton {
                id: btnStop
                    variant: "tonal"
                    accent: Theme.danger
                text: "Stop"
                enabled: false
                Layout.fillWidth: true
                Layout.preferredHeight: 48
                onClicked: {
                    mqtt.publishCommand("stop")
                    recTimerRunning = false
                    recordingSecs = 0
                    startRemainingSecs = 0
                    autoStopTimer.stop()
                    enableButtons("stopped")
                    logAppend("Sent STOP command.", "info")
                }
            }

            FilledButton {
                id: btnDownload
                    variant: "outlined"
                    accent: Theme.accent
                text: "Files"
                enabled: false
                Layout.fillWidth: true
                Layout.preferredHeight: 48
                onClicked: downloadDialog.open()
            }

            FilledButton {
                id: btnGraphs
                    variant: "outlined"
                    accent: Theme.accent
                text: "Graphs"
                enabled: false
                Layout.fillWidth: true
                Layout.preferredHeight: 48
                onClicked: {
                    updateGraphFilesModel()
                    showGraph = true
                    if (graphFileCombo.currentIndex < 0 && graphFilesModel.count > 0) {
                        graphFileCombo.currentIndex = 0
                    } else {
                        loadSelectedFile(graphFileCombo.currentIndex)
                    }
                }
            }
        }

        /*
         * Live telemetry.
         *
         * dataModel was being filled on every incoming row -- onDataReceived
         * splits the 13 CSV fields and writes them in -- and then displayed
         * nowhere at all: nothing in the file bound to it. So the recorder
         * streamed motor data to the GUI continuously and the GUI dropped it on
         * the floor, which is also what left the middle of the window as one
         * large empty rectangle.
         *
         * The field order is the one mqtt_client.c publishes:
         *   ts, current[0..7], vib_x, vib_y, vib_z, rpm
         */
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 190
            color: Theme.surface
            radius: Theme.radius
            border.color: Theme.border
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.spacing
                spacing: Theme.spacingTight

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "Live telemetry"
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontTitle
                        font.weight: Font.DemiBold
                    }
                    Item { Layout.fillWidth: true }
                    StatusPill {
                        text: recTimerRunning ? "streaming" : "idle"
                        tone: recTimerRunning ? "recording" : "neutral"
                        pulse: recTimerRunning
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 7
                    rowSpacing: Theme.spacingTight
                    columnSpacing: Theme.spacing

                    Repeater {
                        model: dataModel
                        delegate: ColumnLayout {
                            spacing: 2
                            Layout.fillWidth: true
                            Text {
                                text: window.channelLabels[index] !== undefined
                                      ? window.channelLabels[index] : ("ch" + index)
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontTiny
                                font.weight: Font.DemiBold
                            }
                            Text {
                                text: model.value
                                color: model.value === "---" ? Theme.textDisabled
                                                             : Theme.textPrimary
                                font.family: Theme.monoFamily
                                font.pixelSize: Theme.fontBody
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: Theme.surface
            radius: 8
            border.color: Theme.border
            clip: true

            ListView {
                id: logArea
                anchors.fill: parent
                anchors.margins: 8
                model: logModel
                spacing: 2
                /* Newest first, filling from the top.
                   It was BottomToTop while logAppend inserts at index 0, which
                   put the newest line at the BOTTOM and left the panel as a
                   tall empty rectangle with a few lines stuck along its lower
                   edge -- the emptiest part of the window sat where the eye
                   goes first. Same ordering, drawn the way it reads. */
                boundsBehavior: Flickable.StopAtBounds
                clip: true

                ScrollBar.vertical: ScrollBar {
                    width: 8
                    policy: ScrollBar.AsNeeded
                    background: Rectangle { color: "transparent" }
                    contentItem: Rectangle {
                        radius: 4
                        color: Theme.textDisabled
                    }
                }

                delegate: Text {
                    text: model.text
                    color: window.logColorFor(model.logType)
                    /* "Consolas" is a Windows font; on Linux this silently fell
                       back to whatever the default sans was, so the log was not
                       monospaced and columns did not line up. Theme.monoFamily
                       names a font that ships with the platform. */
                    font.family: Theme.monoFamily
                    font.pixelSize: Theme.fontSmall
                    wrapMode: Text.Wrap
                }
            }
        }

        Rectangle {
            id: progressPanel
            Layout.fillWidth: true
            /*
             * Sized from its contents, not a magic number.
             *
             * This was a fixed 54px with clip:true, while the column inside
             * needs about 76 -- two 8px bars with 12px labels, a title row, the
             * spacings and 8px margins. So the download bar and its label were
             * simply cut off by the bottom edge, which is what "the download
             * bars do not look right" was.
             */
            Layout.preferredHeight: progressCol.implicitHeight + 20
            visible: downloadQueueActive && downloadQueue.length > 0
            color: Theme.surface
            radius: 8
            border.color: Theme.border
            clip: true

            ColumnLayout {
                id: progressCol
                anchors.fill: parent
                anchors.margins: 8
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Text {
                        id: progressFileLabel
                        text: {
                            if (downloadQueueIndex < downloadQueue.length)
                                return downloadQueue[downloadQueueIndex].file
                            return ""
                        }
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSmall
                        font.bold: true
                        elide: Text.ElideMiddle
                        Layout.fillWidth: true
                    }

                    Text {
                        text: {
                            var done = 0
                            for (var i = 0; i < downloadQueue.length; ++i)
                                if (downloadQueue[i].status === "done") done++
                            return done + "/" + downloadQueue.length + " complete"
                        }
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSmall
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 8
                        radius: 4
                        color: Theme.background
                        clip: true

                        /* Bound to a percentage rather than assigned a pixel
                           width by the signal handlers. The old form read the
                           parent's width at the moment the message arrived, so
                           the bar kept a stale pixel length across a window
                           resize and no longer matched its own track. */
                        Rectangle {
                            id: uploadBar
                            height: parent.height
                            width: parent.width * (window.uploadPct / 100)
                            color: Theme.accentHover
                            radius: 4
                            Behavior on width { NumberAnimation { duration: 150 } }
                        }
                    }

                    Text {
                        id: uploadLabel
                        text: "Upload 0%"
                        color: Theme.accentHover
                        font.pixelSize: Theme.fontTiny
                        font.bold: true
                        Layout.preferredWidth: 80
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 8
                        radius: 4
                        color: Theme.background
                        clip: true

                        Rectangle {
                            id: downloadBar
                            height: parent.height
                            width: parent.width * (window.downloadPct / 100)
                            color: Theme.success
                            radius: 4
                            Behavior on width { NumberAnimation { duration: 150 } }
                        }
                    }

                    Text {
                        id: downloadLabel
                        text: "Download 0%"
                        color: Theme.success
                        font.pixelSize: Theme.fontTiny
                        font.bold: true
                        Layout.preferredWidth: 80
                    }
                }
            }
        }

        /*
         * The footer.
         *
         * Everything here was sized in absolute pixels for the old 9-11px type
         * -- a 20px-tall directory box and a 50x20 "Browse" button. Against the
         * larger scale the text no longer fits its container, so the bottom
         * strip came out clipped and crooked. Heights follow the font now, and
         * the button is allowed to size to its own label.
         */
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Theme.spacingTight
            spacing: Theme.spacingTight

            Text {
                id: statusText
                text: "Ready"
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSmall
                elide: Text.ElideRight
                Layout.fillWidth: true
            }

            Text {
                text: "Save to:"
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSmall
            }

            Rectangle {
                Layout.preferredWidth: 280
                Layout.preferredHeight: 36
                color: Theme.surface
                radius: Theme.radiusSmall
                border.color: Theme.border
                border.width: 1
                clip: true

                TextInput {
                    id: downloadDirInput
                    text: downloadDir
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSmall
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacingTight
                    anchors.rightMargin: Theme.spacingTight
                    anchors.verticalCenter: parent.verticalCenter
                    onEditingFinished: { downloadDir = text; updateGraphFilesModel() }
                    selectByMouse: true
                }
            }

            FilledButton {
                text: "Browse"
                implicitHeight: 36
                fill: Theme.surfaceAlt
                fillHover: Theme.accentSoft
                textColor: Theme.textPrimary
                onClicked: folderDialog.open()
            }
        }
    }

        } // close mainView RowLayout
    } // close main wrapper Item

    // Graph scene
    Item {
        id: graphView
        visible: showGraph
        anchors.fill: parent
        anchors.margins: 16
        z: 1

        onVisibleChanged: {
            if (visible)
                chartCanvas.requestPaint()
        }

        RowLayout {
            anchors.fill: parent
            spacing: 8

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Button {
                        text: "\u2190 Back"
                        implicitWidth: 70
                        onClicked: showGraph = false
                        contentItem: Text { text: parent.text; color: Theme.textPrimary; font.bold: true; font.pixelSize: Theme.fontSmall; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.hovered ? Theme.accent : Theme.surfaceAlt; radius: 4; border.color: Theme.border; border.width: 1 }
                        implicitHeight: 28
                    }

                    Text { text: "File:"; color: Theme.textSecondary; font.pixelSize: Theme.fontSmall }

                    ComboBox {
                        id: graphFileCombo
                        Layout.fillWidth: true
                        model: graphFilesModel
                        textRole: "displayName"
                        onCurrentIndexChanged: {
                            if (currentIndex >= 0)
                                loadSelectedFile(currentIndex)
                        }
                        background: Rectangle { color: Theme.surface; radius: 4; border.color: Theme.border; border.width: 1 }
                        contentItem: Text { text: graphFileCombo.currentText; color: Theme.textPrimary; x: 8; font.pixelSize: Theme.fontSmall }
                        indicator: Text { text: "\u25bc"; color: Theme.textSecondary; anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter }
                    }

                    Text { text: "From:"; color: Theme.textSecondary; font.pixelSize: Theme.fontSmall }
                    TextField {
                        id: graphStartField
                        implicitWidth: 70
                        color: Theme.textPrimary
                        background: Rectangle { color: Theme.surface; radius: 4; border.color: Theme.border; border.width: 1 }
                        leftPadding: 6; font.pixelSize: Theme.fontSmall
                        validator: IntValidator { bottom: 0 }
                    }

                    Text { text: "To:"; color: Theme.textSecondary; font.pixelSize: Theme.fontSmall }
                    TextField {
                        id: graphEndField
                        implicitWidth: 70
                        color: Theme.textPrimary
                        background: Rectangle { color: Theme.surface; radius: 4; border.color: Theme.border; border.width: 1 }
                        leftPadding: 6; font.pixelSize: Theme.fontSmall
                        validator: IntValidator { bottom: 0 }
                    }

                    Button {
                        text: "Update"
                        implicitWidth: 70
                        onClicked: {
                            var s = parseInt(graphStartField.text)
                            var e = parseInt(graphEndField.text)
                            if (!isNaN(s) && s >= 0) graphStartRow = s
                            if (!isNaN(e) && e > s && e < csvTotalRows) graphEndRow = e
                            else graphEndRow = csvTotalRows
                            chartCanvas.requestPaint()
                        }
                        contentItem: Text { text: parent.text; color: Theme.textPrimary; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: Theme.fontSmall }
                        background: Rectangle { color: parent.hovered ? Theme.accent : Theme.surfaceAlt; radius: 4; border.color: Theme.border; border.width: 1 }
                        implicitHeight: 28
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: Theme.surface
                    radius: 6
                    border.color: Theme.border
                    border.width: 1
                    clip: true

                    Canvas {
                        id: chartCanvas
                        anchors.fill: parent
                        property real zoomMin: 0
                        property real zoomMax: csvTotalRows > 0 ? csvTotalRows : 1

                        /* Y window. NaN on either side means autoscale. */
                        property real yLo: NaN
                        property real yHi: NaN

                        /* Plot geometry, written by onPaint so the mouse
                           handlers can map a pixel back to (row, value). They
                           cannot recompute it: the margins and the autoscaled
                           Y range are only known inside the paint. */
                        property real plotL: 60
                        property real plotT: 10
                        property real plotW: 1
                        property real plotH: 1
                        property real viewX0: 0
                        property real viewSpan: 1
                        property real viewYLo: 0
                        property real viewYHi: 1

                        function pxToRow(px) {
                            return viewX0 + viewSpan * ((px - plotL) / Math.max(1, plotW))
                        }
                        function pxToVal(py) {
                            return viewYLo + (viewYHi - viewYLo)
                                   * (1 - (py - plotT) / Math.max(1, plotH))
                        }
                        function resetZoom() {
                            yLo = NaN; yHi = NaN
                            graphStartRow = 0
                            graphEndRow = csvTotalRows
                            graphStartField.text = "0"
                            graphEndField.text = csvTotalRows > 0 ? (csvTotalRows - 1).toString() : "0"
                            requestPaint()
                        }
                        /* Clamp an X window to the data and keep it usable --
                           without a floor, one more wheel notch at full zoom
                           collapses the span to zero and nothing draws. */
                        function setXWindow(a, b) {
                            var lo = Math.max(0, Math.round(Math.min(a, b)))
                            var hi = Math.min(csvTotalRows, Math.round(Math.max(a, b)))
                            if (hi - lo < 2) {
                                var mid = (lo + hi) / 2
                                lo = Math.max(0, Math.round(mid - 1))
                                hi = Math.min(csvTotalRows, lo + 2)
                            }
                            graphStartRow = lo
                            graphEndRow = hi
                            graphStartField.text = lo.toString()
                            graphEndField.text = (hi - 1).toString()
                            requestPaint()
                        }

                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            var data = csvData
                            if (data.length < 2) {
                                ctx.fillStyle = Theme.textSecondary; ctx.font = "14px monospace"
                                ctx.fillText("No data to display", width/2 - 70, height/2)
                                return
                            }

                            var startRow = graphStartRow
                            var endRow = graphEndRow
                            if (endRow <= startRow) { endRow = csvTotalRows > 0 ? csvTotalRows : data.length; startRow = 0 }
                            var visibleRange = endRow - startRow
                            if (visibleRange < 1) visibleRange = 1

                            var mL = 60
                            var mR = 10
                            var mT = 10
                            var mB = 40
                            var pW = Math.max(0, width - mL - mR)
                            var pH = Math.max(0, height - mT - mB)

                            var checked = checkedColumns
                            var maxPts = Math.max(200, Math.min(graphMaxPoints, Math.floor(width)))
                            var sIdx = Math.floor(startRow / csvStep)
                            var eIdx = Math.min(data.length, Math.ceil(endRow / csvStep))
                            if (sIdx < 0) sIdx = 0
                            if (eIdx > data.length) eIdx = data.length
                            if (sIdx >= eIdx) sIdx = Math.max(0, eIdx - 1)
                            var nSamples = eIdx - sIdx
                            var plotStep = Math.max(1, Math.ceil(nSamples / maxPts))
                            var nCols = csvColumns.length > 0 ? csvColumns.length : Math.min(13, data[0].length)

                            var yMin = Infinity, yMax = -Infinity
                            for (var si = sIdx; si < eIdx; si += plotStep) {
                                for (var cj = 1; cj < Math.min(nCols, data[si].length); cj++) {
                                    if (checked[cj]) {
                                        var v = Number(data[si][cj])
                                        if (!isNaN(v)) { if (v < yMin) yMin = v; if (v > yMax) yMax = v }
                                    }
                                }
                            }
                            if (yMin === Infinity) { yMin = 0; yMax = 1000 }
                            var pad = (yMax - yMin) * 0.1 || 1; yMin -= pad; yMax += pad

                            /* A box zoom pins Y as well as X; without that,
                               drawing a rectangle round a feature would widen
                               back out to the autoscale the moment it repainted.
                               NaN means "autoscale", which is what Reset
                               restores. */
                            if (!isNaN(chartCanvas.yLo) && !isNaN(chartCanvas.yHi)
                                && chartCanvas.yHi > chartCanvas.yLo) {
                                yMin = chartCanvas.yLo
                                yMax = chartCanvas.yHi
                            }
                            /* Published so the mouse handlers can convert a
                               pixel back into a row and a value. */
                            chartCanvas.plotL = mL; chartCanvas.plotT = mT
                            chartCanvas.plotW = pW; chartCanvas.plotH = pH
                            chartCanvas.viewYLo = yMin; chartCanvas.viewYHi = yMax
                            chartCanvas.viewX0 = startRow; chartCanvas.viewSpan = visibleRange

                            ctx.strokeStyle = Theme.border; ctx.lineWidth = 0.5
                            var yTicks = Math.max(6, Math.min(10, Math.floor(pH / 18)))
                            var xTicks = Math.max(6, Math.min(10, Math.floor(pW / 55)))
                            function fmtTick(v) {
                                var a = Math.abs(v)
                                if (a >= 1000) return v.toFixed(0)
                                if (a >= 1) return v.toFixed(1)
                                return v.toFixed(2)
                            }
                            for (var gy = 0; gy <= yTicks; gy++) {
                                var yFrac = gy / yTicks
                                var yY = mT + pH * (1 - yFrac)
                                ctx.beginPath(); ctx.moveTo(mL, yY); ctx.lineTo(width - mR, yY); ctx.stroke()
                                ctx.fillStyle = Theme.textSecondary; ctx.font = "9px monospace"
                                var yLbl = fmtTick(yMin + (yMax - yMin) * yFrac)
                                ctx.fillText(yLbl, mL - 4 - ctx.measureText(yLbl).width, yY + 3)
                            }
                            for (var gx = 0; gx <= xTicks; gx++) {
                                var xFrac = gx / xTicks
                                var xX = mL + pW * xFrac
                                ctx.beginPath(); ctx.moveTo(xX, mT); ctx.lineTo(xX, mT + pH); ctx.stroke()
                                ctx.fillStyle = Theme.textSecondary; ctx.font = "9px monospace"
                                var xLbl = (startRow + visibleRange * xFrac).toFixed(0)
                                ctx.fillText(xLbl, xX - ctx.measureText(xLbl).width / 2, height - 5)
                            }
                            ctx.fillStyle = Theme.textSecondary; ctx.font = "9px monospace"
                            ctx.fillText("Row #", mL + pW / 2 - 15, height - 22)

                            for (var ci = 1; ci < Math.min(nCols, data[sIdx].length); ci++) {
                                if (!checked[ci]) continue
                                ctx.strokeStyle = traceColors[ci % traceColors.length]
                                ctx.lineWidth = 1.2
                                ctx.beginPath()
                                var started = false
                                for (var sj = sIdx; sj < eIdx; sj += plotStep) {
                                    var origRow = sj * csvStep
                                    var xPos = mL + pW * ((origRow - startRow) / visibleRange)
                                    var val = Number(data[sj][ci])
                                    if (isNaN(val)) continue
                                    var yPos = mT + pH * (1 - (val - yMin) / (yMax - yMin))
                                    if (!started) { ctx.moveTo(xPos, yPos); started = true }
                                    else ctx.lineTo(xPos, yPos)
                                }
                                ctx.stroke()
                            }
                        }
                    }

                    /*
                     * Zoom, the way MATLAB's figure window does it:
                     *   drag           -- rubber band, zoom to the box (X and Y)
                     *   wheel          -- zoom X about the cursor
                     *   shift + wheel  -- zoom Y about the cursor
                     *   right-drag     -- pan
                     *   double-click   -- back to full extent
                     *
                     * Kept as a sibling of the Canvas rather than a child, so
                     * it is not repainted with it.
                     */
                    Rectangle {
                        id: rubberBand
                        visible: false
                        color: "#301f6feb"
                        border.color: Theme.accent
                        border.width: 1
                        z: 5
                    }

                    MouseArea {
                        id: chartMouse
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        hoverEnabled: true
                        cursorShape: pressedButtons & Qt.RightButton
                                     ? Qt.ClosedHandCursor : Qt.CrossCursor

                        property real dragX0: 0
                        property real dragY0: 0
                        property bool banding: false
                        property bool panning: false
                        property real panRow0: 0
                        property real panStart0: 0
                        property real panEnd0: 0

                        onPressed: (mouse) => {
                            if (csvData.length < 2) return
                            dragX0 = mouse.x; dragY0 = mouse.y
                            if (mouse.button === Qt.RightButton) {
                                panning = true
                                panRow0 = chartCanvas.pxToRow(mouse.x)
                                panStart0 = graphStartRow
                                panEnd0 = graphEndRow
                            } else {
                                banding = true
                                rubberBand.x = mouse.x; rubberBand.y = mouse.y
                                rubberBand.width = 0; rubberBand.height = 0
                                rubberBand.visible = true
                            }
                        }

                        onPositionChanged: (mouse) => {
                            if (banding) {
                                rubberBand.x = Math.min(dragX0, mouse.x)
                                rubberBand.y = Math.min(dragY0, mouse.y)
                                rubberBand.width = Math.abs(mouse.x - dragX0)
                                rubberBand.height = Math.abs(mouse.y - dragY0)
                            } else if (panning) {
                                /* Drag the data with the cursor: hold the row
                                   that was grabbed under the pointer. */
                                var span = panEnd0 - panStart0
                                var dRows = -(mouse.x - dragX0) / Math.max(1, chartCanvas.plotW) * span
                                chartCanvas.setXWindow(panStart0 + dRows, panEnd0 + dRows)
                            }
                        }

                        onReleased: (mouse) => {
                            if (panning) { panning = false; return }
                            if (!banding) return
                            banding = false
                            rubberBand.visible = false

                            /* A click, not a drag: ignore rather than zooming
                               to a zero-width box and blanking the plot. */
                            if (rubberBand.width < 8 || rubberBand.height < 8) return

                            var r0 = chartCanvas.pxToRow(rubberBand.x)
                            var r1 = chartCanvas.pxToRow(rubberBand.x + rubberBand.width)
                            /* y is inverted: the top of the box is the HIGH value */
                            var vTop = chartCanvas.pxToVal(rubberBand.y)
                            var vBot = chartCanvas.pxToVal(rubberBand.y + rubberBand.height)
                            chartCanvas.yLo = Math.min(vTop, vBot)
                            chartCanvas.yHi = Math.max(vTop, vBot)
                            chartCanvas.setXWindow(r0, r1)
                        }

                        onDoubleClicked: chartCanvas.resetZoom()

                        onWheel: (wheel) => {
                            if (csvData.length < 2) return
                            var factor = wheel.angleDelta.y > 0 ? 0.8 : 1.25

                            if (wheel.modifiers & Qt.ShiftModifier) {
                                /* Y zoom about the cursor. Seed from the live
                                   autoscaled range when no manual range is set,
                                   so the first shift-wheel does not jump. */
                                var lo = isNaN(chartCanvas.yLo) ? chartCanvas.viewYLo : chartCanvas.yLo
                                var hi = isNaN(chartCanvas.yHi) ? chartCanvas.viewYHi : chartCanvas.yHi
                                var at = chartCanvas.pxToVal(wheel.y)
                                chartCanvas.yLo = at - (at - lo) * factor
                                chartCanvas.yHi = at + (hi - at) * factor
                                chartCanvas.requestPaint()
                            } else {
                                var atRow = chartCanvas.pxToRow(wheel.x)
                                var s = graphStartRow, e = graphEndRow
                                if (e <= s) { s = 0; e = csvTotalRows }
                                chartCanvas.setXWindow(atRow - (atRow - s) * factor,
                                                       atRow + (e - atRow) * factor)
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Item { Layout.fillWidth: true }

                    Button {
                        text: "Reset"
                        implicitWidth: 70; implicitHeight: 24
                        onClicked: {
                            graphStartRow = 0
                            graphEndRow = csvTotalRows
                            graphStartField.text = "0"
                            graphEndField.text = csvTotalRows > 0 ? (csvTotalRows - 1).toString() : "0"
                            chartCanvas.zoomMin = 0
                            chartCanvas.zoomMax = csvTotalRows > 0 ? csvTotalRows : 1
                            /* Also drop the Y window, or Reset would restore the
                               full row range while leaving the plot zoomed in
                               vertically -- half a reset reads as a bug. */
                            chartCanvas.yLo = NaN
                            chartCanvas.yHi = NaN
                            chartCanvas.requestPaint()
                        }
                        contentItem: Text { text: parent.text; color: Theme.textPrimary; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: Theme.fontSmall }
                        background: Rectangle { color: parent.hovered ? Theme.accent : Theme.surfaceAlt; radius: 4; border.color: Theme.border; border.width: 1 }
                    }
                }
            }

            Rectangle {
                Layout.preferredWidth: 170
                Layout.fillHeight: true
                color: Theme.surface
                radius: 6
                border.color: Theme.border
                visible: csvColumns.length > 0
                clip: true

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 4

                    Text { text: "Data Columns"; color: Theme.textPrimary; font.bold: true; font.pixelSize: Theme.fontSmall }

                    Rectangle { Layout.fillWidth: true; height: 1; color: Theme.border }

                    ListView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        model: csvColumns
                        spacing: 2
                        delegate: RowLayout {
                            width: parent ? parent.width : 0
                            spacing: 6
                            CheckBox {
                                id: cb
                                checked: index < 1 ? false : (index < checkedColumns.length && checkedColumns[index])
                                enabled: index >= 1
                                onCheckedChanged: {
                                    if (index >= 1 && index < checkedColumns.length) {
                                        checkedColumns[index] = checked
                                        chartCanvas.requestPaint()
                                    }
                                }
                                indicator: Rectangle {
                                    implicitWidth: 14; implicitHeight: 14
                                    x: cb.leftPadding; y: parent.height / 2 - 7
                                    radius: 3; color: "transparent"; border.color: Theme.accentHover; border.width: 1
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 10; height: 10; radius: 2
                                        color: cb.checked ? (traceColors[index % traceColors.length]) : "transparent"
                                    }
                                }
                            }
                            Rectangle {
                                width: 10; height: 10; radius: 2
                                color: index < 1 ? "transparent" : traceColors[index % traceColors.length]
                            }
                            Text {
                                text: index === 0 ? csvColumns[index] + " (x)" : csvColumns[index]
                                color: index === 0 ? Theme.textSecondary : Theme.textPrimary; font.pixelSize: Theme.fontSmall
                                Layout.fillWidth: true; elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }

    Dialog {
        id: startDialog
        title: "Start Recording"
        modal: true
        x: (parent.width - width) / 2
        y: (parent.height - height) / 3
        width: 380
        background: Rectangle { color: Theme.surface; radius: 8; border.color: Theme.border; border.width: 1 }

        header: Label {
            text: "Start Recording"
            color: Theme.textPrimary
            font.pixelSize: Theme.fontTitle
            font.bold: true
            padding: 16
        }

        /* Text for the dismissive action, filled for the confirming one --
           the Material pairing. The old Cancel went solid accent on hover,
           which made the two buttons compete for the same emphasis. */
        footer: DialogButtonBox {
            spacing: Theme.spacingTight
            padding: Theme.spacing
            background: Rectangle { color: "transparent" }
            FilledButton {
                text: "Cancel"
                variant: "text"
                onClicked: startDialog.close()
            }
            FilledButton {
                text: "Start recording"
                variant: "filled"
                onClicked: startDialog.accept()
            }
        }

        onAccepted: {
            var name = startNameField.text.trim()
            var dur = parseInt(startDurationField.text)
            if (isNaN(dur) || dur < 0) dur = 0

            mqtt.startRecording(name, dur)

            recTimerRunning = true
            recordingSecs = 0

            if (dur > 0) {
                startRemainingSecs = dur
                autoStopTimer.start()
            }

            statusText.text = "Starting recording..."
            btnStart.enabled = false
            btnStop.enabled = true
            btnConnect.enabled = false
            startNameField.text = ""
            startDurationField.text = "0"
        }

        ColumnLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 16
            spacing: 12

            /* The caption is the field's own floating label now. It used to be
               a separate Text above each field AS WELL AS a placeholderText,
               which the Material style also renders as a floating label -- so
               every field was captioned twice, and the floating copy rose onto
               the custom background's border and sat across it. */
            MaterialField {
                id: startNameField
                Layout.fillWidth: true
                label: "Recording name (optional)"
                hint: "e.g. motor_test_1"
                text: "motor_test_1"
            }

            MaterialField {
                id: startDurationField
                Layout.fillWidth: true
                label: "Duration (seconds)"
                hint: "0 = stop manually"
                text: "0"
                inputMethodHints: Qt.ImhDigitsOnly
                validator: IntValidator { bottom: 0; top: 86400 }
            }
        }
    }

    Dialog {
        id: downloadDialog
        title: "Recording Files"
        modal: true
        x: (parent.width - width) / 2
        y: (parent.height - height) / 3
        width: 520
        height: 460
        background: Rectangle { color: Theme.surface; radius: 8; border.color: Theme.border; border.width: 1 }

        header: Label {
            text: "Recording Files on Device"
            color: Theme.textPrimary
            font.pixelSize: Theme.fontTitle
            font.bold: true
            padding: 16
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    text: fileListLoading ? "Loading..." : fileListModel.count + " file(s) found"
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSmall
                }

                Item { Layout.fillWidth: true }

                FilledButton {
                    text: "Select All"
                    variant: "text"
                    implicitHeight: 36
                    onClicked: {
                        for (var i = 0; i < fileListModel.count; ++i)
                            fileListModel.set(i, {checked: true})
                    }
                }

                FilledButton {
                    text: "Clear"
                    variant: "text"
                    implicitHeight: 36
                    onClicked: {
                        for (var i = 0; i < fileListModel.count; ++i)
                            fileListModel.set(i, {checked: false})
                    }
                }

                FilledButton {
                    text: "Refresh"
                    variant: "text"
                    implicitHeight: 36
                    onClicked: {
                        fileListLoading = true
                        fileListModel.clear()
                        mqtt.requestFileList()
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: Theme.background
                radius: 6
                border.color: Theme.border
                clip: true

                ListView {
                    anchors.fill: parent
                    anchors.margins: 4
                    model: fileListModel
                    spacing: 2

                    delegate: Rectangle {
                        width: parent ? parent.width : 0
                        height: 36
                        color: checked ? "#201f6feb" : "transparent"
                        radius: 4

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8

                            /*
                             * A Material checkbox: an outlined box when off, a
                             * filled accent box with a white tick when on.
                             *
                             * It used to draw a smaller filled square inside
                             * the outline and no tick at all, so "checked"
                             * showed as a solid blue block -- which reads as a
                             * disabled or half-painted control rather than as a
                             * tick, and gave the two states nothing in common
                             * but colour.
                             */
                            CheckBox {
                                id: itemCheck
                                checked: model.checked
                                onCheckedChanged: fileListModel.set(index, {checked: checked})
                                indicator: Rectangle {
                                    implicitWidth: 20; implicitHeight: 20
                                    x: itemCheck.leftPadding
                                    y: itemCheck.height / 2 - height / 2
                                    radius: 4
                                    color: itemCheck.checked ? Theme.accent : "transparent"
                                    border.color: itemCheck.checked ? Theme.accent
                                                                    : Theme.textSecondary
                                    border.width: 2
                                    Behavior on color { ColorAnimation { duration: 100 } }

                                    Text {
                                        anchors.centerIn: parent
                                        text: "✓"
                                        color: "#ffffff"
                                        font.pixelSize: 14
                                        font.bold: true
                                        opacity: itemCheck.checked ? 1 : 0
                                        Behavior on opacity { NumberAnimation { duration: 100 } }
                                    }
                                }
                            }

                            Text {
                                text: model.fileName
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSmall
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                            }

                            Text {
                                text: model.sizeStr
                                color: Theme.textSecondary
                                font.pixelSize: Theme.fontSmall
                                Layout.preferredWidth: 80
                                horizontalAlignment: Text.AlignRight
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: fileListLoading ? "Requesting list..." : "Press Refresh to load files"
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontBody
                        visible: fileListModel.count === 0
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                FilledButton {
                    text: "Download Selected"
                    variant: "filled"
                    accent: Theme.accent
                    Layout.fillWidth: true
                    enabled: {
                        var c = 0
                        for (var i = 0; i < fileListModel.count; ++i)
                            if (fileListModel.get(i).checked) c++
                        return c > 0 && !fileListLoading
                    }
                    onClicked: {
                        var selected = []
                        for (var i = 0; i < fileListModel.count; ++i) {
                            if (fileListModel.get(i).checked)
                                selected.push(fileListModel.get(i).fileName)
                        }
                        downloadQueue = selected.map(function(f) { return {file: f, dir: downloadDir, status: "pending"} })
                        downloadQueueIndex = 0
                        downloadQueueActive = true
                        downloadDialog.close()
                        processDownloadQueue()
                    }
                                                            implicitHeight: 34
                }

                FilledButton {
                    text: "Delete Selected"
                    variant: "outlined"
                    accent: Theme.danger
                    Layout.fillWidth: true
                    enabled: {
                        var c = 0
                        for (var i = 0; i < fileListModel.count; ++i)
                            if (fileListModel.get(i).checked) c++
                        return c > 0 && !fileListLoading
                    }
                    onClicked: {
                        for (var i = 0; i < fileListModel.count; ++i) {
                            if (fileListModel.get(i).checked)
                                mqtt.deleteFile(fileListModel.get(i).fileName)
                        }
                        mqtt.requestFileList()
                        logAppend("Delete commands sent.", "info")
                    }
                                                            implicitHeight: 34
                }
            }
        }
    }

    /* Names for the 13 fields mqtt_client.c puts on the data topic, in its
       order: timestamp, eight current channels, three vibration axes, rpm.
       The model carried bare values with no labels, so even had it been shown,
       the numbers would have meant nothing. */
    readonly property var channelLabels: [
        "TIMESTAMP", "CURRENT 0", "CURRENT 1", "CURRENT 2", "CURRENT 3",
        "CURRENT 4", "CURRENT 5", "CURRENT 6", "CURRENT 7",
        "VIB X", "VIB Y", "VIB Z", "RPM"
    ]

    Component.onCompleted: {
        for (var i = 0; i < 13; ++i)
            dataModel.append({value: "---"})
        downloadDir = mqtt.getDownloadDir()
        downloadDirInput.text = downloadDir
        logAppend("GUI started. Connecting to broker...", "info")
        Qt.callLater(mqtt.connectToBroker)
    }
}
