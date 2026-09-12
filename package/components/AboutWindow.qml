// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 关于窗口：DTK 原生风格的独立顶层窗口，桌面居中弹出，展示插件信息
// 设计要点：圆角卡片 + 键值对信息布局，信息标签使用 deepin 蓝（#0081FF），
// 关闭按钮 hover 高亮色由父组件通过 accentColor 传入（红色）；
// 深/浅主题由 isDarkMode 切换（networkview.qml 依据 DTK.palette 检测任务栏深浅后传入），
// 默认浅色，保证组件独立预览时与原版视觉一致
// 对外依赖：accentColor、isDarkMode，由 networkview.qml 实例化时传入，触发方式为 show()/raise()/requestActivate()
// 公共能力复用：主题色取自 WindowTheme，标题栏/圆角卡片取自 TitleBar，消除三窗口样板重复
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import "."

Window {
    id: root

    // 公共主题色：集中定义于 WindowTheme.qml，随 isDarkMode 切换深浅
    WindowTheme {
        id: theme
        isDarkMode: root.isDarkMode
    }

    // 对外依赖：关闭按钮 hover 态文字高亮色，由父组件传入
    // 默认值与 networkview.qml 中 root.accentRed 一致，确保独立可用
    property color accentColor: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)

    // 插件版本号，由父组件从 C++ 后端 applet.version 传入
    // 版本唯一源是 CMakeLists.txt 的 project(VERSION)（经 metadata.json → 后端兜底），
    // 故此处默认空串、由界面显示占位符，不硬编码字面量版本号以免与真实版本不符
    property string version: ""

    // 深色模式标记：由 networkview.qml 根据 DTK.palette 检测后传入；
    // 默认 false（浅色）保证组件独立预览时与原版视觉一致
    property bool isDarkMode: false

    // 复制成功状态标记：true 时复制图标变绿并显示"已复制"提示，
    // 2 秒后由 copyResetTimer 复位
    property bool copied: false

    width: 320
    height: 260
    visible: false
    flags: Qt.FramelessWindowHint | Qt.Window
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

    // 窗口主体：圆角卡片（背景与边框随 isDarkMode 切换深浅），1px 边框模拟 DTK 窗口描边
    Rectangle {
        anchors.fill: parent
        color: theme.winBg
        radius: 12
        border.width: 1
        border.color: theme.lineColor

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // 公共标题栏：标题文字 + 圆形关闭按钮，整栏可拖动
            TitleBar {
                Layout.fillWidth: true
                titleText: qsTr("About")
                textColor: theme.textPrimary
                secondaryTextColor: theme.textSecondary
                closeHoverColor: root.accentColor
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
                    text: qsTr("Network Speed Monitor")
                    font.pixelSize: 18
                    font.weight: Font.Bold
                    color: theme.textPrimary
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                }

                Text {
                    text: "JNetApplet"
                    font.pixelSize: 12
                    color: theme.textTertiary
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
                color: theme.lineColor
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
                        text: qsTr("Version")
                        font.pixelSize: 12
                        color: "#0081FF"
                        Layout.preferredWidth: 56
                        Layout.alignment: Qt.AlignTop
                    }

                    Text {
                        text: version.length > 0 ? version : "—"
                        font.pixelSize: 12
                        color: theme.textPrimary
                        Layout.fillWidth: true
                    }
                }

                // 作者行
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Text {
                        text: qsTr("Author")
                        font.pixelSize: 12
                        color: "#0081FF"
                        Layout.preferredWidth: 56
                        Layout.alignment: Qt.AlignTop
                    }

                    Text {
                        text: "Jokul"
                        font.pixelSize: 12
                        color: theme.textPrimary
                        Layout.fillWidth: true
                    }
                }

                // 描述行
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Text {
                        text: qsTr("Description")
                        font.pixelSize: 12
                        color: "#0081FF"
                        Layout.preferredWidth: 56
                        Layout.alignment: Qt.AlignTop
                    }

                    Text {
                        text: qsTr("Monitor network speed and traffic")
                        font.pixelSize: 12
                        color: theme.textPrimary
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }
                }

                // 仓库行：URL 无空格，需 WrapAnywhere 才能在窄宽度下正确折行
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Text {
                        text: qsTr("Repository")
                        font.pixelSize: 12
                        color: "#0081FF"
                        Layout.preferredWidth: 56
                        Layout.alignment: Qt.AlignTop
                    }

                    Text {
                        text: "github.com/GershonWang/JNetApplet"
                        font.pixelSize: 11
                        color: theme.textTertiary
                        Layout.fillWidth: true
                        wrapMode: Text.WrapAnywhere
                    }

                    // 复制按钮：点击复制仓库地址到剪贴板，成功后图标变绿并显示"已复制"提示 2 秒
                    Item {
                        Layout.preferredWidth: 24
                        Layout.preferredHeight: 24
                        Layout.alignment: Qt.AlignTop

                        // "已复制"提示：卡片底色绿字小标签，显示在按钮左侧，
                        // 覆盖于 URL 文字上方，避免与值文本混排
                        Rectangle {
                            anchors.right: parent.left
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            visible: copied
                            width: copiedHintText.implicitWidth + 10
                            height: 18
                            radius: 4
                            color: theme.cardBg
                            border.width: 1
                            border.color: "#22A34A"

                            Text {
                                id: copiedHintText
                                anchors.centerIn: parent
                                text: qsTr("Copied")
                                font.pixelSize: 10
                                color: "#22A34A"
                            }
                        }

                        MouseArea {
                            id: copyRepoMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                // 界面展示省略协议前缀以节省横向空间；复制时补全 https://，
                                // 使粘贴出去的内容可直接被浏览器/终端识别为可访问链接
                                clipboardHelper.text = "https://github.com/GershonWang/JNetApplet"
                                clipboardHelper.selectAll()
                                clipboardHelper.copy()
                                copied = true
                                copyResetTimer.restart()
                            }
                        }

                        // 复制图标：两个重叠的小圆角矩形
                        // 前层矩形以卡片底色压住后层边框重叠区，形成"堆叠纸张"的视觉效果
                        // 后层矩形（向右下偏移 2px）
                        Rectangle {
                            x: 8
                            y: 8
                            width: 10
                            height: 10
                            radius: 2
                            color: theme.cardBg
                            border.width: 1
                            border.color: copyRepoMouse.containsMouse ? theme.textPrimary : theme.textTertiary
                        }

                        // 前层矩形（左上），复制成功时边框短暂变绿
                        Rectangle {
                            x: 6
                            y: 6
                            width: 10
                            height: 10
                            radius: 2
                            color: theme.cardBg
                            border.width: 1
                            border.color: copied ? "#22A34A" : (copyRepoMouse.containsMouse ? theme.textPrimary : theme.textTertiary)
                        }
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

    // 隐藏的 TextEdit 用于复制仓库地址到剪贴板
    // QML 没有直接剪贴板 API，用 TextEdit.selectAll()+copy() 实现
    //（与 networkview.qml 中 clipboardHelper 同模式）
    TextEdit {
        id: clipboardHelper
        visible: false
        text: ""
    }

    // 复制状态还原定时器：2 秒后将 copied 复位，图标与"已复制"提示恢复原状
    Timer {
        id: copyResetTimer
        interval: 2000
        onTriggered: root.copied = false
    }
}
