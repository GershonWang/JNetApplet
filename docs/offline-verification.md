# 在缺少 deepin 构建环境时验证本项目

> 记录日期：2026-11-14
> 适用场景：当前开发环境（容器）里没有 `g++`/`make`/Qt6/lrelease，但需要真实
> 编译并运行单元测试，而不是只做静态阅读。

## 背景

项目依赖 DDEShell / DTK6，二者只在 deepin 仓库提供，GitHub 托管 runner 装不上，
本容器也没有安装。这导致一个常见误区："无法编译所以只能靠读代码"。

实际上宿主机的根文件系统在容器内可读（`/run/host/rootfs`），其中包含完整的
`g++`、Qt 6.8、Dtk6、DDEShell。**它的库文件可以被容器内的进程直接链接和运行**，
只需注意两点：

1. **不要** 把 `/run/host/rootfs/usr/lib/x86_64-linux-gnu` 整体加进
   `LD_LIBRARY_PATH`——那会让进程加载宿主的 `libc.so.6`，与容器的 glibc 混用后
   表现为 `*** stack smashing detected ***`（连 `ldd` 都会崩）。
   正确做法是把**需要的库逐个**软链到一个独立目录（见下）。
2. `/tmp` 在不同工具间不共享，构建目录一律放在工作区内（已在 `.gitignore` 忽略）。

## 可复现步骤

### 1. 配置（用容器内 cmake + 宿主编译器）

```sh
cmake -B .verify-build -S . -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH=/run/host/rootfs/usr \
      -DCMAKE_CXX_COMPILER=/run/host/rootfs/usr/bin/g++
```

配置成功时会打印实际安装位置，应形如：

```
-- JNetApplet 安装位置：插件 /usr/lib/x86_64-linux-gnu/dde-shell，资源 /usr/share/dde-shell/space.jokul.JNetApplet
```

### 2. 收集运行期库（关键：排除 libc）

```sh
R=/run/host/rootfs/usr/lib/x86_64-linux-gnu
mkdir -p .verify-libs && cd .verify-libs
for f in libQt6Test.so.6 libQt6Core.so.6 libQt6Gui.so.6 libQt6Network.so.6 \
         libQt6Qml.so.6 libQt6Quick.so.6 libQt6QuickTemplates2.so.6 \
         libQt6QuickControls2.so.6 libQt6OpenGL.so.6 libQt6Xml.so.6 libQt6DBus.so.6 \
         libQt6QmlModels.so.6 libQt6QmlMeta.so.6 libQt6QmlWorkerScript.so.6 \
         libdtk6core.so.6 libdtk6gui.so.6 libdtk6log.so.0 \
         libspdlog.so.1.12 libdouble-conversion.so.3 libwayland-client.so.0 \
         libQt6WaylandClient.so.6 libmd4c.so.0 libb2.so.1 libfmt.so.10; do
  [ -e "$R/$f" ] && ln -sf "$R/$f" .
done
# dde-shell 的 SONAME 是 libdde-shell.so.1，实体是 .so.2.0.61
ln -sf $R/libdde-shell.so.2.0.61 libdde-shell.so.1
```

### 3. 编译

`cmake --build` 的编译阶段正常，但**链接阶段会失败**：宿主的 `libdtk6log` /
`libdde-shell` 自身依赖（`spdlog` 符号、Wayland 私有 API）在此环境下解析不到。
处理方式是手工用 `--allow-shlib-undefined` 链接一次，产物可直接运行
（运行时这些符号并不被实际调用）：

```sh
R=/run/host/rootfs/usr/lib/x86_64-linux-gnu
cd .verify-build
/run/host/rootfs/usr/bin/g++ -O3 -DNDEBUG \
  CMakeFiles/tst_networkmonitorapplet.dir/tst_networkmonitorapplet_autogen/mocs_compilation.cpp.o \
  CMakeFiles/tst_networkmonitorapplet.dir/tests/tst_networkmonitorapplet.cpp.o \
  CMakeFiles/tst_networkmonitorapplet.dir/src/networkmonitorapplet.cpp.o \
  -o tst_networkmonitorapplet -Wl,--allow-shlib-undefined \
  $R/libQt6Test.so.6.8.0 $R/libdde-shell.so.2.0.61 $R/libQt6Quick.so.6.8.0 \
  $R/libQt6Qml.so.6.8.0 $R/libQt6OpenGL.so.6.8.0 $R/libdtk6gui.so.6.7.52 \
  $R/libQt6Network.so.6.8.0 $R/libdtk6core.so.6.7.52 $R/libQt6Xml.so.6.8.0 \
  $R/libdtk6log.so.0.7.52 $R/libQt6Gui.so.6.8.0 $R/libQt6DBus.so.6.8.0 \
  $R/libQt6Core.so.6.8.0 $R/libspdlog.so.1.12 $R/libdouble-conversion.so.3 \
  $R/libwayland-client.so.0 $R/libQt6WaylandClient.so.6
```

### 4. 运行

Qt 需要平台插件；`offscreen` 插件在宿主 Qt 里，需显式指路：

```sh
export LD_LIBRARY_PATH="$PWD/.verify-libs"
export QT_QPA_PLATFORM=offscreen
export QT_PLUGIN_PATH=/run/host/rootfs/usr/lib/x86_64-linux-gnu/qt6/plugins
./tst_networkmonitorapplet
```

预期结尾：

```
Totals: 63 passed, 0 failed, 0 skipped, 0 blacklisted, 31ms
```

## 已知限制（本环境下无法验证）

| 项目 | 原因 |
|---|---|
| 翻译 `.qm` 生成与加载 | 宿主 `lrelease` 在本沙箱内崩溃（栈损坏），`ctest` 未覆盖该链路 |
| `ctest` 直接驱动 | 链接阶段依赖同上，需按第 3 步手工链接 |
| QML 渲染与交互 | 无 dde-shell 运行环境；只能用 `qmllint` 检查语法 |
| 断连态、竖向任务栏、窗口位置等真机行为 | 需在真实 deepin 会话中人工确认 |

## 其他可用工具

- `qmllint`（宿主 Qt 6.8）：`qmllint -I /run/host/rootfs/usr/lib/x86_64-linux-gnu/qt6/qml <file>`
  —— 会因缺 `org.deepin.dtk` 产生大量 import 告警，只有
  `Syntax error` / `Expected token` / `Unable to assign` / `is not a type`
  这几类才是真问题。
- `lupdate`：宿主版本缺 `libclang-cpp` 符号，**不可用**；翻译同步改用
  `python3 scripts/check-translations.py`。
