// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 警告图标：三角轮廓内带感叹号，用矢量绘制替代文本字符 "⚠"。
//
// 为什么需要这个文件：
// 空状态（未检测到网络接口）原先用 U+26A0 WARNING SIGN。该码位按 Unicode 标准
// 属于 Emoji 可选呈现字符——在装了彩色 emoji 字体的系统上会被渲染成彩色图形，
// 与本插件整体的单色风格冲突；缺字形时则显示方框（豆腐块）。
// 矢量绘制保证跨环境完全一致。
//
// 为什么不用 Canvas：Canvas 不随属性绑定重绘，需逐处维护 requestPaint 时机；
// 本图标颜色跟随主题变化，用 Shape 的普通属性即可自动重绘。
//
// 绘制方式：空心三角（描边）+ 内部感叹号（实心），单色线条风格。
// 之所以用描边而非实心三角：实心色块在小尺寸下显得沉重，
// 且要挖出感叹号必须知道背景色，描边方案不依赖背景色，更简单可靠。
//
// 尺寸契约（与 ArrowIcon 一致）：
//   调用方传的 width/height 即期望的**视觉尺寸**。路径不占满画框，
//   四周留白（约占画框 78%），使图标在原字符字号下观感相当。
//   描边宽度也按画框比例给（1.6/24），随尺寸等比缩放——
//   若写成固定值，小尺寸下会显得过粗。
import QtQuick 2.15
import QtQuick.Shapes 1.15

Item {
    id: control

    // 描边与感叹号颜色，由调用方传入（通常为 tertiaryText 等弱化文字色）
    property color color: "#000000"

    implicitWidth: 24
    implicitHeight: 24

    // ---- 三角轮廓 ----
    // 24×24 画框内缩留白：顶点 (12,3.5)、底边 y=20.5、左右 (4,20.5)/(20,20.5)
    // 视觉高 17/24 = 0.708、宽 16/24 = 0.667（三角本身比箭头宽，故横纵比例不同）
    Shape {
        anchors.fill: parent

        ShapePath {
            // 描边按画框比例给：1.6/24 ≈ 6.7%，随实际尺寸等比缩放
            strokeWidth: 1.6
            strokeColor: control.color
            fillColor: "transparent"
            joinStyle: ShapePath.MiterJoin
            startX: 12
            startY: 3.5
            PathLine { x: 20; y: 20.5 }
            PathLine { x: 4;  y: 20.5 }
            PathLine { x: 12; y: 3.5 }
        }
    }

    // ---- 内部感叹号：竖条 + 下方点 ----
    // 位置取三角重心附近（重心 y ≈ 14.8），整体略偏下以避开尖端窄区
    Shape {
        anchors.fill: parent

        // 竖条
        ShapePath {
            strokeWidth: 0
            fillColor: control.color
            startX: 11.3
            startY: 10
            PathLine { x: 12.7; y: 10 }
            PathLine { x: 12.7; y: 15 }
            PathLine { x: 11.3; y: 15 }
            PathLine { x: 11.3; y: 10 }
        }

        // 下方点：用小方块近似（1.4×1.4 逻辑单位），避免引入 PathArc 的复杂度
        ShapePath {
            strokeWidth: 0
            fillColor: control.color
            startX: 11.3
            startY: 16.3
            PathLine { x: 12.7; y: 16.3 }
            PathLine { x: 12.7; y: 17.7 }
            PathLine { x: 11.3; y: 17.7 }
            PathLine { x: 11.3; y: 16.3 }
        }
    }
}
