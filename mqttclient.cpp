#include "mqttclient.h"
#include <QApplication>
#include <QWindow>
#include <QDateTime>
#include <QElapsedTimer>

#define MQTT_BROKER "tcp://139.185.38.211:1883"
#define MQTT_USER "mqttuser"
#define MQTT_PASS "123456"

#define STATUS_TOPIC "guest/rpi5guest1/status"
#define CMD_TOPIC "guest/rpi5guest1/cmd"
#define DATA_TOPIC "guest/rpi5guest1/data"
#define DOWNLOAD_TOPIC "guest/rpi5guest1/download"

#ifdef HAVE_MQTT

struct MqttContext {
    MqttClient *self;
    QString clientId;
    MQTTClient_connectOptions opts;
};

static void on_connection_lost(void *context, char *cause)
{
    auto *ctx = static_cast<MqttContext *>(context);
    fprintf(stderr, "[MQTT] Connection lost: %s\n", cause ? cause : "unknown");
    QMetaObject::invokeMethod(ctx->self, [self = ctx->self]() {
        if (!self->isConnected())
            return;
        self->setConnected(false);
        self->setStatusText("Reconnecting");
        emit self->mqttDisconnected();
        emit self->logMessage("Connection lost to broker. Reconnecting...", "warning");
        self->scheduleReconnect();
    }, Qt::QueuedConnection);
}

static int on_message(void *context, char *topicName, int topicLen,
                      MQTTClient_message *message)
{
    auto *ctx = static_cast<MqttContext *>(context);
    int tlen = (topicLen > 0) ? topicLen : (topicName ? strlen(topicName) : 0);
    QString topic = QString::fromUtf8(topicName, tlen);
    QString payload = QString::fromUtf8(
        static_cast<char *>(message->payload), message->payloadlen);

    fprintf(stderr, "[MQTT] << %s : %s\n", qPrintable(topic), payload.left(120).toUtf8().constData());

    QMetaObject::invokeMethod(ctx->self, [self = ctx->self, topic, payload]() {
        if (topic == CMD_TOPIC) {
            emit self->commandReceived(payload);
        } else if (topic == STATUS_TOPIC) {
            QJsonDocument doc = QJsonDocument::fromJson(payload.toUtf8());
            QString state = doc.object().value("state").toString();
            QString msg = doc.object().value("msg").toString();
            if (state == "uploading") {
                int pct = doc.object().value("progress").toInt();
                emit self->uploadProgress(pct);
            } else if (state == "file_list") {
                self->clearPendingCmd();
                emit self->fileListReceived(payload);
                return;
            } else if (state == "delete_result") {
                self->clearPendingCmd();
                QString file = doc.object().value("file").toString();
                bool ok = doc.object().value("success").toBool();
                emit self->deleteResult(file, ok);
                return;
            }
            if (state == "stopped") {
                QString url = doc.object().value("url").toString();
                if (!url.isEmpty()) {
                    self->clearPendingCmd();
                    self->onUploadComplete(url);
                    return;
                }
            }
            emit self->statusReceived(state, msg, payload);
            self->clearPendingCmd();
        } else if (topic == DATA_TOPIC)
            emit self->dataReceived(payload);
        else if (topic == DOWNLOAD_TOPIC) {
            QJsonDocument doc = QJsonDocument::fromJson(payload.toUtf8());
            int chunk = doc.object().value("chunk").toInt();
            int total = doc.object().value("total").toInt();
            QString data = doc.object().value("data").toString();
            emit self->downloadChunkReceived(chunk, total, data);
            self->clearPendingCmd();
        }
    }, Qt::QueuedConnection);

    MQTTClient_freeMessage(&message);
    MQTTClient_free(topicName);
    return 1;
}

#endif

MqttClient::MqttClient(QObject *parent)
    : QObject(parent), m_connected(false), m_statusText("Initializing")
#ifdef HAVE_MQTT
    , m_client(nullptr)
