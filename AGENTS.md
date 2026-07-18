# AGENTS.md

Guidance for AI agents working in this repo. Verified against `CMakeLists.txt`,
`package/metadata.json`, and the installed macro file at
`/usr/lib/x86_64-linux-gnu/cmake/DDEShell/DDEShellPackageMacros.cmake`.

## What this is

A **pure-QML dde-shell applet** (deepin desktop shell panel widget). There is no
C++ and no `.so` plugin — the entire applet is `package/main.qml` +
`package/metadata.json`, installed as a data package via dde-shell's CMake macros.

- Applet ID: `space.jokul.JNetApplet`.
- Root element of `main.qml` must be `AppletItem` from `import org.deepin.ds 1.0`.

## Build & install

Requires the `DDEShell` CMake package (from the `dde-shell` dev package) at configure
time. Standard flow:

```sh
cmake -B build
cmake --build build
sudo cmake --install build   # -> /usr/share/dde-shell/space.jokul.JNetApplet/
```

`cmake --install` needs `sudo` because the default `DDE_SHELL_PACKAGE_INSTALL_DIR`
is `/usr/share/dde-shell` (a CMake CACHE variable on this system). For a user-local
install instead:

```sh
cmake -B build -DCMAKE_INSTALL_PREFIX=$HOME/.local
cmake --build build && cmake --install build   # -> ~/.local/share/dde-shell/space.jokul.JNetApplet/
```

There is no test, lint, typecheck, or CI target. Verification is manual: install,
then restart `dde-shell` (it discovers applets by scanning the install dir for
`metadata.json`). The build also stages a copy at `build/packages/space.jokul.JNetApplet/`
for previewing the QML without installing.

## Identifier correspondence (keep in sync when renaming)

| Where | Field | Value |
|---|---|---|
| `CMakeLists.txt` | `ds_install_package(PACKAGE …)` | `space.jokul.JNetApplet` |
| `package/metadata.json` | `Plugin.Id` | `space.jokul.JNetApplet` |

The CMake `PACKAGE` becomes the install subdirectory name; `Plugin.Id` is the runtime
identifier. They don't technically have to match, but every official dde-shell applet
keeps them identical — treat them as required to match.

`Plugin.Url` (`main.qml`) is a path **relative to `package/`**, not an identifier.
Keep it pointing at the entry QML.

## Required metadata fields (QML applet)

`metadata.json` must contain `Plugin.Version`, `Plugin.Id`, and `Plugin.Url`. The
current file is complete — don't drop any. (`Plugin.Url` is omitted only for
widget-based, non-QML plugins.)

## Package layout is fixed by the macro

`ds_install_package` reads `package/` relative to `CMAKE_CURRENT_SOURCE_DIR` by
default (overridable via `PACKAGE_ROOT_DIR`, not used here). Keep the directory named
`package/` with `metadata.json` at its root.

## Adding translations (not yet set up)

If i18n is needed, use the `ds_handle_package(PACKAGE <id>)` macro from the same
DDEShell package. It expects `.ts` files at `translations/<id>_<lang>.ts` and
installs compiled `.qm` to `${DDE_SHELL_TRANSLATION_INSTALL_DIR}/<id>/translations/`.
Do not invent a different translation workflow.

## Conventions

- QML files carry SPDX headers (`SPDX-FileCopyrightText` +
  `SPDX-License-Identifier: LGPL-3.0-or-later`). Preserve on new/edited QML files.
- Default branch is `master` (not `main`).
