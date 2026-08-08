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
        // 外层 Item 固定高度 + 内层 ColumnLayout anchors.centerIn：
        // 无 IP 地址时内容在区域内垂直居中，避免单行内容贴顶导致网卡名偏上
        Item {
            Layout.fillWidth: true
            // preferredHeight 40 为无 IP 时的最小高度；有 IP/IPv6 时内容自然撑高
            Layout.preferredHeight: Math.max(40, ifaceCol.implicitHeight)
            visible: popup.ready

            ColumnLayout {
                id: ifaceCol
                anchors.centerIn: parent
                width: parent.width
                spacing: 4

                // 行1：类型图标 + 接口名 + · + IPv4
                // 拆分为独立 Text 元素，使接口名用 primaryText 跟随用户 textColor，
                // 图标和 IPv4 保持系统主题色（tertiaryText/secondaryText），层次分明
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 4

                    // 网卡类型图标：与设置窗口列表图标一致，次要色不抢速度区焦点
                    Text {
                        text: common.interfaceIcon(popup.activeInterface)
                        font.pixelSize: Math.round(12 * popup.fontScale)
                        color: popup.tertiaryText
                    }

                    // 接口名：跟随用户 textColor（primaryText），Spec 5.1 节要求
                    Text {
                        text: popup.activeInterface
                        font.pixelSize: Math.round(13 * popup.fontScale)
                        color: popup.primaryText
                    }

                    // IPv4 地址：次要色，与接口名区分层次
                    Text {
                        text: popup.ipAddress ? "·  " + popup.ipAddress : ""
                        font.pixelSize: Math.round(13 * popup.fontScale)
                        color: popup.secondaryText
                        visible: popup.ipAddress !== ""
                    }
                }

                // 行2：IPv6 地址（超长截断 + hover tooltip 显示完整地址）
                Text {
                    Layout.alignment: Qt.AlignHCenter
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
