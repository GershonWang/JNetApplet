# AGENTS.md

Guidance for AI agents working in this repo. Verified against `CMakeLists.txt`,
`package/metadata.json.in`, and the installed macro file at
`/usr/lib/<triplet>/cmake/DDEShell/DDEShellPackageMacros.cmake`
(`x86_64-linux-gnu` on amd64; see "Build & install").

## What this is

A **dde-shell applet** (deepin desktop shell panel widget) for network speed monitoring.
Uses a C++ backend (`NetworkMonitorApplet` class) for data collection and a QML frontend
for the UI. The C++ backend reads `/proc/net/dev` to monitor network traffic.

- Applet ID: `space.jokul.JNetApplet`.
- Root element of `networkview.qml` must be `AppletItem` from `import org.deepin.ds 1.0`.

## Features

- Real-time download/upload speed monitoring (1-second refresh, real elapsed time)
- Session cumulative download/upload traffic statistics
- Multiple network interface support with interface switching (popup + settings)
- Taskbar icon displays live speed (changes color at high speeds)
- Customizable taskbar font color (follow system theme or pick from preset)
- Hover tooltip shows interface name + IP address
- Click to open detailed popup (speed, totals, interface chips)
- Popup shows active interface IPv4/IPv6 address
- Traffic chart window: 5-minute speed trend (download/upload dual line chart)
- Settings window: interface selection, font color picker, one-click uninstall
- Full dark mode support (taskbar icon, popup, all independent windows)
- All interfaces sampled in background; switching interfaces shows history immediately

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

The plugin shared library installs to `/usr/lib/${_GNU_TRIPLET}/dde-shell/`, where
the GNU triplet is derived at configure time from `dpkg --print-architecture`
(amd64 -> `x86_64-linux-gnu`, arm64 -> `aarch64-linux-gnu`,
loong64 -> `loongarch64-linux-gnu`), falling back to `CMAKE_LIBRARY_ARCHITECTURE`
and then `x86_64-linux-gnu`. `install.sh` mirrors the same detection for its
post-install verification output.

### Deb packaging

`build-deb.sh` builds a `.deb` from the version declared in `CMakeLists.txt`:

```sh
bash build-deb.sh   # -> jnetapplet_<version>_<arch>.deb
```

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
├── build-deb.sh                   # Deb packaging script
├── src/
│   ├── networkmonitorapplet.h     # C++ backend header
│   └── networkmonitorapplet.cpp   # C++ backend implementation
├── package/
│   ├── metadata.json.in           # Plugin metadata 模板（由 CMake 生成 metadata.json）
│   ├── networkview.qml            # QML UI 主入口
│   └── components/                # 拆分出的子组件
│       ├── NetCommon.qml          # 公共颜色与格式化函数
│       ├── NetworkPopup.qml       # 左键弹窗内容
│       ├── SettingsWindow.qml     # 设置窗口（接口/颜色/卸载）
│       ├── TrafficChartWindow.qml # 流量波动图窗口
│       ├── TextColorPicker.qml    # 字体颜色选择器
│       └── AboutWindow.qml        # 关于窗口
├── docs/                          # Design docs and review checklist
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
- `downloadSpeed` / `uploadSpeed`: Current speed in bytes/sec (real elapsed time)
- `totalDownload` / `totalUpload`: Session cumulative traffic
- `networkInterfaces`: List of available interfaces
- `activeInterface`: Currently selected interface (persisted to `~/.config/jnetapplet/settings.ini`)
- `ipAddress` / `ipv6Address`: IP address of the active interface
- `version`: Plugin version (from metadata, fallback to `PROJECT_VERSION` macro)
- `textColor`: Taskbar font color (empty = follow system theme, persisted)
- `speedHistoryDownload` / `speedHistoryUpload`: Per-interface speed history (QPointF list, 5-min window)
- `setActiveInterface(name)`: Switch active interface (validates against interface list)
- `refresh()`: Internal timer callback (not Q_INVOKABLE, called by m_refreshTimer every second)

## Identifier correspondence (keep in sync when renaming)

| Where | Field | Value |
|---|---|---|
| `CMakeLists.txt` | `add_library(...)` target | `space.jokul.JNetApplet` |
| `CMakeLists.txt` | `PLUGIN_ID` | `space.jokul.JNetApplet` |
| `package/metadata.json.in` | `Plugin.Id` | `space.jokul.JNetApplet` |

`Plugin.Url` (`networkview.qml`) is a path **relative to `package/`**, not an identifier.
Keep it pointing at the entry QML.

## Required metadata fields (QML applet)

`package/metadata.json.in` is the template; CMake's `configure_file()` generates the
final `metadata.json` in the build directory at configure time. The template must
contain `Plugin.Version`, `Plugin.Id`, `Plugin.Url`, and `Plugin.Parent`. Don't drop any.

## Version management

**Single source of truth**: `CMakeLists.txt` line 3 `project(JNetApplet VERSION x.y.z)`.

- `package/metadata.json.in` uses `@PROJECT_VERSION@` placeholder, substituted at
  configure time -> installed `metadata.json` always matches.
- `build-deb.sh` extracts the version directly from `CMakeLists.txt` via grep.
- **To bump the version**: edit only the `project(... VERSION ...)` line in
  `CMakeLists.txt`. All downstream consumers (install, deb) pick it up automatically.

## Conventions

- QML files carry SPDX headers (`SPDX-FileCopyrightText` +
  `SPDX-License-Identifier: LGPL-3.0-or-later`). Preserve on new/edited QML files.
- C++ files carry SPDX headers (`SPDX-License-Identifier: LGPL-3.0-or-later`).
- Default branch is `master` (not `main`).
- QML property types must be QML-compatible (use `double`/`real` instead of `qint64`).