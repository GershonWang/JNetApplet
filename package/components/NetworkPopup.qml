// SPDX-FileCopyrightText: 2024 MyCompany
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 网络速度监控弹窗内容组件
// 展示实时速度、总量统计、网卡切换 chip 列表；
// 由 networkview.qml 的 PanelPopup 实例化，传入 applet 属性，内部自行派生颜色和数据
// 设计原因：PanelPopup 是 dock 上下文类型，不能作为独立组件根元素，
// 因此本组件用 Control 作为根，由 networkview.qml 的 PanelPopup 包裹

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import org.deepin.ds.dock 1.0
import org.deepin.dtk 1.0

Control {
    id: popup

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

    // 弹窗颜色派生自 DTK 系统调色板（windowText），而非 DockPalette.iconTextPalette。
    // 设计原因：PanelPopup 背景跟随系统主题（深色模式下变黑），但 DockPalette.iconTextPalette
    // 反映的是任务栏图标文字色，不随系统深色主题变化，导致深色模式下弹窗黑底黑字。
    // DTK.palette.windowText 在深色模式下为浅色文字、浅色模式下为深色文字，与弹窗背景同步。
    // 主题切换时 DTK.paletteChanged 信号自动触发属性绑定重新求值。
    readonly property color baseTextColor: DTK.palette.windowText
    readonly property color primaryText: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.95)
    readonly property color secondaryText: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.80)
    readonly property color tertiaryText: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.65)
    readonly property color cardBackground: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.06)
    readonly property color cardBorder: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.10)

    // 强调色：下载蓝、上传绿，是面板的主视觉区分
    readonly property color accentBlue: Qt.rgba(20 / 255, 80 / 255, 160 / 255, 1)
    readonly property color accentBlueLight: Qt.rgba(20 / 255, 80 / 255, 160 / 255, 0.12)
    readonly property color accentGreen: Qt.rgba(22 / 255, 163 / 255, 74 / 255, 1)
    readonly property color accentGreenLight: Qt.rgba(22 / 255, 163 / 255, 74 / 255, 0.12)

    // 高速警示色：下载速度超过阈值时由蓝转橙再转红
    readonly property color accentOrange: Qt.rgba(245 / 255, 158 / 255, 11 / 255, 1)
    readonly property color accentRed: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)

    // 下载值颜色：保留原有阈值逻辑（>10MB/s 红、>1MB/s 橙、否则蓝），仅作用于下载值
    readonly property color downloadValueColor: {
        if (downloadSpeed > 10 * 1024 * 1024) return accentRed
        if (downloadSpeed > 1 * 1024 * 1024) return accentOrange
        return accentBlue
    }

    // 上传值颜色：固定绿色，不做高速警示
    readonly property color uploadValueColor: accentGreen

    // 判断是否为物理网卡（QML 侧排序用，与 C++ isPhysicalInterface 逻辑一致）
    function isPhysicalIf(name) {
        return name.startsWith("wlp") || name.startsWith("wlan")
            || name.startsWith("enp") || name.startsWith("eth")
    }

    // 排序后的接口列表：物理网卡在前，虚拟网卡在后，各自按名称排序
    // 设计原因：保持稳定排序，活动接口不再移到最前，避免切换网卡时 chip 顺序跳动；
    // 活动 chip 若被截断，由 chipFlickable 自动滚动露出完整样式
    readonly property var sortedInterfaces: {
        if (!popup.ready || popup.networkInterfaces.length === 0) return []
        var physical = []
        var virtual = []
        for (var i = 0; i < popup.networkInterfaces.length; i++) {
            var name = popup.networkInterfaces[i]
            if (popup.isPhysicalIf(name)) physical.push(name)
            else virtual.push(name)
        }
        physical.sort()
        virtual.sort()
        return physical.concat(virtual)
    }

    // 格式化速度显示（带单位，用于弹出面板，信息更完整）
    // 最小单位为 KB，与 formatSpeedShort 保持一致；所有级别保留 2 位小数
    function formatSpeed(bytesPerSec) {
        if (bytesPerSec < 1024 * 1024) {
            return (bytesPerSec / 1024).toFixed(2) + " KB/s"
        } else if (bytesPerSec < 1024 * 1024 * 1024) {
            return (bytesPerSec / (1024 * 1024)).toFixed(2) + " MB/s"
        } else {
            return (bytesPerSec / (1024 * 1024 * 1024)).toFixed(2) + " GB/s"
        }
    }

    // 格式化总量显示（用于弹出面板的累计统计）
    function formatTotal(bytes) {
        if (bytes < 1024) {
            return bytes.toFixed(0) + " B"
        } else if (bytes < 1024 * 1024) {
            return (bytes / 1024).toFixed(1) + " KB"
        } else if (bytes < 1024 * 1024 * 1024) {
            return (bytes / (1024 * 1024)).toFixed(1) + " MB"
        } else {
            return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB"
        }
    }

    // 供外部调用：popup 打开时滚动到活动 chip
    function scrollToActiveChip(animated) {
        chipFlickable.scrollToActiveChip(animated)
    }

    padding: 16

    contentItem: ColumnLayout {
            spacing: 12

            // 标题栏：标题在上，网卡名+IP 在卡片底色背景内
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 72

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 6

                    Text {
                        text: qsTr("网络速度监控")
                        font.pixelSize: 15
                        font.weight: Font.Bold
                        color: popup.primaryText
                        Layout.alignment: Qt.AlignHCenter
                    }

                    // 网卡名 + IP 地址卡片背景
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 300
                        // 有 IPv6 时增高以容纳第三行；无 IPv6 时保持原 40px
                        Layout.preferredHeight: popup.ipv6Address ? 54 : 40
                        color: popup.cardBackground
                        radius: 8
                        border.width: 1
                        border.color: popup.cardBorder
                        visible: popup.ready

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 0

                            Text {
                                text: popup.activeInterface
                                font.pixelSize: 11
                                color: popup.secondaryText
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: popup.ipAddress ? qsTr("IPv4：") + popup.ipAddress : ""
                                font.pixelSize: 13
                                color: popup.secondaryText
                                visible: popup.ipAddress !== ""
                                Layout.alignment: Qt.AlignHCenter
                            }

                            // IPv6 全球地址行，无 IPv6 时隐藏不占位
                            Text {
                                text: popup.ipv6Address ? qsTr("IPv6：") + popup.ipv6Address : ""
                                font.pixelSize: 13
                                color: popup.secondaryText
                                visible: popup.ipv6Address !== ""
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }
                }
            }

            // 实时速度卡片：双列布局，每列内容在各自半区内水平垂直居中
            // 设计原因：用显式 anchor 分两个等宽半区，比 RowLayout+fillWidth 更可靠，
            // 确保下载/上传内容各自在左/右半区正中显示
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 110
                color: popup.cardBackground
                radius: 12
                border.width: 1
                border.color: popup.cardBorder

                // 下载半区（左半）
                Item {
                    id: downloadHalf
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: 12
                    width: (parent.width - 1) / 2 - 12

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 4

                        Rectangle {
                            width: 32
                            height: 32
                            radius: 16
                            color: popup.accentBlueLight
                            Layout.alignment: Qt.AlignHCenter

                            Text {
                                anchors.centerIn: parent
                                text: "↓"
                                font.pixelSize: 18
                                font.weight: Font.Bold
                                color: popup.accentBlue
                            }
                        }

                        Text {
                            text: qsTr("下载")
                            font.pixelSize: 11
                            color: popup.secondaryText
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            text: popup.formatSpeed(popup.downloadSpeed)
                            font.pixelSize: 18
                            font.weight: Font.Bold
                            color: popup.downloadValueColor
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }

                // 中间分隔线
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 12
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 12
                    width: 1
                    color: popup.cardBorder
                }

                // 上传半区（右半）
                Item {
                    id: uploadHalf
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.rightMargin: 12
                    width: (parent.width - 1) / 2 - 12

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 4

                        Rectangle {
                            width: 32
                            height: 32
                            radius: 16
                            color: popup.accentGreenLight
                            Layout.alignment: Qt.AlignHCenter

                            Text {
                                anchors.centerIn: parent
                                text: "↑"
                                font.pixelSize: 18
                                font.weight: Font.Bold
                                color: popup.accentGreen
                            }
                        }

                        Text {
                            text: qsTr("上传")
                            font.pixelSize: 11
                            color: popup.secondaryText
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            text: popup.formatSpeed(popup.uploadSpeed)
                            font.pixelSize: 18
                            font.weight: Font.Bold
                            color: popup.uploadValueColor
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }
            }

            // 总量统计：单行紧凑
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                color: popup.cardBackground
                radius: 12
                border.width: 1
                border.color: popup.cardBorder
                visible: popup.ready

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 8

                    Item { Layout.fillWidth: true }

                    Text {
                        text: qsTr("总计")
                        font.pixelSize: 11
                        font.weight: Font.Bold
                        color: popup.secondaryText
                    }

                    Text {
                        text: "↓ " + popup.formatTotal(popup.totalDownload)
                        font.pixelSize: 12
                        color: popup.primaryText
                    }

                    Text {
                        text: "↑ " + popup.formatTotal(popup.totalUpload)
                        font.pixelSize: 12
                        color: popup.primaryText
                    }

                    Item { Layout.fillWidth: true }
                }
            }

            // 接口切换 chip 列表：水平滚动，物理网卡在前、虚拟网卡在后，顺序稳定不随切换变化
            // chip 少时分散撑满一行；chip 多超出宽度时固定宽度 + 水平滚动
            // 活动 chip 不在可视区域或被截断时，自动滚动露出完整样式（见 scrollToActiveChip）
            Flickable {
                id: chipFlickable
                Layout.fillWidth: true
                // 高度需容纳 chip（28px）+ 水平滚动条（~6px）+ 上下间距，
                // 此前 32px 仅剩 4px 给滚动条，导致滚动条无法正常显示
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
                            color: modelData === popup.activeInterface
                                   ? popup.accentBlue
                                   : (chipMouse.containsMouse ? popup.accentBlueLight : popup.cardBackground)
                            border.width: 1
                            border.color: modelData === popup.activeInterface
                                           ? popup.accentBlue
                                           : popup.cardBorder

                            Text {
                                id: chipText
                                anchors.centerIn: parent
                                text: modelData
                                font.pixelSize: 11
                                font.weight: modelData === popup.activeInterface ? Font.Bold : Font.Normal
                                color: modelData === popup.activeInterface ? "white" : popup.primaryText
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

            // 未检测到接口占位
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 80
                color: popup.cardBackground
                radius: 12
                border.width: 1
                border.color: popup.cardBorder
                visible: !popup.ready

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 6

                    Text {
                        text: "⚠"
                        font.pixelSize: 24
                        color: popup.secondaryText
                        Layout.alignment: Qt.AlignHCenter
                    }

                    Text {
                        text: qsTr("未检测到网络接口")
                        font.pixelSize: 12
                        color: popup.secondaryText
                        Layout.alignment: Qt.AlignHCenter
                    }
                }
            }

            Item { Layout.fillHeight: true }
        }
}
