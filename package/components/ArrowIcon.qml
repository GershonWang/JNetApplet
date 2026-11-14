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
// 尺寸契约（重要，曾因此回归过一次）：
//   调用方传的 width/height 应等于**原字符的 font.pixelSize**，视觉尺寸由本组件负责换算。
//   字符的字形并不占满 em 框——符号类字形高约占字号 70%、宽约占 45%。
//   因此本组件的路径只占画框中间约 70%×46%，四周留白，使矢量图标与原字符同尺寸。
//   第一版把路径画满整个画框（高 92%、宽 67%），结果任务栏箭头比数字还高、
//   杆子显得粗重，是调用方无法靠调 width 修正的组件契约缺陷。
//
// 使用方式（width/height 直接填字号档位即可）：
//     ArrowIcon {
//         width: common.fontSizeBody
//         height: common.fontSizeBody
//         downward: true
//         color: popup.accentBlue
//     }
import QtQuick 2.15
import QtQuick.Shapes 1.15

Item {
    id: control

    // 是否向下：true = ↓（下载），false = ↑（上传）
    property bool downward: true
    // 填充色：跟随调用方的主题/配色，由调用方传入
    property color color: "#000000"

    // 逻辑画框固定 24×24，实际尺寸由调用方的 width/height 决定，
    // 二者之比即缩放系数（Shape 不自动缩放路径，见下方 Shape 处说明）
    implicitWidth: 24
    implicitHeight: 24
    readonly property real unitScale: width > 0 ? width / 24 : 1

    // 关键：QQuickShape **不缩放**路径坐标，它按绝对像素绘制，width/height 只影响
    // 该项占位（且路径会溢出）。因此必须显式施加缩放变换，
    // 让 24×24 逻辑画框缩放到调用方要求的实际尺寸。
    // 实测依据：同一路径在 width=9.6 与 width=24 下渲染结果完全相同（宽10 高17），
    // 证明此前把 fontSize 当尺寸传是无效的——这也是"箭头仍然太大"的真正原因。
    Shape {
        width: 24
        height: 24
        transform: Scale {
            xScale: control.unitScale
            yScale: control.unitScale
            origin.x: 0
            origin.y: 0
        }
        // 居中对齐：24 画框按 unitScale 缩放后的视觉尺寸由调用方尺寸承载
        x: (control.width  - 24 * control.unitScale) / 2
        y: (control.height - 24 * control.unitScale) / 2

        ShapePath {
            strokeWidth: 0
            fillColor: control.color

            // 以下坐标在 24×24 逻辑画框内，且**不占满画框**（见文件头"尺寸契约"）。
            // 实测占比：高 17/24 = 0.708、宽 11/24 = 0.458，
            // 与符号字形 0.70/0.45 的经验比例对齐。
            // 形状构成：三角头（占一半高度）+ 短竖杆（占另一半）。
            startX: 12
            startY: control.downward ? 20.5 : 3.5

            // 头部左/右翼：y=12 为头与杆的分界（画框垂直中心）
            PathLine { x: 6.5; y: 12 }
            // 杆左侧上行到另一端
            PathLine { x: 10.25; y: control.downward ? 3.5 : 20.5 }
            // 杆右端
            PathLine { x: 13.75; y: control.downward ? 3.5 : 20.5 }
            // 杆右侧回到分界
            PathLine { x: 13.75; y: 12 }
            // 头部右翼
            PathLine { x: 17.5; y: 12 }
            // 闭合回尖端
            PathLine { x: 12; y: control.downward ? 20.5 : 3.5 }
        }
    }
}
