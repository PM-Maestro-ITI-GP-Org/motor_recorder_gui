#include "mainwindow.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QHeaderView>
#include <QMessageBox>
#include <QDateTime>
#include <QFileDialog>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QFrame>
#include <QScrollBar>
#include <QApplication>

#ifdef HAVE_MQTT
#include <MQTTClient.h>
#endif

#include <iostream>

#define MQTT_BROKER "139.185.38.211"
#define MQTT_PORT 1883
#define MQTT_USER "mqttuser"
#define MQTT_PASS "123456"

#define STATUS_TOPIC "guest/rpi5guest1/status"
#define CMD_TOPIC "guest/rpi5guest1/cmd"
#define DATA_TOPIC "guest/rpi5guest1/data"
#define DOWNLOAD_TOPIC "guest/rpi5guest1/download"

#ifdef HAVE_MQTT

class MqttClientWrapper : public QObject
{
    Q_OBJECT

public:
    MqttClientWrapper(const QString &clientId, QObject *parent = nullptr)
        : QObject(parent), m_clientId(clientId)
    {
        MQTTClient_create(&m_client, MQTT_BROKER, clientId.toStdString().c_str(),
                         MQTTCLIENT_PERSISTENCE_NONE, nullptr);
        m_opts = MQTTClient_connectOptions_initializer;
        m_opts.connectTimeout = 5;
        m_opts.username = MQTT_USER;
        m_opts.password = MQTT_PASS;
        MQTTClient_setCallbacks(m_client, this, on_connection_lost, on_message, nullptr);
        m_connected = false;
    }

    ~MqttClientWrapper()
    {
        if (m_connected) MQTTClient_disconnect(m_client, 1000);
        MQTTClient_destroy(&m_client);
    }

    bool connect()
    {
        int rc = MQTTClient_connect(m_client, &m_opts);
        if (rc == MQTTCLIENT_SUCCESS) {
            m_connected = true;
            MQTTClient_subscribe(m_client, CMD_TOPIC, 0);
            MQTTClient_subscribe(m_client, DATA_TOPIC, 0);
            emit connected(true);
        } else {
            m_connected = false;
            emit connected(false);
        }
        return rc == MQTTCLIENT_SUCCESS;
    }

    void disconnect()
    {
        MQTTClient_disconnect(m_client, 1000);
        m_connected = false;
        emit connected(false);
    }

    void publishStatus(const QString &state, const QString &msg)
    {
        QJsonObject obj;
        obj["state"] = state;
        obj["msg"] = msg;
        QJsonDocument doc(obj);
        QByteArray json = doc.toJson(QJsonDocument::Compact);
        MQTTClient_publish(m_client, STATUS_TOPIC, json.size(), json.constData(), 0, false, nullptr);
    }

    void publishCommand(const QString &cmd)
    {
        QByteArray utf8 = cmd.toUtf8();
        MQTTClient_publish(m_client, CMD_TOPIC, utf8.size(), utf8.constData(), 0, false, nullptr);
    }

    bool isConnected() const { return m_connected; }

signals:
    void connected(bool connected);
    void commandReceived(const QString &cmd);
    void dataReceived(const QString &data);

private:
    MQTTClient m_client;
    QString m_clientId;
    MQTTClient_connectOptions m_opts;
    bool m_connected;

    static void on_connection_lost(void *context, char *cause)
    {
        auto *wrapper = static_cast<MqttClientWrapper *>(context);
        wrapper->m_connected = false;
        emit wrapper->connected(false);
    }

    static int on_message(void *context, char *topicName, int topicLen,
                          MQTTClient_message *message)
    {
        auto *wrapper = static_cast<MqttClientWrapper *>(context);
        QString topic = QString::fromUtf8(topicName, topicLen);
        QString payload = QString::fromUtf8(
            static_cast<char *>(message->payload), message->payloadlen);
        if (topic == CMD_TOPIC)
            emit wrapper->commandReceived(payload);
        else if (topic == DATA_TOPIC)
            emit wrapper->dataReceived(payload);
        MQTTClient_freeMessage(&message);
        MQTTClient_free(topicName);
        return 1;
    }
};

#endif

