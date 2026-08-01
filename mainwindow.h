#ifndef MAINWINDOW_H
#define MAINWINDOW_H

#include <QMainWindow>
#include <QTableWidget>
#include <QPushButton>
#include <QLabel>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QGroupBox>
#include <QTimer>
#include <QVector>
#include <QTextEdit>

#ifdef HAVE_MQTT
class MqttClientWrapper;
#endif

class MainWindow : public QMainWindow
{
    Q_OBJECT

public:
    MainWindow(QWidget *parent = nullptr);
    ~MainWindow();

private slots:
    void onConnect();
    void onDisconnect();
    void onStart();
    void onStop();
    void onDownload();
    void onPublishStatus();

private:
    void setupUI();
    void setupStyle();
    void setupMqtt();
    void publishStatus(const QString &state, const QString &msg);
    void publishCommand(const QString &cmd);
    void logResponse(const QString &msg, const QString &type = "info");

    QTableWidget *m_table;
    QPushButton *m_btnConnect;
    QPushButton *m_btnStart;
    QPushButton *m_btnStop;
    QPushButton *m_btnDownload;
    QLabel *m_statusLabel;
    QLabel *m_connectionIndicator;
    QTextEdit *m_logArea;

#ifdef HAVE_MQTT
    MqttClientWrapper *m_mqtt;
#endif

    QVector<double> m_currents;
    QVector<double> m_vib;
    double m_rpm;

    QTimer *m_refreshTimer;
};

#endif
