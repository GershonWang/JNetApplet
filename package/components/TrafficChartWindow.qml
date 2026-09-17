// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 流量波动图窗口：屏幕居中的独立顶层窗口，展示当前活动接口最近 1/5/30 分钟（可切换）
// 的网速趋势（下载/上传双折线图），随 C++ 后端 speedHistoryChanged 信号每秒动态刷新
// 设计要点：
// - 视觉风格复用 AboutWindow.qml（圆角卡片 12px、1px 边框、44px 标题栏、
//   28x28 圆形关闭按钮 hover 淡红底）；深/浅主题由 isDarkMode 切换
//   （networkview.qml 依据 DTK.palette 检测任务栏深浅后传入），默认浅色保证独立预览可用
// - 图表使用纯 QML Canvas 绘制，无 QtCharts 等外部依赖（与项目零依赖风格一致）；
//   Canvas 不随属性绑定自动重绘，isDarkMode 变化时主动 requestPaint()
// - 数据通过属性注入：applet 即 networkview.qml 的 root.applet（C++ 后端对象），
//   为 null 时组件可独立预览（Canvas 显示"暂无历史数据"空状态）
// 触发方式：右键菜单"流量波动图" -> show()/raise()/requestActivate()
// 公共能力复用：窗口外壳（标题栏/置顶/位置持久化）取自 WindowShell，主题色经 root.theme 访问，
// 消除三窗口样板重复
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import "."

