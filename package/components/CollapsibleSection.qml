// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 可折叠的分区容器：标题行（可点击展开/收起）+ 内容区。
//
// 为什么需要这个文件：
// 设置窗口分区增至 7 个（接口/字体颜色/刷新间隔/速度单位/任务栏显示/流量提醒/卸载），
// 实测内容合计约 900px，而窗口高度 640px——打开就有一半内容看不见，
// 用户必须先滚动才知道底部还有「流量提醒」「卸载插件」。
// 折叠低频分区可把首屏内容压到一屏以内。
//
// 设计取舍：
//  - 折叠头是完整可访问控件（读屏可朗读、Tab 可聚焦、Enter/Space 可切换），
//    与项目内其它按钮遵循同一无障碍契约；
//  - 折叠状态**不持久化**：若持久化，用户误折叠后下次启动看不到该分区，
//    会以为功能消失。默认展开与否由调用方按"是否常用"决定；
//  - 内容区用 visible 而非 height:0 隐藏：ColumnLayout 会自动跳过不可见子项，
//    无需补偿高度，也没有动画期的布局抖动；
//  - 指示三角用 Shape 绘制而非文本字符 ▸/▾，理由同 ArrowIcon：
//    避免字形依赖，且能随 expanded 自动重绘。
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Shapes 1.15
import "."

ColumnLayout {
    id: control

    // 分区标题
    property string title: ""
    // 读屏朗读名称：默认用 title，需要更具体描述时由调用方覆盖
    property string accessibleName: title
    // 是否展开
    property bool expanded: true
    // 标题字号：由调用方传入档位（common.fontSizeSubtitle），组件内不硬编码
    property int titleFontSize: 13
    property color titleColor: "#000000"
    property color indicatorColor: "#888888"

    // 默认属性别名：使用方写在 CollapsibleSection { ... } 内的子项自动进入内容区
    default property alias content: contentLayout.data

    spacing: 0

    // ---- 折叠头：整行可点击 ----
    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 28
        // 上方留白：分区之间需要有比"分区内元素"更强的分隔感。
        // 不用手写占位 Item，直接在此声明（同 SettingsWindow 的分区标题做法）
        Layout.topMargin: 8

        // 无障碍：折叠头是按钮语义，读屏可朗读并可激活
        Accessible.role: Accessible.Button
        Accessible.name: control.accessibleName
        Accessible.checked: control.expanded
        Accessible.onPressAction: control.expanded = !control.expanded
        activeFocusOnTab: true
        Keys.onReturnPressed: control.expanded = !control.expanded
        Keys.onEnterPressed: control.expanded = !control.expanded
        Keys.onSpacePressed: control.expanded = !control.expanded

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 2
            spacing: 6

            // 折叠指示三角：收起时朝右（▸），展开时朝下（▾）
            Shape {
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: 8
                Layout.preferredHeight: 8

                ShapePath {
                    strokeWidth: 0

                    // 朝右三角（收起态）。ShapePath 没有 opacity 属性，
                    // 故用 fillColor 的 alpha 控制显隐——设 strokeWidth: 0 时
                    // 只有填充可见，透明填充即等效隐藏
                    startX: 1
                    startY: 0
                    PathLine { x: 1; y: 8 }
                    PathLine { x: 7; y: 4 }
                    PathLine { x: 1; y: 0 }
                    fillColor: control.expanded ? "transparent" : control.indicatorColor
                }

                ShapePath {
                    strokeWidth: 0

                    // 朝下三角（展开态）
                    startX: 0
                    startY: 1
                    PathLine { x: 8; y: 1 }
                    PathLine { x: 4; y: 7 }
                    PathLine { x: 0; y: 1 }
                    fillColor: control.expanded ? control.indicatorColor : "transparent"
                }
            }

            Text {
                Layout.fillWidth: true
                text: control.title
                font.pixelSize: control.titleFontSize
                font.weight: Font.Bold
                color: control.titleColor
                elide: Text.ElideRight
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: control.expanded = !control.expanded
        }
    }

    // ---- 内容区 ----
    // 内容本身的间距由使用方子项自行控制（本容器的 spacing 已设为 12，
    // 与其在 SettingsWindow 中的原有节奏一致）
    ColumnLayout {
        id: contentLayout
        Layout.fillWidth: true
        spacing: 12
        visible: control.expanded
    }
}
