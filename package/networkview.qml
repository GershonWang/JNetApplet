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

    // 任务栏图标颜色派生自 DTK 系统调色板（windowText），跟随系统主题适配。
    // 设计原因：原用 DockPalette.iconTextPalette，但实测其不随系统深色主题变化，
    // 深色模式下返回深色文字（黑底黑字）、浅色模式下返回浅色文字（白底白字），方向相反。
    // DTK.palette.windowText 在深色模式下为浅色、浅色模式下为深色，与任务栏背景匹配。
    // 注意：仅用于任务栏图标区（speedTextColor 回退），弹窗和独立窗口各自派生颜色。
    readonly property color baseTextColor: DTK.palette.windowText
    readonly property color primaryText: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.95)
    readonly property color secondaryText: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.80)
    readonly property color tertiaryText: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.65)
    readonly property color cardBackground: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.06)
    readonly property color cardBorder: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.10)

    // 深色模式检测：用 DTK 系统调色板的窗口背景亮度判定，而非 DockPalette。
    // 设计原因：DockPalette.iconTextPalette 反映的是任务栏图标文字色，不随系统深色主题变化；
    // DTK.palette.window 是系统主题的窗口背景色，深色模式下为深色（hslLightness < 0.5），
    // 浅色模式下为浅色（hslLightness >= 0.5）。主题切换时 DTK.paletteChanged 自动触发重新求值。
    // 检测结果通过属性注入各独立窗口（AboutWindow 等独立 Window 无法访问 dock 上下文的 DockPalette）
    readonly property bool isDarkMode: DTK.palette.window.hslLightness < 0.5

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
    // 设计原因：primaryText 派生自 DTK.palette.windowText，深浅色系统主题自动适配；
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

    // 弹出窗口：PanelPopup 壳在此处（dock 上下文类型不能作为独立组件根元素），
    // 弹窗内容由 NetworkPopup.qml 提供，传入 applet，内部自行派生颜色和数据
    PanelPopup {
        id: networkPopup
        width: 360
        height: 320
        popupX: DockPanelPositioner.x
        popupY: DockPanelPositioner.y

        onPopupVisibleChanged: {
            if (popupVisible) {
                toolTip.close()
                // popup 打开时确保活动 chip 完整可见
                Qt.callLater(function() { popupContent.scrollToActiveChip(false) })
            }
        }

        NetworkPopup {
            id: popupContent
            applet: root.applet
            anchors.fill: parent
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
    // 依赖通过属性传入：accentColor = root.accentRed，version 取自 C++ 后端 applet.version，
    // isDarkMode 取自上方 DockPalette 检测结果
    AboutWindow {
        id: aboutWindow
        accentColor: root.accentRed
        version: root.applet ? root.applet.version : "1.0"
        isDarkMode: root.isDarkMode
    }

    // 流量波动图窗口：屏幕居中独立窗口，展示活动接口最近 30 分钟网速趋势
    // 依赖通过属性传入：accentColor = root.accentRed，applet = root.applet，
    // isDarkMode 取自上方 DockPalette 检测结果
    TrafficChartWindow {
        id: trafficChartWindow
        accentColor: root.accentRed
        applet: root.applet
        isDarkMode: root.isDarkMode
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
        isDarkMode: root.isDarkMode
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