#endif
    , m_cmdTimer(new QTimer(this)), m_yieldTimer(new QTimer(this)), m_timeoutSec(5), m_nam(new QNetworkAccessManager(this))
{
    m_cmdTimer->setSingleShot(true);
    connect(m_cmdTimer, &QTimer::timeout, this, &MqttClient::onCmdTimeout);
    /* 500ms, not 50ms.
       MQTTClient_yield() only matters for a client with no callbacks set; this
       one sets them in connectToBroker(), so Paho delivers on its own thread
       and this is a safety net rather than the delivery mechanism. At 50ms it
       was waking the GUI thread twenty times a second to do nothing. */
    m_yieldTimer->setInterval(500);
    connect(m_yieldTimer, &QTimer::timeout, this, [this]() {
#ifdef HAVE_MQTT
        if (m_client) {
            MQTTClient_yield();
        }
#endif
    });
    m_reconnectTimer = new QTimer(this);
    m_reconnectTimer->setSingleShot(true);
    m_reconnectTimer->setInterval(5000);
    connect(m_reconnectTimer, &QTimer::timeout, this, &MqttClient::attemptReconnect);
}

/*
 * Every route that lets go of a client comes through here.
 *
 * There were three things to release and no single place releasing them, so
 * each path forgot a different one. connectToBroker() in particular ran
 * MQTTClient_create() straight over m_client without destroying the previous
 * handle, and deleted its MqttContext only on the two failure paths -- so a
 * connection that succeeded leaked the context, and every reconnect after a
 * dropped link leaked a whole Paho client as well. A GUI left running across a
 * flaky broker accumulated both indefinitely.
 */
void MqttClient::teardownClient()
{
#ifdef HAVE_MQTT
    if (m_client) {
        MQTTClient_disconnect(m_client, 1000);
        MQTTClient_destroy(&m_client);
        m_client = nullptr;
    }
#endif
    /* After the client is destroyed, so Paho can no longer call into it. */
    delete m_ctx;
    m_ctx = nullptr;
}

MqttClient::~MqttClient()
{
    teardownClient();
}

bool MqttClient::isConnected() const
{
    return m_connected;
}

QString MqttClient::statusText() const
{
    return m_statusText;
}

void MqttClient::setConnected(bool c)
{
    if (m_connected != c) {
        m_connected = c;
        emit connectedChanged();
    }
}

void MqttClient::setStatusText(const QString &t)
{
    if (m_statusText != t) {
        m_statusText = t;
        emit statusTextChanged();
    }
}

void MqttClient::connectToBroker()
{
#ifdef HAVE_MQTT
    m_reconnectTimer->stop();
    setStatusText("Connecting...");
    fprintf(stderr, "[GUI] Connecting to MQTT broker %s...\n", MQTT_BROKER);
    emit logMessage("Connecting to MQTT broker...", "info");

    /* Release whatever the previous attempt left behind before allocating
       again. This is also the reconnect path, and it used to overwrite
       m_client with a fresh handle and drop the old one on the floor. */
    teardownClient();

    auto *ctx = new MqttContext;
    ctx->self = this;
    ctx->clientId = "motor_gui_" + QString::number(QDateTime::currentMSecsSinceEpoch());

    int rc = MQTTClient_create(&m_client, MQTT_BROKER, ctx->clientId.toStdString().c_str(),
                              MQTTCLIENT_PERSISTENCE_NONE, nullptr);
    if (rc != MQTTCLIENT_SUCCESS) {
        fprintf(stderr, "[GUI] MQTTClient_create failed: %d\n", rc);
        emit logMessage("Failed to create MQTT client.", "error");
        setStatusText("Create failed");
        delete ctx;
        m_client = nullptr;
        return;
    }

    /* Owned from here on, and freed by teardownClient(). */
    m_ctx = ctx;

    ctx->opts = MQTTClient_connectOptions_initializer;
    ctx->opts.connectTimeout = 5;
    ctx->opts.username = MQTT_USER;
    ctx->opts.password = MQTT_PASS;

    MQTTClient_setCallbacks(m_client, ctx, on_connection_lost, on_message, nullptr);

    rc = MQTTClient_connect(m_client, &ctx->opts);
    if (rc == MQTTCLIENT_SUCCESS) {
        MQTTClient_subscribe(m_client, STATUS_TOPIC, 0);
        MQTTClient_subscribe(m_client, DATA_TOPIC, 0);
        MQTTClient_subscribe(m_client, DOWNLOAD_TOPIC, 0);
        m_reconnectTimer->stop();
        m_reconnectAttempts = 0;
        setConnected(true);
        setStatusText("Connected");
        m_yieldTimer->start();
        fprintf(stderr, "[GUI] Connected to broker at " MQTT_BROKER "\n");
        emit logMessage("Connected to broker at " MQTT_BROKER, "success");
        emit mqttConnected();
        publishStatusMsg("idle", "GUI connected");
    } else {
        setConnected(false);
        setStatusText("Connection failed");
        fprintf(stderr, "[GUI] MQTT connection failed (error %d)\n", rc);
        emit logMessage(QString("MQTT connection failed (error %1).").arg(rc), "error");
        teardownClient();          /* destroys the client and frees m_ctx */
        scheduleReconnect();
    }
#else
    setStatusText("Demo mode");
    emit logMessage("MQTT not available — running in demo mode.", "warning");
#endif
}

