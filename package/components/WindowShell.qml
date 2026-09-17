// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 独立窗口公共外壳：无边框窗口 + 圆角卡片 + 公共标题栏（含可选置顶按钮）
// + 位置/置顶状态持久化 + 内容区
// 设计原因：图表 / 流量统计 / TCP 连接清单三个独立窗口此前各自复制同一套外壳代码
// （flags、color、圆角卡片 Rectangle、ColumnLayout、TitleBar、关闭与置顶按钮、
// 居中与位置恢复逻辑），任何一处调整都要同步三份，且已经出现实际漂移
// （窗口圆角与标题栏边距各写各的、置顶按钮只存在于图表窗口且逻辑与视图混在一起）。
// 现集中到本组件：使用方只声明标题、尺寸、几何 key 与内容，不再关心外壳如何实现。
//
// 用法：
//   WindowShell {
//       id: root
//       windowKey: "stats"                       // 位置与置顶状态按此键持久化
//       title: qsTr(窗口标题)                 // 实际代码里由各窗口给出 qsTr 文案
//       width: 620; height: 440
//       applet: root.applet                     // 读写持久化设置，null 时跳过
//       isDarkMode: root.isDarkMode             // 由 networkview.qml 传入
//       accentColor: root.accentColor
//       ColumnLayout { ...内容... }              // 声明的子项自动进入内容列
//   }
//
// 内容区：使用方声明的子项会成为 contentColumn（ColumnLayout）的子项，
// 因此可直接使用 Layout.* 附加属性，与原各窗口把内容写在自己 ColumnLayout 里的写法一致。
// 该写法与项目内 TitleBar.extraActions 使用的是同一套"默认属性别名"机制
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import "."

