cmake_minimum_required(VERSION 3.16)
project(MotorGUI)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# Qt6_DIR was hardcoded to /home/gemy/Qt/... -- one developer's home directory,
# which meant the build worked on exactly one machine and failed everywhere else
# with a "Qt6 not found" that pointed at the wrong problem. Pass the location in
# the normal way instead:
#
#   cmake -B build -DCMAKE_PREFIX_PATH=/path/to/Qt/6.x/gcc_64
#
find_package(Qt6 REQUIRED COMPONENTS Quick Qml Network Widgets QuickControls2)

# Find Paho MQTT C library
find_path(PAHO_MQTT_INCLUDE_DIR MQTTClient.h)
find_library(PAHO_MQTT_LIBRARY NAMES paho-mqtt3c paho-mqtt3a)

if(NOT PAHO_MQTT_INCLUDE_DIR OR NOT PAHO_MQTT_LIBRARY)
    message(WARNING "Paho MQTT C library not found — building without MQTT")
    set(WITH_MQTT OFF)
else()
    set(WITH_MQTT ON)
    include_directories(${PAHO_MQTT_INCLUDE_DIR})
endif()

# mainwindow.cpp/.h are gone: a second, complete, QWidget-based UI that was
# never in this list and never referenced from anywhere, so it had never been
# compiled. Two UIs for one app, one of them dead, is a trap for whoever reads
# this next. It is in the git history if it is ever wanted.
add_executable(motor_gui
    main.cpp
    mqttclient.h
    mqttclient.cpp
    traceview.h
    traceview.cpp
)

target_link_libraries(motor_gui PRIVATE
    Qt6::Quick
    Qt6::Qml
    Qt6::Network
    Qt6::Widgets
    Qt6::QuickControls2
)

if(WITH_MQTT)
    target_link_libraries(motor_gui PRIVATE ${PAHO_MQTT_LIBRARY})
    target_compile_definitions(motor_gui PRIVATE HAVE_MQTT)
endif()

qt6_add_resources(motor_gui "resources"
    PREFIX "/"
    FILES
        main.qml
        Theme.qml
        AppCard.qml
        FilledButton.qml
        MaterialField.qml
        StatusPill.qml
)

install(TARGETS motor_gui RUNTIME DESTINATION bin)
