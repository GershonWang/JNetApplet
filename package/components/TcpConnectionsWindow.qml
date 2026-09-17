// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// TCP 连接清单窗口：屏幕居中的独立顶层窗口，展示当前所有 ESTABLISHED 状态的
// TCP 连接详情（本地地址:端口、远程地址:端口、状态、进程名），数据来自 C++ 后端
// 解析 /proc/net/tcp 与 tcp6（含进程名反查）。
// 设计要点：
// - 视觉风格复用 TrafficStatsWindow.qml（圆角卡片 12px、1px 边框、44px 标题栏、
//   28x28 圆形关闭按钮 hover 淡红底）；深/浅主题由 isDarkMode 切换
//   （networkview.qml 依据 DTK.palette 检测任务栏深浅后传入），默认浅色保证独立预览可用
// - 数据通过属性注入：applet 即 networkview.qml 的 root.applet（C++ 后端对象），
//   applet.tcpConnectionList 为 QVariantList of QVariantMap，每项含
//   {localAddress, localPort, remoteAddress, remotePort, state, processName}，
//   为 null 时组件可独立预览（显示空状态）
// - 定时刷新：窗口可见时每 5 秒重建清单（与 C++ 后端降频周期一致），关闭时停止
// 触发方式：右键菜单"TCP 连接清单" -> show()/raise()/requestActivate()
// 公共能力复用：主题色取自 WindowTheme，标题栏（含关闭按钮）取自 TitleBar
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import "."

