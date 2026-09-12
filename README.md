# JNetApplet

基于 dde-shell 的**深度系统任务栏网络速率监控插件**，使用 C++ 后端采集数据、
QML 前端渲染界面，实时显示当前网卡的上行/下行速率与累计流量。

- 插件 ID：`space.jokul.JNetApplet`
- 适用环境：deepin 桌面环境（dde-shell 面板）
- 数据源：读取 `/proc/net/dev` 计算网络流量

## 功能特性

- 实时上行/下行速率监控（刷新间隔可在设置中选 1/2/5 秒，按真实时间间隔计算）
- 本次会话累计上传/下载流量统计
- 多网卡支持，可在弹窗或设置窗口中切换活动网卡
- 任务栏图标实时显示速率，高速时变色提示
- 任务栏字体颜色可自定义，支持跟随系统主题
- 悬停显示速率摘要与网卡 IP 地址，点击展开详情弹窗
- 详情弹窗展示活动网卡 IPv4/IPv6 地址、各网卡速率对比与统计
- 流量波动图窗口：展示活动接口网速趋势（下载/上传双折线，1/5/30 分钟窗口可切换）
- 设置窗口：网络接口选择、字体颜色自定义、一键卸载插件
- 深色模式全适配（任务栏图标、弹窗、独立窗口均跟随系统主题）
- 所有接口后台持续采集速度历史，切换网卡时趋势图立即有数据

## 构建与安装

### 构建依赖

构建需要以下开发包：

```sh
sudo apt install build-essential cmake pkg-config qt6-base-dev qt6-declarative-dev qt6-tools-dev libdtk6core-dev libdtkcommon-dev libdtk6gui-dev libxkbcommon-dev libdde-shell-dev
```

各包与 CMake `find_package` 的对应关系：

| 依赖包 | 提供 | 对应 CMake find_package |
|---|---|---|
| qt6-base-dev | Qt6 Core / Network | Qt6 Core Network |
| qt6-declarative-dev | Qt6 Quick（Test 为可选组件） | Qt6 Quick、Qt6 Test（可选） |
| qt6-tools-dev | Qt6 LinguistTools（lrelease/lupdate） | Qt6 LinguistTools |
| libdtk6core-dev | Dtk6 Core 的库与 CMake 配置（Dtk6CoreConfig.cmake） | Dtk6 Core |
| libdtkcommon-dev | Dtk6 公共 CMake 配置（Dtk6Config.cmake） | 被 Dtk6 配置引用 |
| libdtk6gui-dev | Dtk6 Gui（DDEShell 间接依赖） | Dtk6Gui（由 DDEShellConfig.cmake find_dependency） |
| libxkbcommon-dev | XKB（DDEShell 间接依赖） | XKB（由 DDEShellConfig.cmake find_dependency） |
| libdde-shell-dev | DDEShell | DDEShell |

> 运行时仅需 `dde-shell` 及 Qt6/Dtk6 运行库，上述 `-dev` 包仅构建时需要。
>
> 上表按 Debian 系（含 deepin）的常规包内容整理；若你的发行版把这些 CMake
> 配置拆到别的包里，以 `dpkg -S /usr/lib/*/cmake/Dtk6Core/Dtk6CoreConfig.cmake`
> 之类的实际查询结果为准。

### 方式一：从源码安装

```sh
cmake -B build
cmake --build build
sudo cmake --install build   # -> /usr/share/dde-shell/space.jokul.JNetApplet/
```

或使用安装脚本：

```sh
bash install.sh
```

`cmake --install` 需要 `sudo`，因为默认 `DDE_SHELL_PACKAGE_INSTALL_DIR`
为 `/usr/share/dde-shell`（本机 CMake CACHE 变量）。

插件动态库的安装目录按系统 GNU 三元组自动适配，无需手工改路径：
amd64 装到 `/usr/lib/x86_64-linux-gnu/dde-shell`，arm64 装到
`/usr/lib/aarch64-linux-gnu/dde-shell`，loong64 装到
`/usr/lib/loongarch64-linux-gnu/dde-shell`。三元组由 CMake 在配置阶段通过
`dpkg --print-architecture` 推导，非 Debian 系回退 `CMAKE_LIBRARY_ARCHITECTURE`；
`install.sh` 的安装后校验沿用同一套规则。

安装后重启 dde-shell 使插件生效：

```sh
systemctl --user restart dde-shell@DDE
```

### 方式二：打包为 deb 安装

仓库提供 `build-deb.sh` 一键打包脚本，会从 `CMakeLists.txt` 读取版本号并构建 deb 包：

```sh
bash build-deb.sh
```

产物为 `jnetapplet_<version>_<arch>.deb`，可直接用 `dpkg -i` 安装。

## 验证

### 单元测试

`tests/` 下为基于 Qt Test 的单元测试，覆盖速度计算、负值钳制、总量累加、接口校验、
流量日志的累加/裁剪/损坏降级，以及 `iw` 与 `ss` 输出的解析逻辑：

```sh
cmake -B build
cmake --build build
ctest --output-on-failure
```

Qt6 Test 属于**可选**依赖：缺失时不会生成测试目标，`ctest` 会显示 0 个测试
——这只说明"测试未构建"，不代表"测试通过"。

### 手动验证

安装后重启 `dde-shell`（其通过扫描安装目录中的 `metadata.json` 发现插件）：

```sh
bash install.sh
systemctl --user restart dde-shell@DDE
```

仓库暂无 CI，QML 界面部分没有自动化检查，需人工确认显示与交互。

## 项目结构

```
├── CMakeLists.txt                          # 构建配置
├── install.sh                              # 安装脚本
├── build-deb.sh                            # deb 一键打包脚本
├── src/
│   ├── networkmonitorapplet.h              # C++ 后端头文件
│   └── networkmonitorapplet.cpp            # C++ 后端实现
├── package/
│   ├── metadata.json.in                   # 插件元数据模板（由 CMake 生成 metadata.json）
│   ├── networkview.qml                    # QML 界面主入口
│   └── components/                        # 拆分出的子组件
│       ├── NetCommon.qml                  # 公共颜色、格式化与接口排序函数
│       ├── WindowTheme.qml                # 独立窗口公共主题色
│       ├── TitleBar.qml                   # 独立窗口公共标题栏
│       ├── NetworkPopup.qml               # 左键弹窗内容（速度/总量/网卡切换）
│       ├── SettingsWindow.qml             # 设置窗口（接口选择/字体颜色/卸载）
│       ├── TrafficChartWindow.qml         # 流量波动图窗口（1/5/30 分钟趋势折线）
│       ├── TrafficStatsWindow.qml         # 流量统计窗口（按日/按月累计）
│       ├── TcpConnectionsWindow.qml       # TCP 连接清单窗口
│       ├── TextColorPicker.qml            # 字体颜色选择器
│       └── AboutWindow.qml                # 关于窗口
├── translations/                           # 中文翻译（.ts -> .qm）
├── tests/                                  # Qt Test 单元测试
├── docs/                                   # 设计文档与审查清单
├── README.md                               # 本文件
└── AGENTS.md                               # AI 代理工作指引
```