Window {
    id: shell

    // ---- 使用方接口 ----
    // 标题栏文字
    property string title: ""
    // 窗口标识：位置与置顶状态按此键持久化（C++ 侧仅接受 chart/stats/tcp）
    property string windowKey: ""
    // 深色模式标记：由 networkview.qml 依据任务栏主题检测后传入
    property bool isDarkMode: false
    // C++ 后端对象：读写窗口几何与置顶状态；为 null 时跳过持久化（组件可独立预览）
    property var applet: null
    // 关闭按钮 hover 高亮色：由各窗口传入 accentColor
    property color accentColor: common.accentRed
    // 是否显示置顶按钮：三个业务窗口（图表/统计/TCP）均已开启，
    // 保留该开关是为了让"不需要置顶"的窗口（或将来复用的新窗口）能不显示按钮
    property bool pinnable: false
    // 置顶状态：与窗口 flags（WindowStaysOnTopHint）联动并持久化
    property bool pinned: false

    // 公共强调色：仅用于 accentColor 的默认值，避免与各窗口各写一份红色字面量
    NetCommon { id: common }

    // 外壳自建主题色：三个窗口的深浅取值与 WindowTheme 默认值一致，无需各自实例化
    WindowTheme {
        id: themeObject
        isDarkMode: shell.isDarkMode
    }
    // 主题色对象：内容文件里经 root.theme.xxx 访问（内容定义在使用方文件，
    // 看不到本文件的 id，必须由属性暴露）
    readonly property var theme: themeObject

    // 置顶按钮 hover 底色：与图表窗口原取值一致（半透明白/黑），深浅主题下均可见
    readonly property color pinHoverBg: isDarkMode ? Qt.rgba(1, 1, 1, 0.10)
                                                   : Qt.rgba(0, 0, 0, 0.06)

    // ---- 窗口外观：此前三个窗口各自声明的部分，现为外壳唯一来源 ----
    visible: false
    flags: Qt.FramelessWindowHint | Qt.Window | (pinned ? Qt.WindowStaysOnTopHint : 0)
    modality: Qt.NonModal
    color: "transparent"

    // ---- 窗口位置持久化（写入 settings.ini 的 geometry/<windowKey>）----
    // 设计原因：三个窗口此前每次打开都居中，用户拖到顺手的位置后下次打开又回到屏幕中央
    // 首次定位是否已完成：完成前不允许保存，避免把初始布局阶段的临时坐标写进配置
    property bool geometryReady: false

    // 显示时定位：有保存位置就用保存位置（C++ 已确认该点仍落在某个屏幕上），
    // 否则居中到任务栏所在屏幕（加 virtualX/virtualY 偏移，避免多显示器下出现在非预期屏幕）
    function applyInitialGeometry() {
        var g = shell.applet ? shell.applet.windowGeometry(shell.windowKey) : null
        if (g && g.valid) {
            x = g.x
            y = g.y
        } else {
            x = Screen.virtualX + (Screen.width - width) / 2
            y = Screen.virtualY + (Screen.height - height) / 2
        }
        shell.geometryReady = true
    }

    Timer {
        id: geometrySaveTimer
        interval: 500
        onTriggered: if (shell.applet && shell.geometryReady) {
            shell.applet.saveWindowGeometry(shell.windowKey, Math.round(shell.x), Math.round(shell.y))
        }
    }

    // 启动时恢复置顶状态。
    // 放在独立子对象的 Component.onCompleted 中，而不是外壳根对象的 Component.onCompleted：
    // 使用方窗口（如统计窗口）会在自己的根对象上声明 Component.onCompleted 做首次建表，
    // 外部对同名处理器的赋值会覆盖组件内部的处理器，导致置顶状态恢复失效
    QtObject {
        Component.onCompleted: if (shell.applet) shell.pinned = shell.applet.windowPinned(shell.windowKey)
    }

    // ---- 外壳需要监听的自身信号 ----
    // 统一用 Connections 监听，而不是在根对象上写 onXxxChanged / onVisibleChanged：
    // 使用方窗口会在自己的根对象（即本外壳实例）上声明 onVisibleChanged（刷新数据）、
    // onIsDarkModeChanged（重绘自身 Canvas）等处理器，外部赋值会覆盖组件内部的同名处理器，
    // 使位置恢复、位置保存、图钉重绘这些外壳行为静默失效。
    // Connections 的处理器挂在独立对象上，不会与使用方的声明冲突
    Connections {
        target: shell

        // 位置变化：拖动停止 500ms 后写一次盘（拖动中高频变化，逐次写盘无意义且产生大量 INI 写入）
        function onXChanged() { if (shell.visible && shell.geometryReady) geometrySaveTimer.restart() }
        function onYChanged() { if (shell.visible && shell.geometryReady) geometrySaveTimer.restart() }

        // 显示时定位：有保存位置就用保存位置，否则居中（见 applyInitialGeometry）
        function onVisibleChanged() { if (shell.visible) shell.applyInitialGeometry() }

        // 置顶状态：立即写盘 + 重绘图钉图标
        // （图钉由 Canvas 绘制，Canvas 不随属性绑定自动重绘，需主动触发）。
        // 恢复动作本身也会触发本处理器写回同一个值，多一次幂等写入，
        // 换取"任何赋值路径都能落盘"的简单性（无需额外的"是否来自恢复"标记）
        function onPinnedChanged() {
            if (shell.applet) shell.applet.setWindowPinned(shell.windowKey, shell.pinned)
            pinIcon.requestPaint()
        }

        // 主题切换：描边色取主题三级文字色，需重绘图钉图标
        function onIsDarkModeChanged() { pinIcon.requestPaint() }
    }

    // ---- 内容区 ----
    // 使用方声明的子项自动进入 contentColumn，与 TitleBar.extraActions 同一套写法
    default property alias windowContent: contentColumn.data

    // 圆角卡片背景：1px 边框模拟 DTK 窗口描边，圆角 12（与 AboutWindow 一致）
    Rectangle {
        anchors.fill: parent
        color: themeObject.winBg
        radius: 12
        border.width: 1
        border.color: themeObject.lineColor

        ColumnLayout {
            id: contentColumn
            anchors.fill: parent
            spacing: 0

            // 公共标题栏：标题文字 + 可选置顶按钮 + 关闭按钮，整栏可拖动
            TitleBar {
                Layout.fillWidth: true
                titleText: shell.title
                textColor: themeObject.textPrimary
                secondaryTextColor: themeObject.textSecondary
                closeHoverColor: shell.accentColor

                // 置顶按钮：28x28 圆形（与关闭按钮一致），由 TitleBar 的额外按钮槽
                // 自动布局到关闭按钮左侧。三态视觉：未置顶=灰色图钉轮廓；
                // 置顶=高亮蓝填充 + 淡蓝底；hover=淡灰底（置顶时淡蓝底优先）
                Rectangle {
                    visible: shell.pinnable
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 28
                    height: 28
                    radius: 14
                    // 三态：按下 > 置顶(淡蓝底) > hover(淡灰底)。
                    // pinHoverBg 是半透明色，按下态用同色提高透明度，
                    // 不用 Qt.darker（对含透明度的颜色会改变透明度语义）
                    color: pinMouse.pressed
                           ? Qt.rgba(shell.pinHoverBg.r, shell.pinHoverBg.g, shell.pinHoverBg.b, shell.pinHoverBg.a * 1.8)
                           : (shell.pinned ? Qt.rgba(common.accentBlueBright.r, common.accentBlueBright.g, common.accentBlueBright.b, 0.12)
                                           : (pinMouse.containsMouse ? shell.pinHoverBg : "transparent"))

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
                            var c = shell.pinned ? common.accentBlueBright : themeObject.textTertiary
                            ctx.strokeStyle = c
                            ctx.fillStyle = c
                            ctx.lineCap = "round"
                            ctx.lineJoin = "round"
                            ctx.lineWidth = shell.pinned ? 2 : 1.5

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

                            if (shell.pinned) {
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

                    // 无障碍：置顶按钮无文字（Canvas 画的图钉），名称需说明当前动作与结果
                    Accessible.role: Accessible.Button
                    Accessible.name: shell.pinned ? qsTr("Unpin window") : qsTr("Pin window on top")

                    MouseArea {
                        id: pinMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: shell.pinned = !shell.pinned
                    }
                }
            }
        }
    }
}
