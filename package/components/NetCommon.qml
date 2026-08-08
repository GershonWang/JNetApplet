// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 网络监控插件的公共颜色与格式化函数
// 消除 networkview.qml 与 NetworkPopup.qml、TrafficChartWindow.qml 之间的重复定义：
// 以下颜色与函数此前在各组件内各持一份拷贝，改一处需同步多处；
// 现集中到本文件，各组件实例化 NetCommon { id: common } 后统一经 common.xxx 访问
// 设计原因：
// - 颜色统一派生自 DTK 系统调色板（windowText），跟随系统深浅主题自动适配。
//   不采用 DockPalette.iconTextPalette：实测其不随系统深色主题变化，
//   深色模式下返回深色文字（黑底黑字）、浅色模式下返回浅色文字（白底白字），方向相反；
//   DTK.palette.windowText 则与面板/弹窗背景同步。主题切换时 DTK.paletteChanged
//   自动触发属性绑定重新求值（QtObject 内绑定 DTK.palette 与 Item 内行为一致，已实测验证）
// - 函数与颜色分离：downloadValueColor 依赖调用方的速度值，提取为函数由调用方传入，
//   消除对组件上下文的依赖；sortedInterfaces 依赖各组件自身的接口列表，仍留在各组件内
import QtQuick 2.15
import org.deepin.dtk 1.0

QtObject {
    // ---- 主题感知颜色（派生自 DTK 系统调色板）----
    // baseTextColor 为中间基准色，以下各级文字/卡片颜色均由它加透明度派生
    readonly property color baseTextColor: DTK.palette.windowText
    readonly property color primaryText: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.95)
    readonly property color secondaryText: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.80)
    readonly property color tertiaryText: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.65)
    readonly property color cardBackground: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.06)
    readonly property color cardBorder: Qt.rgba(baseTextColor.r, baseTextColor.g, baseTextColor.b, 0.10)

    // ---- 强调色：下载蓝、上传绿，是面板与任务栏的主视觉区分 ----
    readonly property color accentBlue: Qt.rgba(20 / 255, 80 / 255, 160 / 255, 1)
    readonly property color accentBlueLight: Qt.rgba(20 / 255, 80 / 255, 160 / 255, 0.12)
    readonly property color accentGreen: Qt.rgba(22 / 255, 163 / 255, 74 / 255, 1)
    readonly property color accentGreenLight: Qt.rgba(22 / 255, 163 / 255, 74 / 255, 0.12)

    // ---- 高速警示色：下载速度超过阈值时由蓝转橙再转红 ----
    readonly property color accentOrange: Qt.rgba(245 / 255, 158 / 255, 11 / 255, 1)
    readonly property color accentRed: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)

    // 下载值颜色：保留原有阈值逻辑（>10MB/s 红、>1MB/s 橙、否则蓝），仅作用于下载值
    // 原为各组件内的属性绑定（依赖组件自身的 downloadSpeed），提取为公共函数后
    // 由调用方传入速度值；在绑定表达式中调用时，绑定仍随速度变化自动重算，行为不变
    function downloadValueColor(downloadSpeed) {
        if (downloadSpeed > 10 * 1024 * 1024) return accentRed
        if (downloadSpeed > 1 * 1024 * 1024) return accentOrange
        return accentBlue
    }

    // 上传值颜色：固定绿色，不做高速警示
    readonly property color uploadValueColor: accentGreen

    // 判断是否为物理网卡（QML 侧排序用，与 C++ isPhysicalInterface 逻辑一致）
    function isPhysicalIf(name) {
        return name.startsWith("wlp") || name.startsWith("wlan")
            || name.startsWith("enp") || name.startsWith("eth")
    }

    // 格式化速度显示（带单位，用于弹出面板，信息更完整）
    // 最小单位为 KB，与 networkview.qml 的 formatSpeedShort 保持一致；所有级别保留 2 位小数
    function formatSpeed(bytesPerSec) {
        if (bytesPerSec < 1024 * 1024) {
            return (bytesPerSec / 1024).toFixed(2) + " KB/s"
        } else if (bytesPerSec < 1024 * 1024 * 1024) {
            return (bytesPerSec / (1024 * 1024)).toFixed(2) + " MB/s"
        } else {
            return (bytesPerSec / (1024 * 1024 * 1024)).toFixed(2) + " GB/s"
        }
    }

    // 格式化总量显示（用于弹出面板的累计统计）
    function formatTotal(bytes) {
        if (bytes < 1024) {
            return bytes.toFixed(0) + " B"
        } else if (bytes < 1024 * 1024) {
            return (bytes / 1024).toFixed(1) + " KB"
        } else if (bytes < 1024 * 1024 * 1024) {
            return (bytes / (1024 * 1024)).toFixed(1) + " MB"
        } else {
            return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB"
        }
    }

    // 根据接口名返回类型图标（Unicode 符号），用于网络接口列表和弹窗接口信息区
    // 设计原因：项目未引入图标库，用 Text 渲染 Unicode 符号（与 ↓↑ 一致）；
    // 所选符号均为 DejaVu/Noto 等常见字体覆盖的单色字形，避免彩色 emoji 破坏浅色主题观感
    function interfaceIcon(name) {
        if (name === "lo") return "↻"               // 本地回环：循环箭头
        if (name === "Meta") return "▢"             // 虚拟接口：空心方块
        if (/^enp|^eth/.test(name)) return "⇄"      // 有线网络：双向链路
        if (/^wlp|^wlan/.test(name)) return "∿"     // 无线网络：信号波形
        if (/^docker|^veth/.test(name)) return "▣"  // 容器网络：盒中盒
        if (/^br/.test(name)) return "⋈"            // 桥接：连接
        if (/^tun|^tap/.test(name)) return "⚿"      // VPN：钥匙
        if (/^virbr/.test(name)) return "⋈"         // 虚拟桥接：同桥接
        return "◉"                                  // 其他：通用网络节点
    }

    // 根据接口名返回类型描述，用于设置窗口网络接口列表和弹窗 tooltip
    // 设计原因：用户面对多个网口时难以仅凭 enp3s0/wlp3s0 等命名判断用途，
    // 加一行类型说明（有线/无线/VPN 等）降低认知负担
    function interfaceDescription(name) {
        if (name === "lo") return qsTr("Loopback")
        if (name === "Meta") return qsTr("Virtual Interface")
        if (/^enp|^eth/.test(name)) return qsTr("Wired Network")
        if (/^wlp|^wlan/.test(name)) return qsTr("Wireless Network")
        if (/^docker|^veth/.test(name)) return qsTr("Container Network")
        if (/^br/.test(name)) return qsTr("Bridge")
        if (/^tun|^tap/.test(name)) return qsTr("VPN")
        if (/^virbr/.test(name)) return qsTr("Virtual Bridge")
        return qsTr("Other")
    }

    // 拆分速度字符串为数值部分：formatSpeed 返回 "4.11 KB/s"，本函数返回 "4.11"
    // 设计原因：弹窗速度区需将数值（大号粗体）与单位（小号）拆分显示以增强层次感
    function formatSpeedValue(bytesPerSec) {
        var str = formatSpeed(bytesPerSec)
        var idx = str.indexOf(' ')
        return idx < 0 ? str : str.substring(0, idx)
    }

    // 拆分速度字符串为单位部分：formatSpeed 返回 "4.11 KB/s"，本函数返回 "KB/s"
    function formatSpeedUnit(bytesPerSec) {
        var str = formatSpeed(bytesPerSec)
        var idx = str.indexOf(' ')
        return idx < 0 ? "" : str.substring(idx + 1)
    }
}
