// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 带选中态的选项按钮：页签（按日/按月）、刷新间隔（1/2/5s）、
// 速度单位（智能/KB/s/Mbps）、任务栏显示（当前接口/全部接口）、
// 设置窗口的网卡列表共用此组件。
//
// 与 IconButton 分开的原因：两者视觉差异是结构性的，不是参数化的——
// 选项按钮有"选中/未选中"两套完整配色（底色 + 边框 + 文字色同步变化），
// 而图标按钮只有三态底色。硬塞进一个组件会让两组无关属性互相污染。
//
// 无障碍契约与 IconButton 一致（这是本需求的核心）：
//   role=RadioButton、name、checked、onPressAction、Tab 可聚焦、Enter/Space 可触发。
// 此前这 22 处只有 role/name，键盘完全不可用。
import QtQuick 2.15

Item {
    id: control

    // ---- 对外接口 ----
    // 按钮文字（已由调用方 qsTr 过）
    property string text: ""
    // 无障碍名称：默认取 text，但色块等无文字元素需单独指定
    property string accessibleName: control.text
    // 选中态
    property bool checked: false
    // 文字字号与字重
    property int fontSize: 12
    property bool boldWhenChecked: true

    // ---- 配色（全部由调用方传入，因为各窗口 accent 不同）----
    // 选中态：底色 + 边框 + 文字色（三者一起变，这是"选中"的视觉定义）
    property color selectedColor: "#1A3A5C"
    property color selectedBorderColor: "#2C5A8A"
    property color selectedTextColor: "#64B5F6"
    // 未选中态：常态底色/边框、hover 底色
    property color baseColor: "transparent"
    property color baseBorderColor: "transparent"
    property color hoverColor: "transparent"
    // 文字颜色（未选中时）：默认取系统主文字色由调用方传入
    property color textColor: "#000000"
    // 选中且 hover 时的文字色（未选中时 hover 也用它，与既有实现一致）
    property color hoverTextColor: selectedTextColor

    property int radius: 5
    // 边框宽度与颜色：多数选项恒为 1px，但色块的"选中态"是 0→2px 的变化，
    // 故暴露为可覆盖。默认值保持原来的 1px 细边
    property int borderWidth: 1
    // 强制边框色（非空时优先于选中/hover 推导）：色块用主题文字色做选中环
    property color borderColorOverride: "transparent"

    signal clicked()

    implicitWidth: 90
    implicitHeight: 24

    // ---- 无障碍：契约的唯一位置 ----
    Accessible.role: Accessible.RadioButton
    Accessible.name: control.accessibleName
    Accessible.checked: control.checked
    Accessible.onPressAction: control.clicked()

    // Tab 可聚焦 + Enter/Space 可触发（此前全项目为 0 处）
    activeFocusOnTab: true
    Keys.onReturnPressed: control.clicked()
    Keys.onEnterPressed: control.clicked()
    Keys.onSpacePressed: control.clicked()

    Rectangle {
        anchors.fill: parent
        radius: control.radius
        color: control.checked
               // 选中：按下比常态更深
               ? (mouseArea.pressed ? Qt.darker(control.selectedColor, 1.12) : control.selectedColor)
               : (mouseArea.pressed ? Qt.darker(control.hoverColor, 1.12)
                                    : (mouseArea.containsMouse || control.activeFocus
                                       ? control.hoverColor : control.baseColor))
        border.width: control.borderWidth
        // 焦点环：未选中时也要能看出焦点位置，故 activeFocus 时用强调色描边。
        // borderColorOverride 优先：色块的选中环用的是主题文字色而非强调色
        border.color: control.borderColorOverride !== "transparent"
                      ? control.borderColorOverride
                      : (control.checked
                         ? control.selectedBorderColor
                         : (control.activeFocus || mouseArea.containsMouse
                            ? control.selectedBorderColor : control.baseBorderColor))

        Text {
            anchors.centerIn: parent
            text: control.text
            font.pixelSize: control.fontSize
            font.weight: (control.boldWhenChecked && control.checked) ? Font.Bold : Font.Normal
            color: control.checked
                   ? control.selectedTextColor
                   : (mouseArea.containsMouse || control.activeFocus
                      ? control.hoverTextColor : control.textColor)
        }

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                control.forceActiveFocus()
                control.clicked()
            }
        }
    }
}
