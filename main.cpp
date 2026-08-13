#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QtQml>
#include "mqttclient.h"
#include "traceview.h"

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);

    /* Material, chosen before the engine loads -- QQuickStyle is ignored once
       the first Controls type has been instantiated. */
    QQuickStyle::setStyle("Material");

    qmlRegisterType<MqttClient>("MqttClient", 1, 0, "MqttClient");
    /* GPU-rendered trace plot; see traceview.h for why the Canvas
       it replaces could not keep up. */
    qmlRegisterType<TraceView>("MqttClient", 1, 0, "TraceView");

    /* Theme is a singleton so every file refers to the same palette instead of
       repeating literals. Registered here rather than with a qmldir, which
       would need the QML to live outside the resource bundle. */
    qmlRegisterSingletonType(QUrl("qrc:/Theme.qml"), "App", 1, 0, "Theme");

    QQmlApplicationEngine engine;

    /*
     * A QML error used to be completely silent: engine.load() returned, main()
     * returned app.exec(), and the user got a process with no window and no
     * message. Both halves are reported now -- objectCreated with a null object
     * catches a failure during creation, and the empty-rootObjects check catches
     * a file that could not be parsed at all. (objectCreationFailed would say
     * the same thing more directly, but it needs Qt 6.4; this builds on 6.2.)
     */
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [](QObject *obj, const QUrl &) {
                         if (!obj) {
                             fprintf(stderr, "[GUI] FATAL: QML object creation failed\n");
                             QCoreApplication::exit(1);
                         }
                     }, Qt::QueuedConnection);

    engine.load(QUrl("qrc:/main.qml"));
    if (engine.rootObjects().isEmpty()) {
        fprintf(stderr, "[GUI] FATAL: main.qml failed to load — no window\n");
        return 1;
    }

    return app.exec();
}