Window {
    id: root

    // 公共主题色：集中定义于 WindowTheme.qml，随 isDarkMode 切换深浅
    WindowTheme {
        id: theme
        isDarkMode: root.isDarkMode
    }

    // 公共强调色：仅用于 accentColor 的默认值，避免与其他窗口各写一份红色字面量
    NetCommon { id: common }

    // 对外依赖：关闭按钮 hover 态文字高亮色，由父组件传入
    // 默认值与 networkview.qml 中 root.accentRed 一致（同源于 NetCommon），确保独立可用
    property color accentColor: common.accentRed

    // 对外依赖：C++ 后端对象（NetworkMonitorApplet），由 networkview.qml 传入
    // 提供 tcpConnectionList（QVariantList of QVariantMap）；为 null 时可独立预览（显示空状态）
    property var applet: null

    // 深色模式标记：由 networkview.qml 根据 DTK.palette 检测后传入；
    // 默认 false（浅色）保证组件独立预览时与原版视觉一致
    property bool isDarkMode: false

    // 表格模型：由 refreshModel() 生成的连接记录数组，每项
    // {localAddress, localPort, remoteAddress, remotePort, state, processName}
    property var connModel: []

    // 搜索关键字：非空时筛选匹配本地/远程地址、端口、进程名的连接
    property string searchText: ""

    // 筛选后的模型：searchText 为空时返回全部，否则按关键字过滤
    // 匹配字段：localAddress/localPort/remoteAddress/remotePort/processName
    readonly property var filteredModel: {
        var list = root.connModel
        if (root.searchText.length === 0) return list
        var key = root.searchText.toLowerCase()
        var result = []
        for (var i = 0; i < list.length; i++) {
            var c = list[i]
            if (String(c.localAddress).toLowerCase().indexOf(key) >= 0
                || String(c.localPort).indexOf(key) >= 0
                || String(c.remoteAddress).toLowerCase().indexOf(key) >= 0
                || String(c.remotePort).indexOf(key) >= 0
                || String(c.processName).toLowerCase().indexOf(key) >= 0) {
                result.push(c)
            }
        }
        return result
    }

    // 当前连接总数，底部汇总与顶部状态条共用
    property int connCount: 0

    // 表格列宽：与表头/数据行共用同一组值，保证各列垂直对齐
    // 设计原因：原实现写死 180/180/90，列宽与窗口宽度、字体大小脱钩。
    // 现按可用宽度取比例：本地地址 27%、远程地址 27%、状态 14%，
    // 剩余宽度留给进程名列（该列以 Layout.fillWidth 吸收剩余空间）。
    // 比例按原视觉反推，680px 窗口下的结果与原值接近（175/175/91 对 180/180/90）
    readonly property int colSpacing: 6
    // 表格可用宽度 = 窗口宽 - 左右各 16 的内边距（表头与 ListView 使用的是同一组边距）
    readonly property real tableWidth: Math.max(0, width - 32)
    readonly property int colLocal: Math.max(120, Math.round(tableWidth * 0.27))
    readonly property int colRemote: Math.max(120, Math.round(tableWidth * 0.27))
    readonly property int colState: Math.max(76, Math.round(tableWidth * 0.14))

    // 从 applet.tcpConnectionList 重建表格模型
    // 设计原因：连接清单数量随时变化，每次读取重建数组供 ListView 展示；
    // applet 为 null 时置空模型，保证独立预览可用
    function refreshModel() {
        var list = root.applet ? (root.applet.tcpConnectionList || []) : []
        root.connModel = list
        root.connCount = list.length
    }

    width: 680
    height: 420
    visible: false
    flags: Qt.FramelessWindowHint | Qt.Window
    modality: Qt.NonModal
    color: "transparent"

    onVisibleChanged: {
        if (visible) {
            // 居中到当前屏幕（任务栏所在屏幕），加 virtualX/virtualY 偏移
            // 避免多显示器下窗口出现在非预期屏幕
            x = Screen.virtualX + (Screen.width - width) / 2
            y = Screen.virtualY + (Screen.height - height) / 2
            // 窗口显示时立即刷新一次，确保数据最新
            refreshModel()
        }
    }

    // 兜底刷新：窗口可见时按刷新间隔的 5 倍重建清单（与 C++ 后端 5 秒降频周期一致），
    // 主要更新通道是下方 tcpConnectionListChanged 信号，此处仅作兜底；关闭时停止
    // 设计原因：原实现直接用 refreshInterval（1 倍），与注释所述 5 倍降频不符，
    // 导致窗口打开期间每秒整体重建一次模型
    Timer {
        interval: (root.applet ? root.applet.refreshInterval : 1000) * 5
        repeat: true
        running: root.visible
        onTriggered: refreshModel()
    }

    // 窗口主体：圆角卡片（背景与边框随 isDarkMode 切换深浅），1px 边框模拟 DTK 窗口描边
    Rectangle {
        anchors.fill: parent
        color: theme.winBg
        radius: 12
        border.width: 1
        border.color: theme.lineColor

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // 公共标题栏：标题文字 + 关闭按钮，整栏可拖动
            TitleBar {
                Layout.fillWidth: true
                titleText: qsTr("TCP Connections")
                textColor: theme.textPrimary
                secondaryTextColor: theme.textSecondary
                closeHoverColor: root.accentColor
            }

            // 顶部状态条：当前连接数 + 搜索框 + 刷新间隔说明
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                spacing: 8

                Text {
                    // 动态刷新连接总数，显示筛选后数量/总数
                    text: qsTr("Active connections: ") + root.filteredModel.length + "/" + root.connCount
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    color: theme.textPrimary
                }

                // 搜索框：输入关键字筛选匹配地址/端口/进程名的连接
                TextField {
                    id: searchField
                    Layout.preferredWidth: 200
                    placeholderText: qsTr("Search address, port, process...")
                    font.pixelSize: 12
                    color: theme.textPrimary
                    selectByMouse: true
                    onTextChanged: root.searchText = text
                }

                // 用 Binding 而不是直接写 text: root.searchText：
                // 直接绑定会在用户首次输入时被 TextField 的内部赋值销毁，
                // 导致点击"×"把 root.searchText 置空后，输入框仍显示旧关键字（UI 与实际筛选不一致）
                Binding {
                    target: searchField
                    property: "text"
                    value: root.searchText
                    restoreMode: Binding.RestoreNone
                }

                // 清除按钮：有输入时显示 ×，点击清空搜索
                Rectangle {
                    visible: root.searchText.length > 0
                    width: 20; height: 20
                    radius: 10
                    color: clearSearchMouse.pressed
                           ? Qt.darker(theme.hoverBg, 1.12)
                           : (clearSearchMouse.containsMouse ? theme.hoverBg : "transparent")
                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        font.pixelSize: 14
                        color: clearSearchMouse.pressed
                               ? Qt.darker(root.accentColor, 1.15)
                               : (clearSearchMouse.containsMouse ? root.accentColor : theme.textTertiary)
                    }
                    MouseArea {
                        id: clearSearchMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.searchText = ""
                    }
                }

                Item { Layout.fillWidth: true }

                Text {
                    text: qsTr("Refreshes every ") + ((root.applet ? root.applet.refreshInterval : 1000) / 1000) + qsTr(" seconds")
                    font.pixelSize: 11
                    color: theme.textTertiary
                }
            }

            // 表头行：本地地址:端口 | 远程地址:端口 | 状态 | 进程名
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 2
                spacing: root.colSpacing

                Text {
                    Layout.preferredWidth: root.colLocal
                    text: qsTr("Local Address:Port")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colRemote
                    text: qsTr("Remote Address:Port")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colState
                    text: qsTr("State")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: theme.textSecondary
                }
                Text {
                    Layout.fillWidth: true
                    text: qsTr("Process")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: theme.textSecondary
                }
            }

            // 表头与内容间的分隔线
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 4
                color: theme.lineColor
            }

            // 表格区：ListView 展示每条连接记录，行 hover 高亮
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 2
                Layout.bottomMargin: 2
                clip: true
                model: root.filteredModel
                onCountChanged: emptyHint.visible = root.filteredModel.length === 0

                // 空状态提示（当筛选结果为空时显示）
                Item {
                    id: emptyHint
                    anchors.fill: parent
                    visible: root.filteredModel.length === 0
                    Text {
                        anchors.centerIn: parent
                        text: root.searchText.length > 0 ? qsTr("No matching connections") : qsTr("No active TCP connections")
                        font.pixelSize: 13
                        color: theme.textTertiary
                    }
                }

                delegate: Rectangle {
                    required property int index
                    required property var modelData
                    width: ListView.view.width
                    height: 28
                    radius: 4
                    // 行 hover 高亮：浅色用淡黑、深色用淡白，保证两种卡片背景上均可见
                    color: rowMouse.containsMouse ? theme.hoverBg : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        // 不再额外缩进：ListView 自身已有 16 左右边距，
                        // 此处再各加 8 会使数据列比表头右移 8px（原实现即为此错位）
                        anchors.leftMargin: 0
                        anchors.rightMargin: 0
                        spacing: root.colSpacing

                        Text {
                            Layout.preferredWidth: root.colLocal
                            text: modelData.localAddress + ":" + modelData.localPort
                            font.pixelSize: 12
                            color: theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colRemote
                            text: modelData.remoteAddress + ":" + modelData.remotePort
                            font.pixelSize: 12
                            color: theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colState
                            text: modelData.state
                            font.pixelSize: 12
                            color: theme.textSecondary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            // 进程名可能为空（反查失败），显示占位符避免空白行
                            text: modelData.processName.length > 0 ? modelData.processName : "-"
                            font.pixelSize: 12
                            color: modelData.processName.length > 0 ? theme.textPrimary : theme.textTertiary
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                    }
                }
            }

            // 表头与底部汇总间的分隔线
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                color: theme.lineColor
            }

            // 底部汇总行：连接总数
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                // 与表头/数据行保持同一左边界（原为 24，比表头多 8px）
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                spacing: root.colSpacing

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Total: ") + root.filteredModel.length + "/" + root.connCount + qsTr(" connections")
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    color: theme.textPrimary
                }
            }
        }
    }

    // 数据刷新：C++ 每 5 秒更新并发射 tcpConnectionListChanged，据此重建清单；
    // 窗口不可见时跳过（显示时 onVisibleChanged 会补一次刷新），避免隐藏状态下白重建模型
    Connections {
        target: root.applet
        function onTcpConnectionListChanged() {
            if (!root.visible) return
            refreshModel()
        }
    }
}