static const char *DARK_QSS = R"(
QMainWindow { background-color: #1a1a2e; }
QLabel#titleLabel { color: #e0e0e0; font-size: 20px; font-weight: bold; padding: 8px; }
QLabel#statusLabel { color: #e0e0e0; font-size: 13px; padding: 4px; }
QTableWidget {
    background-color: #16213e; color: #e0e0e0; gridline-color: #0f3460;
    border: 1px solid #0f3460; border-radius: 8px; padding: 4px;
    font-size: 12px; selection-background-color: #0f3460;
}
QTableWidget::item { padding: 4px; }
QHeaderView::section {
    background-color: #0f3460; color: #e0e0e0; padding: 6px;
    border: 1px solid #1a1a2e; font-weight: bold;
}
QPushButton {
    background-color: #0f3460; color: #e0e0e0; border: none;
    border-radius: 6px; padding: 10px 20px; font-size: 13px;
    font-weight: bold; min-width: 100px;
}
QPushButton:hover { background-color: #1a5276; }
QPushButton:pressed { background-color: #0b2a4a; }
QPushButton:disabled { background-color: #2a2a3e; color: #555; }
QPushButton#btnDanger { background-color: #8b0000; }
QPushButton#btnDanger:hover { background-color: #a00000; }
QPushButton#btnSuccess { background-color: #006400; }
QPushButton#btnSuccess:hover { background-color: #008000; }
QGroupBox {
    border: 1px solid #0f3460; border-radius: 8px; margin-top: 12px;
    padding: 12px; color: #e0e0e0; font-weight: bold;
}
QGroupBox::title { subcontrol-origin: margin; left: 12px; padding: 0 6px; }
QTextEdit#logArea {
    background-color: #0d1117; color: #c9d1d9; border: 1px solid #0f3460;
    border-radius: 8px; padding: 8px; font-family: "Consolas", monospace; font-size: 12px;
}
QScrollBar:vertical {
    background: #1a1a2e; width: 10px; border-radius: 5px;
}
QScrollBar::handle:vertical { background: #0f3460; border-radius: 5px; min-height: 20px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
)";

void MainWindow::logResponse(const QString &msg, const QString &type)
{
    QString timestamp = QDateTime::currentDateTime().toString("HH:mm:ss.zzz");
    QString color;
    if (type == "success") color = "#00ff88";
    else if (type == "error") color = "#ff4444";
    else if (type == "warning") color = "#ffaa00";
    else color = "#8888ff";
    m_logArea->append(QString("<span style='color:%1'>[%2]</span> %3").arg(color, timestamp, msg.toHtmlEscaped()));
}

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent)
    , m_table(nullptr), m_btnConnect(nullptr), m_btnStart(nullptr)
    , m_btnStop(nullptr), m_btnDownload(nullptr)
    , m_statusLabel(nullptr), m_connectionIndicator(nullptr), m_logArea(nullptr)
    , m_rpm(0)
{
    m_currents.resize(8, 0.0);
    m_vib.resize(3, 0.0);
    m_refreshTimer = new QTimer(this);
    connect(m_refreshTimer, &QTimer::timeout, this, &MainWindow::onPublishStatus);
    m_refreshTimer->start(100);
    setupUI();
    setupStyle();
    setupMqtt();
}

MainWindow::~MainWindow()
{
    delete m_refreshTimer;
#ifdef HAVE_MQTT
    delete m_mqtt;
#endif
}

void MainWindow::setupStyle()
{
    setStyleSheet(DARK_QSS);
}

void MainWindow::setupUI()
{
    setWindowTitle("Motor Data Recorder");
    resize(1100, 800);
    setMinimumSize(800, 600);

    QWidget *centralWidget = new QWidget(this);
    QVBoxLayout *mainLayout = new QVBoxLayout(centralWidget);
    mainLayout->setContentsMargins(16, 16, 16, 16);
    mainLayout->setSpacing(12);

    // Header
    QHBoxLayout *headerLayout = new QHBoxLayout;
    QLabel *titleLabel = new QLabel("\xE2\x9A\x99 Motor Data Recorder", this);
    titleLabel->setObjectName("titleLabel");
    m_connectionIndicator = new QLabel("\xE2\x97\x8F Disconnected", this);
    m_connectionIndicator->setObjectName("statusLabel");
    m_connectionIndicator->setStyleSheet("color: #ff4444; font-size: 13px; padding: 4px;");
    headerLayout->addWidget(titleLabel);
    headerLayout->addStretch();
    headerLayout->addWidget(m_connectionIndicator);
    mainLayout->addLayout(headerLayout);

    // Response log (compact, above table)
    m_logArea = new QTextEdit(this);
    m_logArea->setObjectName("logArea");
    m_logArea->setReadOnly(true);
    m_logArea->setMaximumHeight(100);
    m_logArea->setMinimumHeight(60);
    logResponse("GUI started. Initializing...", "info");
    mainLayout->addWidget(m_logArea);

    // Data table
    m_table = new QTableWidget(this);
    m_table->setColumnCount(13);
    m_table->setHorizontalHeaderLabels(
        {"Timestamp", "C0 (A)", "C1 (A)", "C2 (A)", "C3 (A)",
         "C4 (A)", "C5 (A)", "C6 (A)", "C7 (A)",
         "VibX (g)", "VibY (g)", "VibZ (g)", "RPM"});
    m_table->horizontalHeader()->setSectionResizeMode(QHeaderView::Stretch);
    m_table->verticalHeader()->setVisible(false);
    m_table->setSelectionMode(QAbstractItemView::NoSelection);
    m_table->setEditTriggers(QAbstractItemView::NoEditTriggers);
    m_table->setAlternatingRowColors(true);
    m_table->setRowCount(1);
    for (int c = 0; c < 13; ++c)
        m_table->setItem(0, c, new QTableWidgetItem("---"));
    mainLayout->addWidget(m_table, 1);

    // Control buttons
    QHBoxLayout *btnLayout = new QHBoxLayout;
    btnLayout->setSpacing(10);

    m_btnConnect = new QPushButton("\xE2\x94\xB7 Connect", this);
    m_btnConnect->setObjectName("btnSuccess");
    m_btnConnect->setToolTip("Connect to MQTT broker");
    connect(m_btnConnect, &QPushButton::clicked, this, &MainWindow::onConnect);

    m_btnStart = new QPushButton("\xE2\x96\xB6 Start", this);
    m_btnStart->setEnabled(false);
    m_btnStart->setToolTip("Start recording");
    connect(m_btnStart, &QPushButton::clicked, this, &MainWindow::onStart);

    m_btnStop = new QPushButton("\xE2\x96\xA0 Stop", this);
    m_btnStop->setObjectName("btnDanger");
    m_btnStop->setEnabled(false);
    m_btnStop->setToolTip("Stop recording");
    connect(m_btnStop, &QPushButton::clicked, this, &MainWindow::onStop);

    m_btnDownload = new QPushButton("\xE2\xAC\x87 Download", this);
    m_btnDownload->setEnabled(false);
    m_btnDownload->setToolTip("Download recorded CSV");
    connect(m_btnDownload, &QPushButton::clicked, this, &MainWindow::onDownload);

    btnLayout->addWidget(m_btnConnect);
    btnLayout->addWidget(m_btnStart);
    btnLayout->addWidget(m_btnStop);
    btnLayout->addWidget(m_btnDownload);
    btnLayout->addStretch();

    // Status footer
    m_statusLabel = new QLabel("Ready", this);
    m_statusLabel->setObjectName("statusLabel");
    m_statusLabel->setStyleSheet("color: #888; font-size: 12px; padding: 2px;");

    mainLayout->addLayout(btnLayout);
    mainLayout->addWidget(m_statusLabel);
    setCentralWidget(centralWidget);

    logResponse("UI initialized. Connecting to broker...", "info");
}

#ifdef HAVE_MQTT

void MainWindow::setupMqtt()
{
    m_mqtt = new MqttClientWrapper("motor_gui_" + QString::number(QDateTime::currentMSecsSinceEpoch()));

    connect(m_mqtt, &MqttClientWrapper::connected, this, [this](bool connected) {
        m_btnConnect->setEnabled(!connected);
        m_btnStart->setEnabled(connected);
        m_btnStop->setEnabled(false);
        m_btnDownload->setEnabled(false);
        if (connected) {
            m_connectionIndicator->setText("\xE2\x97\x8F Connected");
            m_connectionIndicator->setStyleSheet("color: #00ff88; font-size: 13px; padding: 4px;");
            m_statusLabel->setText("Connected to broker at " MQTT_BROKER);
            logResponse("Connected to MQTT broker successfully.", "success");
            publishStatus("idle", "GUI connected");
        } else {
            m_connectionIndicator->setText("\xE2\x97\x8F Disconnected");
            m_connectionIndicator->setStyleSheet("color: #ff4444; font-size: 13px; padding: 4px;");
            m_statusLabel->setText("Disconnected");
            logResponse("Failed to connect to MQTT broker.", "error");
        }
    });

    connect(m_mqtt, &MqttClientWrapper::commandReceived, this, [this](const QString &cmd) {
        logResponse("Command received from recorder: " + cmd, "warning");
        if (cmd == "start") {
            m_btnStart->setEnabled(false);
            m_btnStop->setEnabled(true);
            m_btnDownload->setEnabled(true);
            publishStatus("recording", "Recording started by GUI");
            m_statusLabel->setText("Status: Recording");
            logResponse("Recorder confirmed: recording started.", "success");
        }
        else if (cmd == "stop") {
            m_btnStart->setEnabled(true);
            m_btnStop->setEnabled(false);
            m_btnDownload->setEnabled(true);
            publishStatus("stopped", "Recording stopped");
            m_statusLabel->setText("Status: Stopped");
            logResponse("Recorder confirmed: recording stopped.", "success");
        }
    });

    connect(m_mqtt, &MqttClientWrapper::dataReceived, this, [this](const QString &data) {
        QStringList parts = data.split(',');
        if (parts.size() == 13) {
            bool ok;
            m_currents[0] = parts[1].toDouble(&ok);
            m_currents[1] = parts[2].toDouble(&ok);
            m_currents[2] = parts[3].toDouble(&ok);
            m_currents[3] = parts[4].toDouble(&ok);
            m_currents[4] = parts[5].toDouble(&ok);
            m_currents[5] = parts[6].toDouble(&ok);
            m_currents[6] = parts[7].toDouble(&ok);
            m_currents[7] = parts[8].toDouble(&ok);
            m_vib[0] = parts[9].toDouble(&ok);
            m_vib[1] = parts[10].toDouble(&ok);
            m_vib[2] = parts[11].toDouble(&ok);
            m_rpm = parts[12].toUInt(&ok);
            for (int c = 0; c < 13; ++c)
                if (m_table->item(0, c))
                    m_table->item(0, c)->setText(parts[c]);
        }
    });

    QTimer::singleShot(100, this, [this] {
        logResponse("Attempting MQTT connection...", "info");
        m_mqtt->connect();
    });
}

#else

void MainWindow::setupMqtt()
{
    logResponse("MQTT library not available — running in demo mode.", "warning");
    m_connectionIndicator->setText("\xE2\x97\x8F Demo Mode");
    m_connectionIndicator->setStyleSheet("color: #ffaa00; font-size: 13px; padding: 4px;");
}

#endif

void MainWindow::onConnect()
{
#ifdef HAVE_MQTT
    m_btnConnect->setEnabled(false);
    m_btnConnect->setText("Connecting...");
    logResponse("Connecting to MQTT broker...", "info");
    bool ok = m_mqtt->connect();
    m_btnConnect->setText("\xE2\x94\xB7 Connect");
    if (ok)
        logResponse("Manual connect succeeded.", "success");
    else
        logResponse("Manual connect failed — check broker.", "error");
#else
    logResponse("Connect: MQTT not available.", "error");
#endif
}

void MainWindow::onDisconnect()
{
#ifdef HAVE_MQTT
    m_mqtt->disconnect();
    logResponse("Disconnected from broker.", "warning");
#else
    logResponse("Disconnect: MQTT not available.", "error");
#endif
}

void MainWindow::onStart()
{
#ifdef HAVE_MQTT
    m_mqtt->publishCommand("start");
    m_btnStart->setEnabled(false);
    m_btnStop->setEnabled(true);
    m_btnDownload->setEnabled(true);
    m_statusLabel->setText("Status: Starting recording...");
    logResponse("Sent START command to recorder.", "info");
#else
    logResponse("Start: MQTT not available.", "error");
#endif
}

void MainWindow::onStop()
{
#ifdef HAVE_MQTT
    m_mqtt->publishCommand("stop");
    m_btnStart->setEnabled(true);
    m_btnStop->setEnabled(false);
    m_btnDownload->setEnabled(true);
    m_statusLabel->setText("Status: Stopping recording...");
    logResponse("Sent STOP command to recorder.", "info");
#else
    logResponse("Stop: MQTT not available.", "error");
#endif
}

void MainWindow::onDownload()
{
#ifdef HAVE_MQTT
    QString filename = QFileDialog::getSaveFileName(
        this, "Save Recording",
        QDateTime::currentDateTime().toString("motor_YYYYMMdd_HHmmss") + ".csv",
        "CSV Files (*.csv)");
    if (!filename.isEmpty()) {
        m_mqtt->publishCommand("download " + filename);
        logResponse("Sent DOWNLOAD command — file: " + filename, "info");
        m_statusLabel->setText("Download requested...");
    } else {
        logResponse("Download cancelled by user.", "warning");
    }
#else
    logResponse("Download: MQTT not available.", "error");
#endif
}

void MainWindow::onPublishStatus()
{
#ifdef HAVE_MQTT
    static int tick = 0;
    tick++;
    if (m_mqtt && m_mqtt->isConnected() && tick % 10 == 0) {
        QString status = m_btnStop->isEnabled() ? "recording" : "idle";
        QTableWidgetItem *item = m_table->item(0, 12);
        QString rows = item ? item->text() : "0";
        publishStatus(status, QString("Rows: %1, RPM: %2").arg(rows).arg(m_rpm));
    }
#endif
}

void MainWindow::publishStatus(const QString &state, const QString &msg)
{
#ifdef HAVE_MQTT
    m_mqtt->publishStatus(state, msg);
#endif
}

void MainWindow::publishCommand(const QString &cmd)
{
#ifdef HAVE_MQTT
    m_mqtt->publishCommand(cmd);
#endif
}

#include "mainwindow.moc"
