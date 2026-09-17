// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 流量统计窗口：屏幕居中的独立顶层窗口，展示按日/按月持久化的累计流量
// （下载/上传/总计），数据来自 C++ 后端持久化的 traffic_log.json，
// 跨重启累加，让用户了解长期流量趋势。
// 设计要点：
// - 视觉风格复用 TrafficChartWindow.qml（圆角卡片 12px、1px 边框、44px 标题栏、
//   28x28 圆形关闭按钮 hover 淡红底）；深/浅主题由 isDarkMode 切换
//   （networkview.qml 依据 DTK.palette 检测任务栏深浅后传入），默认浅色保证独立预览可用
// - 数据通过属性注入：applet 即 networkview.qml 的 root.applet（C++ 后端对象），
//   applet.trafficLog 为 JSON 对象 {"byDay": {日期: {接口: {rx, tx}}},
//   "byMonth": {月份: {接口: {rx, tx}}}}，为 null 时组件可独立预览（显示空状态）
// - 顶部 tab 切换按日/按月；表格按日期/月份降序（最新在上）展示，每行一个
//   （日期, 接口）记录；底部汇总所有显示记录的总下载/总上传/总流量
// - 数据刷新：C++ 每 30 秒保存并发射 trafficLogChanged，本窗口据此重建表格
// 触发方式：右键菜单"流量统计" -> show()/raise()/requestActivate()
// 公共能力复用：窗口外壳（标题栏/位置持久化）取自 WindowShell，主题色经 root.theme 访问，
// 格式化函数取自 NetCommon.formatTotal
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import "."

