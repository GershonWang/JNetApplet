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
//   消除对组件上下文的依赖；接口列表由调用方传入，排序规则（sortInterfaces）
//   与物理网卡判定（isPhysicalIf）集中在此，各组件不再各自实现
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

    // 高亮蓝：比 accentBlue 更亮，用于可点击链接（关于窗口的仓库地址）、
    // 图表窗口的"置顶"激活色，以及趋势图折线的下载色。
    // 设计原因：这几处此前各自写死 #0081FF，取值恰好相同却没有共同来源，
    // 任一处调整就会产生色差，故在此收敛为唯一定义
    readonly property color accentBlueBright: Qt.rgba(0 / 255, 129 / 255, 255 / 255, 1)

    // 上面两个强调色的字符串形式，供 Canvas 2D 使用（趋势图折线/圆点）
    // 设计原因：Canvas 2D 上下文只接受 CSS 颜色字符串，QML 的 color 类型序列化结果
    // （尤其含 alpha 时的 #AARRGGBB）它无法解析，故在颜色定义处同时给出字符串形式，
    // 保证"下载=蓝、上传=绿"的语义仍只在本文件维护。改动上面的 color 时须同步此处
    readonly property string accentBlueBrightHex: "#0081FF"
    readonly property string accentGreenHex: "#16A34A"

    // ---- 高速警示色：下载速度超过阈值时由蓝转橙再转红 ----
    readonly property color accentOrange: Qt.rgba(245 / 255, 158 / 255, 11 / 255, 1)
    readonly property color accentRed: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)
    // 危险操作（卸载插件）按钮的底色：常态淡红、悬停略深，与 accentRed 同源
    // 设计原因：同一组透明度此前散落在设置窗口内以字面量书写，改主色时需逐处对齐
    readonly property color accentRedLight: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 0.08)
    readonly property color accentRedHover: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 0.15)

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

    // 判断接口名是否命中无线命名约定
    // 设计原因：deepin 25 上无线接口名为 wlo1，早期只匹配 wlp/wlan 导致漏判，故补齐 wlo/wlx。
    // 本函数是**排序**的唯一无线判据（排序不查后端，原因见 sortInterfaces）；
    // 图标与类型文案则以调用方传入的无线接口名列表为准，命中本函数仅作兜底
    function isWirelessName(name) {
        return name.startsWith("wlp") || name.startsWith("wlan")
            || name.startsWith("wlo") || name.startsWith("wlx")
    }

    // 判断是否为物理网卡（QML 侧排序用，与 C++ isPhysicalInterface 逻辑一致）
    // 无线判定走 isWirelessName（命名集合已含 wlo/wlx），有线匹配 enp/eth；
    // 排序不查询后端：该函数被 Repeater.model 绑定，绑定中触达后端数据易导致求值异常
    function isPhysicalIf(name) {
        return isWirelessName(name)
            || name.startsWith("enp") || name.startsWith("eth")
    }

    // 接口列表排序：物理网卡在前、虚拟接口在后，各自按名称升序
    // 设计原因：弹窗接口 chip 与设置窗口列表必须顺序一致（否则同一台机器出现两套排序）。
    // 原实现由 NetworkPopup 与 networkview 各持一份，networkview 那份还无人引用，
    // 设置窗口则直接用未排序列表；统一收敛到此处后三处共用同一规则。
    //
    // 刻意只依赖接口名、不接收后端判定结果：该函数被 Repeater.model 直接绑定求值，
    // 参数一旦取自后端数据（曾试过后端判定回调），绑定在求值时触达后端会使列表整体消失。
    // 无线命名集合已补齐 wlo/wlx，排序归类与后端 isPhysicalInterface 结果一致
    function sortInterfaces(list) {
        if (!list || list.length === 0) return []
        var physical = []
        var virtual = []
        for (var i = 0; i < list.length; i++) {
            if (isPhysicalIf(list[i])) physical.push(list[i])
            else virtual.push(list[i])
        }
        physical.sort()
        virtual.sort()
        return physical.concat(virtual)
    }

    // 后端对象：由使用方注入（如 `common.applet: root.applet`）。
    // 设计原因：格式化需要后端换算，但本组件被多处实例化（弹窗/趋势图/设置窗口）；
    // 用属性注入而非全局单例，保证各窗口共享同一个后端实例，且组件可独立预览时置空。
    // 单位也由后端 speedUnit 决定，调用方无需再传——避免各处传参不一致
    property var applet: null

    // 当前速度显示单位，直接转发后端；无后端对象时按智能自动（0）处理
    readonly property int speedUnit: applet ? (applet.speedUnit || 0) : 0
    // 语义化判据转发：调用方用 common.speedUnitIsMbps 而不是 `speedUnit === 2`，
    // 避免单位取值调整后散落的数字比较静默失配
    readonly property bool speedUnitIsMbps: applet ? (applet.speedUnitIsMbps === true) : false
    readonly property bool speedUnitIsKBps: applet ? (applet.speedUnitIsKBps === true) : false

    // 格式化速度显示（带单位，用于弹出面板与趋势图）
    // 设计原因：换算规则不再在本文件实现，而是转调后端 formatSpeed()——
    // 单位有三档（智能自动 / 固定 KB/s / 固定 Mbps），若 QML 再维护一份阈值表，
    // 与后端必然漂移；放在 C++ 还能被单元测试覆盖（见 tests/）。
    // 独立预览（applet 为空）时退回智能自动的本地实现，保证组件可单独渲染
    function formatSpeed(bytesPerSec) {
        if (applet) return applet.formatSpeed(bytesPerSec, speedUnit)
        if (bytesPerSec < 1024 * 1024) {
            return (bytesPerSec / 1024).toFixed(2) + " KB/s"
        } else if (bytesPerSec < 1024 * 1024 * 1024) {
            return (bytesPerSec / (1024 * 1024)).toFixed(2) + " MB/s"
        }
        return (bytesPerSec / (1024 * 1024 * 1024)).toFixed(2) + " GB/s"
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

    // 对外展示用的接口名称：有 WiFi 名称就用它，否则回退接口名。
    // 设计原因：wlo1/eno1 这类名字由内核按 PCI 位置生成，用户无法据此判断
    // "连的是哪个 WiFi"；此前任务栏提示与弹窗各自拼接口名，新增 SSID 后
    // 若各写一套"有则替换"的判断，必然出现一处显示 SSID、一处仍显示 wlo1 的错位。
    // 参数 ssid 允许为空（非无线接口、无线未连接、或后端尚未取到）
    function displayName(iface, ssid) {
        if (ssid && ssid.length > 0) return ssid
        return iface || ""
    }

    // 根据接口名返回类型图标（Unicode 符号），用于网络接口列表和弹窗接口信息区
    // 设计原因：项目未引入图标库，用 Text 渲染 Unicode 符号（与 ↓↑ 一致）。
    //
    // 符号选型约束（真机实测教训）：当前字体未指定 font.family，Qt 依靠系统字体回退渲染，
    // 而回退链并不覆盖冷僻区块的字形——原选用的 ∿(U+223F，仅 13 个字体覆盖)、
    // ⚿(U+26BF，3 个)、⋈(U+22C8，19 个)、↻(U+21BB，27 个) 在真机上全部渲染为空白，
    // 接口类型图标整列消失。故改用系统字体覆盖率高的等义符号（括号内覆盖数取自
    // `fc-list ':charset=<码点>'` 统计），最低覆盖由 3 提升到 129，
    // 且全部为单色字形，不含彩色 emoji，不破坏浅色主题观感。
    // 新增符号前务必先用同样的命令确认覆盖率足够
    // 参数 wireless：该接口是否无线（调用方查后端 wirelessInterfaces 列表得出），语义同 isPhysicalIf
    function interfaceIcon(name, wireless) {
        if (name === "lo") return "⇋"               // 本地回环：双向（U+21C4 类，覆盖 131）
        if (name === "Meta") return "▢"             // 虚拟接口：空心方块（覆盖 129）
        if (wireless === true || (wireless === undefined && isWirelessName(name))) return "≈" // 无线网络：波形（覆盖 359）
        if (/^enp|^eth/.test(name)) return "⇄"      // 有线网络：双向链路（覆盖 231）
        if (/^docker|^veth/.test(name)) return "▣"  // 容器网络：盒中盒（覆盖 134）
        if (/^br/.test(name)) return "⊕"            // 桥接：交汇（覆盖 264）
        if (/^tun|^tap/.test(name)) return "⇅"      // VPN：上下行隧道（覆盖 132）
        if (/^virbr/.test(name)) return "⊕"         // 虚拟桥接：同桥接
        return "◉"                                  // 其他：通用网络节点（覆盖 133）
    }

    // 根据接口名返回类型描述，用于设置窗口网络接口列表和弹窗 tooltip
    // 设计原因：用户面对多个网口时难以仅凭 enp3s0/wlp3s0 等命名判断用途，
    // 加一行类型说明（有线/无线/VPN 等）降低认知负担。
    // 参数 wireless：该接口是否无线（调用方查后端 wirelessInterfaces 列表得出），语义同 isPhysicalIf
    function interfaceDescription(name, wireless) {
        if (name === "lo") return qsTr("Loopback")
        if (name === "Meta") return qsTr("Virtual Interface")
        if (wireless === true || (wireless === undefined && isWirelessName(name))) return qsTr("Wireless Network")
        if (/^enp|^eth/.test(name)) return qsTr("Wired Network")
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

    // 格式化链路协商速率（Mbps 输入）：>=1000 显示 Gbps（保留 1 位小数），否则显示 Mbps
    // 设计原因：有线常见 1000/2500 Mbps，无线常见 866 Mbps，按阈值切换单位更易读
    function formatLinkSpeed(mbps) {
        if (mbps >= 1000) {
            return (mbps / 1000).toFixed(1) + " Gbps"
        }
        return mbps.toFixed(0) + " Mbps"
    }
}
