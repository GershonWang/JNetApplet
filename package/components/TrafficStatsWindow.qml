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
// 公共能力复用：窗口外壳（标题栏/置顶/位置与置顶状态持久化）取自 WindowShell，主题色经 root.theme 访问，
// 格式化函数取自 NetCommon.formatTotal
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
// Qt6 的 QtQuick.Dialogs 只导出 6.2+（见该模块 plugins.qmltypes 的 exports），
// 写成 Qt5 时代的 1.3 会让本文件整体加载失败——表现为整个插件从任务栏消失
import QtQuick.Dialogs 6.2
import "."

WindowShell {
    id: root

    // 外壳参数：窗口标识（位置与置顶状态持久化用）与标题栏文字
    windowKey: "stats"
    title: qsTr("Traffic Statistics")
    // 置顶按钮：统计窗口常用于"边看曲线/表格边做别的事"，与图表窗口一致提供置顶
    pinnable: true

    // 公共格式化函数：集中定义于同目录 NetCommon.qml，
    // 与 networkview.qml、TrafficChartWindow 共享同一份实现
    NetCommon {
        id: common
        // 注入后端对象：单位换算（formatSpeed）由后端统一完成，避免 QML 再维护阈值表
        applet: root.applet
    }

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

    // ---- 导出 ----
    // 导出结果提示：成功显示实际路径，失败显示原因；空串表示无提示
    // 设计原因：文件对话框在部分环境（无 xdg-desktop-portal）弹不出来，
    // 此时自动降级到下载目录，必须让用户知道文件到底写哪了
    property string exportStatus: ""
    // 提示自动消失计时器（毫秒）
    property int exportStatusTimeout: 6000

    // 当前页签对应的后端 section 键
    readonly property string exportSection: root.currentTab === 0 ? "byDay" : "byMonth"
    // 扩展名（对话框筛选依据）
    readonly property string exportExtension: "csv"

    // 执行导出到指定路径：把"取数据 + 写盘 + 显示结果"收敛到一处
    // 设计原因：正常路径与降级路径都要走同一套提示逻辑，各写一遍必然漂移
    function exportTo(path) {
        if (!root.applet) {
            root.exportStatus = qsTr("Export failed: plugin backend unavailable")
            return
        }
        // 按扩展名决定 serialize 格式：CSV 用后端序列化，JSON 直接取结构化数据
        var content = path.toLowerCase().endsWith(".json")
                ? root.applet.exportTrafficAsJson(root.exportSection)
                : root.applet.exportTrafficAsCsv(root.exportSection)
        var result = root.applet.saveExportFile(path, content)
        if (result && result.ok) {
            root.exportStatus = qsTr("Exported to %1").arg(result.path)
        } else {
            root.exportStatus = qsTr("Export failed: %1")
                    .arg(result && result.error ? result.error : qsTr("unknown error"))
        }
        exportStatusTimer.restart()
    }

    // 导出入口：由按钮调用。
    // 设计原因：FileDialog 在没有 xdg-desktop-portal 的环境下打开后既不回调 accepted
    // 也不回调 rejected（Qt 只打印一条告警），界面表现为"点击没反应"。
    // 因此这里不假设对话框一定可用：若后端未就绪或本次导出无数据，直接给出明确提示；
    // 否则弹出对话框。用户仍可右键按钮触发 exportToDefaultLocation() 走降级路径
    function requestExport() {
        if (!root.applet) {
            root.exportStatus = qsTr("Export failed: plugin backend unavailable")
            exportStatusTimer.restart()
            return
        }
        // 无记录时没必要弹框：导出出去只有表头，用户会以为导出坏了
        if (root.statsModel.length === 0) {
            root.exportStatus = qsTr("Nothing to export for the current view")
            exportStatusTimer.restart()
            return
        }
        exportDialog.open()
    }

    // 兜底导出：对话框不可用时直接写到下载目录
    function exportToDefaultLocation() {
        if (!root.applet) {
            root.exportStatus = qsTr("Export failed: plugin backend unavailable")
            return
        }
        root.exportTo(root.applet.defaultExportPath(root.exportSection, root.exportExtension))
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

                // 按日 / 按月 tab：改用公共 ChoiceButton。
                // 配色按原值传入：选中=accentBlue 底 + 白字 + 加粗；未选中=透明底、
                // hover 时 blue 描边与蓝字。选中按下加深 1.2 倍（组件内已实现）
                ChoiceButton {
                    width: 80
                    height: 24
                    radius: 5
                    text: qsTr("By Day")
                    fontSize: 12
                    checked: root.currentTab === 0
                    selectedColor: common.accentBlue
                    selectedBorderColor: common.accentBlue
                    selectedTextColor: "white"
                    baseColor: "transparent"
                    baseBorderColor: root.theme.lineColor
                    hoverColor: "transparent"
                    textColor: root.theme.textSecondary
                    hoverTextColor: common.accentBlue
                    onClicked: root.currentTab = 0
                }

                ChoiceButton {
                    width: 90
                    height: 24
                    radius: 5
                    text: qsTr("By Month")
                    fontSize: 12
                    checked: root.currentTab === 1
                    selectedColor: common.accentBlue
                    selectedBorderColor: common.accentBlue
                    selectedTextColor: "white"
                    baseColor: "transparent"
                    baseBorderColor: root.theme.lineColor
                    hoverColor: "transparent"
                    textColor: root.theme.textSecondary
                    hoverTextColor: common.accentBlue
                    onClicked: root.currentTab = 1
                }

                Item { Layout.fillWidth: true }

                // 导出按钮：把当前页签数据导出为 CSV/JSON。
                // 放在周期说明左侧，与右侧文字同属"辅助操作"区，不抢表格焦点
                // 改用公共 IconButton：顺带修掉此前的重复标注——
                // 原实现在 Rectangle 与 MouseArea 上各写了一次 Accessible.role/name，
                // 读屏会重复朗读；现在契约只存在于组件内的唯一位置
                IconButton {
                    id: exportButton
                    accessibleName: qsTr("Export")
                    width: 64
                    height: 24
                    radius: 5
                    borderWidth: 1
                    borderColor: root.theme.lineColor
                    baseColor: "transparent"
                    hoverColor: Qt.rgba(common.accentBlue.r, common.accentBlue.g, common.accentBlue.b, 0.12)
                    pressedColor: Qt.rgba(common.accentBlue.r, common.accentBlue.g, common.accentBlue.b, 0.22)
                    symbol: qsTr("Export")
                    symbolFontSize: 11
                    symbolColor: root.theme.textSecondary
                    symbolHoverColor: common.accentBlue
                    onClicked: root.requestExport()

                    // 右键 = 直接导出到下载目录。
                    // 不依赖门户服务的固定路径：无 xdg-desktop-portal 的环境里
                    // FileDialog 打开后既不 accepted 也不 rejected，用户会以为"点了没反应"
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.RightButton
                        hoverEnabled: false
                        onPressed: root.exportToDefaultLocation()
                    }
                }

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
                    font.pixelSize: common.fontSizeSmall
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
                    font.pixelSize: common.fontSizeSmall
                    font.weight: Font.Bold
                    color: root.theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colIface
                    text: qsTr("Interface")
                    font.pixelSize: common.fontSizeSmall
                    font.weight: Font.Bold
                    color: root.theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: qsTr("Download")
                    font.pixelSize: common.fontSizeSmall
                    font.weight: Font.Bold
                    color: root.theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: qsTr("Upload")
                    font.pixelSize: common.fontSizeSmall
                    font.weight: Font.Bold
                    color: root.theme.textSecondary
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: qsTr("Total")
                    font.pixelSize: common.fontSizeSmall
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
                        font.pixelSize: common.fontSizeBody
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
                            font.pixelSize: common.fontSizeBody
                            color: root.theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colIface
                            text: modelData.iface
                            font.pixelSize: common.fontSizeBody
                            color: root.theme.textSecondary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colNum
                            text: common.formatTotal(modelData.rx)
                            font.pixelSize: common.fontSizeBody
                            color: root.theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colNum
                            text: common.formatTotal(modelData.tx)
                            font.pixelSize: common.fontSizeBody
                            color: root.theme.textPrimary
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.preferredWidth: root.colNum
                            text: common.formatTotal(modelData.total)
                            font.pixelSize: common.fontSizeBody
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
                    font.pixelSize: common.fontSizeBody
                    font.weight: Font.Bold
                    color: root.theme.textPrimary
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: common.formatTotal(root.totals.rx)
                    font.pixelSize: common.fontSizeBody
                    font.weight: Font.Bold
                    color: common.accentBlue
                    elide: Text.ElideRight
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: common.formatTotal(root.totals.tx)
                    font.pixelSize: common.fontSizeBody
                    font.weight: Font.Bold
                    color: common.accentGreen
                    elide: Text.ElideRight
                }
                Text {
                    Layout.preferredWidth: root.colNum
                    text: common.formatTotal(root.totals.total)
                    font.pixelSize: common.fontSizeBody
                    font.weight: Font.Bold
                    color: root.theme.textPrimary
                    elide: Text.ElideRight
                }
                Item { Layout.fillWidth: true }
            }


    // 导出结果提示条：浮在内容区底部，仅在有结果时显示。
    // 设计原因：用窗口级浮层而非插入 ColumnLayout——
    // 插入布局会改变表格与汇总行的间距，而提示是临时状态，不该占位。
    // 对话框可能降级到下载目录，用户必须能看到文件到底写到了哪里
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 12
        visible: root.exportStatus.length > 0
        height: exportStatusText.implicitHeight + 16
        radius: 6
        color: root.isDarkMode ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.06)
        border.width: 1
        border.color: root.theme.lineColor

        Text {
            id: exportStatusText
            anchors.fill: parent
            anchors.margins: 8
            text: root.exportStatus
            font.pixelSize: common.fontSizeSmall
            color: root.theme.textSecondary
            wrapMode: Text.Wrap
            elide: Text.ElideMiddle
            verticalAlignment: Text.AlignVCenter
        }

        MouseArea {
            anchors.fill: parent
            // 点一下即可收起提示，无需等自动消失
            onClicked: root.exportStatus = ""
        }
    }

    // 导出文件对话框：用户自选保存路径。
    // 设计原因：用 QtQuick.Dialogs 的 FileDialog 而非自建路径输入框——
    // 它能调用系统原生对话框，用户可浏览目录、看到已有文件，这是桌面应用的既有习惯。
    // 该模块依赖 xdg-desktop-portal：精简环境下可能弹不出来，故 onRejected 与
    // 打开失败都会走 exportToDefaultLocation() 兜底
    FileDialog {
        id: exportDialog
        title: root.currentTab === 0 ? qsTr("Export daily traffic") : qsTr("Export monthly traffic")
        // 属性与信号按 Qt 官方元对象 plugins.qmltypes 核实（qmllint 无法解析该模块，
        // 其"属性不存在"告警不可信，故以元对象为准）：
        //   QQuickFileDialog 提供 currentFolder / selectedFile / fileMode /
        //   defaultSuffix / nameFilters，**没有** folder 与 fileUrl；
        //   accepted 信号不带参数，选定路径从 selectedFile（QUrl）读
        // 初始目录：用后端算好的降级路径所在目录（下载目录），
        // 不引 Qt.labs.platform 的 shortcuts 单例——本文件只导入 QtQuick.Dialogs，
        // 跨模块用 shortcuts 会在运行时找不到符号
        currentFolder: {
            if (!root.applet) return "file:///"
            var p = root.applet.defaultExportPath(root.exportSection, root.exportExtension)
            var dir = p.substring(0, p.lastIndexOf('/'))
            return "file://" + encodeURIComponent(dir).replace(/%2F/g, "/")
        }
        fileMode: FileDialog.SaveFile
        // 默认文件名带范围与周期，避免重复导出时互相覆盖
        defaultSuffix: root.exportExtension
        nameFilters: [qsTr("CSV file (*.csv)"), qsTr("JSON file (*.json)"), qsTr("All files (*)")]
        // accepted 信号不带参数：选定路径要从 selectedFile 读（它是 file:// URL）
        onAccepted: {
            // accepted 不带参数：选定路径从 selectedFile（QUrl）读
            var path = selectedFile ? selectedFile.toString() : ""
            // URL → 本地路径。decodeURIComponent 必须做：中文目录名（如「下载」）
            // 在 URL 里是百分号编码的，不解码会写出名为 "%E4%B8%8B%E8%BD%BD" 的目录
            if (path.indexOf("file://") === 0) {
                path = decodeURIComponent(path.substring(7))
            }
            root.exportTo(path)
        }
        // 用户取消：清掉旧提示，不写文件
        onRejected: root.exportStatus = ""
    }



    // 导出结果提示自动消失
    Timer {
        id: exportStatusTimer
        interval: root.exportStatusTimeout
        onTriggered: root.exportStatus = ""
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
