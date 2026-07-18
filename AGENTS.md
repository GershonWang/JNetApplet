# AGENTS.md

Guidance for AI agents working in this repo. Verified against `CMakeLists.txt`,
`package/metadata.json`, and the installed macro file at
`/usr/lib/x86_64-linux-gnu/cmake/DDEShell/DDEShellPackageMacros.cmake`.

## What this is

A **dde-shell applet** (deepin desktop shell panel widget) for network speed monitoring.
Uses a C++ backend (`NetworkMonitorApplet` class) for data collection and a QML frontend
for the UI. The C++ backend reads `/proc/net/dev` to monitor network traffic.

- Applet ID: `space.jokul.JNetApplet`.
- Root element of `networkview.qml` must be `AppletItem` from `import org.deepin.ds 1.0`.

## Features

- Real-time download/upload speed monitoring (1-second refresh)
- Total data transfer statistics
- Multiple network interface support with interface switching
- Taskbar icon displays live speed (changes color at high speeds)
- Hover tooltip shows speed summary
- Click to open detailed popup

## Build & install

Requires the `DDEShell` CMake package (from the `dde-shell` dev package) at configure
time. Standard flow:

```sh
cmake -B build
cmake --build build
sudo cmake --install build   # -> /usr/share/dde-shell/space.jokul.JNetApplet/
```

Or use the install script:

```sh
bash install.sh
```

`cmake --install` needs `sudo` because the default `DDE_SHELL_PACKAGE_INSTALL_DIR`
is `/usr/share/dde-shell` (a CMake CACHE variable on this system).

After installation, restart dde-shell:

```sh
systemctl --user restart dde-shell@DDE
```

There is no test, lint, typecheck, or CI target. Verification is manual: install,
then restart `dde-shell` (it discovers applets by scanning the install dir for
`metadata.json`).

## Project structure

```
├── CMakeLists.txt                 # Build configuration
├── install.sh                     # Install script
├── networkmonitorapplet.h         # C++ backend header
├── networkmonitorapplet.cpp       # C++ backend implementation
├── package/
│   ├── metadata.json              # Plugin metadata
│   └── networkview.qml            # QML UI
└── AGENTS.md                      # This file
```

## Architecture

```
┌──────────────────────────────────────────────────┐
│              DDE Shell Taskbar                   │
├──────────────────────────────────────────────────┤
│        space.jokul.JNetApplet                    │
│  ┌────────────────┐  ┌────────────────────────┐  │
│  │ C++ Backend    │  │ QML Frontend           │  │
│  │ NetworkMonitor │  │ networkview.qml        │  │
│  │ - /proc/net/dev│  │ - Speed display        │  │
│  │ - Speed calc   │  │ - Popup window         │  │
│  │ - Interface    │  │ - Interface switcher   │  │
│  └────────────────┘  └────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

## C++ Backend (NetworkMonitorApplet)

Inherits from `DApplet`, provides:
- `downloadSpeed` / `uploadSpeed`: Current speed in bytes/sec
- `totalDownload` / `totalUpload`: Total data transferred
- `networkInterfaces`: List of available interfaces
- `interfaceStats`: Per-interface statistics
- `activeInterface`: Currently selected interface
- `refresh()`: Manually trigger stats update
- `setActiveInterface(name)`: Switch active interface

## Identifier correspondence (keep in sync when renaming)

| Where | Field | Value |
|---|---|---|
| `CMakeLists.txt` | `add_library(...)` target | `space.jokul.JNetApplet` |
| `CMakeLists.txt` | `PLUGIN_ID` | `space.jokul.JNetApplet` |
| `package/metadata.json` | `Plugin.Id` | `space.jokul.JNetApplet` |

`Plugin.Url` (`networkview.qml`) is a path **relative to `package/`**, not an identifier.
Keep it pointing at the entry QML.

## Required metadata fields (QML applet)

`metadata.json` must contain `Plugin.Version`, `Plugin.Id`, `Plugin.Url`, and
`Plugin.Parent`. The current file is complete — don't drop any.

## Conventions

- QML files carry SPDX headers (`SPDX-FileCopyrightText` +
  `SPDX-License-Identifier: LGPL-3.0-or-later`). Preserve on new/edited QML files.
- C++ files carry SPDX headers (`SPDX-License-Identifier: LGPL-3.0-or-later`).
- Default branch is `master` (not `main`).
- QML property types must be QML-compatible (use `double`/`real` instead of `qint64`).