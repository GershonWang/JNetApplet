# 左键弹窗重新设计 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重新设计 NetworkPopup 左键弹窗布局，采用通透分区方案，适配用户字体颜色和网卡图标，预留字号缩放扩展点。

**Architecture:** 去掉自绘卡片背景，用分隔线+留白划分四个区域（接口信息/实时速度/累计流量/接口切换），速度数字放大为视觉锚点。将 SettingsWindow 的 interfaceIcon/interfaceDescription 提取到 NetCommon 共享，NetworkPopup 接入用户 textColor 和 fontScale。

**Tech Stack:** QML 2.15 + QtQuick.Controls 2.15 + DTK 1.0 + dde-shell PanelPopup

## Global Constraints

- 项目无测试/lint/CI 目标，验证为手动：`cmake --build build` + `sudo cmake --install build` + `systemctl --user restart dde-shell@DDE`
- QML 文件保留 SPDX 头（`SPDX-FileCopyrightText: 2026 Jokul` + `SPDX-License-Identifier: LGPL-3.0-or-later`）
- 注释语言统一使用中文，字段/函数上方必须添加中文注释
- `NetCommon.qml` 的现有颜色定义和格式化函数不变，仅新增函数
- C++ 后端本次不改（fontScale 预留扩展点，后续再加）
- Commit message 使用中文，格式遵循 conventional commits

---

## File Structure

| 文件 | 职责 | 本次改动 |
|---|---|---|
| `package/components/NetCommon.qml` | 公共颜色与格式化函数 | 新增 `interfaceIcon`、`interfaceDescription`、`formatSpeedValue`、`formatSpeedUnit` 四个函数 |
| `package/components/SettingsWindow.qml` | 设置窗口 | 删除本地 `interfaceIcon`/`interfaceDescription`，改为调用 `common.xxx` |
| `package/components/NetworkPopup.qml` | 弹窗内容组件 | 完全重写布局 |
| `package/networkview.qml` | 主入口 | 仅改 `PanelPopup` 的 width/height |

---

### Task 1: 提取共享函数到 NetCommon.qml + 更新 SettingsWindow.qml

**Files:**
- Modify: `package/components/NetCommon.qml`（在 `formatTotal` 函数后、闭合 `}` 前新增四个函数）
- Modify: `package/components/SettingsWindow.qml`（删除本地 interfaceIcon/interfaceDescription，新增 import 和 common 实例，替换调用处）

**Interfaces:**
- Produces: `common.interfaceIcon(name)` 返回 Unicode 符号字符串；`common.interfaceDescription(name)` 返回翻译后的类型描述字符串；`common.formatSpeedValue(bytesPerSec)` 返回速度数值部分（如 `"4.11"`）；`common.formatSpeedUnit(bytesPerSec)` 返回速度单位部分（如 `"KB/s"`）

- [ ] **Step 1: 在 NetCommon.qml 新增四个函数**

在 `NetCommon.qml` 的 `formatTotal` 函数闭合 `}` 之后、文件最终闭合 `}` 之前，插入以下代码：

