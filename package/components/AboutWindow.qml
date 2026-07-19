// SPDX-FileCopyrightText: 2024 MyCompany
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 关于窗口：独立顶层窗口，桌面居中弹出，展示插件信息
// 从 networkview.qml 抽取，由父组件实例化并调用 show() 触发
// 对外依赖：accentColor（关闭按钮 hover 高亮色），由父组件传入
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15

Window {
    id: root

    // 对外依赖：关闭按钮 hover 态文字高亮色，由父组件传入
    // 默认值与 networkview.qml 中 root.accentRed 一致，确保独立可用
    property color accentColor: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)

    width: 320
    height: 230
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

    Rectangle {
        anchors.fill: parent
        color: "#f5f5f5"
        radius: 12
        border.width: 1
        border.color: "#e0e0e0"

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 0
            spacing: 0

            // 自定义标题栏（可拖动）
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 44
                color: "transparent"

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

                Rectangle {
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 28
                    height: 28
                    radius: 14
                    color: aboutCloseMouse.containsMouse ? Qt.rgba(220/255, 38/255, 38/255, 0.15) : "transparent"

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

            // 内容区
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                anchors.margins: 0
                spacing: 10
                Layout.leftMargin: 24
                Layout.rightMargin: 24
                Layout.topMargin: 4

                // 标题组：插件名 + 英文名紧凑排列
                ColumnLayout {
                    spacing: 2
                    Layout.alignment: Qt.AlignHCenter

                    Text {
                        text: qsTr("网络速度监控")
                        font.pixelSize: 18
                        font.weight: Font.Bold
                        color: "#333333"
                        Layout.alignment: Qt.AlignHCenter
                    }

                    Text {
                        text: "JNetApplet"
                        font.pixelSize: 12
                        color: "#999999"
                        Layout.alignment: Qt.AlignHCenter
                    }
                }

                // 分隔线
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: "#e0e0e0"
                }

                // 信息行
                ColumnLayout {
                    spacing: 6
                    Layout.fillWidth: true

                    Text {
                        text: qsTr("版本：1.0")
                        font.pixelSize: 12
                        color: "#666666"
                    }

                    Text {
                        text: qsTr("作者：Jokul")
                        font.pixelSize: 12
                        color: "#666666"
                    }

                    Text {
                        text: qsTr("描述：监控网络速度和流量")
                        font.pixelSize: 12
                        color: "#666666"
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        text: qsTr("仓库：git.jokul.space/Jokul/JNetApplet")
                        font.pixelSize: 11
                        color: "#999999"
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }
    }
}
