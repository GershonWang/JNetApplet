// SPDX-FileCopyrightText: 2024 MyCompany
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 字体颜色选择器：用于设置窗口，提供预设色板与"跟随系统"选项
// 设计要点：白色圆角卡片与设置窗口其他分区视觉一致；圆形色块 22x22，
// 当前选中色加 2px 深色边框高亮；点击只发射 colorSelected 信号，
// 由父层（networkview.qml）回写 currentColor 并同步到 C++ 后端持久化
// 属性语义：
//   currentColor - 当前选中颜色字符串，空串表示"跟随系统"（默认）
//   colorSelected(string) - 用户点击色块时发射，参数为空串或 #RRGGBB
import QtQuick 2.15
import QtQuick.Layouts 1.15

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

    Layout.fillWidth: true
    Layout.preferredHeight: 52
    color: "#ffffff"
    radius: 10
    border.width: 1
    border.color: "#e0e0e0"

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
                // 当前选中态：2px 深色边框
                border.width: root.currentColor === modelData ? 2 : 0
                border.color: "#333333"

                Rectangle {
                    anchors.centerIn: parent
                    width: 22
                    height: 22
                    radius: 11
                    // 白色色块在白卡上需细边框可见
                    color: modelData
                    border.width: modelData === "#FFFFFF" ? 1 : 0
                    border.color: "#e0e0e0"
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
            border.color: "#333333"

            Rectangle {
                anchors.centerIn: parent
                width: 22
                height: 22
                radius: 11
                color: "#f5f5f5"
                border.width: 1
                border.color: "#e0e0e0"

                // 斜线：表示"无自定义色/跟随系统"
                Canvas {
                    anchors.fill: parent
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        ctx.strokeStyle = "#999999"
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
