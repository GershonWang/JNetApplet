// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 独立窗口公共自定义标题栏
// 消除 AboutWindow / SettingsWindow / TrafficChartWindow 三个独立顶层窗口之间的
// 标题栏样板重复（此前各窗口各持一份"拖动层 + 标题文字 + 圆形关闭按钮"的拷贝）。
// 现提取为本组件，各窗口在圆角卡片顶部的 ColumnLayout 中实例化 TitleBar 即可。
// 对外能力：
// - titleText：标题栏文字
// - textColor / secondaryTextColor：标题文字色与关闭按钮默认文字色（取主题色）
// - closeHoverColor：关闭按钮 hover 态文字高亮色（accentColor，默认红色）
// - 拖动：整栏按住调用 Window.window.startSystemMove() 系统级拖动（frameless
//   Window 的正确做法，drag.target 对 Window 无效）；拖动层声明在按钮下方，
//   不遮挡关闭/额外按钮的点击与 hover
// - 关闭按钮：28x28 圆形，hover 时淡红底 + 红色 ×，点击 Window.window.hide()
// - extraActions：default property，供子窗口在关闭按钮左侧填充额外按钮
//   （如 TrafficChartWindow 的"置顶"按钮），其逻辑仍保留在子窗口内
import QtQuick 2.15
import QtQuick.Window 2.15
import "."

Item {
    id: titleBar

    // 公共强调色：仅用于关闭按钮的默认高亮色，避免与各窗口的 accentRed 各写一份
    NetCommon { id: common }

    // 标题栏文字，由子窗口传入（qsTr 文案在子窗口侧）
    property string titleText: ""

    // 标题文字颜色：取主题色 textPrimary
    property color textColor: "#333333"

    // 关闭按钮默认文字色：取主题色 textSecondary
    property color secondaryTextColor: "#666666"

    // 关闭按钮 hover 态文字高亮色：取子窗口 accentColor（默认与 NetCommon.accentRed 同源）
    property color closeHoverColor: common.accentRed

    // 额外右侧按钮容器：default property 让子窗口直接把按钮写进标题栏，
    // 按钮将布局在关闭按钮左侧（用于置顶按钮等）
    default property alias extraActions: actionHost.data

    implicitHeight: 44

    // 拖动层：声明在关闭/额外按钮之前（位于其下方），避免遮挡按钮点击与 hover
    // 用 startSystemMove() 系统级窗口拖动，由窗口管理器接管移动，
    // 这是 frameless Window 的正确做法，pressed 即触发，丝滑无抖动
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.OpenHandCursor
        onPressed: Window.window.startSystemMove()
    }

    // 标题文字
    Text {
        anchors.left: parent.left
        anchors.leftMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        text: titleBar.titleText
        font.pixelSize: 15
        font.weight: Font.Bold
        color: titleBar.textColor
    }

    // 额外右侧按钮容器：右缘贴关闭按钮左侧，高度与标题栏一致
    Item {
        id: actionHost
        anchors.right: closeButton.left
        anchors.rightMargin: 4
        anchors.top: parent.top
        anchors.bottom: parent.bottom
    }

    // 关闭按钮：28x28 圆形，hover 时淡红底 + 红色 ×（颜色由 closeHoverColor 决定）
    Rectangle {
        id: closeButton
        // 无障碍：图标按钮的文字是 "×"，对屏幕阅读器无意义，显式给出名称与角色
        Accessible.role: Accessible.Button
        Accessible.name: qsTr("Close")
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        width: 28
        height: 28
        radius: 14
        // hover 底色由 closeHoverColor 派生（同色 15% 透明），不再写死红色：
        // 子窗口若换用非红色高亮，底与字仍然一致
        // 三态：按下 > hover > 常态，底色透明度逐级加深
        color: closeMouse.pressed
               ? Qt.rgba(titleBar.closeHoverColor.r, titleBar.closeHoverColor.g, titleBar.closeHoverColor.b, 0.25)
               : (closeMouse.containsMouse
                  ? Qt.rgba(titleBar.closeHoverColor.r, titleBar.closeHoverColor.g, titleBar.closeHoverColor.b, 0.15)
                  : "transparent")

        Text {
            anchors.centerIn: parent
            text: "×"
            font.pixelSize: 20
            font.weight: Font.Bold
            color: closeMouse.containsMouse ? titleBar.closeHoverColor : titleBar.secondaryTextColor
        }

        MouseArea {
            id: closeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Window.window.hide()
        }
    }
}
