#include "datacollectionapp.h"

#include <QUrl>

#include "appregistry.h"

namespace PdM {
namespace DataCollection {

void registerWithShell()
{
    /* The path a QML module's files land on: RESOURCE_PREFIX defaults to
       /qt/qml and the URI becomes the directory. It is not the qrc:/ path this
       app used before the port. */
    AppRegistry::instance()->setPage(
        QStringLiteral("data_collection"),
        QUrl(QStringLiteral("qrc:/qt/qml/PdM/DataCollection/DataCollectionPage.qml")));
}

} // namespace DataCollection
} // namespace PdM