```qml

    // 根据接口名返回类型图标（Unicode 符号），用于网络接口列表和弹窗接口信息区
    // 设计原因：项目未引入图标库，用 Text 渲染 Unicode 符号（与 ↓↑ 一致）；
    // 所选符号均为 DejaVu/Noto 等常见字体覆盖的单色字形，避免彩色 emoji 破坏浅色主题观感
    function interfaceIcon(name) {
        if (name === "lo") return "↻"               // 本地回环：循环箭头
        if (name === "Meta") return "▢"             // 虚拟接口：空心方块
        if (/^enp|^eth/.test(name)) return "⇄"      // 有线网络：双向链路
        if (/^wlp|^wlan/.test(name)) return "∿"     // 无线网络：信号波形
        if (/^docker|^veth/.test(name)) return "▣"  // 容器网络：盒中盒
        if (/^br/.test(name)) return "⋈"            // 桥接：连接
        if (/^tun|^tap/.test(name)) return "⚿"      // VPN：钥匙
        if (/^virbr/.test(name)) return "⋈"         // 虚拟桥接：同桥接
        return "◉"                                  // 其他：通用网络节点
    }

    // 根据接口名返回类型描述，用于设置窗口网络接口列表和弹窗 tooltip
    // 设计原因：用户面对多个网口时难以仅凭 enp3s0/wlp3s0 等命名判断用途，
    // 加一行类型说明（有线/无线/VPN 等）降低认知负担
    function interfaceDescription(name) {
        if (name === "lo") return qsTr("Loopback")
        if (name === "Meta") return qsTr("Virtual Interface")
        if (/^enp|^eth/.test(name)) return qsTr("Wired Network")
        if (/^wlp|^wlan/.test(name)) return qsTr("Wireless Network")
        if (/^docker|^veth/.test(name)) return qsTr("Container Network")
        if (/^br/.test(name)) return qsTr("Bridge")
        if (/^tun|^tap/.test(name)) return qsTr("VPN")
        if (/^virbr/.test(name)) return qsTr("Virtual Bridge")
        return qsTr("Other")
    }

    // 拆分速度字符串为数值部分：formatSpeed 返回 "4.11 KB/s"，本函数返回 "4.11"
    // 设计原因：弹窗速度区需将数值（大号粗体）与单位（小号）拆分显示以增强层次感
    function formatSpeedValue(bytesPerSec) {
        var str = formatSpeed(bytesPerSec)
        var idx = str.indexOf(' ')
        return idx < 0 ? str : str.substring(0, idx)
    }

    // 拆分速度字符串为单位部分：formatSpeed 返回 "4.11 KB/s"，本函数返回 "KB/s"
    function formatSpeedUnit(bytesPerSec) {
        var str = formatSpeed(bytesPerSec)
        var idx = str.indexOf(' ')
        return idx < 0 ? "" : str.substring(idx + 1)
    }
```

- [ ] **Step 2: 在 SettingsWindow.qml 添加 import 和 NetCommon 实例**

在 `SettingsWindow.qml` 的 import 块末尾（`import QtQuick.Window 2.15` 之后）添加：

```qml
import "."
```

在 `Window { id: root` 之后、`property var applet: null` 之前添加：

```qml
    // 公共函数：interfaceIcon/interfaceDescription 已从本文件迁移至 NetCommon.qml，
    // 与 NetworkPopup 共享同一份实现，消除跨组件重复定义
    NetCommon { id: common }
```

- [ ] **Step 3: 删除 SettingsWindow.qml 的本地 interfaceIcon 和 interfaceDescription 函数**

删除 `SettingsWindow.qml` 中 `interfaceDescription` 函数（当前第 72-82 行）和 `interfaceIcon` 函数（当前第 88-98 行）的完整定义，包括函数上方的注释。

- [ ] **Step 4: 替换 SettingsWindow.qml 中的函数调用处**

将 `SettingsWindow.qml` 中所有 `interfaceIcon(modelData)` 替换为 `common.interfaceIcon(modelData)`，将 `interfaceDescription(modelData)` 替换为 `common.interfaceDescription(modelData)`。

涉及两处（均在接口列表 Repeater 的 delegate 内）：
- 图标 Text 的 `text: interfaceIcon(modelData)` -> `text: common.interfaceIcon(modelData)`
- 描述 Text 的 `text: interfaceDescription(modelData)` -> `text: common.interfaceDescription(modelData)`

- [ ] **Step 5: 构建**

Run: `cmake --build build`
Expected: 编译成功，无错误

- [ ] **Step 6: 安装并重启 dde-shell**

Run: `sudo cmake --install build && systemctl --user restart dde-shell@DDE`
Expected: 安装成功，dde-shell 重启

- [ ] **Step 7: 手动验证设置窗口**

验证清单：
1. 右键任务栏网络监控图标 -> 点击"设置"
2. 设置窗口打开，网络接口列表每行左侧仍显示类型图标（∿/⇄/▢ 等）
3. 每行右侧仍显示类型描述（"无线网络"/"有线网络"/"虚拟接口" 等）
4. 图标和描述与改动前完全一致

- [ ] **Step 8: 提交**

```bash
git add package/components/NetCommon.qml package/components/SettingsWindow.qml
git commit -m "refactor: 提取 interfaceIcon/interfaceDescription 到 NetCommon 共享

将 SettingsWindow 的接口图标和描述函数迁移到 NetCommon.qml，
消除与 NetworkPopup 的重复定义；新增 formatSpeedValue/formatSpeedUnit
为弹窗速度数值与单位拆分显示做准备"
```

