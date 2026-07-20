// SPDX-FileCopyrightText: 2024 MyCompany
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 设置窗口：独立顶层窗口，桌面居中弹出，提供网络接口选择、字体颜色选择、插件卸载功能
// 设计要点：白色圆角卡片 + 自定义标题栏可拖动，接口单选切换，卸载按钮带复制命令功能
// 对外依赖：applet（C++ 后端对象）、networkInterfaces（接口列表）、activeInterface（当前接口）、
// accentColor（强调色），由 networkview.qml 实例化时传入，触发方式为 show()/raise()/requestActivate()
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15

Window {
    id: root

    // 对外依赖：C++ 后端对象，用于获取/设置接口、字体颜色等
    property var applet: null

    // 网络接口名称列表，由父组件从 C++ 后端 applet.networkInterfaces 传入
    property var networkInterfaces: []

    // 当前活动接口名称，由父组件从 C++ 后端 applet.activeInterface 传入
    property string activeInterface: ""

    // 强调色（红色），关闭按钮 hover 态文字高亮色，由父组件传入
    // 默认值与 networkview.qml 中 root.accentRed 一致，确保独立可用
    property color accentColor: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)

    // 卸载按钮文字：复制命令后临时显示提示，定时器到期后还原
    property string uninstallButtonText: qsTr("卸载插件")

    width: 350
    height: 390
    minimumWidth: 350
    maximumWidth: 350
    minimumHeight: 390
    maximumHeight: 390
    visible: false
    flags: Qt.FramelessWindowHint | Qt.Window
    // NonModal：不阻塞桌面其他区域，用户可同时操作任务栏
    modality: Qt.NonModal
    // 窗口透明：让圆角外的区域不显示，由内部 Rectangle 提供可见背景
    color: "transparent"

    // 根据接口名返回类型描述，用于设置窗口网络接口列表
    // 设计原因：用户面对多个网口时难以仅凭 enp3s0/wlp3s0 等命名判断用途，
    // 加一行类型说明（有线/无线/VPN 等）降低认知负担
    function interfaceDescription(name) {
        if (name === "lo") return qsTr("本地回环")
        if (name === "Meta") return qsTr("虚拟接口")
        if (/^enp|^eth/.test(name)) return qsTr("有线网络")
        if (/^wlp|^wlan/.test(name)) return qsTr("无线网络")
        if (/^docker|^veth/.test(name)) return qsTr("容器网络")
        if (/^br/.test(name)) return qsTr("桥接")
        if (/^tun|^tap/.test(name)) return qsTr("VPN")
        if (/^virbr/.test(name)) return qsTr("虚拟桥接")
        return qsTr("其他")
    }

    // 显示时居中到桌面
    onVisibleChanged: {
        if (visible) {
            x = (Screen.width - width) / 2
            y = (Screen.height - height) / 2
        }
    }

    // 主容器：提供不透明背景 + 圆角 + 边框
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

                // 拖动层：声明在关闭按钮之前（位于其下方），避免遮挡按钮点击与 hover
                // 用 startSystemMove() 系统级窗口拖动，由窗口管理器接管移动，
                // 这是 frameless Window 的正确做法，pressed 即触发，丝滑无抖动
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.OpenHandCursor
                    onPressed: root.startSystemMove()
                }

                // 标题文字
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("设置")
                    font.pixelSize: 15
                    font.weight: Font.Bold
                    color: "#333333"
                }

                // 关闭按钮
                Rectangle {
                    id: closeButton
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 28
                    height: 28
                    radius: 14
                    color: closeMouse.containsMouse ? Qt.rgba(220/255, 38/255, 38/255, 0.15) : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: closeMouse.containsMouse ? accentColor : "#666666"
                    }

                    MouseArea {
                        id: closeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.hide()
                    }
                }
            }

            // 分隔线
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: "#e0e0e0"
            }

            // 内容区域
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 12

                    // 网络接口选择区
                    Text {
                        text: qsTr("网络接口")
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: "#666666"
                    }

                    // 接口列表容器
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: networkInterfaces.length > 0 ? 40 + networkInterfaces.length * 28 : 80
                        color: "#ffffff"
                        radius: 10
                        border.width: 1
                        border.color: "#e0e0e0"

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 8

                            // 接口列表：RadioButton 单选切换活动接口
                            Repeater {
                                model: networkInterfaces
                                delegate: Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 28
                                    color: "transparent"
                                    radius: 6

                                    RadioButton {
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData
                                        checked: modelData === activeInterface
                                        onToggled: {
                                            if (applet) applet.setActiveInterface(modelData)
                                        }
                                    }

                                    // 接口类型描述：右对齐显示，与接口名分居两侧
                                    Text {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: interfaceDescription(modelData)
                                        font.pixelSize: 12
                                        color: "#999999"
                                    }
                                }
                            }

                            // 无接口提示
                            Text {
                                text: qsTr("未检测到网络接口")
                                font.pixelSize: 12
                                color: "#999999"
                                visible: networkInterfaces.length === 0
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }

                    // 字体颜色选择区：预设色板 + 跟随系统选项
                    // 设计原因：用户选择的颜色通过 applet.textColor 持久化到
                    // ~/.config/jnetapplet/settings.ini，重启 dde-shell 后仍生效
                    Text {
                        text: qsTr("字体颜色")
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: "#666666"
                    }

                    TextColorPicker {
                        Layout.fillWidth: true
                        currentColor: applet ? applet.textColor : ""
                        onColorSelected: if (applet) applet.textColor = color
                    }

                    Item { Layout.preferredHeight: 4 }

                    // 卸载插件按钮：文字可动态切换（复制命令后显示提示）
                    // 提示状态期间按钮不可点击，文字变绿色
                    Rectangle {
                        id: uninstallButton
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        // 提示状态时背景和边框变绿
                        readonly property bool isStatus: uninstallButtonText !== qsTr("卸载插件")
                        color: isStatus
                               ? Qt.rgba(22/255, 163/255, 74/255, 0.08)
                               : (uninstallMouse.containsMouse ? Qt.rgba(220/255, 38/255, 38/255, 0.15) : Qt.rgba(220/255, 38/255, 38/255, 0.08))
                        radius: 10
                        border.width: 1
                        border.color: isStatus ? Qt.rgba(22/255, 163/255, 74/255, 1) : accentColor

                        Text {
                            anchors.centerIn: parent
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: 8
                            text: uninstallButtonText
                            font.pixelSize: uninstallButton.isStatus ? 11 : 13
                            font.weight: Font.Medium
                            // 提示状态时文字绿色，否则红色
                            color: uninstallButton.isStatus ? Qt.rgba(22/255, 163/255, 74/255, 1) : accentColor
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                        }

                        MouseArea {
                            id: uninstallMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // 提示状态期间禁用点击
                            enabled: !uninstallButton.isStatus
                            onClicked: uninstallConfirmDialog.open()
                        }
                    }


                }
            }
        }
    }

    // 卸载确认对话框：在设置窗口内水平居中
    Dialog {
        id: uninstallConfirmDialog
        width: 320
        height: 260
        modal: true
        visible: false
        // 在设置窗口中心显示
        x: (root.width - width) / 2
        y: (root.height - height) / 2

        background: Rectangle {
            color: "#f5f5f5"
            radius: 12
            border.width: 1
            border.color: "#e0e0e0"
        }

        contentItem: ColumnLayout {
            spacing: 16
            anchors.fill: parent
            anchors.margins: 20

            Text {
                text: qsTr("警告")
                font.pixelSize: 16
                font.weight: Font.Bold
                color: accentColor
                Layout.alignment: Qt.AlignHCenter
            }

            Text {
                text: qsTr("以下命令用于卸载插件并重启 dde-shell，请复制到终端中执行：")
                font.pixelSize: 12
                color: "#333333"
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            // 命令显示区域
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 60
                color: "#e8e8e8"
                radius: 8

                Text {
                    anchors.fill: parent
                    anchors.margins: 10
                    text: "sudo rm -rf /usr/share/dde-shell/space.jokul.JNetApplet/ && systemctl --user restart dde-shell@DDE"
                    font.pixelSize: 10
                    font.family: "monospace"
                    color: "#666666"
                    wrapMode: Text.WordWrap
                }
            }

            Item { Layout.fillHeight: true }

            // 按钮区域
            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                // 取消按钮
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    color: cancelUninstallMouse.containsMouse ? "#f0f0f0" : "#ffffff"
                    radius: 8
                    border.width: 1
                    border.color: "#e0e0e0"

                    Text {
                        anchors.centerIn: parent
                        text: qsTr("取消")
                        font.pixelSize: 13
                        color: "#333333"
                    }

                    MouseArea {
                        id: cancelUninstallMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: uninstallConfirmDialog.close()
                    }
                }

                // 复制命令按钮
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 36
                    color: confirmUninstallMouse.containsMouse ? accentColor : Qt.rgba(220/255, 38/255, 38/255, 0.8)
                    radius: 8

                    Text {
                        anchors.centerIn: parent
                        text: qsTr("复制命令")
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        color: "white"
                    }

                    MouseArea {
                        id: confirmUninstallMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // 复制卸载命令到剪贴板
                            clipboardHelper.selectAll()
                            clipboardHelper.copy()
                            uninstallConfirmDialog.close()
                            // 卸载按钮文字临时替换为复制成功提示，5 秒后还原
                            uninstallButtonText = qsTr("卸载命令已复制到剪贴板，请在终端中粘贴执行")
                            statusHideTimer.start()
                        }
                    }
                }
            }
        }
    }

    // 隐藏的 TextEdit 用于复制卸载命令到剪贴板
    // QML 没有直接剪贴板 API，用 TextEdit.selectAll()+copy() 实现
    TextEdit {
        id: clipboardHelper
        visible: false
        text: "sudo rm -rf /usr/share/dde-shell/space.jokul.JNetApplet/ && systemctl --user restart dde-shell@DDE"
    }

    // 卸载按钮文字还原定时器：复制命令后 5 秒将按钮文字从提示还原为"卸载插件"
    Timer {
        id: statusHideTimer
        interval: 5000
        onTriggered: uninstallButtonText = qsTr("卸载插件")
    }
}
