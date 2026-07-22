// SPDX-FileCopyrightText: 2024 MyCompany
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import Qt.labs.platform as Platform
import org.deepin.ds 1.0
import org.deepin.ds.dock 1.0
import org.deepin.dtk 1.0
import "components"

AppletItem {
    id: root
    objectName: "network monitor applet"
    property int dockOrder: 21
    property int dockSize: Panel.rootObject.dockItemMaxSize || 48
    // 任务栏方向：0=Top, 1=Right, 2=Bottom, 3=Left；% 2 为 0 表示水平，1 表示竖向
    // 设计原因：dde-shell 规范用法，org.deepin.ds.dock 已在 line 11 导入
    property bool isVerticalDock: Panel.position % 2 === 1

    // 水平任务栏：宽度稍宽容纳双行数值，高度匹配 dock 尺寸
    // 竖向任务栏：宽度匹配 dock 尺寸（~40px），高度加大容纳竖排字符
    // 2.4 倍：dockSize=40 时约 96px，可容纳最多 8 字符的速度字符串（如 "1023.99K"）
    // 增大字号后需更高以容纳竖排字符
    implicitWidth: isVerticalDock ? dockSize : Math.round(dockSize * 1.35)
    implicitHeight: isVerticalDock ? Math.round(dockSize * 2.4) : dockSize

    readonly property var applet: Applet
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
    readonly property var interfaceStats: applet ? (applet.interfaceStats || []) : []

    // 判断是否为物理网卡（QML 侧排序用，与 C++ isPhysicalInterface 逻辑一致）
    function isPhysicalIf(name) {
        return name.startsWith("wlp") || name.startsWith("wlan")
            || name.startsWith("enp") || name.startsWith("eth")
    }

    // 排序后的接口列表：物理网卡在前，虚拟网卡在后，各自按名称排序
    // 设计原因：保持稳定排序，活动接口不再移到最前，避免切换网卡时 chip 顺序跳动；
    // 活动 chip 若被截断，由 chipFlickable 自动滚动露出完整样式
    readonly property var sortedInterfaces: {
        if (!root.ready || root.networkInterfaces.length === 0) return []
        var physical = []
        var virtual = []
        for (var i = 0; i < root.networkInterfaces.length; i++) {
            var name = root.networkInterfaces[i]
            if (root.isPhysicalIf(name)) physical.push(name)
            else virtual.push(name)
        }
        physical.sort()
        virtual.sort()
        return physical.concat(virtual)
    }

    // 紧凑格式化速度（用于任务栏图标和 tooltip，不带单位后缀，节省空间）
    // 设计原因：任务栏 ~48px 空间有限，"1.2M" 比 "1.2 MB/s" 节省约一半宽度
    // 最小单位为 KB：B 级别也转换为 KB 显示（如 512 B/s -> "0.50K"），
    // 避免纯数字无后缀时用户无法判断单位；所有级别保留 2 位小数
    function formatSpeedShort(bytesPerSec) {
        if (bytesPerSec < 1024 * 1024) {
            return (bytesPerSec / 1024).toFixed(2) + "K"
        } else if (bytesPerSec < 1024 * 1024 * 1024) {
            return (bytesPerSec / (1024 * 1024)).toFixed(2) + "M"
        } else {
            return (bytesPerSec / (1024 * 1024 * 1024)).toFixed(2) + "G"
        }
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

    // 任务栏与面板的颜色全部派生自 DockPalette.iconTextPalette
    // 这样在深色/浅色任务栏下自动适配，无需手动判断主题
    property Palette basePalette: DockPalette.iconTextPalette
    readonly property color primaryText: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.95)
    readonly property color secondaryText: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.80)
    readonly property color tertiaryText: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.65)
    readonly property color cardBackground: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.06)
    readonly property color cardBorder: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.10)

    // 强调色：下载蓝、上传绿，是面板与任务栏的主视觉区分
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

    // 任务栏网速数值字体色：用户自定义色优先（持久化），未设置时跟随系统主题
    // 设计原因：primaryText 派生自 DockPalette，深浅色任务栏自动适配；
    // 用户主动选色后覆盖，空串回退到 primaryText 保持自适应
    readonly property color speedTextColor: (applet && applet.textColor.length > 0) ? applet.textColor : primaryText

    // 任务栏图标区：双行紧凑数值，箭头与数值紧贴、左对齐
    // 设计原因：箭头与数值作为一组固定在左侧，数值左对齐紧贴箭头；
    // 不给每行固定高度，让 RowLayout 按内容自然高度排列，
    // 整组垂直居中于 dock 区域，避免两行间出现过大间隙
    Column {
        visible: !root.isVerticalDock
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 4
        spacing: 0

        // 下载速度行
        RowLayout {
            spacing: 2

            Text {
                text: "↓"
                font.pixelSize: root.dockSize * 0.20
                color: root.speedTextColor
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                text: root.formatSpeedShort(root.downloadSpeed)
                font.pixelSize: root.dockSize * 0.25
                font.weight: Font.Medium
                color: root.speedTextColor
                Layout.alignment: Qt.AlignVCenter
                horizontalAlignment: Text.AlignLeft
            }
        }

        // 上传速度行
        RowLayout {
            spacing: 2

            Text {
                text: "↑"
                font.pixelSize: root.dockSize * 0.20
                color: root.speedTextColor
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                text: root.formatSpeedShort(root.uploadSpeed)
                font.pixelSize: root.dockSize * 0.25
                font.weight: Font.Medium
                color: root.speedTextColor
                Layout.alignment: Qt.AlignVCenter
                horizontalAlignment: Text.AlignLeft
            }
        }
    }

    // 竖向任务栏布局：双列字符竖排，每列一个方向（下载|上传）
    // 设计原因：竖向任务栏宽度仅 ~40px，水平布局的 "↓6.64K" 约 35px 勉强容纳但
    // 数值长度变化时易裁切；逐字符竖排每列仅 ~10px，双列 ~25px，舒适容纳且视觉对称
    RowLayout {
        visible: root.isVerticalDock
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 4
        spacing: 4

        // 下载列：箭头在上，数值字符从上往下竖排
        Column {
            spacing: 0
            Layout.alignment: Qt.AlignTop | Qt.AlignHCenter

            Text {
                text: "↓"
                font.pixelSize: root.dockSize * 0.20
                color: root.speedTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Repeater {
                // 将 "6.64K" 拆为 ["6", ".", "6", "4", "K"] 逐字符渲染
                // 属性绑定：downloadSpeed 变化时 formatSpeedShort 重算，split 自动刷新 model
                model: root.formatSpeedShort(root.downloadSpeed).split('')
                Text {
                    text: modelData
                    font.pixelSize: root.dockSize * 0.25
                    height: font.pixelSize
                    font.weight: Font.Medium
                    color: root.speedTextColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }

        // 上传列：结构与下载列对称，颜色用 uploadValueColor
        Column {
            spacing: 0
            Layout.alignment: Qt.AlignTop | Qt.AlignHCenter

            Text {
                text: "↑"
                font.pixelSize: root.dockSize * 0.20
                color: root.speedTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Repeater {
                model: root.formatSpeedShort(root.uploadSpeed).split('')
                Text {
                    text: modelData
                    font.pixelSize: root.dockSize * 0.25
                    height: font.pixelSize
                    font.weight: Font.Medium
                    color: root.speedTextColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    // 悬停提示：网卡名 + IPv4 单行，IPv6 在第二行（仅有 IPv6 时追加）
    // 设计原因：IPv6 地址较长，单行容纳不下；无 IPv6 时保持单行与原视觉一致
    PanelToolTip {
        id: toolTip
        text: root.ready
              ? (root.activeInterface
                 + " · IPv4：" + (root.ipAddress || qsTr("无"))
                 + (root.ipv6Address ? "\nIPv6：" + root.ipv6Address : ""))
              : qsTr("未检测到网络接口")
        toolTipX: DockPanelPositioner.x
        toolTipY: DockPanelPositioner.y
    }

    // 注意：不再需要 QML 侧的 statsRefreshTimer。
    // C++ 后端 NetworkMonitorApplet::init() 已启动 1 秒间隔的 m_refreshTimer，
    // 持续调用 refresh()->readNetworkStats()->calculateSpeed() 更新速度属性。
    // QML 通过属性绑定自动获取最新值，无需主动触发 refresh。
    // 此前 QML 额外调用 applet.refresh() 会打破 1 秒定时间隔，
    // 导致 calculateSpeed() 基于不固定间隔计算字节差，速度显示接近 0。

    Timer {
        id: toolTipShowTimer
        interval: 50
        onTriggered: {
            const point = root.mapToItem(null, root.width / 2, root.height / 2)
            toolTip.DockPanelPositioner.bounding = Qt.rect(point.x, point.y, toolTip.width, toolTip.height)
            toolTip.open()
        }
    }

    HoverHandler {
        onHoveredChanged: {
            // 仅控制 tooltip 显示，不触发 refresh。
            // C++ 后端 m_refreshTimer 持续每秒更新速度属性，QML 属性绑定自动反映。
            if (hovered && !networkPopup.popupVisible) {
                toolTipShowTimer.start()
            } else {
                if (toolTipShowTimer.running) {
                    toolTipShowTimer.stop()
                }
                toolTip.close()
            }
        }
    }

    // 弹出窗口
    PanelPopup {
        id: networkPopup
        width: 360
        height: 320
        popupX: DockPanelPositioner.x
        popupY: DockPanelPositioner.y

        onPopupVisibleChanged: {
            // 仅控制 tooltip 关闭，不触发 refresh。
            // C++ 后端 m_refreshTimer 持续更新，popup 通过属性绑定自动显示最新数据。
            if (popupVisible) {
                toolTip.close()
                // popup 打开时确保活动 chip 完整可见：直接定位不播放动画，避免看到打开瞬间的滚动；
                // Qt.callLater 等待首次打开时 Repeater 完成实例化与布局后再计算位置
                Qt.callLater(function() { chipFlickable.scrollToActiveChip(false) })
            }
        }

        Control {
            id: popupContainer
            anchors.fill: parent
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
                            color: root.primaryText
                            Layout.alignment: Qt.AlignHCenter
                        }

                        // 网卡名 + IP 地址卡片背景
                        Rectangle {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.preferredWidth: 300
                            // 有 IPv6 时增高以容纳第三行；无 IPv6 时保持原 40px
                            Layout.preferredHeight: root.ipv6Address ? 54 : 40
                            color: root.cardBackground
                            radius: 8
                            border.width: 1
                            border.color: root.cardBorder
                            visible: root.ready

                            ColumnLayout {
                                anchors.centerIn: parent
                                spacing: 0

                                Text {
                                    text: root.activeInterface
                                    font.pixelSize: 11
                                    color: root.secondaryText
                                    Layout.alignment: Qt.AlignHCenter
                                }

                                Text {
                                    text: root.ipAddress ? qsTr("IPv4：") + root.ipAddress : ""
                                    font.pixelSize: 13
                                    color: root.secondaryText
                                    visible: root.ipAddress !== ""
                                    Layout.alignment: Qt.AlignHCenter
                                }

                                // IPv6 全球地址行，无 IPv6 时隐藏不占位
                                Text {
                                    text: root.ipv6Address ? qsTr("IPv6：") + root.ipv6Address : ""
                                    font.pixelSize: 13
                                    color: root.secondaryText
                                    visible: root.ipv6Address !== ""
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
                    color: root.cardBackground
                    radius: 12
                    border.width: 1
                    border.color: root.cardBorder

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
                                color: root.accentBlueLight
                                Layout.alignment: Qt.AlignHCenter

                                Text {
                                    anchors.centerIn: parent
                                    text: "↓"
                                    font.pixelSize: 18
                                    font.weight: Font.Bold
                                    color: root.accentBlue
                                }
                            }

                            Text {
                                text: qsTr("下载")
                                font.pixelSize: 11
                                color: root.secondaryText
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: root.formatSpeed(root.downloadSpeed)
                                font.pixelSize: 18
                                font.weight: Font.Bold
                                color: root.downloadValueColor
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
                        color: root.cardBorder
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
                                color: root.accentGreenLight
                                Layout.alignment: Qt.AlignHCenter

                                Text {
                                    anchors.centerIn: parent
                                    text: "↑"
                                    font.pixelSize: 18
                                    font.weight: Font.Bold
                                    color: root.accentGreen
                                }
                            }

                            Text {
                                text: qsTr("上传")
                                font.pixelSize: 11
                                color: root.secondaryText
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: root.formatSpeed(root.uploadSpeed)
                                font.pixelSize: 18
                                font.weight: Font.Bold
                                color: root.uploadValueColor
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }
                }

                // 总量统计：单行紧凑
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44
                    color: root.cardBackground
                    radius: 12
                    border.width: 1
                    border.color: root.cardBorder
                    visible: root.ready

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 8

                        Item { Layout.fillWidth: true }

                        Text {
                            text: qsTr("总计")
                            font.pixelSize: 11
                            font.weight: Font.Bold
                            color: root.secondaryText
                        }

                        Text {
                            text: "↓ " + root.formatTotal(root.totalDownload)
                            font.pixelSize: 12
                            color: root.primaryText
                        }

                        Text {
                            text: "↑ " + root.formatTotal(root.totalUpload)
                            font.pixelSize: 12
                            color: root.primaryText
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
                    visible: root.ready && root.networkInterfaces.length > 1
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
                        var idx = root.sortedInterfaces.indexOf(root.activeInterface)
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
                        target: root
                        function onActiveInterfaceChanged() {
                            chipFlickable.scrollToActiveChip(true)
                        }
                    }

                    // 等宽分配宽度：假设所有 chip 等宽撑满时的单个宽度
                    readonly property real equalChipWidth: root.sortedInterfaces.length > 0
                        ? (width - 6 * (root.sortedInterfaces.length - 1)) / root.sortedInterfaces.length
                        : 0

                    Row {
                        id: chipRow
                        spacing: 6

                        Repeater {
                            id: chipRepeater
                            model: root.sortedInterfaces

                            Rectangle {
                                // 宽度取等宽和自然宽度的较大值：
                                // chip 少时 equalChipWidth > 自然宽度 -> 分散撑满一行
                                // chip 多时 自然宽度 > equalChipWidth -> 固定宽度 + 水平滚动
                                width: Math.max(chipFlickable.equalChipWidth, chipText.implicitWidth + 24)
                                height: 28
                                radius: 8
                                color: modelData === root.activeInterface
                                       ? root.accentBlue
                                       : (chipMouse.containsMouse ? root.accentBlueLight : root.cardBackground)
                                border.width: 1
                                border.color: modelData === root.activeInterface
                                               ? root.accentBlue
                                               : root.cardBorder

                                Text {
                                    id: chipText
                                    anchors.centerIn: parent
                                    text: modelData
                                    font.pixelSize: 11
                                    font.weight: modelData === root.activeInterface ? Font.Bold : Font.Normal
                                    color: modelData === root.activeInterface ? "white" : root.primaryText
                                }

                                MouseArea {
                                    id: chipMouse
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    hoverEnabled: true
                                    onClicked: {
                                        if (root.applet) root.applet.setActiveInterface(modelData)
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
                            color: chipScrollBar.pressed ? root.secondaryText
                                  : (chipScrollBar.hovered ? root.secondaryText : root.tertiaryText)
                        }
                    }
                }

                // 未检测到接口占位
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 80
                    color: root.cardBackground
                    radius: 12
                    border.width: 1
                    border.color: root.cardBorder
                    visible: !root.ready

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: "⚠"
                            font.pixelSize: 24
                            color: root.secondaryText
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            text: qsTr("未检测到网络接口")
                            font.pixelSize: 12
                            color: root.secondaryText
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }

        Component.onCompleted: {
            DockPanelPositioner.bounding = Qt.binding(function () {
                const point = root.mapToItem(null, root.width / 2, root.height / 2)
                return Qt.rect(point.x, point.y, networkPopup.width, networkPopup.height)
            })
        }
    }

    // 右键菜单：使用 Qt.labs.platform.Menu + MenuHelper
    // 设计原因：dde-shell dock 环境下 AppletItem 嵌入 layer-shell 窗口，
    // QtQuick.Controls.Menu.popup() 无法获取有效 QQuickWindow 来弹出菜单。
    // 必须用 Qt.labs.platform.Menu（原生菜单）配合 org.deepin.ds.dock 的
    // MenuHelper 单例管理菜单生命周期（确保同一时间只有一个菜单打开）。
    Platform.Menu {
        id: contextMenu

        Platform.MenuItem {
            text: qsTr("设置")
            onTriggered: {
                settingsWindow.show()
                settingsWindow.raise()
                settingsWindow.requestActivate()
            }
        }

        // 流量波动图：屏幕居中独立窗口，展示活动接口最近 30 分钟网速趋势
        Platform.MenuItem {
            text: qsTr("流量波动图")
            onTriggered: {
                trafficChartWindow.show()
                trafficChartWindow.raise()
                trafficChartWindow.requestActivate()
            }
        }

        Platform.MenuSeparator {}

        Platform.MenuItem {
            text: qsTr("关于")
            onTriggered: {
                aboutWindow.show()
                aboutWindow.raise()
                aboutWindow.requestActivate()
            }
        }
    }

    // 关于窗口：抽取为独立组件 package/components/AboutWindow.qml
    // 依赖通过属性传入：accentColor = root.accentRed，version 取自 C++ 后端 applet.version
    AboutWindow {
        id: aboutWindow
        accentColor: root.accentRed
        version: root.applet ? root.applet.version : "1.0"
    }

    // 流量波动图窗口：屏幕居中独立窗口，展示活动接口最近 30 分钟网速趋势
    // 依赖通过属性传入：accentColor = root.accentRed，applet = root.applet
    TrafficChartWindow {
        id: trafficChartWindow
        accentColor: root.accentRed
        applet: root.applet
    }

    // 设置窗口：独立顶层窗口，在桌面中间弹出
    // 设计原因：Dialog 使用父窗口（dock layer-surface）的 overlay，仅覆盖任务栏区域，
    // 无法在桌面中间显示。改用 Window 创建独立顶层窗口，可在桌面任意位置弹出。
    SettingsWindow {
        id: settingsWindow
        applet: root.applet
        networkInterfaces: root.networkInterfaces
        activeInterface: root.activeInterface
        accentColor: root.accentRed
    }

    // 点击处理
    TapHandler {
        acceptedButtons: Qt.LeftButton
        gesturePolicy: TapHandler.ReleaseWithinBounds

        onTapped: {
            if (networkPopup.popupVisible) {
                networkPopup.close()
            } else {
                Panel.requestClosePopup()
                const point = root.mapToItem(null, root.width / 2, root.height / 2)
                networkPopup.DockPanelPositioner.bounding = Qt.rect(point.x, point.y, networkPopup.width, networkPopup.height)
                networkPopup.open()
            }
            toolTip.close()
        }
    }

    // 右键点击：弹出上下文菜单
    TapHandler {
        acceptedButtons: Qt.RightButton
        gesturePolicy: TapHandler.ReleaseWithinBounds

        onTapped: {
            // 关闭可能打开的 popup，避免视觉冲突
            if (networkPopup.popupVisible) networkPopup.close()
            toolTip.close()
            // 使用 MenuHelper 打开菜单（dde-shell dock 环境必需，
            // 它会先关闭当前活动菜单再打开新菜单，保证同一时间只有一个菜单）
            MenuHelper.openMenu(contextMenu)
        }
    }
}