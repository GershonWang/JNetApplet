// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 流量波动图窗口：屏幕居中的独立顶层窗口，展示当前活动接口最近 5 分钟的
// 网速趋势（下载/上传双折线图），随 C++ 后端 speedHistoryChanged 信号每秒动态刷新
// 设计要点：
// - 视觉风格复用 AboutWindow.qml（圆角卡片 12px、1px 边框、44px 标题栏、
//   28x28 圆形关闭按钮 hover 淡红底）；深/浅主题由 isDarkMode 切换
//   （networkview.qml 依据 DockPalette 检测任务栏深浅后传入），默认浅色保证独立预览可用
// - 图表使用纯 QML Canvas 绘制，无 QtCharts 等外部依赖（与项目零依赖风格一致）；
//   Canvas 不随属性绑定自动重绘，isDarkMode 变化时主动 requestPaint()
// - 数据通过属性注入：applet 即 networkview.qml 的 root.applet（C++ 后端对象），
//   为 null 时组件可独立预览（Canvas 显示"暂无历史数据"空状态）
// 触发方式：右键菜单"流量波动图" -> show()/raise()/requestActivate()
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import "."

Window {
    id: root

    // 公共格式化函数：集中定义于同目录 NetCommon.qml，
    // 与 networkview.qml、NetworkPopup 共享同一份实现，消除跨组件重复定义
    NetCommon { id: common }

    // 对外依赖：关闭按钮 hover 态文字高亮色，由父组件传入
    // 默认值与 networkview.qml 中 root.accentRed 一致，确保独立可用
    property color accentColor: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)

    // 对外依赖：C++ 后端对象（NetworkMonitorApplet），由 networkview.qml 传入
    // 提供 speedHistoryDownload / speedHistoryUpload（QVariantList of QPointF，
    // x=时间戳秒, y=速度 bytes/sec）、downloadSpeed / uploadSpeed、activeInterface
    // 为 null 时组件可独立预览（显示空状态），所有数据访问处均需做空值兜底
    property var applet: null

    // 深色模式标记：由 networkview.qml 根据 DockPalette 检测后传入；
    // 默认 false（浅色）保证组件独立预览时与原版视觉一致
    property bool isDarkMode: false

    // ---- 主题感知颜色：isDarkMode 为 false 时取值与原浅色硬编码完全一致 ----
    readonly property color winBg: isDarkMode ? "#202020" : "#FFFFFF"
    readonly property color lineColor: isDarkMode ? "#383838" : "#E8E8E8"
    readonly property color textPrimary: isDarkMode ? "#E0E0E0" : "#333333"
    readonly property color textSecondary: isDarkMode ? "#AAAAAA" : "#666666"
    readonly property color textTertiary: isDarkMode ? "#888888" : "#999999"
    // 置顶按钮 hover 底色：浅色用淡黑、深色用淡白，保证两种卡片背景上均可见
    readonly property color pinHoverBg: isDarkMode ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.06)

    // 图表绘制色：声明为 string 供 Canvas 2D 上下文直接使用
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

    // 窗口置顶状态：true 时 flags 附加 Qt.WindowStaysOnTopHint，窗口保持在
    // 所有非置顶窗口之上（便于边下载大文件边观察曲线）；由标题栏图钉按钮切换
    property bool pinned: false

    // 置顶状态变化时重绘图钉图标（未置顶=灰色轮廓，置顶=蓝色填充）
    onPinnedChanged: pinIcon.requestPaint()

    // 主题切换时重绘图表与图钉图标：Canvas 不随属性绑定自动重绘，需主动触发
    onIsDarkModeChanged: {
        pinIcon.requestPaint()
        canvas.requestPaint()
    }

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
    visible: false
    // flags 绑定 pinned：置顶时附加 WindowStaysOnTopHint；未置顶时该位为 0，
    // 与原静态 flags 行为完全一致
    flags: Qt.FramelessWindowHint | Qt.Window | (pinned ? Qt.WindowStaysOnTopHint : 0)
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

    // 窗口主体：圆角卡片（背景与边框随 isDarkMode 切换深浅），1px 边框模拟 DTK 窗口描边（与 AboutWindow 一致）
    Rectangle {
        anchors.fill: parent
        color: root.winBg
        radius: 12
        border.width: 1
        border.color: root.lineColor

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // 自定义标题栏：左侧"流量波动图"标题 + 右侧置顶/关闭按钮，整栏可拖动窗口
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                color: "transparent"

                // 拖动层：声明在关闭/置顶按钮之前（位于其下方），避免遮挡按钮点击与 hover
                // 注意：drag.target 只对 Item 生效，对 Window 无效（原实现拖动不工作）；
                // 改用 startSystemMove() 系统级窗口拖动，这是 frameless Window 的正确做法，
                // pressed 即触发，由窗口管理器接管移动，不干扰按钮的 hover/click
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.OpenHandCursor
                    onPressed: root.startSystemMove()
                }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Traffic Chart")
                    font.pixelSize: 15
                    font.weight: Font.Bold
                    color: root.textPrimary
                }

                // 置顶按钮：28x28 圆形（与关闭按钮一致），位于关闭按钮左侧
                // 三态视觉：未置顶=灰色图钉轮廓；置顶=deepin 蓝填充 + 淡蓝底；
                // hover=淡灰底（置顶时淡蓝底优先）
                Rectangle {
                    anchors.right: chartCloseButton.left
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    width: 28
                    height: 28
                    radius: 14
                    color: root.pinned ? Qt.rgba(0, 129 / 255, 1, 0.12)
                                       : (pinMouse.containsMouse ? root.pinHoverBg : "transparent")

                    // 置顶图标：Canvas 绘制"上箭头触顶"（⤒ 风格）——向上箭头指向顶部横杠，
                    // 是"置顶/移到顶部"最通用的视觉语言，与关闭按钮"×"形态区分明显
                    // 未置顶：灰色细线描边；置顶：蓝色加粗 + 箭头头部实心填充，激活态更醒目
                    Canvas {
                        id: pinIcon
                        anchors.centerIn: parent
                        width: 16
                        height: 16

                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            var c = root.pinned ? "#0081FF" : root.axisTextColor
                            ctx.strokeStyle = c
                            ctx.fillStyle = c
                            ctx.lineCap = "round"
                            ctx.lineJoin = "round"
                            ctx.lineWidth = root.pinned ? 2 : 1.5

                            // 顶部横杠：y=3，x 3..13
                            ctx.beginPath()
                            ctx.moveTo(3, 3)
                            ctx.lineTo(13, 3)
                            ctx.stroke()

                            // 箭头主干：自底部 (8,13) 向上至 (8,7)，
                            // 与横杠间留 ~1.5px 间隙，保持"触顶"的意象清晰
                            ctx.beginPath()
                            ctx.moveTo(8, 13)
                            ctx.lineTo(8, 7)
                            ctx.stroke()

                            if (root.pinned) {
                                // 置顶：箭头头部实心三角填充，与描边态形成明确视觉差异
                                ctx.beginPath()
                                ctx.moveTo(8, 5.2)
                                ctx.lineTo(4.6, 9)
                                ctx.lineTo(11.4, 9)
                                ctx.closePath()
                                ctx.fill()
                            } else {
                                // 未置顶：左右两片箭头羽，自顶端 (8,5.5) 向两肩展开
                                ctx.beginPath()
                                ctx.moveTo(8, 5.5)
                                ctx.lineTo(5, 8.5)
                                ctx.moveTo(8, 5.5)
                                ctx.lineTo(11, 8.5)
                                ctx.stroke()
                            }
                        }
                    }

                    MouseArea {
                        id: pinMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pinned = !root.pinned
                    }
                }

                // 关闭按钮：28x28 圆形，hover 时淡红底 + 红色 ×（颜色由 accentColor 决定）
                Rectangle {
                    id: chartCloseButton
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 28
                    height: 28
                    radius: 14
                    color: chartCloseMouse.containsMouse ? Qt.rgba(220 / 255, 38 / 255, 38 / 255, 0.15) : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: chartCloseMouse.containsMouse ? root.accentColor : root.textSecondary
                    }

                    MouseArea {
                        id: chartCloseMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.hide()
                    }
                }
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
                    color: root.textPrimary
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
                    color: root.textPrimary
                }

                Item { Layout.fillWidth: true }

                Text {
                    text: (root.applet && root.applet.activeInterface
                           ? root.applet.activeInterface : "—") + " · 5min"
                    font.pixelSize: 12
                    color: root.textTertiary
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

                    // ---- Y 轴上限计算（动态适应最近活动）----
                    // 使用最近 60 秒的数据计算 Y 轴上限，而非全量 5 分钟缓冲。
                    // 设计原因：若使用全量缓冲，当历史中存在大流量峰值（如 12MB/s 下载）时，
                    // 即使当前网速已降至 KB/s 级别，Y 轴仍保持高位，导致当前曲线被压到底部
                    // 无法观察波动。改用 60 秒窗口后，峰值滑出窗口时 Y 轴自动缩小，
                    // 始终为当前活动提供合适的显示比例。
                    var vMax = 0
                    var i
                    var recentWindow = 60  // 秒，Y 轴基于最近 1 分钟的活动计算
                    var recentStart = Math.max(0, n - recentWindow)
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

                    // ---- X 轴刻度：每分钟一个标签，均布于绘图区 ----
                    // 5 分钟窗口用 -5m/-4m/-3m/-2m/-1m/now 共 6 个标签，比 4 个三分点
                    // 的 -3m20s/-1m40s 更易读；循环按数组长度参数化，两端左/右对齐
                    var xLabels = ["-5m", "-4m", "-3m", "-2m", "-1m", "now"]
                    ctx.fillStyle = root.axisTextColor
                    ctx.textBaseline = "alphabetic"
                    for (i = 0; i < xLabels.length; i++) {
                        var lx = pl + pw * i / (xLabels.length - 1)
                        // 两端标签分别左/右对齐，避免文字越出卡片边缘被裁剪
                        ctx.textAlign = i === 0 ? "left" : (i === xLabels.length - 1 ? "right" : "center")
                        ctx.fillText(xLabels[i], lx, height - 8)
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
                    // X 轴固定为 5 分钟窗口 [tMax-300, tMax]：右缘始终对齐"now"，
                    // 数据不足 5 分钟时曲线从右侧向左生长，左侧留空网格。
                    // 设计原因：若按实际数据范围 [dl[0].x, tMax] 映射，刚启动时仅有
                    // 几秒数据会被拉伸到整个绘图宽度，X 轴标签 -5m/-4m/... 与实际范围
                    // 严重不符，用户看到的是"几秒趋势图"而非"5 分钟趋势图"。
                    // 300 = 5 分钟 × 60 秒，与 C++ MAX_HISTORY_SAMPLES 一致
                    var tMax = dl[n - 1].x
                    var tMin = tMax - 300
                    var tRange = 300

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
                    // 5 点滑动平均（±2 样本）：抑制 1 秒采样的亚秒混叠尖峰，
                    // 使曲线反映趋势而非瞬时脉冲；hover 提示仍显示原始值供诊断
                    function smoothY(data, idx) {
                        var sum = 0, cnt = 0
                        for (var k = Math.max(0, idx - 2); k <= Math.min(data.length - 1, idx + 2); k++) {
                            sum += data[k].y
                            cnt++
                        }
                        return cnt > 0 ? sum / cnt : data[idx].y
                    }
                    function drawSeries(data, colorCss, fillCss) {
                        var m = data.length
                        if (m === 0) return
                        var j, px, py
                        // 线下淡色填充（alpha 0.08）：贴到基线形成闭合区域
                        ctx.beginPath()
                        for (j = 0; j < m; j++) {
                            px = pl + ((data[j].x - tMin) / tRange) * pw
                            py = pt + ph - (smoothY(data, j) / yMax) * ph
                            if (j === 0) ctx.moveTo(px, py)
                            else ctx.lineTo(px, py)
                        }
                        ctx.lineTo(pl + ((data[m - 1].x - tMin) / tRange) * pw, pt + ph)
                        ctx.lineTo(pl + ((data[0].x - tMin) / tRange) * pw, pt + ph)
                        ctx.closePath()
                        ctx.fillStyle = fillCss
                        ctx.fill()
                        // 主线：2px 描边
                        ctx.beginPath()
                        for (j = 0; j < m; j++) {
                            px = pl + ((data[j].x - tMin) / tRange) * pw
                            py = pt + ph - (smoothY(data, j) / yMax) * ph
                            if (j === 0) ctx.moveTo(px, py)
                            else ctx.lineTo(px, py)
                        }
                        ctx.strokeStyle = colorCss
                        ctx.lineWidth = 2
                        ctx.lineCap = "round"
                        ctx.lineJoin = "round"
                        ctx.stroke()
                    }

                    // 先画上传（橙）再画下载（绿）：下载通常是主视线，后画置于上层
                    drawSeries(ul, "#FF9500", "rgba(255, 149, 0, 0.08)")
                    drawSeries(dl, "#34C759", "rgba(52, 199, 89, 0.08)")

                    // ---- Hover：竖直辅助线 + 两条折线上的圆点标记 ----
                    // hoverIndex 由 chartHover 根据 mouseX 反查更新；此处按索引换算坐标
                    var hi = root.hoverIndex
                    if (hi >= 0 && hi < n) {
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
                // 再线性扫描找最近点；300 点上限下扫描开销可忽略，无需二分
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
                        // X 轴用与绘制一致的固定 5 分钟窗口 [tMax-300, tMax] 反推时间戳，
                        // 保证 Hover 辅助线与折线上的采样点严格对齐
                        var tMax = dl[n - 1].x
                        var tMin = tMax - 300
                        var tRange = 300
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
                    color: root.hoverHint.length > 0 ? root.textPrimary : root.textTertiary
                }
            }
        }
    }

    // 动态刷新：C++ 每秒追加采样点时发射 speedHistoryChanged，触发 Canvas 重绘
    // 注意：此处不重置 Hover 状态，否则用户悬停时提示会随每秒刷新闪断；
    // 缓冲满后旧点滑出导致的索引漂移由 onPaint 中 hi < n 的边界判断兜底
    Connections {
        target: root.applet
        function onSpeedHistoryChanged() {
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
