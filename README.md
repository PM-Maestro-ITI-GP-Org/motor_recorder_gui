# Motor Recorder GUI

Qt/QML desktop GUI for the **Motor Data Recorder** system. It connects to an MQTT
broker to control a QNX-based recorder (start/stop recording), watch live motor
data, download recorded CSV files, and plot them.

```
┌─────────────────┐      MQTT (139.185.38.211:1883)      ┌──────────────────────┐
│  motor_recorder │  ───────────────────────────────────> │  motor_recorder_gui  │
│   (QNX VM)      │  <── topics: cmd, download ────────  │      (Laptop)        │
└─────────────────┘                                       └──────────────────────┘
```

## Features

- MQTT connection with automatic retry / reconnect (retries until the broker is reachable)
- Start / Stop recording with optional auto-stop duration
- Live motor data table (13 channels: 8 currents, vib X/Y/Z, RPM)
- File manager: list, refresh, select, download, delete recordings on the recorder
- CSV downloads saved into a user-selected directory (in-window folder picker)
- Graph viewer: load CSV files from the download directory, select columns to plot,
  plot a time range, reset to the full range

## Prerequisites

### 1. Qt 6.10.2 (Desktop gcc_64)

The app is built against **Qt 6.10.2 for Linux (gcc_64)**, installed manually with
the **Qt Online Installer**. The system Qt packages from Ubuntu (`qt6-base-dev`,
6.2.4) are **not** sufficient — the app uses `Qt.labs.folderlistmodel` and other
Qt Quick modules only shipped with a full Qt install.

1. Download the Qt Online Installer from: https://www.qt.io/download
2. Run it, sign in, and install **Qt 6.10.2 → Desktop Linux → gcc_64**.
   (Select the default modules: Qt Quick, Qt Quick Controls, Qt Quick Dialogs.)
3. After installation the Qt root is at `/home/<user>/Qt/6.10.2/gcc_64`
   (the CMake config lives at `<root>/lib/cmake/Qt6`).

If your install path differs, update the Qt location before building:

```bash
export QT_ROOT=/home/<user>/Qt/6.10.2/gcc_64
```

### 2. Paho MQTT C client

The app uses the Eclipse Paho MQTT C library (`MQTTClient.h`, `libpaho-mqtt3c`).

Ubuntu/Debian:

```bash
sudo apt update
sudo apt install libpaho-mqtt-dev
```

> If the library is missing the app still builds and runs in **demo mode**
> (no MQTT), so a build without it will succeed but cannot connect.

### 3. Build tools and Qt rendering dependencies

```bash
sudo apt update
sudo apt install build-essential cmake ninja-build \
                 libgl1-mesa-dev libvulkan-dev \
                 libxkbcommon-x11-0 libxcb-xinerama0 \
                 libxcb-cursor0 libxcb-icccm4 libxcb-keysyms1 \
                 libxcb-shape0 libxcb-render-util0
```

## Build

```bash
cd /media/gemy/Extra/ITI_GP/motor_recorder_gui

# Configure (Qt 6.10.2 must be found)
cmake -B build -DCMAKE_PREFIX_PATH=/home/gemy/Qt/6.10.2/gcc_64 -DCMAKE_BUILD_TYPE=Release

# Build
cmake --build build --target motor_gui -j$(nproc)
```

The binary is produced at `build/motor_gui`.

### Rebuild after changes

```bash
cmake --build build --target motor_gui -j$(nproc)
```

### Clean rebuild

```bash
rm -rf build
cmake -B build -DCMAKE_PREFIX_PATH=/home/gemy/Qt/6.10.2/gcc_64 -DCMAKE_BUILD_TYPE=Release
cmake --build build --target motor_gui -j$(nproc)
```

## Run

```bash
./build/motor_gui
```

The GUI connects to the broker automatically on startup
(`tcp://139.185.38.211:1883`). If the broker is unreachable it keeps retrying.

## Usage

1. **Connect** — auto-connects on startup; the status badge shows Connected/Disconnected.
2. **Start** — opens a dialog to set an optional recording name and duration (0 = manual stop).
3. **Stop** — stops recording; metadata (rows, drops, span) is shown.
4. **Files** — lists recordings on the device. Select files, then
   **Download Selected** (saved to the directory shown at the bottom) or
   **Delete Selected**.
5. **Browse** — pick the save directory with the in-window folder picker.
6. **Graphs** — shows CSV files from the save directory (and downloaded ones).
   Use the file dropdown, pick columns from the right-hand panel, set a row
   range with From/To, and use **Reset** to show the full time range.

## MQTT Topics

| Topic | Direction | Format | Description |
|-------|-----------|--------|-------------|
| `guest/rpi5guest1/status` | Recorder → GUI | JSON `{"state":"idle\|recording\|stopped","msg":"..."}` | Status updates |
| `guest/rpi5guest1/cmd` | GUI → Recorder | `start`, `start <name> [sec]`, `stop`, `list`, `upload <file>`, `download <file>`, `delete <file>` | Commands |
| `guest/rpi5guest1/data` | Recorder → GUI | CSV: `timestamp,C0..C7,VibX,VibY,VibZ,RPM` | Live data rows |
| `guest/rpi5guest1/download` | Recorder → GUI | JSON `{"chunk":N,"total":N,"data":"..."}` | CSV download chunks |

Credentials (in `mqttclient.cpp`): user `mqttuser`, password `123456`.

## Project Structure

- `main.cpp` — entry point, registers the `MqttClient` QML type
- `main.qml` — the whole UI (dashboard, file manager, folder picker, graph view)
- `mqttclient.h` / `mqttclient.cpp` — MQTT wrapper (Paho), file helpers, reconnect logic
- `CMakeLists.txt` — build configuration (finds Qt 6.10.2 + Paho)

## Troubleshooting

### `Could not find a package configuration file provided by "Qt6"`
Qt 6.10.2 is not installed or `CMAKE_PREFIX_PATH`/`Qt6_DIR` points to the wrong path.
Install Qt 6.10.2 via the Qt Online Installer and pass
`-DCMAKE_PREFIX_PATH=/home/<user>/Qt/6.10.2/gcc_64`.

### Builds but shows "MQTT not available — running in demo mode"
The Paho MQTT C library is missing. Install it: `sudo apt install libpaho-mqtt-dev`.

### `Qt platform plugin "xcb" could not be loaded`
Missing X11 runtime libraries for Qt. Install the `libxcb-*` packages listed above.

### Graph shows no data
- Confirm the save directory contains `.csv` files (check the path shown next to Browse).
- Confirm the CSV rows have 13 columns (the parser skips malformed rows).
- Open Graphs again after choosing the directory.

### Folder picker doesn't open
The picker is a QML dialog, not a native OS dialog, so it works on both X11 and
Wayland. If nothing appears, check the console output for a "FolderDialog opened" log.
