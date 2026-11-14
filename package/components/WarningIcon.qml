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
// 绘制方式：空心三角（描边）+ 内部感叹号（实心），单色线条风格，
// 与 DTK 与系统其它警告图标的观感一致。之所以用描边而非实心三角：
// 实心色块在小尺寸下显得沉重，且需要知道背景色才能挖出感叹号。
import QtQuick 2.15
import QtQuick.Shapes 1.15

Item {
    id: control

    // 描边与感叹号颜色，由调用方传入（通常为 tertiaryText 等弱化文字色）
    property color color: "#000000"

    implicitWidth: 24
    implicitHeight: 24

    // 三角轮廓：24×24 逻辑坐标系内，顶点 (12,2)、底边 y=20、左右 (2,20)/(22,20)
    Shape {
        anchors.fill: parent

        ShapePath {
            strokeWidth: 2
            strokeColor: control.color
            fillColor: "transparent"
            // 圆角效果由 strokeJoin 提供：小尺寸下尖角会显得粗糙
            joinStyle: ShapePath.RoundJoin
            startX: 12
            startY: 2
            PathLine { x: 22; y: 20 }
            PathLine { x: 2;  y: 20 }
            PathLine { x: 12; y: 2 }
        }
    }

    // 感叹号：竖条 + 下方圆点。位置在三角重心附近（三角形重心 y ≈ 14），
    // 整体略偏下以避开三角尖端的窄区
    Shape {
        anchors.fill: parent

        // 竖条
        ShapePath {
            strokeWidth: 0
            fillColor: control.color
            startX: 11.2
            startY: 9
            PathLine { x: 12.8; y: 9 }
            PathLine { x: 12.8; y: 14.2 }
            PathLine { x: 11.2; y: 14.2 }
            PathLine { x: 11.2; y: 9 }
        }

        // 圆点：用极小的正方形近似（2×2 逻辑单位），避免引入 PathArc 的复杂度
        ShapePath {
            strokeWidth: 0
            fillColor: control.color
            startX: 11.2
            startY: 15.6
            PathLine { x: 12.8; y: 15.6 }
            PathLine { x: 12.8; y: 17.2 }
            PathLine { x: 11.2; y: 17.2 }
            PathLine { x: 11.2; y: 15.6 }
        }
    }
}
