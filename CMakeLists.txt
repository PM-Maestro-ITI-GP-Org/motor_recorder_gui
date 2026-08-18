#
# motor_recorder_gui -- the data collection app.
#
# Builds two ways and both matter:
#
#   * on its own, as it always has: cmake -B build && ./build/motor_gui
#   * as a library inside PdM-Maestro_gui, where it becomes the first tab
#
# The split is the library below plus a main() that is only compiled when this
# repository is the top-level project. See docs/INTEGRATION_CONTRACT.md in the
# Maestro repo for the rules and the breakage each one prevents.
#
cmake_minimum_required(VERSION 3.21)

project(MotorGUI
    VERSION 0.2.0
    DESCRIPTION "Motor data recorder"
    LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 6.5, up from the unversioned find_package this used to do. The QML module
# machinery below (qt_add_qml_module, loadFromModule, static plugin handling)
# wants it, and the system Qt 6.2.4 will no longer do -- point CMake at a newer
# one the normal way:
#
#   cmake -B build -DCMAKE_PREFIX_PATH=$HOME/Qt/6.10.3/gcc_64
#
find_package(Qt6 6.5 REQUIRED COMPONENTS Quick Qml Network Widgets QuickControls2)

qt_standard_project_setup(REQUIRES 6.5)

# The palette, message bus and app registry. Carried as a submodule so this repo
# still builds when cloned on its own; the guard is what stops it being added a
# second time inside a Maestro build, where Maestro has already added its own
# pinned copy and both would claim the PdM.Core module URI.
if(NOT TARGET pdm_core)
    add_subdirectory(core)
endif()

# Find Paho MQTT C library
find_path(PAHO_MQTT_INCLUDE_DIR MQTTClient.h)
find_library(PAHO_MQTT_LIBRARY NAMES paho-mqtt3c paho-mqtt3a)

if(NOT PAHO_MQTT_INCLUDE_DIR OR NOT PAHO_MQTT_LIBRARY)
    message(WARNING "Paho MQTT C library not found — building without MQTT")
    set(WITH_MQTT OFF)
else()
    set(WITH_MQTT ON)
endif()

#
# ---- the app, as a library --------------------------------------------------
#
qt_add_library(pdm_datacollection STATIC)

# The QML lives at the repository root rather than under qml/, which keeps every
# file a first-class type of the module. A subdirectory would need its own
# generated qmldir (policy QTP0004) and resolve under a sub-namespace.
#
# Main.qml is deliberately NOT in this list -- it belongs to the standalone
# executable's module further down. A file that imports PdM.DataCollection
# cannot also be a member of it.
qt_add_qml_module(pdm_datacollection
    URI PdM.DataCollection
    VERSION 1.0
    SOURCES
        mqttclient.h
        mqttclient.cpp
        traceview.h
        traceview.cpp
        datacollectionapp.h
        datacollectionapp.cpp
    QML_FILES
        DataCollectionPage.qml
        AppCard.qml
        FilledButton.qml
        MaterialField.qml
        StatusPill.qml
)

# Widgets because mqttclient.cpp opens a QFileDialog for the download
# destination. That is also why Maestro's shell has to construct a QApplication
# rather than a QGuiApplication -- the widest application object any tab needs
# is the one the whole process gets.
# So the shell can reach datacollectionapp.h to call registerWithShell().
target_include_directories(pdm_datacollection PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
)

target_link_libraries(pdm_datacollection PUBLIC
    pdm_core
    Qt6::Quick
    Qt6::Qml
    Qt6::Network
    Qt6::Widgets
    Qt6::QuickControls2
)

if(WITH_MQTT)
    target_include_directories(pdm_datacollection PRIVATE ${PAHO_MQTT_INCLUDE_DIR})
    target_link_libraries(pdm_datacollection PRIVATE ${PAHO_MQTT_LIBRARY})
    target_compile_definitions(pdm_datacollection PRIVATE HAVE_MQTT)
endif()

#
# ---- the standalone app -----------------------------------------------------
#
# Not compiled when Maestro pulls this repository in with add_subdirectory():
# there, PROJECT_IS_TOP_LEVEL is false and the shell owns the only main().
#
if(PROJECT_IS_TOP_LEVEL)
    qt_add_executable(motor_gui main.cpp)

    # Its own module, so Main.qml can import PdM.DataCollection without the
    # circularity of being a member of the module it imports.
    qt_add_qml_module(motor_gui
        URI MotorGuiApp
        VERSION 1.0
        QML_FILES Main.qml
    )

    # Both halves of each static QML module: the library carries the types, the
    # plugin carries the registration that Q_IMPORT_QML_PLUGIN in main.cpp
    # refers to. Linking only the libraries fails at link time; omitting the
    # macros builds clean and fails at run time with a missing type.
    target_link_libraries(motor_gui PRIVATE
        pdm_datacollection
        pdm_datacollectionplugin
        pdm_core
        pdm_coreplugin
    )

    install(TARGETS motor_gui RUNTIME DESTINATION bin)
endif()
