// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 速度方向箭头图标：用矢量绘制替代原先的文本字符 "↓" / "↑"。
//
// 为什么需要这个文件：
// 全工程 12 处用 Unicode 箭头字符当作速度方向标记（任务栏 4、弹窗 6、趋势图 2）。
// 文本字符的问题：字形依赖系统字体，同一箭头在不同字体下粗细、字宽、基线都不同；
// 在等宽/符号字体缺失的环境里甚至显示为方框。矢量绘制能保证跨环境完全一致。
//
// 为什么用 Shape 而不是 Canvas：
// 项目已有 Canvas 先例（趋势图），但 Canvas 不随属性绑定重绘，那边为此写了 6 处
// requestPaint。箭头颜色要跟随主题与用户自定义配色变化，若用 Canvas 需逐处维护
// 重绘时机；Shape 的 fillColor 是普通属性，颜色变化自动重绘。
//
// ================= 尺寸实现（三次踩坑后的结论，勿改）=================
// QQuickShape 的路径坐标是**绝对像素**，不随 width/height 缩放。实测过三种做法：
//   1. 路径按 24 画框写死、靠 width/height 缩放 → 无效，渲染恒为 24px 画框那么大；
//   2. 加 transform: Scale → 无效，transform 只做视觉变换，不改布局尺寸，
//      在 RowLayout 里仍按 24px 占位并把整行撑开；
//   3. implicitWidth/Layout.preferredWidth 跟随 width → 仍被布局覆盖为 24。
// 唯一有效做法：**路径坐标直接按目标尺寸计算**（见下方 sx/sy 乘法）。
// 实测确认：路径按 8×8 设计时渲染出宽 3 高 5，与预期一致。
//
// 尺寸契约：调用方传的 width/height 即**视觉尺寸**，
// 视觉高度约占该值的 0.70、宽度约占 0.46，与原字符的字形比例一致。
import QtQuick 2.15
import QtQuick.Shapes 1.15
import QtQuick.Layouts 1.15

Item {
    id: control

    // 是否向下：true = ↓（下载），false = ↑（上传）
    property bool downward: true
    // 填充色：跟随调用方的主题/配色，由调用方传入
    property color color: "#000000"

    // 布局容器需要 preferred 尺寸才能正确分配空间（缺了会被按 24 撑开）
    implicitWidth: width
    implicitHeight: height
    Layout.preferredWidth: width
    Layout.preferredHeight: height

    // 以 24×24 为设计基准，换算成当前实际尺寸的系数。
    // 设计基准下的视觉占比：高 17/24 = 0.708、宽 11/24 = 0.458，
    // 与符号字形（高约 0.70、宽约 0.45）对齐，保证与原字符同尺寸。
    readonly property real sx: width / 24
    readonly property real sy: height / 24

    Shape {
        anchors.fill: parent

        ShapePath {
            strokeWidth: 0
            fillColor: control.color

            // 形状：三角头（占一半高度）+ 短竖杆（占另一半）
            startX: 12 * control.sx
            startY: (control.downward ? 20.5 : 3.5) * control.sy
            PathLine { x: 6.5 * control.sx;   y: 12 * control.sy }
            PathLine { x: 10.25 * control.sx; y: (control.downward ? 3.5 : 20.5) * control.sy }
            PathLine { x: 13.75 * control.sx; y: (control.downward ? 3.5 : 20.5) * control.sy }
            PathLine { x: 13.75 * control.sx; y: 12 * control.sy }
            PathLine { x: 17.5 * control.sx;  y: 12 * control.sy }
            PathLine { x: 12 * control.sx;    y: (control.downward ? 20.5 : 3.5) * control.sy }
        }
    }
}
