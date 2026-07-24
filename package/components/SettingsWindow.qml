// SPDX-FileCopyrightText: 2024 MyCompany
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 设置窗口：独立顶层窗口，桌面居中弹出，提供网络接口选择、字体颜色选择、插件卸载功能
// 设计要点：圆角卡片 + 自定义标题栏可拖动，接口单选切换，卸载按钮带复制命令功能；
// 深/浅主题由 isDarkMode 切换（networkview.qml 依据 DockPalette 检测任务栏深浅后传入），
// 默认浅色，保证组件独立预览时与原版视觉一致
// 对外依赖：applet（C++ 后端对象）、networkInterfaces（接口列表）、activeInterface（当前接口）、
// accentColor（强调色）、isDarkMode（深色模式标记），由 networkview.qml 实例化时传入，
// 触发方式为 show()/raise()/requestActivate()
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

    // 深色模式标记：由 networkview.qml 根据 DockPalette 检测后传入；
    // 默认 false（浅色）保证组件独立预览时与原版视觉一致
    property bool isDarkMode: false

    // ---- 主题感知颜色：isDarkMode 为 false 时取值与原浅色硬编码完全一致 ----
    readonly property color winBg: isDarkMode ? "#202020" : "#F5F5F5"
    readonly property color cardBg: isDarkMode ? "#2A2A2A" : "#FFFFFF"
    readonly property color lineColor: isDarkMode ? "#383838" : "#E0E0E0"
    readonly property color textPrimary: isDarkMode ? "#E0E0E0" : "#333333"
    readonly property color textSecondary: isDarkMode ? "#AAAAAA" : "#666666"
    readonly property color textTertiary: isDarkMode ? "#888888" : "#999999"
    readonly property color iconGray: isDarkMode ? "#AAAAAA" : "#777777"
    readonly property color hoverBg: isDarkMode ? "#353535" : "#F0F0F0"
    readonly property color codeBg: isDarkMode ? "#2A2A2A" : "#E8E8E8"
    // 选中态蓝色系：深色模式下背景压暗、文字改浅蓝，保证深色卡片上的对比度
    readonly property color selBg: isDarkMode ? "#1A3A5C" : "#E3F2FD"
    readonly property color selBgHover: isDarkMode ? "#1E4A6E" : "#D8ECFD"
    readonly property color selBorder: isDarkMode ? "#2C5A8A" : "#90CAF9"
    readonly property color selText: isDarkMode ? "#64B5F6" : "#1565C0"

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

    // 根据接口名返回类型图标（Unicode 符号），用于网络接口列表每行左侧
    // 设计原因：项目未引入图标库，用 Text 渲染 Unicode 符号（与 networkview.qml 的 ↓↑ 一致）；
    // 所选符号均为 DejaVu/Noto 等常见字体覆盖的单色字形，避免彩色 emoji 破坏浅色主题观感，
    // 匹配规则与 interfaceDescription 保持一致
    function interfaceIcon(name) {
        if (name === "lo") return "↻"               // 本地回环：循环箭头
        if (name === "Meta") return "▢"             // 虚拟接口：空心方块
        if (/^enp|^eth/.test(name)) return "⇄"      // 有线网络：双向链路
        if (/^wlp|^wlan/.test(name)) return "∿"     // 无线网络：信号波形
        if (/^docker|^veth/.test(name)) return "▣"  // 容器网络：盒中盒
        if (/^br/.test(name)) return "⋈"            // 桥接：连接（蝴蝶结形）
        if (/^tun|^tap/.test(name)) return "⚿"      // VPN：钥匙
        if (/^virbr/.test(name)) return "⋈"         // 虚拟桥接：同桥接
        return "◉"                                  // 其他：通用网络节点
    }

    // 显示时居中到当前屏幕（任务栏所在屏幕）
    onVisibleChanged: {
        if (visible) {
            // 加 virtualX/virtualY 偏移，避免多显示器下窗口出现在非预期屏幕
            x = Screen.virtualX + (Screen.width - width) / 2
            y = Screen.virtualY + (Screen.height - height) / 2
        }
    }

    // 主容器：提供不透明背景（随 isDarkMode 切换深浅）+ 圆角 + 边框
    Rectangle {
        anchors.fill: parent
        color: root.winBg
        radius: 12
        border.width: 1
        border.color: root.lineColor

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
                    color: root.textPrimary
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
                        color: closeMouse.containsMouse ? accentColor : root.textSecondary
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
                color: root.lineColor
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
                        color: root.textSecondary
                    }

                    // 接口列表容器：最多显示约 5 行（160px），超出部分垂直滚动
                    Rectangle {
                        Layout.fillWidth: true
                        // 高度 = 上下边距 10*2 + 列表可视高度；可视高度 = min(内容高度, 160)
                        // 内容高度 = 行高 30*n + 行间距 2*(n-1)，接口少时卡片随行数收缩
                        Layout.preferredHeight: networkInterfaces.length > 0
                            ? Math.min(ifaceColumn.implicitHeight, 160) + 20
                            : 80
                        color: root.cardBg
                        radius: 10
                        border.width: 1
                        border.color: root.lineColor

                        // 用 ScrollView 而非裸 Flickable：自带滚轮滚动支持，
                        // 且滚动条显示时自动让出内容宽度，不会遮挡行内文字
                        ScrollView {
                            id: ifaceScrollView
                            anchors.fill: parent
                            anchors.margins: 10
                            visible: networkInterfaces.length > 0
                            clip: true
                            // 内容宽度跟随可视宽度（自动减去滚动条占位），禁止水平滚动
                            contentWidth: availableWidth

                            // 自定义滚动条样式：与 networkview.qml chip 滚动条一致（4px 圆角矩形），
                            // 颜色使用主题感知灰色系（随 isDarkMode 切换深浅）；
                            // AsNeeded 策略保证接口少时不显示滚动条
                            ScrollBar.vertical: ScrollBar {
                                id: ifaceScrollBar
                                policy: ScrollBar.AsNeeded
                                interactive: true

                                contentItem: Rectangle {
                                    implicitWidth: 4
                                    radius: 2
                                    // 按压/悬停加深、默认稍淡，保证滚动条在卡片背景上可见
                                    color: ifaceScrollBar.pressed ? root.textSecondary
                                          : (ifaceScrollBar.hovered ? root.textSecondary : root.textTertiary)
                                }
                            }

                            Column {
                                id: ifaceColumn
                                width: ifaceScrollView.availableWidth
                                // 行间距 2：紧凑列表，各行 hover 背景不粘连
                                spacing: 2

                                // 接口列表：整行点击切换活动接口
                                // 行样式：类型图标 + 单选圆点 + 名称 + 右侧类型描述；
                                // hover 底、选中底与边框颜色均随 isDarkMode 切换深浅
                                Repeater {
                                    model: networkInterfaces
                                    delegate: Rectangle {
                                        id: ifaceRow
                                        width: ifaceColumn.width
                                        height: 30
                                        radius: 8
                                        // 当前行是否为活动接口（选中态）
                                        readonly property bool isActive: modelData === activeInterface
                                        readonly property bool hovered: rowMouse.containsMouse
                                        // 选中态强调色由 root.selText 提供（浅色 #1565c0 / 深色 #64b5f6）：
                                        // 保证 ▢ 等空心图标在选中背景上仍有足够对比度
                                        readonly property color activeColor: root.selText
                                        // 背景优先级：选中 > hover；选中行 hover 时稍加深以保留交互反馈
                                        color: isActive
                                               ? (hovered ? root.selBgHover : root.selBg)
                                               : (hovered ? root.hoverBg : "transparent")
                                        // 选中行加细边框增强视觉；未选中保持透明边框占位，避免切换时出现 1px 抖动
                                        border.width: 1
                                        border.color: isActive ? root.selBorder : "transparent"

                                        // 整行 hover + 点击：行内元素均不处理鼠标事件，
                                        // 点击行任意位置即选中该接口
                                        MouseArea {
                                            id: rowMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: if (applet) applet.setActiveInterface(modelData)
                                        }

                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 10
                                            anchors.rightMargin: 10
                                            spacing: 8

                                            // 网卡类型图标：固定宽度居中，保证不同字形的视觉对齐
                                            Text {
                                                Layout.alignment: Qt.AlignVCenter
                                                Layout.preferredWidth: 20
                                                horizontalAlignment: Text.AlignHCenter
                                                text: interfaceIcon(modelData)
                                                font.pixelSize: 14
                                                color: ifaceRow.isActive ? ifaceRow.activeColor : root.iconGray
                                            }

                                            // 自绘单选圆点：替代 RadioButton 作纯视觉指示器，
                                            // 避免 DTK 样式渲染差异（本文件早期版本 RadioButton 标签渲染异常），
                                            // 选中态颜色完全可控；点击由整行 MouseArea 统一处理
                                            Rectangle {
                                                Layout.alignment: Qt.AlignVCenter
                                                Layout.preferredWidth: 16
                                                Layout.preferredHeight: 16
                                                radius: 8
                                                color: "transparent"
                                                border.width: 2
                                                border.color: ifaceRow.isActive ? ifaceRow.activeColor
                                                              : (ifaceRow.hovered ? root.textSecondary : root.textTertiary)

                                                Rectangle {
                                                    anchors.centerIn: parent
                                                    width: 8
                                                    height: 8
                                                    radius: 4
                                                    visible: ifaceRow.isActive
                                                    color: ifaceRow.activeColor
                                                }
                                            }

                                            // 接口名称：过长时右侧省略
                                            Text {
                                                Layout.alignment: Qt.AlignVCenter
                                                Layout.fillWidth: true
                                                text: modelData
                                                font.pixelSize: 13
                                                font.weight: ifaceRow.isActive ? Font.Medium : Font.Normal
                                                color: ifaceRow.isActive ? ifaceRow.activeColor : root.textPrimary
                                                elide: Text.ElideRight
                                            }

                                            // 接口类型描述：右对齐显示，与接口名分居两侧
                                            Text {
                                                Layout.alignment: Qt.AlignVCenter
                                                text: interfaceDescription(modelData)
                                                font.pixelSize: 12
                                                color: root.textTertiary
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 无接口提示：在卡片内居中
                        Text {
                            anchors.centerIn: parent
                            text: qsTr("未检测到网络接口")
                            font.pixelSize: 12
                            color: root.textTertiary
                            visible: networkInterfaces.length === 0
                        }
                    }

                    // 字体颜色选择区：预设色板 + 跟随系统选项
                    // 设计原因：用户选择的颜色通过 applet.textColor 持久化到
                    // ~/.config/jnetapplet/settings.ini，重启 dde-shell 后仍生效
                    Text {
                        text: qsTr("字体颜色")
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: root.textSecondary
                    }

                    TextColorPicker {
                        Layout.fillWidth: true
                        currentColor: applet ? applet.textColor : ""
                        // 深色模式标记向下传递：TextColorPicker 内部色板卡片同样主题感知
                        isDarkMode: root.isDarkMode
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
            color: root.winBg
            radius: 12
            border.width: 1
            border.color: root.lineColor
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
                color: root.textPrimary
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            // 命令显示区域
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 60
                color: root.codeBg
                radius: 8

                Text {
                    anchors.fill: parent
                    anchors.margins: 10
                    text: "sudo rm -rf /usr/share/dde-shell/space.jokul.JNetApplet/ && systemctl --user restart dde-shell@DDE"
                    font.pixelSize: 10
                    font.family: "monospace"
                    color: root.textSecondary
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
                    color: cancelUninstallMouse.containsMouse ? root.hoverBg : root.cardBg
                    radius: 8
                    border.width: 1
                    border.color: root.lineColor

                    Text {
                        anchors.centerIn: parent
                        text: qsTr("取消")
                        font.pixelSize: 13
                        color: root.textPrimary
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
