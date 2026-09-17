// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 字体颜色选择器：用于设置窗口，提供预设色板与"跟随系统"选项
// 设计要点：圆角卡片与设置窗口其他分区视觉一致；圆形色块 22x22，
// 当前选中色加 2px 边框高亮（颜色随主题切换）；点击只发射 colorSelected 信号，
// 由父层（SettingsWindow）回写 currentColor 并同步到 C++ 后端持久化；
// 深/浅主题由 isDarkMode 切换（SettingsWindow 传入），默认浅色保证独立预览可用
// 公共能力复用：主题色取自 WindowTheme（本组件原自带第四套深浅色板，已收敛），
// 仅覆盖 lightLineColor 以匹配设置窗口的线色 #E0E0E0
// 属性语义：
//   currentColor - 当前选中颜色字符串，空串表示"跟随系统"（默认）
//   colorSelected(string) - 用户点击色块时发射，参数为空串或 #RRGGBB
import QtQuick 2.15
import QtQuick.Layouts 1.15
import "."

Rectangle {
    id: root

    // 当前选中颜色：空串=跟随系统，用于显示选中态高亮
    property string currentColor: ""

    // 用户点击色块时发射，父层据此回写 currentColor 并持久化
    signal colorSelected(string color)

    // 预设色板：8 个常用色，覆盖白/黑/暖/冷，克制实用
    property var presetColors: [
        "#FFFFFF", "#000000", "#DC2626", "#F59E0B",
        "#16A34A", "#1450A0", "#7C3AED", "#0891B2"
    ]

    // 深色模式标记：由 SettingsWindow 传入；默认 false（浅色）保证独立预览可用
    property bool isDarkMode: false

    // 公共主题色：改用 WindowTheme 提供深浅取值，不再在本文件维护第四套色板
    // 设计原因：此处原有 cardBg/lineColor/ringColor/systemSwatchBg 四组 isDarkMode
    // 三元表达式，与 WindowTheme 的对应项重复；取值等价关系为
    //   cardBg   -> theme.cardBg   （浅 #FFFFFF / 深 #2A2A2A）
    //   lineColor-> theme.lineColor（深色 #383838 相同，浅色本处为 #E0E0E0 故覆盖）
    //   ringColor-> theme.textPrimary（浅 #333333 / 深 #E0E0E0）
    //   systemSwatchBg -> theme.sunkenBg（浅 #F5F5F5 / 深 #202020）
    WindowTheme {
        id: theme
        isDarkMode: root.isDarkMode
        lightLineColor: "#E0E0E0"
    }

    Layout.fillWidth: true
    Layout.preferredHeight: 52
    color: theme.cardBg
    radius: 10
    border.width: 1
    border.color: theme.lineColor

    // Canvas 不随属性绑定自动重绘，主题切换时主动触发"跟随系统"斜线重绘
    onIsDarkModeChanged: slashCanvas.requestPaint()

    RowLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        // 预设色块
        Repeater {
            model: root.presetColors
            delegate: Rectangle {
                width: 26
                height: 26
                radius: 13
                color: "transparent"
                // 当前选中态：2px 边框高亮（颜色随主题切换）
                border.width: root.currentColor === modelData ? 2 : 0
                border.color: theme.textPrimary

                Rectangle {
                    anchors.centerIn: parent
                    width: 22
                    height: 22
                    radius: 11
                    // 白色色块在白卡上需细边框可见；深色模式下深色卡片上的黑色色块同理
                    color: modelData
                    border.width: (modelData === "#FFFFFF"
                                   || (root.isDarkMode && modelData === "#000000")) ? 1 : 0
                    border.color: theme.lineColor
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.colorSelected(modelData)
                }
            }
        }

        // 跟随系统选项：斜线色块表示恢复默认
        Rectangle {
            width: 26
            height: 26
            radius: 13
            color: "transparent"
            // currentColor 为空串时高亮（跟随系统选中态）
            border.width: root.currentColor === "" ? 2 : 0
            border.color: theme.textPrimary

            Rectangle {
                anchors.centerIn: parent
                width: 22
                height: 22
                radius: 11
                color: theme.sunkenBg
                border.width: 1
                border.color: theme.lineColor

                // 斜线：表示"无自定义色/跟随系统"
                Canvas {
                    id: slashCanvas
                    anchors.fill: parent
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        ctx.strokeStyle = theme.textTertiary
                        ctx.lineWidth = 2
                        ctx.beginPath()
                        ctx.moveTo(2, height - 2)
                        ctx.lineTo(width - 2, 2)
                        ctx.stroke()
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.colorSelected("")
            }
        }

        // 弹性空间，让色块左对齐
        Item { Layout.fillWidth: true }
    }
}