WindowShell {
    id: root

    // 外壳参数：窗口标识（位置与置顶状态持久化用）与标题栏文字
    windowKey: "chart"
    title: qsTr("Traffic Chart")
    // 本窗口需要标题栏提供置顶按钮（置顶逻辑与图标绘制均已在外壳内实现）
    pinnable: true

    // 公共格式化函数：集中定义于同目录 NetCommon.qml，
    // 与 networkview.qml、NetworkPopup 共享同一份实现，消除跨组件重复定义
    NetCommon { id: common }

    // 对外依赖：C++ 后端对象（NetworkMonitorApplet），由 networkview.qml 传入
    // 提供 speedHistoryDownload / speedHistoryUpload（QVariantList of QPointF，
    // x=时间戳秒, y=速度 bytes/sec）、downloadSpeed / uploadSpeed、activeInterface
    // 为 null 时组件可独立预览（显示空状态），所有数据访问处均需做空值兜底
    property var applet: null

    // 图表绘制色（本窗口特有）：声明为 string 供 Canvas 2D 上下文直接使用
    //（QML color 类型含 alpha 时序列化为 #AARRGGBB，Canvas 无法正确解析，故不用 color 类型）
    readonly property string gridBaselineColor: isDarkMode ? "#383838" : "#DDDDDD"
    readonly property string gridLineColor: isDarkMode ? "#2A2A2A" : "#E5E5E5"
    readonly property string axisTextColor: isDarkMode ? "#888888" : "#999999"
    readonly property string hoverLineColor: isDarkMode ? "#555555" : "#BBBBBB"
    readonly property string dotCoreColor: isDarkMode ? "#202020" : "#FFFFFF"

    // Hover 状态：当前悬停采样点在历史缓冲中的索引，-1 表示无悬停
    // 由图表区 MouseArea 根据 mouseX 反查最近采样点更新；Canvas 据此绘制
    // 竖直辅助线与圆点标记，底部提示条据此显示该时刻数值
    property int hoverIndex: -1

    // Hover 提示文本：非空时底部提示条显示该内容，为空显示默认引导语
    // 格式："14:23:05  ↓856.00 KB/s  ↑120.00 KB/s"
    property string hoverHint: ""

    // 时间窗口选择（秒）：60=1分钟, 300=5分钟, 1800=30分钟
    // 纯 QML 展示层选择——后端已存够 30 分钟历史（MAX_HISTORY_SAMPLES=1800），
    // 这里仅决定 X 轴绘制范围与标签，不改变后端采集行为
    property int timeWindowSec: 300

    // 时间窗口选项列表：只保留秒数，显示文案统一由 formatWindowLabel 生成
    // 设计原因：原实现把 "1m/5m/30m" 写死在模型里，绕过了翻译；
    // 改为数据与文案分离后，选择器按钮与状态条标签共用同一份文案
    property var timeWindows: [60, 300, 1800]

    // 时间窗口显示文案：按秒数生成（供选择器按钮与状态条标签共用）
    // 设计原因：不写死分钟数，便于后续新增窗口而不必再补文案映射
    function formatWindowLabel(seconds) {
        if (seconds <= 60)   return qsTr("1 min")
        if (seconds <= 300)  return qsTr("5 min")
        return qsTr("30 min")
    }

    // 依据当前 timeWindowSec 反查 X 轴刻度位置数组，元素为"距当前的秒数"（负值，0 表示现在）
    // 设计原因：原实现直接把 "-45s"/"now" 这类英文串写进数组，无法翻译；
    // 改为数据（秒数）与文案（formatTickLabel）分离，刻度数量与间隔逻辑保持不变：
    // 1 分钟用 15 秒间隔 5 个刻度、5 分钟用 1 分钟间隔 6 个、30 分钟用 5 分钟间隔 7 个
    readonly property var xAxisTicks: {
        if (timeWindowSec <= 60)     return [-60, -45, -30, -15, 0]
        if (timeWindowSec <= 300)    return [-300, -240, -180, -120, -60, 0]
        return [-1800, -1500, -1200, -900, -600, -300, 0]
    }

    // 刻度文案：0 显示"现在"，整分钟用分钟表达，其余用秒表达
    function formatTickLabel(seconds) {
        if (seconds === 0) return qsTr("now")
        if (seconds % 60 === 0) return qsTr("-%1 min").arg(-seconds / 60)
        return qsTr("-%1 s").arg(-seconds)
    }

    // 顶部状态条右侧的时间窗口标签文本（如 "· 5 min"），随 timeWindowSec 动态显示
    readonly property string timeWindowLabel: "· " + formatWindowLabel(timeWindowSec)

    // 主题切换时重绘图表：Canvas 不随属性绑定自动重绘，需主动触发
    // （图钉图标随外壳绘制，其重绘由 WindowShell 自行处理）
    onIsDarkModeChanged: canvas.requestPaint()

    // 下载折线颜色（绿）与上传折线颜色（橙），与规范 §4.4 一致
    readonly property color downloadLineColor: "#34C759"
    readonly property color uploadLineColor: "#FF9500"

    // 图表区内边距：左侧容纳 Y 轴刻度标签（如 "10 MB"），底部容纳 X 轴时间标签
    // 定义为根属性，供 Canvas 绘制与 MouseArea 坐标换算共用，保证两处一致
    readonly property int chartMarginLeft: 56
    readonly property int chartMarginRight: 12
    readonly property int chartMarginTop: 12
    readonly property int chartMarginBottom: 26

    width: 680
    height: 420


    onVisibleChanged: {
        if (visible) {
        }
    }

    // 格式化速度显示：统一调用 common.formatSpeed（带单位，最小 KB，保留 2 位小数），
    // 与 networkview.qml / NetworkPopup 共用 NetCommon 中的同一份实现

    // Y 轴上限取整：将 v 向上取整到 1/2/5 × 10^n 序列
    // 设计原因：使刻度值为易读的整数（如 12345 -> 20000，80000 -> 100000），
    // 避免 vMax * 1.2 的余量产生零碎刻度（如 14814）
    function niceCeil(v) {
        if (v <= 0) return 1024
        var exp = Math.floor(Math.log(v) / Math.LN10)
        var base = Math.pow(10, exp)
        var f = v / base
        var nf
        if (f <= 1) nf = 1
        else if (f <= 2) nf = 2
        else if (f <= 5) nf = 5
        else nf = 10
        return nf * base
    }

    // Y 轴刻度单位选择：根据上限自动选择 B/KB/MB/GB，返回 {div, suffix}
    // 设计原因：让刻度数值保持在 0~1000 的易读区间（如 200 KB 而非 204800 B）
    function axisUnit(yMax) {
        if (yMax >= 1024 * 1024 * 1024) return { div: 1024 * 1024 * 1024, suffix: "GB" }
        if (yMax >= 1024 * 1024) return { div: 1024 * 1024, suffix: "MB" }
        if (yMax >= 1024) return { div: 1024, suffix: "KB" }
        return { div: 1, suffix: "B" }
    }

    // 格式化单个 Y 轴刻度值：大值取整、小值保留 1 位小数，避免 "10.00" 这类冗余
    function formatAxisValue(v, unit) {
        var val = v / unit.div
        var s
        if (val >= 100) s = val.toFixed(0)
        else if (val >= 10) s = val.toFixed(1)
        else s = val.toFixed(val === 0 ? 0 : 1)
        return s + " " + unit.suffix
    }


            // 顶部状态条：实时下行/上行速度（箭头颜色与折线一致，兼作图例）
            // + 右侧活动接口名与时间窗口标签
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                spacing: 6

                Text {
                    text: "↓"
                    font.pixelSize: 14
                    font.weight: Font.Bold
                    color: root.downloadLineColor
                }

                Text {
                    // applet 为空时兜底为 0，保证独立预览不报错
                    text: common.formatSpeed(root.applet ? root.applet.downloadSpeed : 0)
                    font.pixelSize: 12
                    color: root.theme.textPrimary
                }

                Item { Layout.preferredWidth: 10 }

                Text {
                    text: "↑"
                    font.pixelSize: 14
                    font.weight: Font.Bold
                    color: root.uploadLineColor
                }

                Text {
                    text: common.formatSpeed(root.applet ? root.applet.uploadSpeed : 0)
                    font.pixelSize: 12
                    color: root.theme.textPrimary
                }

                Item { Layout.fillWidth: true }

                // 时间窗口选择器：三个小按钮 1 分钟 / 5 分钟 / 30 分钟，当前选中项用 accentBlue 高亮
                // 设计原因：时间窗口切换是图表最常用的操作，直接置于顶部状态条便于快速切换；
                // 用比接口 chip 更小的尺寸（22x18）避免挤占状态条空间
                Repeater {
                    model: root.timeWindows

                    Rectangle {
                        required property var modelData
                        property bool isSelected: root.timeWindowSec === modelData
                        // 无障碍：时间窗口按钮是三选一，名称复用按钮上的窗口文案
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: root.formatWindowLabel(modelData)
                        Accessible.checked: isSelected

                        width: 24
                        height: 18
                        radius: 4
                        // 选中态：蓝色填充+白字；未选中态：透明背景+浅边框，hover 边框变蓝
                        color: isSelected
                               ? (mouse.pressed ? Qt.darker(common.accentBlue, 1.2) : common.accentBlue)
                               : (mouse.pressed
                                  ? Qt.rgba(common.cardBackground.r, common.cardBackground.g, common.cardBackground.b, common.cardBackground.a * 1.8)
                                  : "transparent")
                        border.width: 1
                        border.color: isSelected
                                       ? common.accentBlue
                                       : (mouse.containsMouse ? common.accentBlue : root.theme.lineColor)

                        Text {
                            anchors.centerIn: parent
                            text: root.formatWindowLabel(modelData)
                            font.pixelSize: 10
                            font.weight: isSelected ? Font.Bold : Font.Normal
                            color: isSelected ? "white"
                                              : (mouse.pressed ? Qt.darker(common.accentBlue, 1.2)
                                                 : (mouse.containsMouse ? common.accentBlue : root.theme.textSecondary))
                        }

                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: {
                                if (root.timeWindowSec !== modelData) {
                                    root.timeWindowSec = modelData
                                    // 时间窗口变化后：清空 Hover（坐标系已变），并重绘图表
                                    root.hoverIndex = -1
                                    root.hoverHint = ""
                                    canvas.requestPaint()
                                }
                            }
                        }
                    }
                }

                Text {
                    text: (root.applet && root.applet.activeInterface
                           ? root.applet.activeInterface : "—") + " " + root.timeWindowLabel
                    font.pixelSize: 12
                    color: root.theme.textTertiary
                }
            }

            // 图表区：Canvas 绘制双折线 + 网格 + 坐标轴 + Hover 辅助线
            // visible 绑定窗口可见性：弹窗关闭时不绘制（C++ 后端仍继续采集）
            Canvas {
                id: canvas
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                visible: root.visible

                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)

                    // 绘图区几何（与 chartHover 坐标换算共用同一组边距）
                    var pl = root.chartMarginLeft
                    var pr = root.chartMarginRight
                    var pt = root.chartMarginTop
                    var pb = root.chartMarginBottom
                    var pw = width - pl - pr
                    var ph = height - pt - pb
                    if (pw <= 0 || ph <= 0) return

                    // 取历史数据；applet 为空时视为空缓冲（走空状态分支）
                    var dl = root.applet ? root.applet.speedHistoryDownload : []
                    var ul = root.applet ? root.applet.speedHistoryUpload : []
                    var n = dl.length

                    // X 轴窗口 [tMax - timeWindowSec, tMax]，右缘对齐最新采样点。
                    // 提前于此计算（而非绘制折线前）的原因：Y 轴上限需要按可见窗口取极值
                    var tMax = n > 0 ? dl[n - 1].x : 0
                    var tRange = root.timeWindowSec
                    var tMin = tMax - tRange

                    // 可见窗口起点索引：早于 tMin 的采样点仍在缓冲中（30 分钟窗口下最长 1800 点），
                    // 绘制时必须跳过，否则会映射到负坐标而画到绘图区之外
                    var visibleStart = 0
                    while (visibleStart < n - 1 && dl[visibleStart].x < tMin) {
                        visibleStart++
                    }

                    // ---- Y 轴上限计算（动态适应最近活动）----
                    // 取"可见窗口内最近 60 秒"的数据计算 Y 轴上限，而非全量历史缓冲。
                    // 设计原因：若使用全量缓冲，当历史中存在大流量峰值（如 12MB/s 下载）时，
                    // 即使当前网速已降至 KB/s 级别，Y 轴仍保持高位，导致当前曲线被压到底部
                    // 无法观察波动。改用 60 秒窗口后，峰值滑出窗口时 Y 轴自动缩小，
                    // 始终为当前活动提供合适的显示比例。30 分钟视图下 60 秒窗口仍合理
                    //（关注近期活动），故不随 timeWindowSec 变化。
                    // 注意按时间戳筛选而非按下标：原实现用 n - 60 取 60 个采样点，
                    // 刷新间隔设为 5 秒时实际覆盖 300 秒，与"最近 1 分钟"的意图不符
                    var recentStart = visibleStart
                    while (recentStart < n - 1 && dl[recentStart].x < tMax - 60) {
                        recentStart++
                    }
                    var vMax = 0
                    var i
                    for (i = recentStart; i < n; i++) {
                        if (dl[i].y > vMax) vMax = dl[i].y
                        if (i < ul.length && ul[i].y > vMax) vMax = ul[i].y
                    }
                    // Y 轴下限 8KB：纯空闲时微小波动也有 KB 级刻度可辨，
                    // 避免一格都撑不满；8KB 兼顾空闲可读性与小流量不溢出
                    var yMax = vMax <= 0 ? 8192 : Math.max(8192, root.niceCeil(vMax * 1.2))
                    var unit = root.axisUnit(yMax)

                    // ---- 水平网格线与 Y 轴刻度（[0, yMax] 均分 4 段）----
                    ctx.font = "10px sans-serif"
                    ctx.textBaseline = "middle"
                    var g, gy
                    for (g = 0; g <= 4; g++) {
                        gy = pt + ph - (ph * g / 4)
                        // +0.5 让 1px 线条落在像素边界上，避免抗锯齿发虚
                        // 基线（g=0）略深一档；网格与刻度颜色均随 isDarkMode 切换深浅
                        ctx.strokeStyle = g === 0 ? root.gridBaselineColor : root.gridLineColor
                        ctx.lineWidth = 1
                        ctx.beginPath()
                        ctx.moveTo(pl, gy + 0.5)
                        ctx.lineTo(pl + pw, gy + 0.5)
                        ctx.stroke()
                        // 刻度标签右对齐于绘图区左侧
                        ctx.fillStyle = root.axisTextColor
                        ctx.textAlign = "right"
                        ctx.fillText(root.formatAxisValue(yMax * g / 4, unit), pl - 8, gy)
                    }

                    // ---- X 轴刻度：按时间窗口参数化，均布于绘图区 ----
                    // 刻度位置由 root.xAxisTicks 依据 timeWindowSec 动态生成（秒数数组），
                    // 文案由 formatTickLabel 生成；循环按数组长度参数化，两端左/右对齐
                    var xTicks = root.xAxisTicks
                    ctx.fillStyle = root.axisTextColor
                    ctx.textBaseline = "alphabetic"
                    for (i = 0; i < xTicks.length; i++) {
                        var lx = pl + pw * i / (xTicks.length - 1)
                        // 两端标签分别左/右对齐，避免文字越出卡片边缘被裁剪
                        ctx.textAlign = i === 0 ? "left" : (i === xTicks.length - 1 ? "right" : "center")
                        ctx.fillText(root.formatTickLabel(xTicks[i]), lx, height - 8)
                    }

                    // ---- 空状态：画完空网格后中央提示，不画折线（规范 §5）----
                    if (n === 0) {
                        ctx.fillStyle = root.axisTextColor
                        ctx.font = "13px sans-serif"
                        ctx.textAlign = "center"
                        ctx.textBaseline = "middle"
                        ctx.fillText(qsTr("No history data"), pl + pw / 2, pt + ph / 2)
                        return
                    }

                    // ---- 折线绘制 ----
                    // X 轴为可配置窗口 [tMax-timeWindowSec, tMax]：右缘始终对齐"now"，
                    // 数据不足时间窗口时曲线从右侧向左生长，左侧留空网格。
                    // 设计原因：若按实际数据范围 [dl[0].x, tMax] 映射，刚启动时仅有
                    // 几秒数据会被拉伸到整个绘图宽度，X 轴标签与实际范围严重不符，
                    // 用户看到的是"几秒趋势图"而非"时间窗口趋势图"。
                    // tRange 取 timeWindowSec（60/300/1800），对应 1/5/30 分钟窗口，
                    // 与 C++ MAX_HISTORY_SAMPLES（1800）保证 30 分钟窗口下数据充足
                    // tMax/tRange/tMin 已在上方（Y 轴计算之前）求得，此处不再重复声明

                    // 单点边界：只有 1 个采样点时无法连线，画一个圆点。
                    // 固定窗口下单点对齐 now（右缘），而非居中
                    if (n === 1) {
                        var sx = pl + pw
                        var sy = pt + ph - (dl[0].y / yMax) * ph
                        ctx.fillStyle = "#34C759"
                        ctx.beginPath()
                        ctx.arc(sx, sy, 3, 0, 2 * Math.PI)
                        ctx.fill()
                        return
                    }

                    // 绘制一条序列折线：先填充线下淡色区域增强可读性，再描边 2px 主线
                    // lineCap/lineJoin 用 round 使折线端点与转角圆润
                    // 注意每次 stroke/fill 前必须 beginPath()，避免与上一段路径串连
                    // from 为可见窗口起点索引：早于 tMin 的点映射为负坐标，必须跳过，
                    // 否则曲线与填充会越出绘图区、压住 Y 轴刻度与顶部信息条
                    function drawSeries(data, from, colorCss, fillCss) {
                        var m = data.length
                        if (from >= m) return
                        // 5 点滑动平均（±2 样本）：抑制 1 秒采样的亚秒混叠尖峰，
                        // 使曲线反映趋势而非瞬时脉冲；hover 提示仍显示原始值供诊断。
                        // 先算一遍供填充与描边共用——原实现两条路径各算一次，同一点被算两遍
                        var sm = []
                        var j, sum, cnt, k
                        for (j = from; j < m; j++) {
                            sum = 0
                            cnt = 0
                            for (k = Math.max(0, j - 2); k <= Math.min(m - 1, j + 2); k++) {
                                sum += data[k].y
                                cnt++
                            }
                            sm.push(cnt > 0 ? sum / cnt : data[j].y)
                        }
                        var px, py
                        // 线下淡色填充（alpha 0.08）：贴到基线形成闭合区域
                        ctx.beginPath()
                        for (j = from; j < m; j++) {
                            px = pl + ((data[j].x - tMin) / tRange) * pw
                            py = pt + ph - (sm[j - from] / yMax) * ph
                            if (j === from) ctx.moveTo(px, py)
                            else ctx.lineTo(px, py)
                        }
                        ctx.lineTo(pl + ((data[m - 1].x - tMin) / tRange) * pw, pt + ph)
                        ctx.lineTo(pl + ((data[from].x - tMin) / tRange) * pw, pt + ph)
                        ctx.closePath()
                        ctx.fillStyle = fillCss
                        ctx.fill()
                        // 主线：2px 描边
                        ctx.beginPath()
                        for (j = from; j < m; j++) {
                            px = pl + ((data[j].x - tMin) / tRange) * pw
                            py = pt + ph - (sm[j - from] / yMax) * ph
                            if (j === from) ctx.moveTo(px, py)
                            else ctx.lineTo(px, py)
                        }
                        ctx.strokeStyle = colorCss
                        ctx.lineWidth = 2
                        ctx.lineCap = "round"
                        ctx.lineJoin = "round"
                        ctx.stroke()
                    }

                    // 裁剪到绘图区：折线在极值处可能超出 yMax 或负向越界，
                    // clip 作为兜底保证不会画到网格、Y 轴刻度与顶部信息条上
                    ctx.save()
                    ctx.beginPath()
                    ctx.rect(pl, pt, pw, ph)
                    ctx.clip()
                    // 先画上传（橙）再画下载（绿）：下载通常是主视线，后画置于上层
                    drawSeries(ul, visibleStart, "#FF9500", "rgba(255, 149, 0, 0.08)")
                    drawSeries(dl, visibleStart, "#34C759", "rgba(52, 199, 89, 0.08)")
                    ctx.restore()

                    // ---- Hover：竖直辅助线 + 两条折线上的圆点标记 ----
                    // hoverIndex 由 chartHover 根据 mouseX 反查更新；此处按索引换算坐标
                    var hi = root.hoverIndex
                    // 仅在可见窗口内绘制 hover 标记：hi < visibleStart 的点位于绘图区左侧之外
                    if (hi >= visibleStart && hi < n) {
                        var hx = pl + ((dl[hi].x - tMin) / tRange) * pw
                        // 竖直辅助线：虚线，避免与实线折线混淆
                        ctx.strokeStyle = root.hoverLineColor
                        ctx.lineWidth = 1
                        ctx.setLineDash([4, 3])
                        ctx.beginPath()
                        ctx.moveTo(hx, pt)
                        ctx.lineTo(hx, pt + ph)
                        ctx.stroke()
                        ctx.setLineDash([])
                        // 圆点标记：窗口底色芯 + 2px 彩色描边，在折线上形成清晰锚点
                        function drawDot(yVal, colorCss) {
                            var hy = pt + ph - (yVal / yMax) * ph
                            ctx.beginPath()
                            ctx.arc(hx, hy, 4, 0, 2 * Math.PI)
                            ctx.fillStyle = root.dotCoreColor
                            ctx.fill()
                            ctx.strokeStyle = colorCss
                            ctx.lineWidth = 2
                            ctx.stroke()
                        }
                        drawDot(dl[hi].y, "#34C759")
                        if (hi < ul.length) drawDot(ul[hi].y, "#FF9500")
                    }
                }

                // Hover 交互层：横向移动时按 mouseX 反查最近采样点
                // 设计原因：采样点按时间均匀分布（1Hz），先由 X 坐标线性反推时间戳，
                // 再线性扫描找最近点；1800 点上限下扫描开销仍可忽略，无需二分
                MouseArea {
                    id: chartHover
                    anchors.fill: parent
                    hoverEnabled: true

                    onPositionChanged: {
                        if (!root.applet) return
                        var dl = root.applet.speedHistoryDownload
                        var n = dl.length
                        if (n === 0) return
                        var pl = root.chartMarginLeft
                        var pw = width - pl - root.chartMarginRight
                        if (pw <= 0) return
                        // X 轴用与绘制一致的可配置窗口 [tMax-timeWindowSec, tMax] 反推时间戳，
                        // 保证 Hover 辅助线与折线上的采样点严格对齐
                        var tMax = dl[n - 1].x
                        var tRange = root.timeWindowSec
                        var tMin = tMax - tRange
                        // 将 mouseX 限制在绘图区内，再线性反推时间戳
                        var clampedX = Math.max(pl, Math.min(mouse.x, pl + pw))
                        var target = tMin + (clampedX - pl) / pw * tRange
                        var best = 0
                        var bestDist = Math.abs(dl[0].x - target)
                        for (var i = 1; i < n; i++) {
                            var d = Math.abs(dl[i].x - target)
                            if (d < bestDist) {
                                bestDist = d
                                best = i
                            }
                        }
                        root.hoverIndex = best
                        // 更新底部提示条：时间 + 下行/上行速度
                        var ul = root.applet.speedHistoryUpload
                        var idx = root.hoverIndex
                        var upVal = idx < ul.length ? ul[idx].y : 0
                        root.hoverHint = Qt.formatDateTime(new Date(dl[idx].x * 1000), "HH:mm:ss")
                                + "  ↓" + common.formatSpeed(dl[idx].y)
                                + "  ↑" + common.formatSpeed(upVal)
                        canvas.requestPaint()
                    }

                    onExited: {
                        root.hoverIndex = -1
                        root.hoverHint = ""
                        canvas.requestPaint()
                    }
                }
            }

            // 底部提示条：默认显示操作引导；Hover 时显示该时刻的时间与上下行速度
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 30
                color: "transparent"

                Text {
                    anchors.centerIn: parent
                    text: root.hoverHint.length > 0
                          ? root.hoverHint : qsTr("Hover over the curve for details")
                    font.pixelSize: 11
                    color: root.hoverHint.length > 0 ? root.theme.textPrimary : root.theme.textTertiary
                }
            }

    // 动态刷新：C++ 每秒追加采样点时发射 speedHistoryChanged，触发 Canvas 重绘
    // 注意：此处不重置 Hover 状态，否则用户悬停时提示会随每秒刷新闪断；
    // 缓冲满后旧点滑出导致的索引漂移由 onPaint 中 hi < n 的边界判断兜底
    Connections {
        target: root.applet
        function onSpeedHistoryChanged() {
            // 窗口不可见时不重绘：后端仍每秒追加采样点，但无需为隐藏的 Canvas 做无效绘制
            if (!root.visible) return
            canvas.requestPaint()
        }
        // 接口切换时历史整体更换，原 Hover 索引失去意义，需清除避免残留标记
        function onActiveInterfaceChanged() {
            root.hoverIndex = -1
            root.hoverHint = ""
            canvas.requestPaint()
        }
    }
}
