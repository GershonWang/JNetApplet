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

AppletItem {
    id: root
    objectName: "network monitor applet"
    property int dockOrder: 21
    property int dockSize: Panel.rootObject.dockItemMaxSize || 48

    // 任务栏宽度稍宽于标准 dock 尺寸，容纳双行速度数值
    // 设计原因：固定宽度避免数值长度变化导致插件宽度抖动、箭头位置漂移
    implicitWidth: Math.round(dockSize * 1.35)
    implicitHeight: dockSize

    readonly property var applet: Applet
    readonly property bool ready: applet ? applet.ready : false
    readonly property real downloadSpeed: applet ? applet.downloadSpeed : 0
    readonly property real uploadSpeed: applet ? applet.uploadSpeed : 0
    readonly property real totalDownload: applet ? applet.totalDownload : 0
    readonly property real totalUpload: applet ? applet.totalUpload : 0
    readonly property string activeInterface: applet ? (applet.activeInterface || "") : ""
    // 活动接口的 IPv4 地址，由 C++ 后端 detectIpAddress 持续更新
    readonly property string ipAddress: applet ? (applet.ipAddress || "") : ""
    readonly property var networkInterfaces: applet ? (applet.networkInterfaces || []) : []
    readonly property var interfaceStats: applet ? (applet.interfaceStats || []) : []

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

    // 任务栏图标区：双行紧凑数值，箭头与数值紧贴、左对齐
    // 设计原因：箭头与数值作为一组固定在左侧，数值左对齐紧贴箭头；
    // 不给每行固定高度，让 RowLayout 按内容自然高度排列，
    // 整组垂直居中于 dock 区域，避免两行间出现过大间隙
    Column {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 4
        spacing: 0

        // 下载速度行
        RowLayout {
            spacing: 2

            Text {
                text: "↓"
                font.pixelSize: root.dockSize * 0.18
                color: root.secondaryText
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                text: root.formatSpeedShort(root.downloadSpeed)
                font.pixelSize: root.dockSize * 0.22
                font.weight: Font.Medium
                color: root.downloadValueColor
                Layout.alignment: Qt.AlignVCenter
                horizontalAlignment: Text.AlignLeft
            }
        }

        // 上传速度行
        RowLayout {
            spacing: 2

            Text {
                text: "↑"
                font.pixelSize: root.dockSize * 0.18
                color: root.secondaryText
                Layout.alignment: Qt.AlignVCenter
            }

            Text {
                text: root.formatSpeedShort(root.uploadSpeed)
                font.pixelSize: root.dockSize * 0.22
                font.weight: Font.Medium
                color: root.uploadValueColor
                Layout.alignment: Qt.AlignVCenter
                horizontalAlignment: Text.AlignLeft
            }
        }
    }

    // 悬停提示：网卡名 + IP 地址一行展示
    // PanelToolTip 不支持 contentItem 覆盖和文本对齐，用默认左对齐 text 属性
    PanelToolTip {
        id: toolTip
        text: root.ready
              ? (root.activeInterface + " · " + qsTr("IP地址：") + (root.ipAddress || qsTr("无")))
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
                            Layout.preferredWidth: 180
                            Layout.preferredHeight: 40
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
                                    text: root.ipAddress ? qsTr("IP地址：") + root.ipAddress : ""
                                    font.pixelSize: 13
                                    color: root.secondaryText
                                    visible: root.ipAddress !== ""
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

                // 接口切换 chip 列表（仅多接口时显示，一行等宽分散显示）
                Row {
                    Layout.fillWidth: true
                    spacing: 6
                    visible: root.ready && root.networkInterfaces.length > 1

                    Repeater {
                        model: root.networkInterfaces

                        Rectangle {
                            // 每个 chip 等宽分配，撑满一行分散显示
                            width: root.networkInterfaces.length > 0
                                   ? (parent.width - 6 * (root.networkInterfaces.length - 1)) / root.networkInterfaces.length
                                   : 0
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
            text: qsTr("刷新")
            onTriggered: {
                if (root.applet) root.applet.refresh()
            }
        }

        Platform.MenuSeparator {}

        Platform.MenuItem {
            text: qsTr("设置")
            onTriggered: settingsWindow.show()
        }

        Platform.MenuSeparator {}

        Platform.MenuItem {
            text: qsTr("关于")
            onTriggered: aboutDialog.open()
        }
    }

    // 关于对话框：显示插件信息
    Dialog {
        id: aboutDialog
        anchors.centerIn: parent
        modal: true
        width: 280
        height: 160

        background: Rectangle {
            color: root.cardBackground
            radius: 12
            border.width: 1
            border.color: root.cardBorder
        }

        contentItem: ColumnLayout {
            spacing: 8

            Text {
                text: qsTr("网络速度监控")
                font.pixelSize: 16
                font.weight: Font.Bold
                color: root.primaryText
                Layout.alignment: Qt.AlignHCenter
            }

            Text {
                text: qsTr("版本：1.0")
                font.pixelSize: 12
                color: root.secondaryText
                Layout.alignment: Qt.AlignHCenter
            }

            Text {
                text: qsTr("监控网络速度和流量")
                font.pixelSize: 11
                color: root.tertiaryText
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 240
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            Item { Layout.fillHeight: true }

            Button {
                text: qsTr("确定")
                Layout.alignment: Qt.AlignHCenter
                onClicked: aboutDialog.close()
            }
        }
    }

    // 设置窗口：独立顶层窗口，在桌面中间弹出
    // 设计原因：Dialog 使用父窗口（dock layer-surface）的 overlay，仅覆盖任务栏区域，
    // 无法在桌面中间显示。改用 Window 创建独立顶层窗口，可在桌面任意位置弹出。
    Window {
        id: settingsWindow
        width: 340
        height: 350
        visible: false
        flags: Qt.FramelessWindowHint | Qt.Window
        // NonModal：不阻塞桌面其他区域，用户可同时操作任务栏
        modality: Qt.NonModal
        // 窗口透明：让圆角外的区域不显示，由内部 Rectangle 提供可见背景
        color: "transparent"

        // 显示时居中到桌面
        onVisibleChanged: {
            if (visible) {
                x = (Screen.width - width) / 2
                y = (Screen.height - height) / 2
            }
        }

        // 主容器：提供不透明背景 + 圆角 + 边框
        Rectangle {
            anchors.fill: parent
            color: "#f5f5f5"
            radius: 12
            border.width: 1
            border.color: "#e0e0e0"

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 0
                spacing: 0

                // 自定义标题栏（可拖动）
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44
                    color: "transparent"

                    // 拖动区域
                    MouseArea {
                        anchors.fill: parent
                        drag.target: settingsWindow
                        cursorShape: Qt.ArrowCursor
                    }

                    // 标题文字
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("设置")
                        font.pixelSize: 15
                        font.weight: Font.Bold
                        color: "#333333"
                    }

                    // 关闭按钮
                    Rectangle {
                        id: closeButton
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: 28
                        height: 28
                        radius: 14
                        color: closeMouse.containsMouse ? Qt.rgba(220/255, 38/255, 38/255, 0.15) : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: "×"
                            font.pixelSize: 20
                            font.weight: Font.Bold
                            color: closeMouse.containsMouse ? root.accentRed : "#666666"
                        }

                        MouseArea {
                            id: closeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: settingsWindow.hide()
                        }
                    }
                }

                // 分隔线
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: "#e0e0e0"
                }

                // 内容区域
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 16
                        spacing: 12

                        // 网络接口选择区
                        Text {
                            text: qsTr("网络接口")
                            font.pixelSize: 13
                            font.weight: Font.Bold
                            color: "#666666"
                        }

                        // 接口列表容器
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: root.networkInterfaces.length > 0 ? 40 + root.networkInterfaces.length * 28 : 80
                            color: "#ffffff"
                            radius: 10
                            border.width: 1
                            border.color: "#e0e0e0"

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 8

                                // 接口列表：RadioButton 单选切换活动接口
                                Repeater {
                                    model: root.networkInterfaces
                                    delegate: Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 28
                                        color: "transparent"
                                        radius: 6

                                        RadioButton {
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData
                                            checked: modelData === root.activeInterface
                                            onToggled: {
                                                if (root.applet) root.applet.setActiveInterface(modelData)
                                            }
                                        }
                                    }
                                }

                                // 无接口提示
                                Text {
                                    text: qsTr("未检测到网络接口")
                                    font.pixelSize: 12
                                    color: "#999999"
                                    visible: root.networkInterfaces.length === 0
                                    Layout.alignment: Qt.AlignHCenter
                                }
                            }
                        }

                        Item { Layout.fillHeight: true }

                        // 卸载插件按钮
                        Rectangle {
                            id: uninstallButton
                            Layout.fillWidth: true
                            Layout.preferredHeight: 40
                            color: uninstallMouse.containsMouse ? Qt.rgba(220/255, 38/255, 38/255, 0.15) : Qt.rgba(220/255, 38/255, 38/255, 0.08)
                            radius: 10
                            border.width: 1
                            border.color: root.accentRed

                            Text {
                                anchors.centerIn: parent
                                text: qsTr("卸载插件")
                                font.pixelSize: 13
                                font.weight: Font.Medium
                                color: root.accentRed
                            }

                            MouseArea {
                                id: uninstallMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: uninstallConfirmDialog.open()
                            }
                        }

                        // 卸载状态提示（确认后显示，提示用户去终端执行）
                        Text {
                            id: uninstallStatus
                            visible: false
                            text: qsTr("卸载命令已复制到剪贴板，请在终端中粘贴执行")
                            font.pixelSize: 11
                            color: "#16a34a"
                            Layout.alignment: Qt.AlignHCenter
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                        }

                        // 关闭按钮
                        Rectangle {
                            id: bottomCloseButton
                            Layout.fillWidth: true
                            Layout.preferredHeight: 40
                            color: bottomCloseMouse.containsMouse ? root.accentBlueLight : "#ffffff"
                            radius: 10
                            border.width: 1
                            border.color: bottomCloseMouse.containsMouse ? root.accentBlue : "#e0e0e0"

                            Text {
                                anchors.centerIn: parent
                                text: qsTr("关闭")
                                font.pixelSize: 13
                                font.weight: Font.Medium
                                color: bottomCloseMouse.containsMouse ? root.accentBlue : "#333333"
                            }

                            MouseArea {
                                id: bottomCloseMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: settingsWindow.hide()
                            }
                        }
                    }
                }
            }
        }

        // 卸载确认对话框
        Dialog {
            id: uninstallConfirmDialog
            width: 320
            height: 260
            modal: true
            visible: false

            background: Rectangle {
                color: "#f5f5f5"
                radius: 12
                border.width: 1
                border.color: "#e0e0e0"
            }

            contentItem: ColumnLayout {
                spacing: 16
                anchors.fill: parent
                anchors.margins: 20

                Text {
                    text: qsTr("警告")
                    font.pixelSize: 16
                    font.weight: Font.Bold
                    color: root.accentRed
                    Layout.alignment: Qt.AlignHCenter
                }

                Text {
                    text: qsTr("确定要卸载此插件吗？此操作将删除插件文件并重启 dde-shell。")
                    font.pixelSize: 12
                    color: "#333333"
                    Layout.alignment: Qt.AlignHCenter
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                }

                // 命令显示区域
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 60
                    color: "#e8e8e8"
                    radius: 8

                    Text {
                        anchors.fill: parent
                        anchors.margins: 10
                        text: "sudo rm -rf /usr/share/dde-shell/space.jokul.JNetApplet/ && systemctl --user restart dde-shell@DDE"
                        font.pixelSize: 10
                        font.family: "monospace"
                        color: "#666666"
                        wrapMode: Text.WordWrap
                    }
                }

                Item { Layout.fillHeight: true }

                // 按钮区域
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12

                    // 取消按钮
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 36
                        color: cancelUninstallMouse.containsMouse ? "#f0f0f0" : "#ffffff"
                        radius: 8
                        border.width: 1
                        border.color: "#e0e0e0"

                        Text {
                            anchors.centerIn: parent
                            text: qsTr("取消")
                            font.pixelSize: 13
                            color: "#333333"
                        }

                        MouseArea {
                            id: cancelUninstallMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: uninstallConfirmDialog.close()
                        }
                    }

                    // 确认卸载按钮
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 36
                        color: confirmUninstallMouse.containsMouse ? root.accentRed : Qt.rgba(220/255, 38/255, 38/255, 0.8)
                        radius: 8

                        Text {
                            anchors.centerIn: parent
                            text: qsTr("确认卸载")
                            font.pixelSize: 13
                            font.weight: Font.Medium
                            color: "white"
                        }

                        MouseArea {
                            id: confirmUninstallMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                // 复制卸载命令到剪贴板
                                clipboardHelper.selectAll()
                                clipboardHelper.copy()
                                uninstallConfirmDialog.close()
                                // 显示状态提示，5 秒后自动隐藏
                                uninstallStatus.visible = true
                                statusHideTimer.start()
                            }
                        }
                    }
                }
            }
        }
    }

    // 隐藏的 TextEdit 用于复制卸载命令到剪贴板
    // QML 没有直接剪贴板 API，用 TextEdit.selectAll()+copy() 实现
    TextEdit {
        id: clipboardHelper
        visible: false
        text: "sudo rm -rf /usr/share/dde-shell/space.jokul.JNetApplet/ && systemctl --user restart dde-shell@DDE"
    }

    // 卸载状态提示自动隐藏定时器
    Timer {
        id: statusHideTimer
        interval: 5000
        onTriggered: uninstallStatus.visible = false
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