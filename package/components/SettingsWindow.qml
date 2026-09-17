// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 设置窗口：独立顶层窗口，桌面居中弹出，提供网络接口选择、字体颜色选择、插件卸载功能
// 设计要点：圆角卡片 + 自定义标题栏可拖动，接口单选切换，卸载按钮带复制命令功能；
// 深/浅主题由 isDarkMode 切换（networkview.qml 依据 DTK.palette 检测任务栏深浅后传入），
// 默认浅色，保证组件独立预览时与原版视觉一致
// 对外依赖：applet（C++ 后端对象）、networkInterfaces（接口列表）、activeInterface（当前接口）、
// accentColor（强调色）、isDarkMode（深色模式标记），由 networkview.qml 实例化时传入，
// 触发方式为 show()/raise()/requestActivate()
// 公共能力复用：主题色取自 WindowTheme（本窗口 winBg 浅色 #F5F5F5、lineColor 浅色
// #E0E0E0 与其他窗口不同，通过覆盖 WindowTheme 的浅色对实现），标题栏/圆角卡片取自 TitleBar
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import "."

Window {
    id: root

    // 公共函数：interfaceIcon/interfaceDescription 已从本文件迁移至 NetCommon.qml，
    // 与 NetworkPopup 共享同一份实现，消除跨组件重复定义
    NetCommon { id: common }

    // 公共主题色：集中定义于 WindowTheme.qml，随 isDarkMode 切换深浅。
    // 本窗口 winBg 浅色 #F5F5F5、lineColor 浅色 #E0E0E0 与默认值不同，在此覆盖
    WindowTheme {
        id: theme
        isDarkMode: root.isDarkMode
        lightWinBg: "#F5F5F5"
        lightLineColor: "#E0E0E0"
    }

    // 对外依赖：C++ 后端对象，用于获取/设置接口、字体颜色等
    property var applet: null

    // 网络接口名称列表，由父组件从 C++ 后端 applet.networkInterfaces 传入
    property var networkInterfaces: []

    // 当前活动接口名称，由父组件从 C++ 后端 applet.activeInterface 传入
    property string activeInterface: ""

    // 强调色（红色），关闭按钮 hover 态文字高亮色，由父组件传入
    // 默认值与 networkview.qml 中 root.accentRed 一致，确保独立可用
    property color accentColor: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)

    // 深色模式标记：由 networkview.qml 根据 DTK.palette 检测后传入；
    // 默认 false（浅色）保证组件独立预览时与原版视觉一致
    property bool isDarkMode: false

    // ---- 设置窗口特有颜色（不属于三窗口公共主题）----
    // 命令显示区底色
    readonly property color codeBg: isDarkMode ? "#2A2A2A" : "#E8E8E8"
    // 选中态蓝色系：深色模式下背景压暗、文字改浅蓝，保证深色卡片上的对比度
    readonly property color selBg: isDarkMode ? "#1A3A5C" : "#E3F2FD"
    readonly property color selBgHover: isDarkMode ? "#1E4A6E" : "#D8ECFD"
    readonly property color selBorder: isDarkMode ? "#2C5A8A" : "#90CAF9"
    readonly property color selText: isDarkMode ? "#64B5F6" : "#1565C0"

    // 卸载命令单一来源：界面展示文本与剪贴板内容共用同一条字符串
    // 设计原因：原实现把同一串命令硬编码在展示 Text 与隐藏 TextEdit 两处，
    // 插件 ID / 安装路径一旦调整，就可能出现"显示的命令"与"复制的命令"不一致
    readonly property string uninstallCommand: "sudo rm -rf /usr/share/dde-shell/space.jokul.JNetApplet/ && systemctl --user restart dde-shell@DDE"

    // "卸载命令已复制"提示态：控制按钮下方独立状态行的显示
    // 设计原因：早期实现把 76 字符的提示整句赋给按钮文字，而按钮高 40px、文字区仅约 24px，
    // 换行后的提示会被裁切；同时按钮显示的应是动作而非状态。
    // 现在状态由本布尔量驱动一条独立提示行，按钮文字恒为"卸载插件"
    property bool uninstallCopied: false

    // 宽度固定 350；高度改为"默认更高 + 允许随屏幕收缩"，不再把 min/max 锁成同一个值
    // 设计原因：原实现 minimumHeight == maximumHeight == 450，而内容区（标题 44 + 分割线 1
    // + 上下文边距 32 + 各分区合计约 448）在多网卡机器上会超出窗口高度，
    // 底部"卸载插件"区域可能被压缩到难以点击；放开上限后内容优先按 preferred 高度展示
    // 注意：像素是否够用需在多网卡环境实测，必要时可改为整块内容放入滚动容器
    width: 350
    height: 520
    minimumWidth: 350
    maximumWidth: 350
    minimumHeight: 360
    maximumHeight: Screen.height * 0.8
    visible: false
    flags: Qt.FramelessWindowHint | Qt.Window
    // NonModal：不阻塞桌面其他区域，用户可同时操作任务栏
    modality: Qt.NonModal
    // 窗口透明：让圆角外的区域不显示，由内部 Rectangle 提供可见背景
    color: "transparent"

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
        color: theme.winBg
        radius: 12
        border.width: 1
        border.color: theme.lineColor

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 0
            spacing: 0

            // 公共标题栏：标题文字 + 圆形关闭按钮，整栏可拖动
            TitleBar {
                Layout.fillWidth: true
                titleText: qsTr("Settings")
                textColor: theme.textPrimary
                secondaryTextColor: theme.textSecondary
                closeHoverColor: root.accentColor
            }

            // 分隔线
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: theme.lineColor
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
                        text: qsTr("Network Interface")
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: theme.textSecondary
                    }

                    // 接口列表容器：最多显示约 5 行（160px），超出部分垂直滚动
                    Rectangle {
                        Layout.fillWidth: true
                        // 高度 = 上下边距 10*2 + 列表可视高度；可视高度 = min(内容高度, 160)
                        // 内容高度 = 行高 30*n + 行间距 2*(n-1)，接口少时卡片随行数收缩
                        Layout.preferredHeight: networkInterfaces.length > 0
                            ? Math.min(ifaceColumn.implicitHeight, 160) + 20
                            : 80
                        color: theme.cardBg
                        radius: 10
                        border.width: 1
                        border.color: theme.lineColor

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
                                    color: ifaceScrollBar.pressed ? theme.textSecondary
                                          : (ifaceScrollBar.hovered ? theme.textSecondary : theme.textTertiary)
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
                                    // 与弹窗接口 chip 共用同一排序规则，避免两处顺序不一致
                                    model: common.sortInterfaces(networkInterfaces)
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
                                               : (hovered ? theme.hoverBg : "transparent")
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
                                                text: common.interfaceIcon(modelData)
                                                font.pixelSize: 14
                                                color: ifaceRow.isActive ? ifaceRow.activeColor : theme.iconGray
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
                                                              : (ifaceRow.hovered ? theme.textSecondary : theme.textTertiary)

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
                                                color: ifaceRow.isActive ? ifaceRow.activeColor : theme.textPrimary
                                                elide: Text.ElideRight
                                            }

                                            // 接口类型描述：右对齐显示，与接口名分居两侧
                                            Text {
                                                Layout.alignment: Qt.AlignVCenter
                                                text: common.interfaceDescription(modelData)
                                                font.pixelSize: 12
                                                color: theme.textTertiary
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 无接口提示：在卡片内居中
                        Text {
                            anchors.centerIn: parent
                            text: qsTr("No network interface detected")
                            font.pixelSize: 12
                            color: theme.textTertiary
                            visible: networkInterfaces.length === 0
                        }
                    }

                    // 字体颜色选择区：预设色板 + 跟随系统选项
                    // 设计原因：用户选择的颜色通过 applet.textColor 持久化到
                    // ~/.config/jnetapplet/settings.ini，重启 dde-shell 后仍生效
                    Text {
                        text: qsTr("Font Color")
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: theme.textSecondary
                    }

                    TextColorPicker {
                        Layout.fillWidth: true
                        currentColor: applet ? applet.textColor : ""
                        // 深色模式标记向下传递：TextColorPicker 内部色板卡片同样主题感知
                        isDarkMode: root.isDarkMode
                        onColorSelected: if (applet) applet.textColor = color
                    }

                    // 刷新间隔选择区：1 秒 / 2 秒 / 5 秒
                    // 设计原因：用户可能觉得每秒刷新开销大或过于频繁，提供更长的间隔选项；
                    // 选择结果通过 applet.refreshInterval 持久化并即时生效，
                    // 速度计算基于真实流逝时间（elapsedSec），改变间隔不影响计算正确性
                    Text {
                        text: qsTr("Refresh Interval")
                        font.pixelSize: 13
                        font.weight: Font.Bold
                        color: theme.textSecondary
                    }

                    // 三个间隔选项按钮：1 秒 / 2 秒 / 5 秒
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Repeater {
                            model: [1000, 2000, 5000]

                            Rectangle {
                                id: intervalOption
                                Layout.fillWidth: true
                                Layout.preferredHeight: 34
                                radius: 8
                                // 选中态蓝色填充边框，未选中态卡片背景，hover 态加深
                                color: applet && applet.refreshInterval === modelData
                                       ? root.selBg : (intervalMouse.containsMouse ? theme.hoverBg : theme.cardBg)
                                border.width: 1
                                border.color: applet && applet.refreshInterval === modelData
                                              ? root.selBorder : theme.lineColor

                                Text {
                                    anchors.centerIn: parent
                                    text: (modelData / 1000) + "s"
                                    font.pixelSize: 13
                                    color: applet && applet.refreshInterval === modelData
                                           ? root.selText : theme.textPrimary
                                }

                                MouseArea {
                                    id: intervalMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: if (applet) applet.refreshInterval = modelData
                                }
                            }
                        }
                    }

                    Item { Layout.preferredHeight: 4 }

                    // 卸载插件按钮：文字固定为动作名，状态提示由下方独立提示行承担
                    Rectangle {
                        id: uninstallButton
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        color: uninstallMouse.containsMouse ? Qt.rgba(220/255, 38/255, 38/255, 0.15) : Qt.rgba(220/255, 38/255, 38/255, 0.08)
                        radius: 10
                        border.width: 1
                        border.color: accentColor

                        Text {
                            // 只声明垂直居中：水平方向由 left/right + margins 决定宽度，
                            // 与 centerIn 同时声明属于冲突锚点（运行时会告警且以最后赋值者为准）
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: 8
                            text: qsTr("Uninstall Plugin")
                            font.pixelSize: 13
                            font.weight: Font.Medium
                            color: accentColor
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                        }

                        MouseArea {
                            id: uninstallMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: uninstallConfirmDialog.open()
                        }
                    }

                    // 复制成功提示行：独立于按钮，长文案可换行且不受按钮高度限制
                    // 5 秒后由 statusHideTimer 清除（uninstallCopied 置回 false）
                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: -4
                        visible: root.uninstallCopied
                        text: qsTr("Uninstall command copied to clipboard. Please paste and run it in terminal.")
                        font.pixelSize: 11
                        color: Qt.rgba(22/255, 163/255, 74/255, 1)
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
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
            color: theme.winBg
            radius: 12
            border.width: 1
            border.color: theme.lineColor
        }

        contentItem: ColumnLayout {
            spacing: 16
            anchors.fill: parent
            anchors.margins: 20

            Text {
                text: qsTr("Warning")
                font.pixelSize: 16
                font.weight: Font.Bold
                color: accentColor
                Layout.alignment: Qt.AlignHCenter
            }

            Text {
                text: qsTr("The following command uninstalls the plugin and restarts dde-shell. Please copy and run it in terminal:")
                font.pixelSize: 12
                color: theme.textPrimary
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
                    text: root.uninstallCommand
                    font.pixelSize: 10
                    font.family: "monospace"
                    color: theme.textSecondary
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
                    color: cancelUninstallMouse.containsMouse ? theme.hoverBg : theme.cardBg
                    radius: 8
                    border.width: 1
                    border.color: theme.lineColor

                    Text {
                        anchors.centerIn: parent
                        text: qsTr("Cancel")
                        font.pixelSize: 13
                        color: theme.textPrimary
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
                        text: qsTr("Copy Command")
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
                            // 显示按钮下方的独立提示行，5 秒后由 statusHideTimer 清除
                            root.uninstallCopied = true
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
        text: root.uninstallCommand
    }

    // 复制成功提示的隐藏定时器：5 秒后收起按钮下方的提示行
    Timer {
        id: statusHideTimer
        interval: 5000
        onTriggered: root.uninstallCopied = false
    }
}
