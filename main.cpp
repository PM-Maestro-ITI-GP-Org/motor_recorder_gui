#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QtQml/qqmlextensionplugin.h>

/*
 * The standalone entry point, and only that.
 *
 * Maestro does not compile this file -- see PROJECT_IS_TOP_LEVEL in
 * CMakeLists.txt -- so nothing here may be load-bearing for the app itself.
 * Everything that used to live here and matters to both builds has moved:
 * the qmlRegisterType() calls are now QML_ELEMENT in mqttclient.h and
 * traceview.h, and the Theme singleton comes from PdM.Core.
 */

/* Static QML modules need an explicit import from the executable that links
   them. Without these the types resolve at build time and are missing at run
   time, which presents as "DataCollectionPage is not a type" from a file that
   plainly imports the module. */
Q_IMPORT_QML_PLUGIN(PdM_CorePlugin)
Q_IMPORT_QML_PLUGIN(PdM_DataCollectionPlugin)

int main(int argc, char *argv[])
{
    /* QApplication, not QGuiApplication: mqttclient.cpp opens a QFileDialog. */
    QApplication app(argc, argv);

    /* Read by QSettings, which is how PdM.Core's BrokerSettings persists the
       MQTT endpoint. The organisation is shared with Maestro on purpose, so a
       broker set in one is the broker the other uses. */
    app.setOrganizationName("PM-Maestro-ITI-GP-Org");
    app.setApplicationName("Motor Data Recorder");

    /* Material, chosen before the engine loads -- QQuickStyle is ignored once
       the first Controls type has been instantiated. */
    QQuickStyle::setStyle("Material");

    QQmlApplicationEngine engine;

    /*
     * A QML error used to be completely silent: engine.load() returned, main()
     * returned app.exec(), and the user got a process with no window and no
     * message. objectCreationFailed reports it directly; it needs Qt 6.4, which
     * the 6.5 floor in CMakeLists.txt now guarantees.
     */
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, []() {
                         fprintf(stderr, "[GUI] FATAL: QML object creation failed\n");
                         QCoreApplication::exit(1);
                     }, Qt::QueuedConnection);

    engine.loadFromModule("MotorGuiApp", "Main");

    return app.exec();
}
