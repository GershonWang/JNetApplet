// SPDX-FileCopyrightText: 2024 MyCompany
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 关于窗口：DTK 原生风格的独立顶层窗口，桌面居中弹出，展示插件信息
// 设计要点：白色圆角卡片 + 键值对信息布局，信息标签使用 deepin 蓝（#0081FF），
// 关闭按钮 hover 高亮色由父组件通过 accentColor 传入（红色）
// 对外依赖：accentColor，由 networkview.qml 实例化时传入，触发方式为 show()/raise()/requestActivate()
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15

Window {
    id: root

    // 对外依赖：关闭按钮 hover 态文字高亮色，由父组件传入
    // 默认值与 networkview.qml 中 root.accentRed 一致，确保独立可用
    property color accentColor: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)

    width: 320
    height: 260
    visible: false
    flags: Qt.FramelessWindowHint | Qt.Window
    modality: Qt.NonModal
    color: "transparent"

    onVisibleChanged: {
        if (visible) {
            x = (Screen.width - width) / 2
            y = (Screen.height - height) / 2
        }
    }

    // 窗口主体：白色圆角卡片，1px 浅灰边框模拟 DTK 窗口描边
    Rectangle {
        anchors.fill: parent
        color: "#FFFFFF"
        radius: 12
        border.width: 1
        border.color: "#E8E8E8"

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // 自定义标题栏：左侧"关于"标题 + 右侧圆形关闭按钮，整栏可拖动窗口
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                color: "transparent"

                // 拖动层：声明在关闭按钮之前（位于其下方），避免遮挡按钮点击与 hover
                MouseArea {
                    anchors.fill: parent
                    drag.target: root
                }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("关于")
                    font.pixelSize: 15
                    font.weight: Font.Bold
                    color: "#333333"
                }

                // 关闭按钮：28x28 圆形，hover 时淡红底 + 红色 ×（颜色由 accentColor 决定）
                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 28
                    height: 28
                    radius: 14
                    color: aboutCloseMouse.containsMouse ? Qt.rgba(220 / 255, 38 / 255, 38 / 255, 0.15) : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: aboutCloseMouse.containsMouse ? accentColor : "#666666"
                    }

                    MouseArea {
                        id: aboutCloseMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.hide()
                    }
                }
            }

            // 标题区上方间距
            Item {
                Layout.preferredHeight: 12
            }

            // 标题区：插件中文名 + 英文名，整体居中
            // 注意：用 Layout.fillWidth + horizontalAlignment 而非 Layout.alignment，
            // 后者在 ColumnLayout 内对 Text 不可靠（实测会左对齐贴边）
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Text {
                    text: qsTr("网络速度监控")
                    font.pixelSize: 18
                    font.weight: Font.Bold
                    color: "#333333"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    text: "JNetApplet"
                    font.pixelSize: 12
                    color: "#999999"
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            // 标题区下方间距
            Item {
                Layout.preferredHeight: 12
            }

            // 分隔线：左右留 24px 边距，与信息区对齐
            Rectangle {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                Layout.preferredHeight: 1
                color: "#E8E8E8"
            }

            // 信息区上方间距
            Item {
                Layout.preferredHeight: 12
            }

            // 信息区：键值对布局，左侧标签固定 56px 宽（deepin 蓝），右侧为值
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                spacing: 8

                // 版本行
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Text {
                        text: qsTr("版本")
                        font.pixelSize: 12
                        color: "#0081FF"
                        Layout.preferredWidth: 56
                        Layout.alignment: Qt.AlignTop
                    }

                    Text {
                        text: "1.0"
                        font.pixelSize: 12
                        color: "#333333"
                        Layout.fillWidth: true
                    }
                }

                // 作者行
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Text {
                        text: qsTr("作者")
                        font.pixelSize: 12
                        color: "#0081FF"
                        Layout.preferredWidth: 56
                        Layout.alignment: Qt.AlignTop
                    }

                    Text {
                        text: "Jokul"
                        font.pixelSize: 12
                        color: "#333333"
                        Layout.fillWidth: true
                    }
                }

                // 描述行
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Text {
                        text: qsTr("描述")
                        font.pixelSize: 12
                        color: "#0081FF"
                        Layout.preferredWidth: 56
                        Layout.alignment: Qt.AlignTop
                    }

                    Text {
                        text: qsTr("监控网络速度和流量")
                        font.pixelSize: 12
                        color: "#333333"
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }
                }

                // 仓库行：URL 无空格，需 WrapAnywhere 才能在窄宽度下正确折行
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Text {
                        text: qsTr("仓库")
                        font.pixelSize: 12
                        color: "#0081FF"
                        Layout.preferredWidth: 56
                        Layout.alignment: Qt.AlignTop
                    }

                    Text {
                        text: "git.jokul.space/Jokul/JNetApplet"
                        font.pixelSize: 11
                        color: "#999999"
                        Layout.fillWidth: true
                        wrapMode: Text.WrapAnywhere
                    }
                }
            }

            // 弹性空间：吸收多余高度，保证底部内边距固定为 16px
            Item {
                Layout.fillHeight: true
            }

            // 底部内边距
            Item {
                Layout.preferredHeight: 16
            }
        }
    }
}
