// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 独立窗口公共主题色提供者
// 消除 AboutWindow / SettingsWindow / TrafficChartWindow 三个独立顶层窗口之间的
// 主题颜色样板重复（此前各窗口各持一份 isDarkMode ? 深 : 浅 的颜色定义，
// 改一处需同步多处）。现集中到本文件，各窗口实例化 WindowTheme { id: theme } 后
// 统一经 theme.xxx 访问，仅需向 theme.isDarkMode 传入深色模式标记。
// 设计原因：
// - 深/浅主题由 networkview.qml 依据 DTK.palette 检测任务栏深浅后通过 isDarkMode 传入，
//   浅色取值与原各窗口硬编码完全一致，保证独立预览时视觉不变。
// - 个别窗口存在差异值（如 SettingsWindow 的 winBg 浅色为 #F5F5F5、lineColor 为
//   #E0E0E0），因此每个颜色拆成 light/dark 一对可覆盖属性，派生色由它们计算，
//   差异窗口仅需覆盖对应浅/深值即可，无需整体重写。
import QtQuick 2.15

QtObject {
    id: theme

    // 输入：深色模式标记，由父窗口从 networkview.qml 传入
    property bool isDarkMode: false

    // ---- 浅色/深色取色对（默认值与 AboutWindow/TrafficChartWindow 一致，个别窗口可覆盖差异值）----
    property color lightWinBg: "#FFFFFF"
    property color darkWinBg: "#202020"
    property color lightCardBg: "#FFFFFF"
    property color darkCardBg: "#2A2A2A"
    property color lightLineColor: "#E8E8E8"
    property color darkLineColor: "#383838"
    property color lightTextPrimary: "#333333"
    property color darkTextPrimary: "#E0E0E0"
    property color lightTextSecondary: "#666666"
    property color darkTextSecondary: "#AAAAAA"
    property color lightTextTertiary: "#999999"
    property color darkTextTertiary: "#888888"
    property color lightIconGray: "#777777"
    property color darkIconGray: "#AAAAAA"
    property color lightHoverBg: "#F0F0F0"
    property color darkHoverBg: "#353535"

    // ---- 派生主题色：isDarkMode 为 false 时取值与原浅色硬编码完全一致 ----
    readonly property color winBg: isDarkMode ? darkWinBg : lightWinBg
    readonly property color cardBg: isDarkMode ? darkCardBg : lightCardBg
    readonly property color lineColor: isDarkMode ? darkLineColor : lightLineColor
    readonly property color textPrimary: isDarkMode ? darkTextPrimary : lightTextPrimary
    readonly property color textSecondary: isDarkMode ? darkTextSecondary : lightTextSecondary
    readonly property color textTertiary: isDarkMode ? darkTextTertiary : lightTextTertiary
    readonly property color iconGray: isDarkMode ? darkIconGray : lightIconGray
    readonly property color hoverBg: isDarkMode ? darkHoverBg : lightHoverBg
}