void MqttClient::disconnectFromBroker()
{
    m_yieldTimer->stop();
    m_reconnectTimer->stop();
    m_reconnectAttempts = 0;
    teardownClient();
    clearPendingCmd();
    setConnected(false);
    setStatusText("Disconnected");
    emit logMessage("Disconnected from broker.", "warning");
    emit mqttDisconnected();
}

void MqttClient::scheduleReconnect()
{
    if (m_connected)
        return;
    if (m_reconnectTimer->isActive())
        return;                    /* checked before counting, see below */

    m_reconnectAttempts++;

    /*
     * Exponential backoff, 2s doubling to 30s.
     *
     * The interval was a fixed 5s, so a broker that stays down is hammered
     * every five seconds for as long as the app is open, and each attempt
     * blocks the GUI thread for the 5s connectTimeout. The counter is also
     * bumped after the isActive() check now: it used to increment on every
     * call including the ones that returned immediately, so the "attempt N"
     * in the log counted calls rather than attempts.
     */
    int delay = qMin(30000, 2000 * (1 << qMin(m_reconnectAttempts - 1, 4)));
    m_reconnectTimer->setInterval(delay);

    fprintf(stderr, "[GUI] Reconnect attempt %d scheduled in %d ms\n",
            m_reconnectAttempts, delay);
    m_reconnectTimer->start();
}

void MqttClient::attemptReconnect()
{
    if (m_connected)
        return;
    emit logMessage("Attempting to reconnect to broker...", "info");
    connectToBroker();
}

void MqttClient::publishCommand(const QString &cmd)
{
#ifdef HAVE_MQTT
    if (!m_connected || !m_client) {
        emit logMessage("Cannot send command: not connected.", "error");
        return;
    }
    QByteArray utf8 = cmd.toUtf8();
    fprintf(stderr, "[GUI] >> %s : %s\n", CMD_TOPIC, cmd.toUtf8().constData());
    MQTTClient_publish(m_client, CMD_TOPIC, utf8.size(), utf8.constData(), 0, false, nullptr);
    m_pendingCmd = cmd;
    m_cmdTimer->start(m_timeoutSec * 1000);
#endif
}

void MqttClient::publishStatusMsg(const QString &state, const QString &msg)
{
#ifdef HAVE_MQTT
    if (!m_connected || !m_client) return;
    QJsonObject obj;
    obj["state"] = state;
    obj["msg"] = msg;
    QByteArray json = QJsonDocument(obj).toJson(QJsonDocument::Compact);
    MQTTClient_publish(m_client, STATUS_TOPIC, json.size(), json.constData(), 0, false, nullptr);
#endif
}

void MqttClient::onCmdTimeout()
{
    fprintf(stderr, "[GUI] TIMEOUT: no response for '%s'\n", m_pendingCmd.toUtf8().constData());
    emit logMessage(QString("Recorder not responding (timeout %1s) — may be disconnected.").arg(m_timeoutSec), "error");
    QString timedOut = m_pendingCmd;
    m_pendingCmd.clear();
    emit commandTimeout(timedOut);
}

