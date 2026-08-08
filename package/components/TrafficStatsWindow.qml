// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 流量统计窗口：屏幕居中的独立顶层窗口，展示按日/按月持久化的累计流量
// （下载/上传/总计），数据来自 C++ 后端持久化的 traffic_log.json，
// 跨重启累加，让用户了解长期流量趋势。
// 设计要点：
// - 视觉风格复用 TrafficChartWindow.qml（圆角卡片 12px、1px 边框、44px 标题栏、
//   28x28 圆形关闭按钮 hover 淡红底）；深/浅主题由 isDarkMode 切换
//   （networkview.qml 依据 DockPalette 检测任务栏深浅后传入），默认浅色保证独立预览可用
// - 数据通过属性注入：applet 即 networkview.qml 的 root.applet（C++ 后端对象），
//   applet.trafficLog 为 JSON 对象 {"byDay": {日期: {接口: {rx, tx}}},
//   "byMonth": {月份: {接口: {rx, tx}}}}，为 null 时组件可独立预览（显示空状态）
// - 顶部 tab 切换按日/按月；表格按日期/月份降序（最新在上）展示，每行一个
//   （日期, 接口）记录；底部汇总所有显示记录的总下载/总上传/总流量
// - 数据刷新：C++ 每 30 秒保存并发射 trafficLogChanged，本窗口据此重建表格
// 触发方式：右键菜单"流量统计" -> show()/raise()/requestActivate()
// 公共能力复用：主题色取自 WindowTheme，标题栏（含关闭按钮）取自 TitleBar，
// 格式化函数取自 NetCommon.formatTotal
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import "."

