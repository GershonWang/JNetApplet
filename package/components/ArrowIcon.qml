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
// 使用方式：
//     ArrowIcon { width: 10; height: 10; downward: true; color: popup.accentBlue }
import QtQuick 2.15
import QtQuick.Shapes 1.15

Item {
    id: control

    // 是否向下：true = ↓（下载），false = ↑（上传）
    property bool downward: true
    // 填充色：跟随调用方的主题/配色，由调用方传入
    property color color: "#000000"

    // 固定 12:12 的正方形绘制区，窄长比例由 width/height 决定；
    // Shape 会把路径坐标等比缩放到本项尺寸，故只写逻辑坐标即可
    implicitWidth: 24
    implicitHeight: 24

    Shape {
        anchors.fill: parent
        // 作为纯色填充图形，不需要抗锯齿之外的任何特效；
        // 关闭 clip 以避免极窄尺寸下的边缘裁切
        layer.enabled: false

        ShapePath {
            strokeWidth: 0
            fillColor: control.color
            // 起点与后续点由箭头方向决定，坐标在 24×24 逻辑坐标系内。
            // 形状构成：三角头 + 短竖杆。头部占 11/24 高度、杆占 11/24，
            // 宽度上头部 8~20（12 宽）、杆 9~15（6 宽）。
            // 这类比例是视觉调参结果：头部过大会显得笨重，过小则在高 DPI 下辨认不清
            startX: control.downward ? 12 : 12
            startY: control.downward ? 24 : 0

            PathLine { x: 4;  y: control.downward ? 13 : 11 }
            PathLine { x: 9;  y: control.downward ? 13 : 11 }
            PathLine { x: 9;  y: control.downward ? 2 : 22 }
            PathLine { x: 15; y: control.downward ? 2 : 22 }
            PathLine { x: 15; y: control.downward ? 13 : 11 }
            PathLine { x: 20; y: control.downward ? 13 : 11 }
            PathLine { x: 12; y: control.downward ? 24 : 0 }
        }
    }
}