void MqttClient::clearPendingCmd()
{
    m_cmdTimer->stop();
    m_pendingCmd.clear();
}

void MqttClient::requestFileList()
{
    publishCommand("list");
    m_pendingCmd = "list";
    m_cmdTimer->start(m_timeoutSec * 1000);
    emit logMessage("Requesting file list...", "info");
}

void MqttClient::downloadFile(const QString &filename)
{
    fprintf(stderr, "[GUI] downloadFile(%s)\n", qPrintable(filename));
    QString cmd = "download " + filename;
    publishCommand(cmd);
    m_pendingCmd = cmd;
    m_cmdTimer->start(m_timeoutSec * 1000);
    emit logMessage("Requesting download: " + filename, "info");
}

void MqttClient::uploadFile(const QString &filename, const QString &localSavePath)
{
    fprintf(stderr, "[GUI] uploadFile(%s) -> %s\n", qPrintable(filename), qPrintable(localSavePath));
    QString cmd = "upload " + filename;
    publishCommand(cmd);
    m_pendingCmd = cmd;
    m_cmdTimer->start(300000);
    m_pendingSavePath = localSavePath;
    m_pipelineActive = true;
    emit logMessage("Uploading " + filename + " from recorder to server (may take a minute)...", "info");
}

void MqttClient::deleteFile(const QString &filename)
{
    QString cmd = "delete " + filename;
    publishCommand(cmd);
    m_pendingCmd = cmd;
    m_cmdTimer->start(m_timeoutSec * 1000);
    emit logMessage("Requesting delete: " + filename, "info");
}

void MqttClient::startRecording(const QString &name, int durationSec)
{
    QString cmd = "start";
    if (!name.isEmpty())
        cmd += " " + name;
    if (durationSec > 0)
        cmd += " " + QString::number(durationSec);
    publishCommand(cmd);
    m_pendingCmd = "start";
    m_cmdTimer->start(m_timeoutSec * 1000);
    emit logMessage("Sent START command '" + cmd + "' to recorder.", "info");
}

void MqttClient::scpDownload(const QString &remotePath)
{
    auto *tmp = new QTemporaryFile(this);
    tmp->setFileTemplate("/tmp/motor_csv_XXXXXX.csv");
    if (!tmp->open()) {
        emit logMessage("Failed to create temp file.", "error");
        delete tmp;
        return;
    }
    QString local = tmp->fileName();
    tmp->close();
    delete tmp;

    emit logMessage("Downloading via SCP: " + remotePath, "info");
    startScpProcess(remotePath, local);
}

void MqttClient::onUploadComplete(const QString &remoteUrl)
{
    if (m_pendingSavePath.isEmpty()) return;
    fprintf(stderr, "[GUI] onUploadComplete: url=%s savePath=%s\n",
            qPrintable(remoteUrl), qPrintable(m_pendingSavePath));
    m_pipelineActive = false;
    emit logMessage("Upload complete, downloading via SCP...", "info");
    QString local = m_pendingSavePath;
    m_pendingSavePath.clear();
    startScpProcess(remoteUrl, local);
}