Window {
    id: root

    // 公共格式化函数：集中定义于同目录 NetCommon.qml，
    // 与 networkview.qml、TrafficChartWindow 共享同一份实现
    NetCommon { id: common }

    // 公共主题色：集中定义于 WindowTheme.qml，随 isDarkMode 切换深浅
    WindowTheme {
        id: theme
        isDarkMode: root.isDarkMode
    }

    // 对外依赖：关闭按钮 hover 态文字高亮色，由父组件传入
    // 默认值与 networkview.qml 中 root.accentRed 一致，确保独立可用
    property color accentColor: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)

    // 对外依赖：C++ 后端对象（NetworkMonitorApplet），由 networkview.qml 传入
    // 提供 trafficLog（JSON 对象，见文件头注释）；为 null 时组件可独立预览（显示空状态）
    property var applet: null

    // 深色模式标记：由 networkview.qml 根据 DockPalette 检测后传入；
    // 默认 false（浅色）保证组件独立预览时与原版视觉一致
    property bool isDarkMode: false

    // 当前 tab：0=按日, 1=按月，切换后重建表格模型
    property int currentTab: 0

    // 表格模型：由 buildStatsModel() 生成的扁平记录数组，每项
    // {date, iface, rx, tx, total}，按日期/月份降序（最新在上）排列
    property var statsModel: []

    // 底部汇总：所有显示记录的 rx/tx/total 累加值
    property var totals: ({ rx: 0, tx: 0, total: 0 })

    // 表格列宽：与表头/行/底部汇总共用同一组固定宽度，保证各列垂直对齐
    readonly property int colDate: 118
    readonly property int colIface: 108
    readonly property int colNum: 102
    readonly property int colSpacing: 6

    // 依据 currentTab 与 applet.trafficLog 重建表格模型
    // 设计原因：trafficLog 为 {日期/月份: {接口: {rx, tx}}} 的嵌套对象，
    // 需展平为每行一个（键, 接口）记录并按日期降序排序，才能直接供 ListView 展示；
    // 同时累加所有记录得到底部汇总
    function buildStatsModel() {
        var log = root.applet ? root.applet.trafficLog : {}
        var key = root.currentTab === 0 ? "byDay" : "byMonth"
        var entries = (log && log[key]) || {}
        var rows = []
        var tRx = 0, tTx = 0
        for (var d in entries) {
            var ifaces = entries[d]
            for (var i in ifaces) {
                var rec = ifaces[i]
                var rx = rec ? (rec.rx || 0) : 0
                var tx = rec ? (rec.tx || 0) : 0
                rows.push({ date: d, iface: i, rx: rx, tx: tx, total: rx + tx })
                tRx += rx
                tTx += tx
            }
        }
        // 按日期/月份降序（最新在上），同键内按接口名升序
        rows.sort(function (a, b) {
            if (a.date !== b.date) return a.date < b.date ? 1 : -1
            return a.iface < b.iface ? -1 : 1
        })
        root.statsModel = rows
        root.totals = { rx: tRx, tx: tTx, total: tRx + tTx }
    }

    width: 620
    height: 440
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
        }
    }

    // 切换 tab 或首次创建时重建表格模型
    onCurrentTabChanged: buildStatsModel()
    Component.onCompleted: buildStatsModel()
    // 窗口显示时立即刷新一次，确保数据最新
    onVisibleChanged: if (visible) buildStatsModel()

    // 定时刷新：窗口可见时每 5 秒重建表格，不依赖 C++ 30 秒信号
    // 设计原因：C++ 降频 30 秒通知，用户打开窗口期间看不到实时更新；
    // 窗口可见时主动 5 秒刷新，关闭时停止，兼顾实时性与性能
    Timer {
        interval: 5000
        repeat: true
        running: root.visible
        onTriggered: buildStatsModel()
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
                titleText: qsTr("Traffic Statistics")
                textColor: theme.textPrimary
                secondaryTextColor: theme.textSecondary
                closeHoverColor: root.accentColor
            }

            // 顶部 tab 切换：按日 / 按月
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                spacing: 8

                // 按日 tab
                Rectangle {
                    property bool sel: root.currentTab === 0
                    width: 80
                    height: 24
                    radius: 5
                    color: sel ? common.accentBlue : "transparent"
                    border.width: 1
                    border.color: sel ? common.accentBlue
                                      : (dayMouse.containsMouse ? common.accentBlue : theme.lineColor)
                    Text {
                        anchors.centerIn: parent
                        text: qsTr("By Day")
                        font.pixelSize: 12
                        font.weight: sel ? Font.Bold : Font.Normal
                        color: sel ? "white" : (dayMouse.containsMouse ? common.accentBlue : theme.textSecondary)
                    }
                    MouseArea {
                        id: dayMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.currentTab = 0
                    }
                }

                // 按月 tab
                Rectangle {
                    property bool sel: root.currentTab === 1
                    width: 90
                    height: 24
                    radius: 5
                    color: sel ? common.accentBlue : "transparent"
                    border.width: 1
                    border.color: sel ? common.accentBlue
                                      : (monthMouse.containsMouse ? common.accentBlue : theme.lineColor)
                    Text {
                        anchors.centerIn: parent
                        text: qsTr("By Month")
                        font.pixelSize: 12
                        font.weight: sel ? Font.Bold : Font.Normal
                        color: sel ? "white" : (monthMouse.containsMouse ? common.accentBlue : theme.textSecondary)
                    }
                    MouseArea {
                        id: monthMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.currentTab = 1
                    }
                }

                Item { Layout.fillWidth: true }

                // 右侧数据说明：按接口累计
                Text {
                    text: qsTr("Accumulated by interface")
                    font.pixelSize: 11
                    color: theme.textTertiary
                }
            }

            // 表头行：日期/月份 | 接口 | 下载流量 | 上传流量 | 总计
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 2
                spacing: root.colSpacing

                Text {
                    Layout.preferredWidth: root.colDate
                    text: root.currentTab === 0 ? qsTr("Date") : qsTr("Month")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colIface
                    text: qsTr("Interface")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: qsTr("Download")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: qsTr("Upload")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: qsTr("Total")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: theme.textSecondary
                }
                Item { Layout.fillWidth: true }
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

            // 表格区：ListView 展示每条（日期, 接口）记录，行 hover 高亮
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 2
                Layout.bottomMargin: 2
                clip: true
                model: root.statsModel
                onCountChanged: emptyHint.visible = root.statsModel.length === 0

                // 空状态提示（当 statsModel 为空时显示）
                Item {
                    id: emptyHint
                    anchors.fill: parent
                    visible: root.statsModel.length === 0
                    Text {
                        anchors.centerIn: parent
                        text: qsTr("No traffic records yet")
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
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        spacing: root.colSpacing

                        Text {
                            Layout.preferredWidth: root.colDate
                            text: modelData.date
                            font.pixelSize: 12
                            color: theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colIface
                            text: modelData.iface
                            font.pixelSize: 12
                            color: theme.textSecondary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colNum
                            text: common.formatTotal(modelData.rx)
                            font.pixelSize: 12
                            color: theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colNum
                            text: common.formatTotal(modelData.tx)
                            font.pixelSize: 12
                            color: theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colNum
                            text: common.formatTotal(modelData.total)
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Item { Layout.fillWidth: true }
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

            // 底部汇总行：所有显示记录的总下载/总上传/总流量
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                Layout.leftMargin: 24
                Layout.rightMargin: 16
                spacing: root.colSpacing

                Text {
                    Layout.preferredWidth: root.colDate + root.colIface
                    text: qsTr("Total")
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    color: theme.textPrimary
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: common.formatTotal(root.totals.rx)
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    color: common.accentBlue
                    elide: Text.ElideRight
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: common.formatTotal(root.totals.tx)
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    color: common.accentGreen
                    elide: Text.ElideRight
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: common.formatTotal(root.totals.total)
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    color: theme.textPrimary
                    elide: Text.ElideRight
                }
                Item { Layout.fillWidth: true }
            }
        }
    }

    // 数据刷新：C++ 每 30 秒保存并发射 trafficLogChanged，据此重建表格；
    // 接口切换不影响日志（日志按活动接口累计，切接口后数据仍完整）
    Connections {
        target: root.applet
        function onTrafficLogChanged() {
            buildStatsModel()
        }
    }
}