WindowShell {
    id: root

    // 外壳参数：窗口标识（位置与置顶状态持久化用）与标题栏文字
    windowKey: "stats"
    title: qsTr("Traffic Statistics")

    // 公共格式化函数：集中定义于同目录 NetCommon.qml，
    // 与 networkview.qml、TrafficChartWindow 共享同一份实现
    NetCommon { id: common }

    // 对外依赖：C++ 后端对象（NetworkMonitorApplet），由 networkview.qml 传入
    // 提供 trafficLog（JSON 对象，见文件头注释）；为 null 时组件可独立预览（显示空状态）
    property var applet: null

    // 当前 tab：0=按日, 1=按月，切换后重建表格模型
    property int currentTab: 0

    // 表格模型：由 buildStatsModel() 生成的扁平记录数组，每项
    // {date, iface, rx, tx, total}，按日期/月份降序（最新在上）排列
    property var statsModel: []

    // 底部汇总：当前 tab 全部记录的 rx/tx/total 累加值（跨日期、跨接口）
    property var totals: ({ rx: 0, tx: 0, total: 0 })

    // 当前周期合计：按日 tab 为"今日"、按月 tab 为"本月"的 rx/tx 累加值（跨接口）
    // 设计原因：顶部说明必须与数据口径一致——原实现文案写"今日/本月累计"，
    // 但界面上唯一存在的数字是"全部记录合计"，两者口径不同属误导；
    // 此处单独算出周期值，让顶部说明有真实数据支撑
    property var periodTotals: ({ rx: 0, tx: 0, total: 0 })

    // 当前周期是否有记录：无记录时顶部说明显示 "—"，不用 0 冒充真实数据
    property bool periodHasData: false

    // 表格列宽：表头/数据行/底部汇总三处共用同一组值，保证各列垂直对齐
    // 设计原因：原实现写死 118/108/102，列宽与窗口宽度、字体大小脱钩——
    // 窗口变宽时右侧留一道空白；字号放大或译文变长时又会裁字。
    // 现改为按可用宽度取比例：日期列 20%、接口列 18%，其余宽度由三个数值列等分。
    // 比例按原视觉反推，620px 窗口下的结果与原值接近（118/106/113 对 118/108/102）。
    // 各列另设最小宽度，避免窗口被压窄时列宽趋近于 0 而完全不可读
    readonly property int colSpacing: 6
    // 表格可用宽度 = 窗口宽 - 左右各 16 的内边距（表头与 ListView 使用的是同一组边距）
    readonly property real tableWidth: Math.max(0, width - 32)
    readonly property int colDate: Math.max(96, Math.round(tableWidth * 0.20))
    readonly property int colIface: Math.max(88, Math.round(tableWidth * 0.18))
    // 数值列取剩余宽度三等分后向下取整：向下取整保证"三列 + 间距"不超过可用宽度，
    // 不会因 1px 溢出出现横向滚动或末列被截
    readonly property int colNum: Math.max(72, Math.floor((tableWidth - colDate - colIface - 4 * colSpacing) / 3))

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

        // 当前周期合计：日期在此现算而不缓存，窗口开着跨天/跨月后
        // 下一次定时刷新（可见时每 5×刷新间隔重建一次）即自动切到新周期
        var now = new Date()
        var periodKey = root.currentTab === 0
                ? Qt.formatDate(now, "yyyy-MM-dd")
                : Qt.formatDate(now, "yyyy-MM")
        var period = entries[periodKey] || {}
        var pRx = 0, pTx = 0
        var periodCount = 0
        for (var p in period) {
            var prec = period[p]
            pRx += prec ? (prec.rx || 0) : 0
            pTx += prec ? (prec.tx || 0) : 0
            periodCount++
        }
        root.periodHasData = periodCount > 0
        root.periodTotals = { rx: pRx, tx: pTx, total: pRx + pTx }
    }

    width: 620
    height: 440


    onVisibleChanged: {
        if (visible) {
            // 窗口显示时立即刷新一次，确保数据最新
            buildStatsModel()
        }
    }

    // 切换 tab 或首次创建时重建表格模型
    onCurrentTabChanged: buildStatsModel()
    Component.onCompleted: buildStatsModel()

    // 兜底刷新：窗口可见时按刷新间隔的 5 倍重建表格
    // 设计原因：C++ 每 30 秒才发 trafficLogChanged，用户打开窗口期间需要更快看到增量，
    // 故保留窗口内主动刷新；原实现直接用 refreshInterval（1 倍），与注释所述 5 倍降频不符，
    // 导致窗口打开期间每秒整体重建一次模型
    Timer {
        interval: (root.applet ? root.applet.refreshInterval : 1000) * 5
        repeat: true
        running: root.visible
        onTriggered: buildStatsModel()
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
                    // 无障碍：视图切换 tab 视为单选项
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: qsTr("By Day")
                    Accessible.checked: sel
                    width: 80
                    height: 24
                    radius: 5
                    // 三态：按下 > 选中 > 常态；未选中按下用卡片底色给出反馈
                    color: sel
                           ? (dayMouse.pressed ? Qt.darker(common.accentBlue, 1.2) : common.accentBlue)
                           : (dayMouse.pressed
                              ? Qt.rgba(common.cardBackground.r, common.cardBackground.g, common.cardBackground.b, common.cardBackground.a * 1.8)
                              : "transparent")
                    border.width: 1
                    border.color: sel ? common.accentBlue
                                      : (dayMouse.containsMouse ? common.accentBlue : root.theme.lineColor)
                    Text {
                        anchors.centerIn: parent
                        text: qsTr("By Day")
                        font.pixelSize: 12
                        font.weight: sel ? Font.Bold : Font.Normal
                        color: sel ? "white"
                                   : (dayMouse.pressed ? Qt.darker(common.accentBlue, 1.2)
                                      : (dayMouse.containsMouse ? common.accentBlue : root.theme.textSecondary))
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
                    // 无障碍：视图切换 tab 视为单选项
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: qsTr("By Month")
                    Accessible.checked: sel
                    width: 90
                    height: 24
                    radius: 5
                    // 三态：按下 > 选中 > 常态；未选中按下用卡片底色给出反馈
                    color: sel
                           ? (monthMouse.pressed ? Qt.darker(common.accentBlue, 1.2) : common.accentBlue)
                           : (monthMouse.pressed
                              ? Qt.rgba(common.cardBackground.r, common.cardBackground.g, common.cardBackground.b, common.cardBackground.a * 1.8)
                              : "transparent")
                    border.width: 1
                    border.color: sel ? common.accentBlue
                                      : (monthMouse.containsMouse ? common.accentBlue : root.theme.lineColor)
                    Text {
                        anchors.centerIn: parent
                        text: qsTr("By Month")
                        font.pixelSize: 12
                        font.weight: sel ? Font.Bold : Font.Normal
                        color: sel ? "white"
                                   : (monthMouse.pressed ? Qt.darker(common.accentBlue, 1.2)
                                      : (monthMouse.containsMouse ? common.accentBlue : root.theme.textSecondary))
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

                // 右侧周期说明：只报当前周期（今日/本月）合计，与表格的"全部记录"口径区分
                // 无记录时显示 "—"；文案与数值同源，不再出现"文案说今日、数字是全部"的误导
                Text {
                    text: {
                        var label = root.currentTab === 0
                                ? qsTr("Today accumulated")
                                : qsTr("This month accumulated")
                        if (!root.periodHasData) return label + " —"
                        return label + " ↓" + common.formatTotal(root.periodTotals.rx)
                                + " ↑" + common.formatTotal(root.periodTotals.tx)
                    }
                    font.pixelSize: 11
                    color: root.theme.textTertiary
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
                    color: root.theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colIface
                    text: qsTr("Interface")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: root.theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: qsTr("Download")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: root.theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: qsTr("Upload")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: root.theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: qsTr("Total")
                    font.pixelSize: 11
                    font.weight: Font.Bold
                    color: root.theme.textSecondary
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
                color: root.theme.lineColor
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
                        color: root.theme.textTertiary
                    }
                }

                delegate: Rectangle {
                    required property int index
                    required property var modelData
                    width: ListView.view.width
                    height: 28
                    radius: 4
                    // 行 hover 高亮：浅色用淡黑、深色用淡白，保证两种卡片背景上均可见
                    color: rowMouse.containsMouse ? root.theme.hoverBg : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        // 不再额外缩进：ListView 自身已有 16 左右边距，
                        // 此处再各加 8 会使数据列比表头右移 8px（原实现即为此错位）
                        anchors.leftMargin: 0
                        anchors.rightMargin: 0
                        spacing: root.colSpacing

                        Text {
                            Layout.preferredWidth: root.colDate
                            text: modelData.date
                            font.pixelSize: 12
                            color: root.theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colIface
                            text: modelData.iface
                            font.pixelSize: 12
                            color: root.theme.textSecondary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colNum
                            text: common.formatTotal(modelData.rx)
                            font.pixelSize: 12
                            color: root.theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colNum
                            text: common.formatTotal(modelData.tx)
                            font.pixelSize: 12
                            color: root.theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colNum
                            text: common.formatTotal(modelData.total)
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: root.theme.textPrimary
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
                color: root.theme.lineColor
            }

            // 底部汇总行：当前 tab 全部记录的总下载/总上传/总流量
            // 文案明确写"全部记录"，与顶部"今日/本月累计"区分两个口径
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                // 与表头/数据行保持同一左边界（原为 24，比表头多 8px）
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                spacing: root.colSpacing

                Text {
                    // 跨"日期 + 接口"两列的宽度需含两列之间的间距，
                    // 否则后续数值列会比表头对应列左移一个 colSpacing
                    Layout.preferredWidth: root.colDate + root.colSpacing + root.colIface
                    text: qsTr("All records")
                    font.pixelSize: 12
                    font.weight: Font.Bold
                    color: root.theme.textPrimary
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
                    color: root.theme.textPrimary
                    elide: Text.ElideRight
                }
                Item { Layout.fillWidth: true }
            }

    // 数据刷新：C++ 每 30 秒保存并发射 trafficLogChanged，据此重建表格；
    // 接口切换不影响日志（日志按活动接口累计，切接口后数据仍完整）
    // 数据刷新：C++ 每 30 秒更新并发射 trafficLogChanged，据此重建表格；
    // 窗口不可见时跳过（显示时 onVisibleChanged 会补一次刷新），避免隐藏状态下白重建模型
    Connections {
        target: root.applet
        function onTrafficLogChanged() {
            if (!root.visible) return
            buildStatsModel()
        }
    }
}