void MqttClient::startScpProcess(const QString &remotePath, const QString &localPath)
{
    QString userHost = "maxmaster@139.185.38.211";
    QString remoteFile = remotePath;
    if (remotePath.startsWith(userHost + ":"))
        remoteFile = remotePath.mid(userHost.length() + 1);

    fprintf(stderr, "\n[SCP DEBUG] Starting download\n");
    fprintf(stderr, "[SCP DEBUG] Remote: %s\n", qPrintable(remotePath));
    fprintf(stderr, "[SCP DEBUG] Local: %s\n", qPrintable(localPath));

    auto *elapsed = new QElapsedTimer();
    elapsed->start();

    auto *sizeProc = new QProcess(this);
    QStringList args = {
        "-i", QDir::homePath() + "/.ssh/id_ed25519",
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=10",
        userHost, "stat -c %s " + remoteFile
    };

    struct ScpState {
        QProcess *proc;
        QTimer *progressTimer;
        int lastPct = -1;
        qint64 remoteSize = 0;
        QString localPath;
        QString remotePath;
        QElapsedTimer *elapsed;
        QString stderrBuf;
    };

    fprintf(stderr, "[SCP DEBUG] Getting remote file size via SSH...\n");

    auto *st = new ScpState;
    st->proc = new QProcess(this);
    st->progressTimer = new QTimer(this);
    st->localPath = localPath;
    st->remotePath = remotePath;
    st->elapsed = elapsed;

    connect(sizeProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, [this, sizeProc, st](int code, QProcess::ExitStatus) {
        sizeProc->deleteLater();
        if (code == 0) {
            st->remoteSize = QString::fromUtf8(
                sizeProc->readAllStandardOutput()).trimmed().toLongLong();
            fprintf(stderr, "[SCP DEBUG] Remote size: %lld KB (SSH took %lld ms)\n",
                    st->remoteSize / 1024, st->elapsed->elapsed());
        } else {
            fprintf(stderr, "[SCP DEBUG] SSH stat failed (exit=%d): %s\n",
                    code, qPrintable(QString::fromUtf8(sizeProc->readAllStandardError())));
        }

        fprintf(stderr, "[SCP DEBUG] Starting scp...\n");
        QStringList scpArgs = {
            "-v", "-C",
            "-i", QDir::homePath() + "/.ssh/id_ed25519",
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=30",
            "-o", "ServerAliveInterval=10",
            st->remotePath, st->localPath
        };
        fprintf(stderr, "[SCP DEBUG] Cmd: scp %s\n", qPrintable(scpArgs.join(' ')));

        connect(st->proc, &QProcess::readyReadStandardError, this,
                [st]() { st->stderrBuf += QString::fromUtf8(st->proc->readAllStandardError()); });

        if (st->remoteSize > 0) {
            connect(st->progressTimer, &QTimer::timeout, this, [this, st]() {
                QFile f(st->localPath);
                qint64 localSize = 0;
                if (f.open(QIODevice::ReadOnly)) {
                    localSize = f.size();
                    f.close();
                }
                int pct = localSize * 100 / qMax(st->remoteSize, (qint64)1);
                if (pct > 100) pct = 100;
                if (pct != st->lastPct) {
                    st->lastPct = pct;
                    emit downloadProgress(pct);
                }
                if (pct >= 100)
                    st->progressTimer->stop();
            });
            st->progressTimer->start(500);
        }

        connect(st->proc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, [this, st](int exitCode, QProcess::ExitStatus status) {
            st->progressTimer->stop();
            st->progressTimer->deleteLater();
            st->proc->deleteLater();

            qint64 totalTime = st->elapsed->elapsed();
            delete st->elapsed;

            fprintf(stderr, "[SCP DEBUG] Process finished (exit=%d, status=%d, time=%llds)\n",
                    exitCode, (int)status, totalTime / 1000);

            if (!st->stderrBuf.isEmpty()) {
                fprintf(stderr, "--- SCP VERBOSE OUTPUT ---\n%s\n--- END ---\n",
                        qPrintable(st->stderrBuf));
            }

            QFile f(st->localPath);
            if (exitCode == 0 && status == QProcess::NormalExit && f.open(QIODevice::ReadOnly)) {
                qint64 fileSize = f.size();
                QString data = QString::fromUtf8(f.readAll());
                f.close();
                emit downloadProgress(100);
                double rate = fileSize / 1024.0 / (totalTime / 1000.0);
                fprintf(stderr, "[SCP DEBUG] DONE: %lld KB in %llds (%.1f KB/s)\n",
                        fileSize / 1024, totalTime / 1000, rate);
                emit fileDownloaded(data);
                emit logMessage("Downloaded " + QString::number(fileSize / 1024) + " KB in " +
                               QString::number(totalTime / 1000) + "s (" +
                               QString::number(rate, 'f', 1) + " KB/s)", "success");
            } else {
                fprintf(stderr, "[SCP DEBUG] FAILED\n");
                emit logMessage("SCP download failed (exit=" + QString::number(exitCode) + ")", "error");
            }
            if (st->localPath.startsWith("/tmp/"))
                QFile::remove(st->localPath);
            else
                fprintf(stderr, "[SCP DEBUG] Saved to %s\n", qPrintable(st->localPath));

            delete st;
        });

        st->proc->start("scp", scpArgs);
    });

    sizeProc->start("ssh", args);
}

