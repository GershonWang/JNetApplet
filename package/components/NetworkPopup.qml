// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 网络速度监控弹窗内容组件
// 通透分区布局：去掉自绘卡片背景，用分隔线+留白划分四个区域
// （接口信息 / 实时速度 / 累计流量 / 接口切换），速度数字放大为视觉锚点
// 由 networkview.qml 的 PanelPopup 实例化，传入 applet 属性
// 毛玻璃背景、圆角、阴影由 PanelPopup 自动提供，本组件不自绘背景
// 颜色与格式化函数统一取自同目录 NetCommon.qml（common.xxx），数据由 applet 提供
// 可配置适配：primaryText 跟随用户 textColor
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

    // C++ 后端对象，提供速度/接口/IP 等所有数据
    property var applet: null

    // 公共颜色与格式化函数：由 networkview.qml 传入 dock 上下文的 NetCommon 实例
    // 设计原因：PanelPopup 是独立窗口上下文，在此上下文求值 DTK.palette.windowText
    // 深色模式下返回深色文字（与 dock 面板上下文不同），导致深底深字；
    // 传入 dock 上下文的 common 实例，颜色在 dock 面板上下文求值，深色模式正确返回浅色文字
    property var common: null

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

    // 活动接口的收发包/错误/丢包累计统计（自开机起），由 C++ 后端持续更新
    readonly property real rxPackets: applet ? (applet.rxPackets || 0) : 0
    readonly property real txPackets: applet ? (applet.txPackets || 0) : 0
    readonly property real rxErrors: applet ? (applet.rxErrors || 0) : 0
    readonly property real txErrors: applet ? (applet.txErrors || 0) : 0
    readonly property real rxDropped: applet ? (applet.rxDropped || 0) : 0
    readonly property real txDropped: applet ? (applet.txDropped || 0) : 0

    // 活动接口的链路协商速率（Mbps），由 C++ 后端低频检测；0 表示不可用
    readonly property int linkSpeed: applet ? (applet.linkSpeed || 0) : 0
    // 当前活动接口的 TCP ESTABLISHED 连接数，由 C++ 后端每秒统计
    readonly property int tcpConnections: applet ? (applet.tcpConnections || 0) : 0
    // 活动接口的 WiFi 信号强度（dBm，负值），由 C++ 后端低频检测；0 表示不可用
    readonly property int wifiSignal: applet ? (applet.wifiSignal || 0) : 0

    // 用户自定义字体色：非空时覆盖 primaryText，空串回退 DTK 调色板派生
    // 仅作用于主要文字（接口名、速度数值、累计数值、chip 未选中文字）
    // secondaryText/tertiaryText/强调色不跟随，保持系统主题层次不崩
    readonly property string userTextColor: applet ? (applet.textColor || "") : ""
    readonly property color primaryText: userTextColor.length > 0
        ? Qt.rgba(Qt.color(userTextColor).r, Qt.color(userTextColor).g, Qt.color(userTextColor).b, 0.95)
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

    // 复制反馈状态：记录刚复制的字段（"ipv4"/"ipv6"/""），用于图标切换为 ✓
    property string copiedField: ""

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

    // 一键复制：用隐藏 TextEdit 的 selectAll()+copy() 写入系统剪贴板
    // QML 无直接剪贴板 API，此为项目既定模式（SettingsWindow/AboutWindow 同模式）
    function copyToClipboard(text) {
        clipboardHelper.text = text
        clipboardHelper.selectAll()
        clipboardHelper.copy()
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
                font.pixelSize: 40
                color: popup.tertiaryText
                Layout.alignment: Qt.AlignHCenter
            }

            Text {
                text: qsTr("No network interface detected")
                font.pixelSize: 14
                color: popup.secondaryText
                Layout.alignment: Qt.AlignHCenter
            }
        }

        // ==================== 分区1：接口信息 ====================
        // 三行对称结构：行1 接口名（居中），行2 IPv4 地址行，行3 IPv6 地址行
        // 地址行用固定宽度标签 + 地址 + 复制图标，两行结构对称不会错位
        // 固定区域高度（按最多 3 行：接口名 16px + IPv4 16px + IPv6 16px + 间距 8px ≈ 56px）：
        // 无论有无 IP 地址，区域高度恒定，弹窗整体高度不随网卡切换跳动；
        // 内容用 anchors.top 顶部对齐，接口名行始终在顶部同一垂直位置
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 76
            visible: popup.ready

            ColumnLayout {
                id: ifaceCol
                anchors.top: parent.top
                width: parent.width
                spacing: 4

                // 行1：类型图标 + 接口名（居中）
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 4

                    // 网卡类型图标：与设置窗口列表图标一致，次要色不抢速度区焦点
                    Text {
                        text: common.interfaceIcon(popup.activeInterface)
                        font.pixelSize: 12
                        color: popup.tertiaryText
                    }

                    // 接口名：跟随用户 textColor（primaryText），Spec 5.1 节要求
                    Text {
                        text: popup.activeInterface
                        font.pixelSize: 13
                        color: popup.primaryText
                    }

                    // 链路协商速率：speed>=1000 显示 Gbps，否则 Mbps；无速率时隐藏
                    Text {
                        text: popup.linkSpeed > 0 ? "· " + common.formatLinkSpeed(popup.linkSpeed) : ""
                        font.pixelSize: 12
                        color: popup.tertiaryText
                        visible: popup.linkSpeed > 0
                    }
                }

                // 行2：IPv4 标签 + 地址 + 复制图标
                // 与行3 结构对称：标签固定宽度左对齐，地址左对齐，复制图标在右
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.maximumWidth: 320
                    spacing: 6
                    visible: popup.ipAddress !== ""

                    // IPv4 标签：固定宽度，与 IPv6 标签列对齐
                    Text {
                        text: qsTr("IPv4")
                        font.pixelSize: 12
                        color: popup.tertiaryText
                        Layout.preferredWidth: 32
                        horizontalAlignment: Text.AlignLeft
                    }

                    // IPv4 地址：超长截断 + hover tooltip
                    Text {
                        text: popup.ipAddress
                        font.pixelSize: 13
                        color: popup.secondaryText
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignLeft

                        ToolTip.text: popup.ipAddress
                        ToolTip.visible: ipv4Mouse.containsMouse && popup.ipAddress !== ""
                        ToolTip.delay: 300

                        MouseArea {
                            id: ipv4Mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.IBeamCursor
                        }
                    }

                    // 一键复制图标：点击复制 IPv4 到剪贴板，复制后短暂显示 ✓
                    // 默认态用 primaryText 保证深色背景上清晰可见，hover 变蓝
                    Text {
                        text: popup.copiedField === "ipv4" ? "✓" : "⧉"
                        font.pixelSize: 12
                        color: popup.copiedField === "ipv4"
                               ? popup.accentGreen
                               : (ipv4CopyMouse.containsMouse ? popup.accentBlue : popup.primaryText)

                        MouseArea {
                            id: ipv4CopyMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: {
                                popup.copyToClipboard(popup.ipAddress)
                                popup.copiedField = "ipv4"
                                copyFeedbackTimer.restart()
                            }
                        }
                    }
                }

                // 行3：IPv6 标签 + 地址 + 复制图标
                // 与行2 结构对称：标签固定宽度左对齐，地址左对齐，复制图标在右
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.maximumWidth: 320
                    spacing: 6
                    visible: popup.ipv6Address !== ""

                    // IPv6 标签：固定宽度，与 IPv4 标签列对齐
                    Text {
                        text: qsTr("IPv6")
                        font.pixelSize: 12
                        color: popup.tertiaryText
                        Layout.preferredWidth: 32
                        horizontalAlignment: Text.AlignLeft
                    }

                    // IPv6 地址：超长截断 + hover tooltip 显示完整地址
                    Text {
                        text: popup.ipv6Address
                        font.pixelSize: 12
                        color: popup.tertiaryText
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignLeft

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

                    // 一键复制图标：点击复制 IPv6 到剪贴板，复制后短暂显示 ✓
                    // 默认态用 primaryText 保证深色背景上清晰可见，hover 变蓝
                    Text {
                        text: popup.copiedField === "ipv6" ? "✓" : "⧉"
                        font.pixelSize: 12
                        color: popup.copiedField === "ipv6"
                               ? popup.accentGreen
                               : (ipv6CopyMouse.containsMouse ? popup.accentBlue : popup.primaryText)

                        MouseArea {
                            id: ipv6CopyMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: {
                                popup.copyToClipboard(popup.ipv6Address)
                                popup.copiedField = "ipv6"
                                copyFeedbackTimer.restart()
                            }
                        }
                    }
                }

                // 行4：WiFi 信号强度（dBm），仅无线接口有信号时显示
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 6
                    visible: popup.wifiSignal < 0

                    Text {
                        text: qsTr("Signal") + " " + popup.wifiSignal.toFixed(0) + " dBm"
                        font.pixelSize: 12
                        color: popup.tertiaryText
                    }
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
                        font.pixelSize: 12
                        color: popup.secondaryText
                        Layout.alignment: Qt.AlignHCenter
                    }

                    // 箭头 + 数值（大号粗体）+ 单位（小号）
                    RowLayout {
                        spacing: 2
                        Layout.alignment: Qt.AlignHCenter

                        Text {
                            text: "↓"
                            font.pixelSize: 24
                            font.weight: Font.Bold
                            color: common.downloadValueColor(popup.downloadSpeed)
                        }

                        Text {
                            text: common.formatSpeedValue(popup.downloadSpeed)
                            font.pixelSize: 24
                            font.weight: Font.Bold
                            color: common.downloadValueColor(popup.downloadSpeed)
                        }

                        Text {
                            text: common.formatSpeedUnit(popup.downloadSpeed)
                            font.pixelSize: 13
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
                        font.pixelSize: 12
                        color: popup.secondaryText
                        Layout.alignment: Qt.AlignHCenter
                    }

                    // 箭头 + 数值（大号粗体）+ 单位（小号）
                    RowLayout {
                        spacing: 2
                        Layout.alignment: Qt.AlignHCenter

                        Text {
                            text: "↑"
                            font.pixelSize: 24
                            font.weight: Font.Bold
                            color: popup.uploadValueColor
                        }

                        Text {
                            text: common.formatSpeedValue(popup.uploadSpeed)
                            font.pixelSize: 24
                            font.weight: Font.Bold
                            color: popup.uploadValueColor
                        }

                        Text {
                            text: common.formatSpeedUnit(popup.uploadSpeed)
                            font.pixelSize: 13
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
                text: qsTr("Session Total")
                font.pixelSize: 12
                color: popup.tertiaryText
            }

            Text {
                text: "↓"
                font.pixelSize: 12
                font.weight: Font.Bold
                color: popup.accentBlue
            }

            Text {
                text: common.formatTotal(popup.totalDownload)
                font.pixelSize: 13
                color: popup.primaryText
            }

            Text {
                text: "↑"
                font.pixelSize: 12
                font.weight: Font.Bold
                color: popup.accentGreen
            }

            Text {
                text: common.formatTotal(popup.totalUpload)
                font.pixelSize: 13
                color: popup.primaryText
            }

            Item { Layout.fillWidth: true }
        }

        // 包统计：收发包 + 错误/丢包（累计值，自开机起），紧接累计流量下方
        // 布局与流量总计行一致：标签 + ↓蓝粗 + 数值 + ↑绿粗 + 数值，拆分为独立 Text
        // 设计原因：包统计与流量统计同属"累计数据"，放一起信息归属清晰且视觉对称；
        // 包总数始终显示；错误/丢包仅在存在时显示，避免正常网卡信息过载
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: popup.ready

            Item { Layout.fillWidth: true }

            // 包统计标签（与"流量总计"标签对齐）
            Text {
                text: qsTr("Packets")
                font.pixelSize: 12
                color: popup.tertiaryText
            }

            // 接收包数：蓝色下箭头（与流量总计行下载箭头一致）
            Text {
                text: "↓"
                font.pixelSize: 12
                font.weight: Font.Bold
                color: popup.accentBlue
            }

            Text {
                text: popup.rxPackets.toFixed(0)
                font.pixelSize: 13
                color: popup.primaryText
            }

            // 发送包数：绿色上箭头（与流量总计行上传箭头一致）
            Text {
                text: "↑"
                font.pixelSize: 12
                font.weight: Font.Bold
                color: popup.accentGreen
            }

            Text {
                text: popup.txPackets.toFixed(0)
                font.pixelSize: 13
                color: popup.primaryText
            }

            // 错误数：仅在存在错误或丢包时显示，格式 "错误 {rxE}/{txE}"
            Text {
                text: qsTr("Errors") + " " + popup.rxErrors.toFixed(0) + "/" + popup.txErrors.toFixed(0)
                font.pixelSize: 12
                color: popup.tertiaryText
                visible: popup.rxErrors > 0 || popup.txErrors > 0 || popup.rxDropped > 0 || popup.txDropped > 0
            }

            // 丢包数：仅在存在错误或丢包时显示，格式 "丢包 {rxD}/{txD}"
            Text {
                text: qsTr("Dropped") + " " + popup.rxDropped.toFixed(0) + "/" + popup.txDropped.toFixed(0)
                font.pixelSize: 12
                color: popup.tertiaryText
                visible: popup.rxErrors > 0 || popup.txErrors > 0 || popup.rxDropped > 0 || popup.txDropped > 0
            }

            Item { Layout.fillWidth: true }
        }

        // TCP 连接数：仅在连接数>0 时显示，紧跟包统计下方
        // 设计原因：连接数反映当前网络会话活跃度，是用户关心的即时信息
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: popup.ready && popup.tcpConnections > 0

            Item { Layout.fillWidth: true }

            Text {
                text: qsTr("TCP Connections") + " " + popup.tcpConnections.toFixed(0)
                font.pixelSize: 12
                color: popup.tertiaryText
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
                            font.pixelSize: 12
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

    // 隐藏的 TextEdit 用于复制 IP 地址到剪贴板
    // QML 没有直接剪贴板 API，用 TextEdit.selectAll()+copy() 实现
    //（与 SettingsWindow/AboutWindow 中 clipboardHelper 同模式）
    TextEdit {
        id: clipboardHelper
        visible: false
        text: ""
    }

    // 复制反馈定时器：2 秒后将 copiedField 清空，图标从 ✓ 恢复为 ⧉
    Timer {
        id: copyFeedbackTimer
        interval: 2000
        onTriggered: popup.copiedField = ""
    }
}
