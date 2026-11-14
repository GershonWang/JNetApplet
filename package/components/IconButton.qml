// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 通用图标/符号按钮：把项目里 22 处「Rectangle + MouseArea + 手写三态颜色」
// 收敛成唯一实现。
//
// 为什么需要这个组件（真实缺陷）：
// 项目此前每个可点击元素都各自手写一遍 Rectangle + MouseArea + 三态颜色，
// 并且只在其中一部分声明了 Accessible.role/name——读屏能"读出来"，但
// activeFocusOnTab 与按键处理是 0 处，键盘用户完全无法操作。
// 更糟的是标注位置不一致：统计窗口的导出按钮在 Rectangle 与 MouseArea 上
// 各写了一次 Accessible.*（读屏会重复朗读）。
//
// 本组件把无障碍契约固定在**一个位置**（外层 Rectangle）：
//   role/name/onPressAction + activeFocusOnTab + Enter/Space + 焦点环。
// 鼠标、键盘、读屏三条路径统一转调 clicked()，行为不可能不一致。
//
// 视觉约定：除"获得焦点时的边框"外，与手写实现完全一致——
// 圆角、尺寸、hover/按下透明度都由调用方按原值传入，组件不内置主题色
// （各窗口的 accent 不同，写死会导致颜色走样）。
import QtQuick 2.15

Item {
    id: control

    // ---- 对外接口 ----
    // 按钮上显示的符号/文字（如 "×"、"⇋"、"↓"）
    property string symbol: ""
    // 符号字号：不传则按高度推算（保持与原手写实现相同的观感）
    property int symbolFontSize: Math.round(height * 0.7)
    // 符号是否加粗：关闭按钮的 × 原本是 Bold，其余多不是
    property bool symbolBold: false
    // 无障碍名称：**必填**，读屏靠它播报用途（不能直接复用语号，如 "×"）
    property string accessibleName: ""
    // 是否作为单选项（页签、色块等）而非普通按钮
    property bool isRadio: false
    // 单选项的选中态（仅 isRadio 时有意义）
    property bool checked: false

    // ---- 颜色（全部由调用方传入，组件不内置主题色）----
    // 常态底色：默认透明（多数按钮平时无底色）
    property color baseColor: "transparent"
    // hover 底色
    property color hoverColor: "transparent"
    // 按下底色：不传则把 hoverColor 加深，保持"按下比 hover 更重"的既有层次
    property color pressedColor: Qt.darker(hoverColor, 1.25)
    // 符号颜色（常态）与 hover/按下时的颜色
    property color symbolColor: "#000000"
    property color symbolHoverColor: symbolColor
    // 内容插槽里的子元素要跟随按钮状态变色时，读这两个只读属性即可，
    // 不必去猜组件内部结构（此前我在调用方写了 parent.parent.pressed 这种脆弱引用）
    readonly property bool hovered: mouseArea.containsMouse || activeFocus
    readonly property bool pressed: mouseArea.pressed
    // 当前应使用的文字色：激活态 > hover/焦点 > 常态
    readonly property color currentColor: activated
                                         ? activatedColor
                                         : (hovered ? symbolHoverColor : symbolColor)

    // 激活态（如"已复制"变绿）：优先于 hover/常态。
    // 设计原因：复制按钮在成功后显示绿色 ✓，这是四态里的最高优先级；
    // 若只在调用方拼 symbol 文本，颜色就无从切换，视觉反馈会丢失
    property bool activated: false
    property color activatedColor: symbolColor
    // 边框颜色：0 宽度时不画边框
    property int borderWidth: 0
    property color borderColor: "transparent"
    // 圆角：默认按高度取一半，即圆形/胶囊；方角按钮显式传 0
    property int radius: Math.round(height / 2)

    // 点击信号：鼠标、键盘 Enter/Space、读屏 onPressAction 三路都发这一个
    signal clicked()

    // 自定义绘制内容（Canvas 等）的插槽。
    // 设计原因：置顶按钮的图钉是用 Canvas 画的矢量图形，不是文字符号；
    // 若强行塞进 symbol 会丢掉"置顶态实心填充"这一视觉差异。
    // 声明为 default property 后，调用方可直接把 Canvas 写成子元素
    default property alias content: contentHost.data

    // 尺寸由调用方决定（Layout 或显式 width/height）
    implicitWidth: 28
    implicitHeight: 28

    // ---- 无障碍：契约的唯一位置 ----
    // 注意：role/name 必须挂在这里（外层），不要同时再挂到内部 MouseArea 上，
    // 否则读屏会重复朗读——这是此前统计窗口导出按钮的真实问题
    Accessible.role: control.isRadio ? Accessible.RadioButton : Accessible.Button
    Accessible.name: control.accessibleName
    Accessible.checked: control.isRadio ? control.checked : false
    // 读屏软件的"激活"手势（如 Orca 的双击激活）
    Accessible.onPressAction: control.clicked()

    // Tab 可聚焦：这是键盘可达的前提，此前全项目为 0 处
    activeFocusOnTab: true
    // Enter 与 Space 都能触发：桌面应用两种习惯都有，一并支持
    Keys.onReturnPressed: control.clicked()
    Keys.onEnterPressed: control.clicked()
    Keys.onSpacePressed: control.clicked()

    Rectangle {
        id: background
        anchors.fill: parent
        radius: control.radius
        border.width: control.borderWidth
        // 焦点可见性：键盘用户在多个按钮间 Tab 时，必须能看出焦点落在哪。
        // 设计原因：只在获得焦点时画环，鼠标用户完全看不到，故不影响既有观感。
        // 用主题强调色的半透明描边而非系统焦点框，避免与圆角边框错位
        border.color: control.activeFocus ? control.symbolHoverColor : control.borderColor
        color: mouseArea.pressed
               ? control.pressedColor
               : (mouseArea.containsMouse || control.activeFocus
                  ? control.hoverColor
                  : control.baseColor)

        Text {
            anchors.centerIn: parent
            text: control.symbol
            font.pixelSize: control.symbolFontSize
            font.weight: control.symbolBold ? Font.Bold : Font.Normal
            color: control.activated
                   ? control.activatedColor
                   : ((mouseArea.containsMouse || control.activeFocus)
                      ? control.symbolHoverColor : control.symbolColor)
            // 选中态（RadioButton）需要比常态更醒目，由调用方通过颜色区分；
            // 这里不再叠加重置，避免与调用方的配色冲突
        }

        // 自定义内容宿主：与 symbol 互斥使用（调用方二选一）
        Item {
            id: contentHost
            anchors.fill: parent
        }

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                // 点击时把焦点移过来：否则 Tab 顺序与鼠标操作脱节
                control.forceActiveFocus()
                control.clicked()
            }
        }
    }
}