void MqttClient::startPipeline(const QString &)
{
    QString basePath = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    QString savePath = basePath + "/motor_data.csv";
    int n = 1;
    while (QFile::exists(savePath)) {
        savePath = basePath + "/motor_data_" + QString::number(n) + ".csv";
        n++;
    }

    m_pendingSavePath = savePath;
    m_pipelineActive = true;
    emit logMessage("Saving to " + savePath, "info");
    emit logMessage("Uploading from recorder to server...", "info");
    publishCommand("upload");
}

void MqttClient::pickAndDownload(const QString &remoteUrl)
{
    QString fname = remoteUrl.section('/', -1);
    if (fname.isEmpty()) fname = "motor_data.csv";

    QString defaultPath = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation)
                          + "/" + fname;
    QString savePath = QFileDialog::getSaveFileName(nullptr,
        "Save CSV File", defaultPath, "CSV Files (*.csv)");

    if (savePath.isEmpty()) {
        emit logMessage("Download cancelled.", "warning");
        return;
    }

    emit logMessage("Saving to " + savePath, "info");
    startScpProcess(remoteUrl, savePath);
}

void MqttClient::saveStringToFile(const QString &path, const QString &data)
{
    QFile f(path);
    if (f.open(QIODevice::WriteOnly | QIODevice::Text)) {
        f.write(data.toUtf8());
        f.close();
        emit logMessage("Saved " + QString::number(data.size()) + " bytes to " + path, "success");
    } else {
        emit logMessage("Failed to save file: " + path, "error");
    }
}

QString MqttClient::getSaveFilePath(const QString &defaultName)
{
    return QFileDialog::getSaveFileName(nullptr, "Save CSV File",
        QStandardPaths::writableLocation(QStandardPaths::DownloadLocation) + "/" + defaultName,
        "CSV Files (*.csv)");
}

QString MqttClient::getExistingDirectory()
{
    QFileDialog dialog;
    dialog.setFileMode(QFileDialog::Directory);
    dialog.setOption(QFileDialog::ShowDirsOnly, true);
    dialog.setDirectory(QStandardPaths::writableLocation(QStandardPaths::DownloadLocation));
    dialog.setWindowTitle("Select Download Directory");
    dialog.setWindowModality(Qt::WindowModal);

    auto windows = QApplication::topLevelWindows();
    if (!windows.isEmpty()) {
        dialog.winId();
        if (auto *w = dialog.windowHandle())
            w->setTransientParent(windows.first());
    }

    if (dialog.exec() == QDialog::Accepted)
        return dialog.selectedFiles().value(0);
    return QString();
}

QString MqttClient::getDownloadDir()
{
    return QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
}

QStringList MqttClient::listCsvFiles(const QString &dir)
{
    QDir d(dir);
    QStringList files = d.entryList(QStringList() << "*.csv", QDir::Files | QDir::Readable, QDir::Name);
    QStringList paths;
    for (const QString &name : files)
        paths.append(d.filePath(name));
    return paths;
}

QString MqttClient::readTextFile(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return QString();
    QString data = QString::fromUtf8(f.readAll());
    f.close();
    return data;
}

void MqttClient::httpDownload(const QString &url)
{
    emit logMessage("Downloading " + url, "info");
    QNetworkReply *reply = m_nam->get(QNetworkRequest(QUrl(url)));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            emit logMessage("Download failed: " + reply->errorString(), "error");
            return;
        }
        QByteArray data = reply->readAll();
        emit logMessage("Downloaded " + QString::number(data.size() / 1024) + " KB", "success");
        emit fileDownloaded(QString::fromUtf8(data));
    });
    connect(reply, &QNetworkReply::downloadProgress, this, [this, reply](qint64 recv, qint64 total) {
        if (total > 0)
            emit logMessage(QString("Download %1/%2 KB").arg(recv / 1024).arg(total / 1024), "info");
    });
}
