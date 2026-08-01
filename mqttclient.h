#ifndef MOTOR_GUI_MQTTCLIENT_H
#define MOTOR_GUI_MQTTCLIENT_H

#include <QObject>
#include <QString>
#include <QTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QProcess>
#include <QTemporaryFile>
#include <QFile>
#include <QRegularExpression>
#include <QFileDialog>
#include <QStandardPaths>
#include <QDir>

#ifdef HAVE_MQTT
#include <MQTTClient.h>
#endif

class MqttClient : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool connected READ isConnected NOTIFY connectedChanged)
    Q_PROPERTY(QString statusText READ statusText NOTIFY statusTextChanged)

public:
    explicit MqttClient(QObject *parent = nullptr);
    ~MqttClient();

    bool isConnected() const;
    QString statusText() const;

public slots:
    void connectToBroker();
    void disconnectFromBroker();
    void publishCommand(const QString &cmd);
    void publishStatusMsg(const QString &state, const QString &msg);
    Q_INVOKABLE void httpDownload(const QString &url);
    Q_INVOKABLE void scpDownload(const QString &remotePath);
    Q_INVOKABLE void startPipeline(const QString &url);
    Q_INVOKABLE void pickAndDownload(const QString &remoteUrl);
    void startScpProcess(const QString &remotePath, const QString &localPath);
    Q_INVOKABLE void requestFileList();
    Q_INVOKABLE void downloadFile(const QString &filename);
    Q_INVOKABLE void uploadFile(const QString &filename, const QString &localSavePath);
    Q_INVOKABLE void deleteFile(const QString &filename);
    Q_INVOKABLE void startRecording(const QString &name, int durationSec);
    Q_INVOKABLE void saveStringToFile(const QString &path, const QString &data);
    Q_INVOKABLE QString getSaveFilePath(const QString &defaultName);
    Q_INVOKABLE QString getExistingDirectory();
    Q_INVOKABLE QString getDownloadDir();
    Q_INVOKABLE QStringList listCsvFiles(const QString &dir);
    Q_INVOKABLE QString readTextFile(const QString &path);

private slots:
    void onCmdTimeout();
    void attemptReconnect();

signals:
    void connectedChanged();
    void statusTextChanged();
    void commandReceived(const QString &payload);
    void statusReceived(const QString &state, const QString &msg, const QString &raw);
    void dataReceived(const QString &payload);
    void downloadChunkReceived(int chunk, int total, const QString &data);
    void logMessage(const QString &text, const QString &type);
    void mqttConnected();
    void mqttDisconnected();
    void commandTimeout(const QString &cmd);
    void fileDownloaded(const QString &csvData);
    void uploadProgress(int percent);
    void downloadProgress(int percent);
    void fileListReceived(const QString &json);
    void deleteResult(const QString &filename, bool success);
    void singleFileDownloaded(const QString &filename, const QString &localPath);
    void uploadDownloadComplete(const QString &localPath);

private:
    bool m_connected;
    QString m_statusText;

#ifdef HAVE_MQTT
    MQTTClient m_client;
#endif
    QTimer *m_cmdTimer;
    QTimer *m_yieldTimer;
    QTimer *m_reconnectTimer;
    int m_reconnectAttempts = 0;
    QString m_pendingCmd;
    int m_timeoutSec;
    QNetworkAccessManager *m_nam;
    QString m_pendingSavePath;
    bool m_pipelineActive = false;
    QString m_chunkBuffer;
    int m_chunkTotal = 0;
    int m_chunkCount = 0;

public:
    void onUploadComplete(const QString &url);
    void setConnected(bool c);
    void setStatusText(const QString &t);
    void clearPendingCmd();
    void scheduleReconnect();
};

#endif