---

### Task 2: 重写 NetworkPopup.qml + 更新 networkview.qml 弹窗尺寸

**Files:**
- Modify: `package/networkview.qml:267-268`（PanelPopup 的 width/height）
- Rewrite: `package/components/NetworkPopup.qml`（完整重写布局）

**Interfaces:**
- Consumes: `common.interfaceIcon(name)`（Task 1 产出）、`common.formatSpeedValue(bytesPerSec)`、`common.formatSpeedUnit(bytesPerSec)`
- Produces: `popup.primaryText`（支持用户 textColor 覆盖）、`popup.fontScale`（预留字号缩放）

- [ ] **Step 1: 更新 networkview.qml 的 PanelPopup 尺寸**

将 `networkview.qml` 第 267-268 行：

```qml
        width: 360
        height: 320
```

改为：

```qml
        width: 330
        height: 250
```

- [ ] **Step 2: 完整重写 NetworkPopup.qml**

将 `package/components/NetworkPopup.qml` 全文替换为以下内容：

```qml
// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 网络速度监控弹窗内容组件
// 通透分区布局：去掉自绘卡片背景，用分隔线+留白划分四个区域
// （接口信息 / 实时速度 / 累计流量 / 接口切换），速度数字放大为视觉锚点
// 由 networkview.qml 的 PanelPopup 实例化，传入 applet 属性
// 毛玻璃背景、圆角、阴影由 PanelPopup 自动提供，本组件不自绘背景
// 颜色与格式化函数统一取自同目录 NetCommon.qml（common.xxx），数据由 applet 提供
// 可配置适配：primaryText 跟随用户 textColor、fontScale 预留字号缩放扩展点
// 设计原因：PanelPopup 是 dock 上下文类型，不能作为独立组件根元素，
// 因此本组件用 Control 作为根，由 networkview.qml 的 PanelPopup 包裹

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import org.deepin.ds.dock 1.0
import org.deepin.dtk 1.0
import "."

Control {
    id: popup

    // 公共颜色与格式化函数：集中定义于同目录 NetCommon.qml
    NetCommon { id: common }

    // C++ 后端对象，提供速度/接口/IP 等所有数据
    property var applet: null

    readonly property bool ready: applet ? applet.ready : false
    readonly property real downloadSpeed: applet ? applet.downloadSpeed : 0
    readonly property real uploadSpeed: applet ? applet.uploadSpeed : 0
    readonly property real totalDownload: applet ? applet.totalDownload : 0
    readonly property real totalUpload: applet ? applet.totalUpload : 0
    readonly property string activeInterface: applet ? (applet.activeInterface || "") : ""
    // 活动接口的 IPv4 地址，由 C++ 后端 detectIpAddress 持续更新
    readonly property string ipAddress: applet ? (applet.ipAddress || "") : ""
    // 活动接口的 IPv6 全球地址，由 C++ 后端 detectIpAddress 持续更新
    readonly property string ipv6Address: applet ? (applet.ipv6Address || "") : ""
    readonly property var networkInterfaces: applet ? (applet.networkInterfaces || []) : []

    // 用户自定义字体色：非空时覆盖 primaryText，空串回退 DTK 调色板派生
    // 仅作用于主要文字（接口名、速度数值、累计数值、chip 未选中文字）
    // secondaryText/tertiaryText/强调色不跟随，保持系统主题层次不崩
    readonly property string userTextColor: applet ? (applet.textColor || "") : ""
    readonly property color primaryText: userTextColor.length > 0
        ? Qt.rgba(userTextColor.r, userTextColor.g, userTextColor.b, 0.95)
        : common.primaryText

    // 次要/三级文字与卡片边框仍从 common 取 DTK 派生值，不跟随用户色
    readonly property color secondaryText: common.secondaryText
    readonly property color tertiaryText: common.tertiaryText
    readonly property color cardBorder: common.cardBorder

    // 强调色：下载蓝、上传绿，是面板的主视觉区分
    readonly property color accentBlue: common.accentBlue
    readonly property color accentGreen: common.accentGreen

    // 上传值颜色：固定绿色，不做高速警示
    readonly property color uploadValueColor: common.uploadValueColor

    // 字号缩放因子：默认 1.0，后续 C++ 后端新增 applet.fontScale 后自动绑定
    // 所有字号 = 基准字号 × fontScale，实现全局字号调节
    // 当前 applet.fontScale 尚不存在，恒为 1.0，视觉无变化
    readonly property real fontScale: (applet && applet.fontScale !== undefined)
        ? applet.fontScale : 1.0

    // 排序后的接口列表：物理网卡在前，虚拟网卡在后，各自按名称排序
    // 设计原因：保持稳定排序，活动接口不再移到最前，避免切换网卡时 chip 顺序跳动；
    // 活动 chip 若被截断，由 chipFlickable 自动滚动露出完整样式；
    // 物理网卡判断逻辑共用 common.isPhysicalIf（与 C++ isPhysicalInterface 一致）
    readonly property var sortedInterfaces: {
        if (!popup.ready || popup.networkInterfaces.length === 0) return []
        var physical = []
        var virtual = []
        for (var i = 0; i < popup.networkInterfaces.length; i++) {
            var name = popup.networkInterfaces[i]
            if (common.isPhysicalIf(name)) physical.push(name)
            else virtual.push(name)
        }
        physical.sort()
        virtual.sort()
        return physical.concat(virtual)
    }

    // 供外部调用：popup 打开时滚动到活动 chip
    function scrollToActiveChip(animated) {
        chipFlickable.scrollToActiveChip(animated)
    }

    padding: 12

    contentItem: ColumnLayout {
        spacing: 10

        // ==================== 占位态：未检测到接口 ====================
        // 占位时只显示警告图标+文字，不显示其他分区和分隔线
        ColumnLayout {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: 80
            spacing: 6
            visible: !popup.ready

            Text {
                text: "⚠"
                font.pixelSize: Math.round(40 * popup.fontScale)
                color: popup.tertiaryText
                Layout.alignment: Qt.AlignHCenter
            }

            Text {
                text: qsTr("No network interface detected")
                font.pixelSize: Math.round(14 * popup.fontScale)
                color: popup.secondaryText
                Layout.alignment: Qt.AlignHCenter
            }
        }

        // ==================== 分区1：接口信息 ====================
        // 类型图标 + 接口名 + IPv4 一行，IPv6 截断显示一行
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            visible: popup.ready

            // 行1：类型图标 + 接口名 + · + IPv4
            Text {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: Math.round(13 * popup.fontScale)
                color: popup.secondaryText
                text: {
                    var icon = common.interfaceIcon(popup.activeInterface)
                    var parts = icon + " " + popup.activeInterface
                    if (popup.ipAddress) parts += "  ·  " + popup.ipAddress
                    return parts
                }
            }

            // 行2：IPv6 地址（超长截断 + hover tooltip 显示完整地址）
            Text {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                Layout.maximumWidth: 300
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: Math.round(12 * popup.fontScale)
                color: popup.tertiaryText
                visible: popup.ipv6Address !== ""
                text: popup.ipv6Address ? qsTr("IPv6: ") + popup.ipv6Address : ""
                elide: Text.ElideRight

                ToolTip.text: popup.ipv6Address
                ToolTip.visible: ipv6Mouse.containsMouse && popup.ipv6Address !== ""
                ToolTip.delay: 300

                MouseArea {
                    id: ipv6Mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.IBeamCursor
                }
            }
        }

        // 分隔线1
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: popup.cardBorder
            visible: popup.ready
        }

        // ==================== 分区2：实时速度（视觉锚点） ====================
        // 双栏等宽，下载左半区、上传右半区，中间靠留白区分无竖线
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            visible: popup.ready

            // 下载半区（左半）
            Item {
                id: downloadHalf
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width / 2

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 2

                    // 下载标签
                    Text {
                        text: qsTr("Download")
                        font.pixelSize: Math.round(12 * popup.fontScale)
                        color: popup.secondaryText
                        Layout.alignment: Qt.AlignHCenter
                    }

                    // 箭头 + 数值（大号粗体）+ 单位（小号）
                    RowLayout {
                        spacing: 2
                        Layout.alignment: Qt.AlignHCenter

                        Text {
                            text: "↓"
                            font.pixelSize: Math.round(24 * popup.fontScale)
                            font.weight: Font.Bold
                            color: common.downloadValueColor(popup.downloadSpeed)
                        }

                        Text {
                            text: common.formatSpeedValue(popup.downloadSpeed)
                            font.pixelSize: Math.round(24 * popup.fontScale)
                            font.weight: Font.Bold
                            color: common.downloadValueColor(popup.downloadSpeed)
                        }

                        Text {
                            text: common.formatSpeedUnit(popup.downloadSpeed)
                            font.pixelSize: Math.round(13 * popup.fontScale)
                            color: common.downloadValueColor(popup.downloadSpeed)
                            Layout.alignment: Qt.AlignBaseline
                        }
                    }
                }
            }

            // 上传半区（右半）
            Item {
                id: uploadHalf
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: parent.width / 2

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 2

                    // 上传标签
                    Text {
                        text: qsTr("Upload")
                        font.pixelSize: Math.round(12 * popup.fontScale)
                        color: popup.secondaryText
                        Layout.alignment: Qt.AlignHCenter
                    }

                    // 箭头 + 数值（大号粗体）+ 单位（小号）
                    RowLayout {
                        spacing: 2
                        Layout.alignment: Qt.AlignHCenter

                        Text {
                            text: "↑"
                            font.pixelSize: Math.round(24 * popup.fontScale)
                            font.weight: Font.Bold
                            color: popup.uploadValueColor
                        }

                        Text {
                            text: common.formatSpeedValue(popup.uploadSpeed)
                            font.pixelSize: Math.round(24 * popup.fontScale)
                            font.weight: Font.Bold
                            color: popup.uploadValueColor
                        }

                        Text {
                            text: common.formatSpeedUnit(popup.uploadSpeed)
                            font.pixelSize: Math.round(13 * popup.fontScale)
                            color: popup.uploadValueColor
                            Layout.alignment: Qt.AlignBaseline
                        }
                    }
                }
            }
        }

        // 分隔线2
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: popup.cardBorder
            visible: popup.ready
        }

        // ==================== 分区3：累计流量 ====================
        // 单行紧凑：总计标签 + 下载箭头/数值 + 上传箭头/数值
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: popup.ready

            Item { Layout.fillWidth: true }

            Text {
                text: qsTr("Total")
                font.pixelSize: Math.round(12 * popup.fontScale)
                color: popup.tertiaryText
            }

            Text {
                text: "↓"
                font.pixelSize: Math.round(12 * popup.fontScale)
                font.weight: Font.Bold
                color: popup.accentBlue
            }

            Text {
                text: common.formatTotal(popup.totalDownload)
                font.pixelSize: Math.round(13 * popup.fontScale)
                color: popup.primaryText
            }

            Text {
                text: "↑"
                font.pixelSize: Math.round(12 * popup.fontScale)
                font.weight: Font.Bold
                color: popup.accentGreen
            }

            Text {
                text: common.formatTotal(popup.totalUpload)
                font.pixelSize: Math.round(13 * popup.fontScale)
                color: popup.primaryText
            }

            Item { Layout.fillWidth: true }
        }

        // 分隔线3
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: popup.cardBorder
            visible: popup.ready
        }

        // ==================== 分区4：接口切换 chip 列表 ====================
        // 水平滚动，物理网卡在前、虚拟网卡在后，顺序稳定不随切换变化
        // chip 少时分散撑满一行；chip 多超出宽度时固定宽度 + 水平滚动
        // 活动 chip 不在可视区域或被截断时，自动滚动露出完整样式（见 scrollToActiveChip）
        Flickable {
            id: chipFlickable
            Layout.fillWidth: true
            // 高度需容纳 chip（28px）+ 水平滚动条（~6px）+ 上下间距
            Layout.preferredHeight: 40
            visible: popup.ready && popup.networkInterfaces.length > 1
            contentWidth: Math.max(chipRow.width, width)
            contentHeight: chipRow.height
            flickableDirection: Flickable.HorizontalFlick
            clip: true

            // 平滑滚动动画：直接赋值 contentX 会被 Flickable 的拖拽/回弹行为覆盖，
            // 用 NumberAnimation 驱动 contentX 实现自动滚动，平滑且不冲突
            NumberAnimation {
                id: chipScrollAnim
                target: chipFlickable
                property: "contentX"
                duration: 200
                easing.type: Easing.OutCubic
            }

            // 用户开始拖拽/滑动时停止自动滚动，避免动画与用户操作争抢
            onMovementStarted: chipScrollAnim.stop()

            // 自动滚动使活动接口的 chip 完整可见：
            // 列表顺序稳定后活动 chip 可能位于可视区域外或被截断，
            // 切换接口或 popup 打开时调用，将其滚动露出完整样式。
            // animated=false 用于 popup 刚打开时立即定位，跳过滚动过程
            function scrollToActiveChip(animated) {
                if (!visible || width <= 0) return
                var idx = popup.sortedInterfaces.indexOf(popup.activeInterface)
                if (idx < 0) return
                var chip = chipRepeater.itemAt(idx)
                if (!chip) return
                var targetX = contentX
                if (chip.x < contentX) {
                    // chip 在可视区左侧之外：回滚使 chip 左边缘与可视区左缘对齐
                    targetX = chip.x
                } else if (chip.x + chip.width > contentX + width) {
                    // chip 在可视区右侧之外或被截断：滚动使 chip 右边缘与可视区右缘对齐
                    targetX = chip.x + chip.width - width
                }
                // 钳制到合法滚动范围 [0, contentWidth - width]，避免触发边界回弹
                targetX = Math.max(0, Math.min(targetX, Math.max(0, contentWidth - width)))
                if (Math.abs(targetX - contentX) < 1) return
                chipScrollAnim.stop()
                if (animated) {
                    chipScrollAnim.to = targetX
                    chipScrollAnim.start()
                } else {
                    contentX = targetX
                }
            }

            // 活动接口变化时（用户点击 chip 或后端自动切换）自动滚动露出活动 chip
            Connections {
                target: popup
                function onActiveInterfaceChanged() {
                    chipFlickable.scrollToActiveChip(true)
                }
            }

            // 等宽分配宽度：假设所有 chip 等宽撑满时的单个宽度
            readonly property real equalChipWidth: popup.sortedInterfaces.length > 0
                ? (width - 6 * (popup.sortedInterfaces.length - 1)) / popup.sortedInterfaces.length
                : 0

            Row {
                id: chipRow
                spacing: 6

                Repeater {
                    id: chipRepeater
                    model: popup.sortedInterfaces

                    Rectangle {
                        // 宽度取等宽和自然宽度的较大值：
                        // chip 少时 equalChipWidth > 自然宽度 -> 分散撑满一行
                        // chip 多时 自然宽度 > equalChipWidth -> 固定宽度 + 水平滚动
                        width: Math.max(chipFlickable.equalChipWidth, chipText.implicitWidth + 24)
                        height: 28
                        radius: 8
                        // 选中态：蓝色填充+蓝边框；未选中态：透明背景+cardBorder 边框
                        // hover 态：边框变蓝、文字变蓝，提供清晰交互反馈
                        color: modelData === popup.activeInterface
                               ? popup.accentBlue
                               : "transparent"
                        border.width: 1
                        border.color: modelData === popup.activeInterface
                                       ? popup.accentBlue
                                       : (chipMouse.containsMouse ? popup.accentBlue : popup.cardBorder)

                        Text {
                            id: chipText
                            anchors.centerIn: parent
                            text: modelData
                            font.pixelSize: Math.round(12 * popup.fontScale)
                            font.weight: modelData === popup.activeInterface ? Font.Bold : Font.Normal
                            color: modelData === popup.activeInterface
                                   ? "white"
                                   : (chipMouse.containsMouse ? popup.accentBlue : popup.primaryText)
                        }

                        MouseArea {
                            id: chipMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: {
                                if (popup.applet) popup.applet.setActiveInterface(modelData)
                            }
                        }
                    }
                }
            }

            // 自定义滚动条样式：默认 ScrollBar 在面板配色下可能不可见，
            // 用 contentItem 显式绘制，颜色派生自 basePalette 适配深浅主题
            ScrollBar.horizontal: ScrollBar {
                id: chipScrollBar
                policy: ScrollBar.AsNeeded
                interactive: true

                contentItem: Rectangle {
                    implicitHeight: 4
                    radius: 2
                    // 按压时加深、悬停时中等、默认稍淡，保证滚动条在深浅主题下均可见
                    color: chipScrollBar.pressed ? popup.secondaryText
                          : (chipScrollBar.hovered ? popup.secondaryText : popup.tertiaryText)
                }
            }
        }

        // 填充剩余空间，将内容推至顶部
        Item { Layout.fillHeight: true }
    }
}
```

