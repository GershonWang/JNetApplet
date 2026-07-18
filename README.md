# JNetApplet

基于 dde-shell 的**深度系统任务栏网络速率监控插件**，使用 C++ 后端采集数据、
QML 前端渲染界面，实时显示当前网卡的上行/下行速率与累计流量。

- 插件 ID：`space.jokul.JNetApplet`
- 适用环境：deepin 桌面环境（dde-shell 面板）
- 数据源：读取 `/proc/net/dev` 计算网络流量

## 功能特性

- 实时上行/下行速率监控（1 秒刷新）
- 累计上传/下载流量统计
- 多网卡支持，可在弹窗中切换活动网卡
- 任务栏图标实时显示速率，高速时变色提示
- 悬停显示速率摘要，点击展开详情弹窗
- 详情弹窗展示活动网卡 IP 地址、各网卡速率对比与统计图表
- 支持从弹窗一键卸载插件

## 构建与安装

需要配置期存在 `DDEShell` CMake 包（来自 `dde-shell` 开发包）。

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
├── networkmonitorapplet.h                  # C++ 后端头文件
├── networkmonitorapplet.cpp                # C++ 后端实现
├── package/
│   ├── metadata.json                       # 插件元数据
│   └── networkview.qml                     # QML 界面
├── docs/                                   # 设计文档与实现计划
├── README.md                               # 本文件
└── AGENTS.md                               # AI 代理工作指引
```
