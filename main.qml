import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Qt.labs.folderlistmodel
import MqttClient 1.0

ApplicationWindow {
    id: window
    visible: true
    width: 1100
    height: 800
    minimumWidth: 800
    minimumHeight: 600
    title: "Motor Data Recorder"
    color: "#0d1117"

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
            var pw = uploadBar.parent ? uploadBar.parent.width : 200
            uploadBar.width = pct / 100 * pw
            uploadLabel.text = "Upload " + pct + "%"
            logAppend("Upload to server: " + pct + "%", "info")
            statusText.text = "Upload: " + pct + "%"
        }
        onDownloadProgress: (pct) => {
            var pw = downloadBar.parent ? downloadBar.parent.width : 200
            downloadBar.width = pct / 100 * pw
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
            uploadBar.width = 0
            downloadBar.width = 0
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
            var pw = downloadBar.parent ? downloadBar.parent.width : 200
            downloadBar.width = pct / 100 * pw
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

    function logAppend(text, type) {
        var color = "#8888ff"
        if (type === "success") color = "#3fb950"
        else if (type === "error") color = "#f85149"
        else if (type === "warning") color = "#d29922"
        var ts = new Date().toLocaleTimeString("en_US", {hour12: false})
        logModel.insert(0, {text: "[" + ts + "] " + text, textColor: color})
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
        background: Rectangle { color: "#161b22"; radius: 8; border.color: "#30363d"; border.width: 1 }

        header: Label {
            text: folderDialog.title
            color: "#e6edf3"; font.pixelSize: 16; font.bold: true; padding: 16
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

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 28
                    color: "#0d1117"
                    radius: 4
                    border.color: "#30363d"
                    clip: true

                    Text {
                        anchors.left: parent.left; anchors.leftMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        text: folderDialog.currentFolder.toString().replace("file://", "")
                        color: "#e6edf3"; font.pixelSize: 11
                        elide: Text.ElideLeft
                        width: parent.width - 12
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
                    contentItem: Text { text: "\u2191"; color: "#e6edf3"; font.bold: true; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#0d1117"
                radius: 6
                border.color: "#30363d"
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
                        color: ListView.isCurrentItem ? "#1f6feb30" : mouseArea.containsMouse ? "#1f6feb15" : "transparent"
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
                                color: "#8b949e"; font.pixelSize: 12
                            }

                            Text {
                                text: model.fileName
                                color: "#e6edf3"; font.pixelSize: 12
                                Layout.fillWidth: true; elide: Text.ElideRight
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: "(empty folder)"
                        color: "#8b949e"; font.pixelSize: 13
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
                    contentItem: Text { text: parent.text; color: "#ffffff"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 13 }
                    background: Rectangle { color: parent.down ? "#1f6feb" : parent.hovered ? "#238636" : "#238636"; radius: 6 }
                    implicitHeight: 34
                }

                Button {
                    text: "Cancel"
                    Layout.fillWidth: true
                    onClicked: folderDialog.reject()
                    contentItem: Text { text: parent.text; color: "#e6edf3"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 13 }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 6; border.color: "#30363d"; border.width: 1 }
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
        var lines = raw.trim().split('\n')
        if (lines.length < 2) { csvData = []; csvTotalRows = 0; csvStep = 1; return }
        var headerCols = lines[0].split(',')
        csvHeader = headerCols.slice()
        var friendly = []
        for (var k = 0; k < headerCols.length; ++k)
            friendly.push(friendlyColumnName(headerCols[k]))
        csvColumns = friendly
        initColumnStates()
        var nCols = csvColumns.length
        var rows = []
        var dataCount = 0
        var step = Math.max(1, Math.floor((lines.length - 1) / maxPlotRows))
        for (var i = 1; i < lines.length; i++) {
            var line = lines[i].trim()
            if (line === "") continue
            dataCount++
            if ((dataCount - 1) % step !== 0) continue
            var cols = line.split(',')
            if (cols.length >= nCols) rows.push(cols)
        }
        csvTotalRows = dataCount
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
                    color: "#e6edf3"
                    font.pixelSize: 22
                    font.bold: true
                }

                Text {
                    id: recTimerText
                    color: recTimerRunning ? "#3fb950" : "#484f58"
                    font.pixelSize: 20
                    font.bold: true
                    font.family: "Consolas"
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
                    color: "#d29922"
                    font.pixelSize: 13
                    leftPadding: 4
                }

                Item { Layout.fillWidth: true }

                Rectangle {
                    color: indicator.connected ? "#3fb95018" : "#f8514918"
                    radius: 6
                    border.color: indicator.connected ? "#3fb950" : "#f85149"
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
                            color: connected ? "#3fb950" : "#f85149"
                        }
                        Text {
                            text: indicator.connected ? "Connected" : "Disconnected"
                            color: indicator.connected ? "#3fb950" : "#f85149"
                            font.pixelSize: 12
                            font.bold: true
                        }
                    }
                }
            }

            Rectangle {
                id: metadataPanel
                Layout.fillWidth: true
                visible: false
                Layout.preferredHeight: 48
                color: "#161b22"
                radius: 8
                border.color: "#30363d"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 2

                    GridLayout {
                        columns: 12
                        rowSpacing: 0
                        columnSpacing: 8

                        Text { text: "File:"; color: "#8b949e"; font.pixelSize: 11 }
                        Text { text: metaFile; color: "#e6edf3"; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideMiddle; Layout.maximumWidth: 200 }
                        Text { text: "Duration:"; color: "#8b949e"; font.pixelSize: 11 }
                        Text { text: metaSpan; color: "#e6edf3"; font.pixelSize: 11 }
                        Text { text: "Rows:"; color: "#8b949e"; font.pixelSize: 11 }
                        Text { text: metaRows; color: "#e6edf3"; font.pixelSize: 11 }
                        Text { text: "Drops:"; color: "#8b949e"; font.pixelSize: 11 }
                        Text { text: metaDrops; color: "#e6edf3"; font.pixelSize: 11 }
                        Text { text: "Block:"; color: "#8b949e"; font.pixelSize: 11 }
                        Text { text: metaBlockDrops; color: "#e6edf3"; font.pixelSize: 11 }
                        Text { text: "Stalled:"; color: "#8b949e"; font.pixelSize: 11 }
                        Text { text: metaStalled; color: "#e6edf3"; font.pixelSize: 11 }
                    }
                }
            }

            GridLayout {
                columns: 5
                columnSpacing: 8
                rowSpacing: 0
                Layout.fillWidth: true
                Layout.topMargin: 4

                Button {
                    id: btnConnect
                    text: "Connect"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48
                    onClicked: {
                        if (mqtt.connected)
                            mqtt.disconnectFromBroker()
                        else
                            mqtt.connectToBroker()
                    }
                    contentItem: Text {
                        text: btnConnect.text
                        color: btnConnect.enabled ? "#e6edf3" : "#484f58"
                        font.bold: true
                        font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        color: btnConnect.down ? "#1f6feb" : btnConnect.hovered ? "#238636" : btnConnect.enabled ? "#238636" : "#21262d"
                        radius: 8
                    }
                }

                Button {
                    id: btnStart
                    text: "Start"
                    enabled: false
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48
                    onClicked: startDialog.open()
                    contentItem: Text {
                        text: btnStart.text; color: btnStart.enabled ? "#e6edf3" : "#484f58"; font.bold: true; font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                    }
                    background: Rectangle {
                        color: btnStart.down ? "#1f6feb" : btnStart.hovered ? "#1f6feb" : btnStart.enabled ? "#21262d" : "#161b22"
                    radius: 8
                    border.color: btnStart.enabled ? "#58a6ff" : "transparent"
                    border.width: 1
                }
            }

            Button {
                id: btnStop
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
                contentItem: Text {
                    text: btnStop.text; color: btnStop.enabled ? "#e6edf3" : "#484f58"; font.bold: true; font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: btnStop.down ? "#da3633" : btnStop.hovered ? "#da3633" : btnStop.enabled ? "#21262d" : "#161b22"
                    radius: 8
                    border.color: btnStop.enabled ? "#f85149" : "transparent"
                    border.width: 1
                }
            }

            Button {
                id: btnDownload
                text: "Files"
                enabled: false
                Layout.fillWidth: true
                Layout.preferredHeight: 48
                onClicked: downloadDialog.open()
                contentItem: Text {
                    text: btnDownload.text; color: btnDownload.enabled ? "#e6edf3" : "#484f58"; font.bold: true; font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: btnDownload.down ? "#1f6feb" : btnDownload.hovered ? "#1f6feb" : btnDownload.enabled ? "#21262d" : "#161b22"
                    radius: 8
                    border.color: btnDownload.enabled ? "#58a6ff" : "transparent"
                    border.width: 1
                }
            }

            Button {
                id: btnGraphs
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
                contentItem: Text {
                    text: btnGraphs.text; color: btnGraphs.enabled ? "#e6edf3" : "#484f58"; font.bold: true; font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: btnGraphs.down ? "#1f6feb" : btnGraphs.hovered ? "#1f6feb" : btnGraphs.enabled ? "#21262d" : "#161b22"
                    radius: 8
                    border.color: btnGraphs.enabled ? "#58a6ff" : "transparent"
                    border.width: 1
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "#161b22"
            radius: 8
            border.color: "#30363d"
            clip: true

            ListView {
                id: logArea
                anchors.fill: parent
                anchors.margins: 8
                model: logModel
                spacing: 1
                verticalLayoutDirection: ListView.BottomToTop
                boundsBehavior: Flickable.StopAtBounds
                clip: true

                ScrollBar.vertical: ScrollBar {
                    width: 8
                    policy: ScrollBar.AsNeeded
                    background: Rectangle { color: "transparent" }
                    contentItem: Rectangle {
                        radius: 4
                        color: "#484f58"
                    }
                }

                delegate: Text {
                    text: model.text
                    color: model.textColor
                    font.family: "Consolas"
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }
            }
        }

        Rectangle {
            id: progressPanel
            Layout.fillWidth: true
            Layout.preferredHeight: 54
            visible: downloadQueueActive && downloadQueue.length > 0
            color: "#161b22"
            radius: 8
            border.color: "#30363d"
            clip: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 4

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
                        color: "#e6edf3"
                        font.pixelSize: 11
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
                        color: "#8b949e"
                        font.pixelSize: 11
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 8
                        radius: 4
                        color: "#0d1117"
                        clip: true

                        Rectangle {
                            id: uploadBar
                            height: parent.height
                            width: 0
                            color: "#58a6ff"
                            radius: 4
                        }
                    }

                    Text {
                        id: uploadLabel
                        text: "Upload 0%"
                        color: "#58a6ff"
                        font.pixelSize: 10
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
                        color: "#0d1117"
                        clip: true

                        Rectangle {
                            id: downloadBar
                            height: parent.height
                            width: 0
                            color: "#3fb950"
                            radius: 4
                        }
                    }

                    Text {
                        id: downloadLabel
                        text: "Download 0%"
                        color: "#3fb950"
                        font.pixelSize: 10
                        font.bold: true
                        Layout.preferredWidth: 80
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                id: statusText
                text: "Ready"
                color: "#8b949e"
                font.pixelSize: 11
                Layout.fillWidth: true
            }

            Text {
                text: "Save to:"
                color: "#8b949e"
                font.pixelSize: 10
            }

            Rectangle {
                Layout.preferredWidth: 180
                Layout.preferredHeight: 20
                color: "#161b22"
                radius: 4
                border.color: "#30363d"
                border.width: 1
                clip: true

                TextInput {
                    id: downloadDirInput
                    text: downloadDir
                    color: "#e6edf3"
                    font.pixelSize: 10
                    anchors.left: parent.left
                    anchors.leftMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    onEditingFinished: { downloadDir = text; updateGraphFilesModel() }
                    selectByMouse: true
                }
            }

            Button {
                text: "Browse"
                implicitWidth: 50
                implicitHeight: 20
                onClicked: {
                    console.log("Browse clicked")
                    folderDialog.open()
                    console.log("Folder dialog opened")
                }
                contentItem: Text { text: parent.text; color: "#e6edf3"; font.pixelSize: 9; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
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
                        contentItem: Text { text: parent.text; color: "#e6edf3"; font.bold: true; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                        implicitHeight: 28
                    }

                    Text { text: "File:"; color: "#8b949e"; font.pixelSize: 12 }

                    ComboBox {
                        id: graphFileCombo
                        Layout.fillWidth: true
                        model: graphFilesModel
                        textRole: "displayName"
                        onCurrentIndexChanged: {
                            if (currentIndex >= 0)
                                loadSelectedFile(currentIndex)
                        }
                        background: Rectangle { color: "#161b22"; radius: 4; border.color: "#30363d"; border.width: 1 }
                        contentItem: Text { text: graphFileCombo.currentText; color: "#e6edf3"; x: 8; font.pixelSize: 12 }
                        indicator: Text { text: "\u25bc"; color: "#8b949e"; anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter }
                    }

                    Text { text: "From:"; color: "#8b949e"; font.pixelSize: 12 }
                    TextField {
                        id: graphStartField
                        implicitWidth: 70
                        color: "#e6edf3"
                        background: Rectangle { color: "#161b22"; radius: 4; border.color: "#30363d"; border.width: 1 }
                        leftPadding: 6; font.pixelSize: 12
                        validator: IntValidator { bottom: 0 }
                    }

                    Text { text: "To:"; color: "#8b949e"; font.pixelSize: 12 }
                    TextField {
                        id: graphEndField
                        implicitWidth: 70
                        color: "#e6edf3"
                        background: Rectangle { color: "#161b22"; radius: 4; border.color: "#30363d"; border.width: 1 }
                        leftPadding: 6; font.pixelSize: 12
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
                        contentItem: Text { text: parent.text; color: "#e6edf3"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 11 }
                        background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                        implicitHeight: 28
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: "#161b22"
                    radius: 6
                    border.color: "#30363d"
                    border.width: 1
                    clip: true

                    Canvas {
                        id: chartCanvas
                        anchors.fill: parent
                        property real zoomMin: 0
                        property real zoomMax: csvTotalRows > 0 ? csvTotalRows : 1

                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            var data = csvData
                            if (data.length < 2) {
                                ctx.fillStyle = "#8b949e"; ctx.font = "14px monospace"
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

                            ctx.strokeStyle = "#30363d"; ctx.lineWidth = 0.5
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
                                ctx.fillStyle = "#8b949e"; ctx.font = "9px monospace"
                                var yLbl = fmtTick(yMin + (yMax - yMin) * yFrac)
                                ctx.fillText(yLbl, mL - 4 - ctx.measureText(yLbl).width, yY + 3)
                            }
                            for (var gx = 0; gx <= xTicks; gx++) {
                                var xFrac = gx / xTicks
                                var xX = mL + pW * xFrac
                                ctx.beginPath(); ctx.moveTo(xX, mT); ctx.lineTo(xX, mT + pH); ctx.stroke()
                                ctx.fillStyle = "#8b949e"; ctx.font = "9px monospace"
                                var xLbl = (startRow + visibleRange * xFrac).toFixed(0)
                                ctx.fillText(xLbl, xX - ctx.measureText(xLbl).width / 2, height - 5)
                            }
                            ctx.fillStyle = "#8b949e"; ctx.font = "9px monospace"
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
                            chartCanvas.requestPaint()
                        }
                        contentItem: Text { text: parent.text; color: "#e6edf3"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; font.pixelSize: 11 }
                        background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                    }
                }
            }

            Rectangle {
                Layout.preferredWidth: 170
                Layout.fillHeight: true
                color: "#161b22"
                radius: 6
                border.color: "#30363d"
                visible: csvColumns.length > 0
                clip: true

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 4

                    Text { text: "Data Columns"; color: "#e6edf3"; font.bold: true; font.pixelSize: 12 }

                    Rectangle { Layout.fillWidth: true; height: 1; color: "#30363d" }

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
                                    radius: 3; color: "transparent"; border.color: "#58a6ff"; border.width: 1
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
                                color: index === 0 ? "#8b949e" : "#e6edf3"; font.pixelSize: 11
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
        background: Rectangle { color: "#161b22"; radius: 8; border.color: "#30363d"; border.width: 1 }

        header: Label {
            text: "Start Recording"
            color: "#e6edf3"
            font.pixelSize: 16
            font.bold: true
            padding: 16
        }

        footer: DialogButtonBox {
            spacing: 8
            padding: 12
            background: Rectangle { color: "transparent" }
            Button {
                text: "Cancel"
                implicitWidth: 80
                onClicked: startDialog.close()
                contentItem: Text {
                    text: parent.text; color: "#e6edf3"; font.bold: true; font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 6
                    border.color: "#30363d"; border.width: 1
                }
            }
            Button {
                text: "OK"
                implicitWidth: 80
                onClicked: startDialog.accept()
                contentItem: Text {
                    text: parent.text; color: "#ffffff"; font.bold: true; font.pixelSize: 13
                    horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: parent.down ? "#1f6feb" : parent.hovered ? "#238636" : "#238636"; radius: 6
                }
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

            Text { text: "Recording Name (optional):"; color: "#8b949e"; font.pixelSize: 12 }
            TextField {
                id: startNameField
                Layout.fillWidth: true
                text: "motor_test_1"
                placeholderText: "e.g. motor_test_1"
                color: "#e6edf3"
                background: Rectangle { color: "#0d1117"; radius: 4; border.color: "#30363d"; border.width: 1 }
                leftPadding: 8
                font.pixelSize: 13
            }

            Text { text: "Duration (seconds, 0 = manual stop):"; color: "#8b949e"; font.pixelSize: 12 }
            TextField {
                id: startDurationField
                Layout.fillWidth: true
                text: "0"
                placeholderText: "0 = manual stop"
                color: "#e6edf3"
                background: Rectangle { color: "#0d1117"; radius: 4; border.color: "#30363d"; border.width: 1 }
                leftPadding: 8
                font.pixelSize: 13
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
        background: Rectangle { color: "#161b22"; radius: 8; border.color: "#30363d"; border.width: 1 }

        header: Label {
            text: "Recording Files on Device"
            color: "#e6edf3"
            font.pixelSize: 16
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
                    color: "#8b949e"
                    font.pixelSize: 12
                }

                Item { Layout.fillWidth: true }

                Button {
                    text: "Select All"
                    Layout.preferredWidth: 80
                    onClicked: {
                        for (var i = 0; i < fileListModel.count; ++i)
                            fileListModel.set(i, {checked: true})
                    }
                    contentItem: Text { text: parent.text; color: "#e6edf3"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                    implicitHeight: 28
                }

                Button {
                    text: "Clear"
                    Layout.preferredWidth: 60
                    onClicked: {
                        for (var i = 0; i < fileListModel.count; ++i)
                            fileListModel.set(i, {checked: false})
                    }
                    contentItem: Text { text: parent.text; color: "#e6edf3"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                    implicitHeight: 28
                }

                Button {
                    text: "Refresh"
                    Layout.preferredWidth: 70
                    onClicked: {
                        fileListLoading = true
                        fileListModel.clear()
                        mqtt.requestFileList()
                    }
                    contentItem: Text { text: parent.text; color: "#e6edf3"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.hovered ? "#1f6feb" : "#21262d"; radius: 4; border.color: "#30363d"; border.width: 1 }
                    implicitHeight: 28
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#0d1117"
                radius: 6
                border.color: "#30363d"
                clip: true

                ListView {
                    anchors.fill: parent
                    anchors.margins: 4
                    model: fileListModel
                    spacing: 2

                    delegate: Rectangle {
                        width: parent ? parent.width : 0
                        height: 36
                        color: checked ? "#1f6feb20" : "transparent"
                        radius: 4

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8

                            CheckBox {
                                id: itemCheck
                                checked: model.checked
                                onCheckedChanged: fileListModel.set(index, {checked: checked})
                                indicator: Rectangle {
                                    implicitWidth: 16; implicitHeight: 16
                                    x: itemCheck.leftPadding; y: parent.height / 2 - 8
                                    radius: 3; color: "transparent"; border.color: "#58a6ff"; border.width: 1
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 10; height: 10; radius: 2
                                        color: itemCheck.checked ? "#58a6ff" : "transparent"
                                    }
                                }
                            }

                            Text {
                                text: model.fileName
                                color: "#e6edf3"
                                font.pixelSize: 12
                                Layout.fillWidth: true
                                elide: Text.ElideMiddle
                            }

                            Text {
                                text: model.sizeStr
                                color: "#8b949e"
                                font.pixelSize: 11
                                Layout.preferredWidth: 80
                                horizontalAlignment: Text.AlignRight
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        text: fileListLoading ? "Requesting list..." : "Press Refresh to load files"
                        color: "#8b949e"
                        font.pixelSize: 13
                        visible: fileListModel.count === 0
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Button {
                    text: "Download Selected"
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
                    contentItem: Text { text: parent.text; color: "#e6edf3"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.down ? "#238636" : parent.hovered ? "#238636" : parent.enabled ? "#1f6feb" : "#21262d"; radius: 6; border.color: parent.enabled ? "#1f6feb" : "#30363d"; border.width: 1 }
                    implicitHeight: 34
                }

                Button {
                    text: "Delete Selected"
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
                    contentItem: Text { text: parent.text; color: "#e6edf3"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.down ? "#da3633" : parent.hovered ? "#da3633" : parent.enabled ? "#21262d" : "#161b22"; radius: 6; border.color: parent.enabled ? "#f85149" : "#30363d"; border.width: 1 }
                    implicitHeight: 34
                }
            }
        }
    }

    Component.onCompleted: {
        for (var i = 0; i < 13; ++i)
            dataModel.append({value: "---"})
        downloadDir = mqtt.getDownloadDir()
        downloadDirInput.text = downloadDir
        logAppend("GUI started. Connecting to broker...", "info")
        Qt.callLater(mqtt.connectToBroker)
    }
}
