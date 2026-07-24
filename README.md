# JNetApplet

基于 dde-shell 的**深度系统任务栏网络速率监控插件**，使用 C++ 后端采集数据、
QML 前端渲染界面，实时显示当前网卡的上行/下行速率与累计流量。

- 插件 ID：`space.jokul.JNetApplet`
- 适用环境：deepin 桌面环境（dde-shell 面板）
- 数据源：读取 `/proc/net/dev` 计算网络流量

## 功能特性

- 实时上行/下行速率监控（1 秒刷新，按真实时间间隔计算）
- 本次会话累计上传/下载流量统计
- 多网卡支持，可在弹窗或设置窗口中切换活动网卡
- 任务栏图标实时显示速率，高速时变色提示
- 任务栏字体颜色可自定义，支持跟随系统主题
- 悬停显示速率摘要与网卡 IP 地址，点击展开详情弹窗
- 详情弹窗展示活动网卡 IPv4/IPv6 地址、各网卡速率对比与统计
- 流量波动图窗口：展示活动接口最近 5 分钟网速趋势（下载/上传双折线）
- 设置窗口：网络接口选择、字体颜色自定义、一键卸载插件
- 深色模式全适配（任务栏图标、弹窗、独立窗口均跟随系统主题）
- 所有接口后台持续采集速度历史，切换网卡时趋势图立即有数据

## 构建与安装

### 构建依赖

构建需要以下开发包：

```sh
sudo apt install build-essential cmake pkg-config qt6-base-dev qt6-declarative-dev libdtkcommon-dev libdde-shell-dev
```

各包与 CMake `find_package` 的对应关系：

| 依赖包 | 提供 | 对应 CMake find_package |
|---|---|---|
| qt6-base-dev | Qt6 Core / DBus / Network | Qt6 Core DBus Network |
| qt6-declarative-dev | Qt6 Quick | Qt6 Quick |
| libdtkcommon-dev | Dtk6 Core | Dtk6 Core |
| libdde-shell-dev | DDEShell | DDEShell |

> 运行时仅需 `dde-shell` 及 Qt6/Dtk6 运行库，上述 `-dev` 包仅构建时需要。

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

项目无测试 / lint / typecheck / CI 流程，验证方式为手动：安装后重启 `dde-shell`
（其通过扫描安装目录中的 `metadata.json` 发现插件）。

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
│       ├── NetCommon.qml                  # 公共颜色与格式化函数
│       ├── NetworkPopup.qml               # 左键弹窗内容（速度/总量/网卡切换）
│       ├── SettingsWindow.qml             # 设置窗口（接口选择/字体颜色/卸载）
│       ├── TrafficChartWindow.qml         # 流量波动图窗口（5分钟趋势折线）
│       ├── TextColorPicker.qml            # 字体颜色选择器
│       └── AboutWindow.qml                # 关于窗口
├── docs/                                   # 设计文档与审查清单
├── README.md                               # 本文件
└── AGENTS.md                               # AI 代理工作指引
```