- [ ] **Step 3: 构建**

Run: `cmake --build build`
Expected: 编译成功，无错误

- [ ] **Step 4: 安装并重启 dde-shell**

Run: `sudo cmake --install build && systemctl --user restart dde-shell@DDE`
Expected: 安装成功，dde-shell 重启

- [ ] **Step 5: 手动验证弹窗布局**

验证清单：
1. 左键点击任务栏网络监控图标，弹窗打开
2. **无卡片背景**：毛玻璃通透，无 6% 透明度色块，四个区域用分隔线划分
3. **接口信息区**：显示类型图标（如 ∿）+ 接口名 + · + IPv4 地址，居中
4. **IPv6 截断**：IPv6 地址超长时末尾显示 `…`，hover 显示完整地址 tooltip
5. **速度区**：下载/上传标签在上（小字），箭头+数值 24px 粗体在下，单位 KB/s 小号
6. **下载阈值变色**：下载速度 >1MB/s 时数值变橙，>10MB/s 变红，否则蓝色
7. **累计流量区**：单行显示"总计 ↓ 4.85 GB ↑ 134 MB"，紧凑居中
8. **chip 未选中态**：透明背景 + 边框，清晰可辨
9. **chip hover**：边框变蓝，文字变蓝
10. **chip 选中态**：蓝色填充 + 白字
11. **chip 滚动**：接口多时可水平滚动，活动 chip 自动滚入可视区
12. **无冗余标题**：弹窗顶部无"网络速度监控"标题

- [ ] **Step 6: 手动验证深浅主题**

验证清单：
1. 切换系统到深色模式：弹窗毛玻璃深色底，文字浅色，对比度良好
2. 切换系统到浅色模式：弹窗毛玻璃浅色底，文字深色，对比度良好
3. 各分区文字层次清晰：速度数值 > 标签/接口名 > IPv6/总计标签

- [ ] **Step 7: 手动验证字体颜色适配**

验证清单：
1. 右键任务栏图标 -> 设置 -> 字体颜色 -> 选择红色
2. 左键打开弹窗：接口名、速度数值（未超阈值时）、累计数值、chip 未选中文字变红
3. 标签（下载/上传/总计）、IPv6、蓝绿箭头仍保持系统主题色，不跟随
4. 设置 -> 字体颜色 -> 选择"跟随系统"：弹窗恢复 DTK 调色板派生色

- [ ] **Step 8: 手动验证网卡切换**

验证清单：
1. 弹窗底部点击不同 chip，接口信息区更新为对应网卡的图标、名称、IP
2. 速度数值切换到对应网卡的数据
3. chip 选中态正确跟随切换

- [ ] **Step 9: 手动验证占位态**

验证清单：
1. （如条件允许）断开所有网络接口或模拟无接口状态
2. 左键打开弹窗：显示 ⚠ 图标 + "未检测到网络接口"文字，无其他分区

- [ ] **Step 10: 提交**

```bash
git add package/networkview.qml package/components/NetworkPopup.qml
git commit -m "feat: 重新设计左键弹窗布局

采用通透分区方案，去掉自绘卡片背景改用分隔线+留白划分四区：
接口信息（含类型图标）/ 实时速度（24px 锚点）/ 累计流量 / 接口切换
速度数值与单位拆分显示，chip 未选中态改透明+边框
适配用户 textColor（仅主要文字跟随）、预留 fontScale 字号缩放扩展点"
```

---

## 验证总结

本计划无自动化测试，验证完全依赖手动构建+安装+视觉检查：
- Task 1 验证设置窗口接口图标/描述不受影响（函数迁移无行为变化）
- Task 2 验证弹窗新布局、深浅主题、字体颜色跟随、网卡切换、占位态

若构建或运行时报错，优先检查：
- QML import 路径是否正确（`import "."` 在 SettingsWindow.qml 中）
- NetCommon.qml 新增函数的 `qsTr()` 在 QtObject 内是否正常（应正常，qsTr 是全局函数）
- RowLayout 内 `Layout.alignment: Qt.AlignBaseline` 是否被正确解析
