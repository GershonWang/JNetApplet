// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import Qt.labs.platform as Platform
import org.deepin.ds 1.0
import org.deepin.ds.dock 1.0
import org.deepin.dtk 1.0
import "components"

AppletItem {
    id: root
    objectName: "network monitor applet"

    // 无障碍：整个任务栏图标是一个"左键打开网络监控详情弹窗"的按钮。
    // 这一处用 TapHandler 而非 MouseArea，无法直接复用 IconButton 组件，
    // 但键盘契约仍须与其它按钮一致：Tab 可聚焦 + Enter/Space 打开弹窗 +
    // 读屏的 onPressAction 可激活。此前只有 role/name，键盘用户完全无法操作任务栏图标。
    // 注意：任务栏图标通常不在窗口焦点链上，activeFocusOnTab 主要覆盖
    // "任务栏获得焦点"的场景（如无障碍键盘导航模式），不影响鼠标使用
    Accessible.role: Accessible.Button
    Accessible.name: qsTr("Network Speed Monitor")
    Accessible.onPressAction: root.togglePopupFromKeyboard()
    activeFocusOnTab: true
    Keys.onReturnPressed: root.togglePopupFromKeyboard()
    Keys.onEnterPressed: root.togglePopupFromKeyboard()
    Keys.onSpacePressed: root.togglePopupFromKeyboard()
    property int dockOrder: 21
    property int dockSize: Panel.rootObject.dockItemMaxSize || 48
    // 任务栏方向：0=Top, 1=Right, 2=Bottom, 3=Left；% 2 为 0 表示水平，1 表示竖向
    // 设计原因：dde-shell 规范用法，org.deepin.ds.dock 已在 line 11 导入
    property bool isVerticalDock: Panel.position % 2 === 1

    // 水平任务栏宽度需要容纳"↓ 194.07K"这类双行数值；竖向任务栏宽度匹配 dock 尺寸
    // 2.4 倍高度：dockSize=40 时约 96px，可容纳竖排的速度字符串
    //
    // 宽度按当前**单位模式**下最长数值实测，而不是沿用固定的 dockSize*1.35。
    // 设计原因：固定 Mbps 模式会出现 "100.00Mbps"（10 字符），原 1.35 倍（48→65px）
    // 会把它裁掉；而智能自动模式最长只有 "1023.99K"，若一律按 Mbps 宽度加宽，
    // 默认模式下图标会无谓变宽。故用 TextMetrics 按实际字号/字重测量"最长候选字符串"，
    // 与下方整数位宽（intPartMetrics）同一套实测思路，不依赖字符数估算
    // 任务栏内所有字号都按 dockSize 比例推导（0.20/0.25/0.30），而非固定像素：
    // 任务栏尺寸本身随系统缩放变化，故这一层天然跟随 DPI。
    // 本文件**不接入** NetCommon 的字号阶梯——那套阶梯是给独立窗口正文用的
    // （基准 12px + 系统字号比例），与"按任务栏宽度等比缩放"是两种不同口径，
    // 混用会让速度数字在任务栏里忽大忽小。
    TextMetrics {
        id: maxSpeedMetrics
        font.pixelSize: root.dockSize * 0.25
        font.weight: Font.Medium
        // Mbps 档最长 10 字符（100.00Mbps）；自动/KB 档最长 8 字符（1023.99K）
        text: root.applet && root.applet.speedUnitIsMbps ? "100.00Mbps" : "1023.99K"
    }
    // 行内还有 "↓" 箭头（约字号的 0.2 倍）与 4px 间距、左右各 4px 边距
    // 乘 1.15 作为余量，覆盖箭头与间距；下限保持原宽度，避免默认档变窄
    readonly property real speedRowWidth: maxSpeedMetrics.advanceWidth * 1.15
                                           + root.dockSize * 0.20 + 12

    implicitWidth: isVerticalDock
                   ? dockSize
                   : Math.max(Math.round(dockSize * 1.35), Math.round(speedRowWidth))
    implicitHeight: isVerticalDock ? Math.round(dockSize * 2.4) : dockSize

    readonly property var applet: Applet
    readonly property bool ready: applet ? applet.ready : false
    // 单接口瞬时速度（活动接口），始终取自后端，供弹窗与趋势图使用
    readonly property real activeDownloadSpeed: applet ? applet.downloadSpeed : 0
    readonly property real activeUploadSpeed: applet ? applet.uploadSpeed : 0
    // 任务栏显示用的速度：按"合计"开关在单接口与全物理接口合计之间二选一。
    // 设计原因：多网卡场景（有线+无线同时工作）只看单卡会低估实际吞吐；
    // 但单卡视图对多数用户更直观，故由用户显式切换，默认保持单接口
    readonly property bool showAggregate: applet ? (applet.aggregateSpeed === true) : false
    readonly property real downloadSpeed: showAggregate
                                          ? (applet ? applet.totalDownloadSpeed : 0)
                                          : activeDownloadSpeed
    readonly property real uploadSpeed: showAggregate
                                        ? (applet ? applet.totalUploadSpeed : 0)
                                        : activeUploadSpeed
    readonly property real totalDownload: applet ? applet.totalDownload : 0
    readonly property real totalUpload: applet ? applet.totalUpload : 0
    readonly property string activeInterface: applet ? (applet.activeInterface || "") : ""
    // 活动接口连接到的 WiFi 名称（后端 Q_PROPERTY），非无线或未连接时为空串
    readonly property string activeSsid: applet ? (applet.activeSsid || "") : ""
    // 对外展示用的接口名称：无线且已连接时用 WiFi 名称，否则回退接口名。
    // 设计原因：wlo1/eno1 由内核按 PCI 位置生成，用户无法据此判断"连的是哪个 WiFi"；
    // 回退逻辑收敛到 NetCommon.displayName()，与弹窗共用同一规则
    readonly property string displayName: common.displayName(activeInterface, activeSsid)
    // 活动接口的 IPv4 地址，由 C++ 后端 detectIpAddress 持续更新
    readonly property string ipAddress: applet ? (applet.ipAddress || "") : ""
    // 活动接口的 IPv6 全球地址，由 C++ 后端 detectIpAddress 持续更新
    readonly property string ipv6Address: applet ? (applet.ipv6Address || "") : ""
    readonly property var networkInterfaces: applet ? (applet.networkInterfaces || []) : []
    // 无线接口名列表（后端 Q_PROPERTY），供设置窗口判定接口类型图标与文案
    readonly property var wirelessInterfaces: applet ? (applet.wirelessInterfaces || []) : []
    // 活动接口链路层是否断开（后端读 carrier/operstate 判定），供任务栏与提示展示断连态
    readonly property bool linkDown: applet ? (applet.linkDown === true) : false
    // 是否呈现断连态：必须在有接口的前提下才成立
    // 设计原因：无接口时后端会把 linkDown 置回 false，但即便出现时序间隙，
    // 也不该让"未检测到接口"的占位态与"接口断了"混为一谈
    readonly property bool linkDownNow: ready && linkDown

    // 公共颜色与格式化函数：集中定义于 components/NetCommon.qml（随 import "components" 引入），
    // 与 NetworkPopup、TrafficChartWindow 共享同一份实现，消除跨组件重复定义
    NetCommon {
        id: common
        // 注入后端对象：单位换算由后端统一完成，QML 不再各自维护 KB/MB/GB 阈值表
        applet: root.applet
    }

    // 排序后的接口列表已不再需要：排序规则统一由 NetCommon.sortInterfaces 提供
    // （本文件此前维护的 sortedInterfaces 全工程无人引用，故删除）

    // 速度格式化统一走后端：NetCommon 与 networkview 曾各自维护一套 KB/MB/GB 阈值，
    // 新增"固定 Mbps"单位后若继续各写一份必然漂移。
    // 现在换算规则只在 C++ 的 formatSpeed/formatSpeedCompact 里定义（可被单元测试覆盖），
    // 本文件只做拆分以便任务栏的小数点对齐渲染。
    // 设计原因：任务栏宽度有限，且采用"整数部分右对齐 + 小数部分左对齐"的两段式渲染，
    // 整数位数不同时小数点仍垂直对齐
    function formatSpeedIntPart(bytesPerSec) {
        return applet ? applet.formatSpeedCompact(bytesPerSec, applet.speedUnit, true)
                      : "0.00"
    }

    // 拆分速度字符串为小数+单位部分：0.85Mbps -> ".85Mbps"
    // 与 formatSpeedIntPart 配合，分别渲染实现小数点对齐
    function formatSpeedDecimalPart(bytesPerSec) {
        if (!applet) return ""
        var full = applet.formatSpeedCompact(bytesPerSec, applet.speedUnit, false)
        var intPart = applet.formatSpeedCompact(bytesPerSec, applet.speedUnit, true)
        return full.substring(intPart.length)
    }

    // 键盘/读屏打开或关闭详情弹窗的统一入口。
    // 设计原因：TapHandler 的 onTapped 里已有"开着就关、关着就开"的逻辑，
    // 若键盘路径另写一份，两条路迟早不一致（例如一边忘了 requestClosePopup）。
    // 抽到这里后，鼠标与键盘共用同一段行为
    function togglePopupFromKeyboard() {
        if (networkPopup.popupVisible) {
            networkPopup.close()
        } else {
            Panel.requestClosePopup()
            networkPopup.open()
        }
        toolTip.close()
    }

    // 统一打开独立窗口：右键菜单与弹窗内的详情入口共用这一个入口
    // 设计原因：各窗口的打开方式都是同样的 show/raise/requestActivate 三步，
    // 原先在右键菜单里重复了 5 份；新增弹窗入口后若继续各写一遍，
    // 后续调整（如加入位置记忆）就会出现多处逻辑漂移
    function openWindow(key) {
        var target = null
        if (key === "chart")         target = trafficChartWindow
        else if (key === "stats")    target = trafficStatsWindow
        else if (key === "tcp")      target = tcpConnectionsWindow
        else if (key === "settings") target = settingsWindow
        else if (key === "about")    target = aboutWindow
        if (!target) return
        target.show()
        target.raise()
        target.requestActivate()
    }

    // 面板锚点矩形：以任务栏图标中心为锚，尺寸取被定位窗口的当前尺寸
    // 设计原因：弹窗与悬停提示的锚点算法完全相同（图标中心 + 目标窗口尺寸），
    // 此前弹窗绑定与 showToolTip 各写一遍 mapToItem + Qt.rect。收敛到这一个入口后，
    // 锚点规则（尤其是 mapToItem(null, …) 这一坐标参照系的选择）只有一处定义，
    // 以后要改参照系或加偏移量不会出现漏改。
    function panelAnchorRect(targetWidth, targetHeight) {
        const point = root.mapToItem(null, root.width / 2, root.height / 2)
        return Qt.rect(point.x, point.y, targetWidth, targetHeight)
    }

    // 弹窗锚点：作为 Qt.binding 的求值入口使用（绑定表达式需要无参函数）
    // 设计原因：常驻绑定（Component.onCompleted）与每次点击前的刷新必须走同一份计算。
    // 此前点击时用直接赋值覆盖常驻绑定——QML 中给已有绑定的属性直接赋值会拆掉绑定，
    // 拆掉后 bounding 不再随弹窗宽度变化重算；而 DockPanelPositioner 默认取 bounding.width/2
    // 作水平偏移，于是打开期间内容宽度变化时弹窗会按旧宽度居中（偏移量为宽度差的一半）。
    // 故两处都用 Qt.binding 赋值：既刷新当前位置，又保住绑定语义。
    function popupBounding() {
        return panelAnchorRect(networkPopup.width, networkPopup.height)
    }

    // 同步刷新面板定位器坐标：凡是"设置 bounding 后立刻 open()"的路径都必须在 open() 前调用
    // 背景：dde-shell ≤ 2.0.53 的 DockPositioner 把 boundingChanged 只连到 update()，
    // 而 update() 仅是启动 0ms 单次定时器，真正算坐标的 updatePosition() 要等下一轮事件循环。
    // 本插件在同一个 JS 调用栈内"设置 bounding → 立刻 open()"，于是弹窗/提示的首帧
    // 读到的是 DockPositioner 的默认坐标 (0,0)——相对面板左上角，dock 在屏幕底部时
    // 即屏幕左下角，表现为空框先在左下角闪现一下，随后才被定时器算出的正确坐标移到图标上方。
    // 上游已在 dde-shell 2.0.54（commit bcbfbdfb）把该路径改成同步计算；这里显式调用一次
    // updatePosition()，让 ≤2.0.53 也能在 open() 前拿到正确坐标。新版本重复调用是幂等的
    // （坐标未变时 setX/setY 直接返回），无副作用；接口缺失时静默退化为原行为，不因缺接口报错。
    function syncPanelPositioner(attachedPositioner) {
        if (attachedPositioner && typeof attachedPositioner.updatePosition === "function") {
            attachedPositioner.updatePosition()
        }
    }

    // 显示悬停提示：以图标中心为锚点定位后打开
    // 设计原因：图标 hover 与"弹窗关闭后恢复提示"两条路径共用同一份定位逻辑，
    // 避免两处各写一遍 rect 计算；锚点算法本身取自 panelAnchorRect，不再就地展开
    // 首次 hover 也会命中上述首帧默认坐标问题，故定位后先同步坐标再 open
    function showToolTip() {
        toolTip.DockPanelPositioner.bounding = panelAnchorRect(toolTip.width, toolTip.height)
        syncPanelPositioner(toolTip.DockPanelPositioner)
        toolTip.open()
    }

    // 带单位的速度/总量格式化函数（formatSpeed / formatTotal）已移至 NetCommon，
    // 本文件未直接使用；弹窗与图表窗口经 common.formatSpeed / common.formatTotal 调用

    // 颜色别名：转发 common 的公共颜色，保持下游 root.xxx 引用不变。
    // 仅保留本文件实际使用的两个（primaryText 供 speedTextColor 回退、
    // accentRed 传入各独立窗口）；其余公共颜色本文件未用，不再重复定义。
    // 颜色派生逻辑与主题适配的设计原因见 NetCommon.qml 文件头注释
    readonly property color primaryText: common.primaryText
    readonly property color accentRed: common.accentRed

    // 深色模式检测：用 DTK 系统调色板的窗口背景亮度判定，而非 DockPalette。
    // 设计原因：DockPalette.iconTextPalette 反映的是任务栏图标文字色，不随系统深色主题变化；
    // DTK.palette.window 是系统主题的窗口背景色，深色模式下为深色（hslLightness < 0.5），
    // 浅色模式下为浅色（hslLightness >= 0.5）。主题切换时 DTK.paletteChanged 自动触发重新求值。
    // 检测结果通过属性注入各独立窗口（AboutWindow 等独立 Window 无法访问 dock 上下文的 DockPalette）
    readonly property bool isDarkMode: DTK.palette.window.hslLightness < 0.5

    // 任务栏网速数值字体色：用户自定义色优先（持久化），未设置时跟随系统主题
    // 设计原因：primaryText 派生自 DTK.palette.windowText，深浅色系统主题自动适配；
    // 用户主动选色后覆盖，空串回退到 primaryText 保持自适应
    readonly property color speedTextColor: (applet && applet.textColor.length > 0) ? applet.textColor : primaryText

    // 任务栏图标区：双行紧凑数值，箭头与数值紧贴
    // 设计原因：箭头与数值作为一组固定在左侧；
    // 不给每行固定高度，让 RowLayout 按内容自然高度排列，
    // 整组垂直居中于 dock 区域，避免两行间出现过大间隙
    // 小数点对齐：整数部分右对齐到两行最大整数宽度，小数部分左对齐，
    // 整数位数不同时小数点仍垂直对齐；箭头与数值间距固定不随位数变化
    Column {
        id: horizontalSpeed
        // 断连时整组隐藏，改由本文件末尾的断连标识 Text 显示"—"
        // （避免 0.00K 被误读为"网速很慢"）
        visible: !root.isVerticalDock && !root.linkDownNow
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 4
        anchors.right: parent.right
        anchors.rightMargin: 4
        spacing: 0

        // 两行整数部分的最大字符数：动态计算，整数短的行补占位到此宽度
        property int maxIntDigits: Math.max(
            root.formatSpeedIntPart(root.downloadSpeed).length,
            root.formatSpeedIntPart(root.uploadSpeed).length
        )
        // 整数部分固定宽度：用 TextMetrics 按实际字号实测，取代 dockSize * 0.14 的经验估算。
        // 设计原因：0.14 是按默认字号反推的固定比例（号称字号的 ~55%），
        // 但字符宽度随字体族、字号、字形变化——估算偏小会把速度值裁掉，
        // 偏大则整数区留白、小数点右移，两条速度行的小数点对不齐。
        // 这里用与数值 Text 完全相同的字号/字重实测：取两行中位数最多者，
        // 用等宽数字字形 "0" 拼出该位数（主流字体数字等宽，"0" 即可代表最大宽度）
        TextMetrics {
            id: intPartMetrics
            font.pixelSize: root.dockSize * 0.25
            font.weight: Font.Medium
            // new Array(n + 1).join("0") 生成 n 个 "0"（ES3 写法，避免依赖 String.repeat）
            text: new Array(horizontalSpeed.maxIntDigits + 1).join("0")
        }
        property real intPartWidth: intPartMetrics.advanceWidth

        // 下载速度行
        RowLayout {
            spacing: 2

            Text {
                text: "↓"
                font.pixelSize: root.dockSize * 0.20
                color: root.speedTextColor
                Layout.alignment: Qt.AlignVCenter
            }

            // 整数部分：右对齐到两行最大整数宽度，短的补占位
            Text {
                text: root.formatSpeedIntPart(root.downloadSpeed)
                font.pixelSize: root.dockSize * 0.25
                font.weight: Font.Medium
                color: root.speedTextColor
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: horizontalSpeed.intPartWidth
                horizontalAlignment: Text.AlignRight
            }

            // 小数+单位部分：左对齐，紧跟整数部分
            Text {
                text: root.formatSpeedDecimalPart(root.downloadSpeed)
                font.pixelSize: root.dockSize * 0.25
                font.weight: Font.Medium
                color: root.speedTextColor
                Layout.alignment: Qt.AlignVCenter
                horizontalAlignment: Text.AlignLeft
            }
        }

        // 上传速度行
        RowLayout {
            spacing: 2

            Text {
                text: "↑"
                font.pixelSize: root.dockSize * 0.20
                color: root.speedTextColor
                Layout.alignment: Qt.AlignVCenter
            }

            // 整数部分：右对齐到两行最大整数宽度，短的补占位
            Text {
                text: root.formatSpeedIntPart(root.uploadSpeed)
                font.pixelSize: root.dockSize * 0.25
                font.weight: Font.Medium
                color: root.speedTextColor
                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: horizontalSpeed.intPartWidth
                horizontalAlignment: Text.AlignRight
            }

            // 小数+单位部分：左对齐，紧跟整数部分
            Text {
                text: root.formatSpeedDecimalPart(root.uploadSpeed)
                font.pixelSize: root.dockSize * 0.25
                font.weight: Font.Medium
                color: root.speedTextColor
                Layout.alignment: Qt.AlignVCenter
                horizontalAlignment: Text.AlignLeft
            }
        }
    }

    // 竖向任务栏布局：双列字符竖排，每列一个方向（下载|上传）
    // 设计原因：竖向任务栏宽度仅 ~40px，水平布局的 "↓6.64K" 约 35px 勉强容纳但
    // 数值长度变化时易裁切；逐字符竖排每列仅 ~10px，双列 ~25px，舒适容纳且视觉对称
    RowLayout {
        visible: root.isVerticalDock && !root.linkDownNow
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: 4
        spacing: 4

        // 下载列：箭头在上，数值字符从上往下竖排
        Column {
            spacing: 0
            Layout.alignment: Qt.AlignTop | Qt.AlignHCenter

            Text {
                text: "↓"
                font.pixelSize: root.dockSize * 0.20
                color: root.speedTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Repeater {
                // 将 "6.64K" 拆为 ["6", ".", "6", "4", "K"] 逐字符渲染
                // 属性绑定：速度或单位变化时后端重新格式化，split 自动刷新 model
                // 注意：此处必须直接用后端返回值（而不是在 QML 里拼接单位），
                // 否则竖排与横排会显示两套不同的单位口径
                model: root.applet
                       ? root.applet.formatSpeedCompact(root.downloadSpeed, root.applet.speedUnit, false).split('')
                       : []
                Text {
                    text: modelData
                    font.pixelSize: root.dockSize * 0.25
                    height: font.pixelSize
                    font.weight: Font.Medium
                    color: root.speedTextColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }

        // 上传列：结构与下载列对称，颜色用 uploadValueColor
        Column {
            spacing: 0
            Layout.alignment: Qt.AlignTop | Qt.AlignHCenter

            Text {
                text: "↑"
                font.pixelSize: root.dockSize * 0.20
                color: root.speedTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Repeater {
                model: root.applet
                       ? root.applet.formatSpeedCompact(root.uploadSpeed, root.applet.speedUnit, false).split('')
                       : []
                Text {
                    text: modelData
                    font.pixelSize: root.dockSize * 0.25
                    height: font.pixelSize
                    font.weight: Font.Medium
                    color: root.speedTextColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    // 断连标识：水平与竖向两套布局共用同一个"—"（断连时它们各自隐藏，不会重叠）
    // 设计原因：0.00K 会被误读为"网速很慢"而非"链路断开"，故用符号替代数值；
    // 颜色固定用次要色而非用户自定义的速度色——用户若选了红色，断连态会被误读成告警
    Text {
        visible: root.linkDownNow
        anchors.centerIn: parent
        text: "—"
        font.pixelSize: root.dockSize * 0.30
        font.weight: Font.Medium
        color: common.secondaryText
    }

    // 悬停提示：网卡名 + IPv4 单行，IPv6 在第二行（仅有 IPv6 时追加）
    // 设计原因：IPv6 地址较长，单行容纳不下；无 IPv6 时保持单行与原视觉一致。
    // 接口名经 common.displayName() 处理：无线且已连接时显示 WiFi 名称（如 "Home"），
    // 否则回退接口名（如 "wlo1"）——wlo1 这种内核命名对用户没有意义
    PanelToolTip {
        id: toolTip
        text: !root.ready
              ? qsTr("No network interface detected")
              : (root.linkDownNow
                 // 断连时只说明接口已断开，不再拼地址行（此时地址可能仍是残留值）
                 ? (root.displayName + " · " + qsTr("Disconnected"))
                 // 合计模式下任务栏数字不是单卡速度，提示里必须说明口径，
                 // 否则用户会把"有线+无线之和"误认为当前网卡的速率
                 : ((root.showAggregate
                     ? qsTr("All interfaces (combined)")
                     : root.displayName)
                    + " · " + qsTr("IPv4: ") + (root.ipAddress || qsTr("None"))
                    + (root.ipv6Address ? "\n" + qsTr("IPv6: ") + root.ipv6Address : "")))
        toolTipX: DockPanelPositioner.x
        toolTipY: DockPanelPositioner.y
    }

    // 注意：不再需要 QML 侧的 statsRefreshTimer。
    // C++ 后端 NetworkMonitorApplet::init() 已启动 1 秒间隔的 m_refreshTimer，
    // 持续调用 refresh()->readNetworkStats()->calculateSpeed() 更新速度属性。
    // QML 通过属性绑定自动获取最新值，无需主动触发 refresh。
    // refresh() 已移除 Q_INVOKABLE 标记，防止 QML 误调用打破定时间隔。

    Timer {
        id: toolTipShowTimer
        interval: 50
        onTriggered: root.showToolTip()
    }

    HoverHandler {
        id: hoverHandler

        onHoveredChanged: {
            // 仅控制 tooltip 显示，不触发 refresh。
            // C++ 后端 m_refreshTimer 持续每秒更新速度属性，QML 属性绑定自动反映。
            if (hovered && !networkPopup.popupVisible) {
                toolTipShowTimer.start()
            } else {
                if (toolTipShowTimer.running) {
                    toolTipShowTimer.stop()
                }
                toolTip.close()
            }
        }
    }

    // 弹出窗口：PanelPopup 壳在此处（dock 上下文类型不能作为独立组件根元素），
    // 弹窗内容由 NetworkPopup.qml 提供，传入 applet，内部自行派生颜色和数据
    PanelPopup {
        id: networkPopup
        // 尺寸跟随弹窗内容的隐式尺寸：
        // PanelPopup 是独立窗口，超出窗口边界的内容会被直接裁掉。此前硬编码 330x348，
        // 而中文文案下内容实测需要 412x377（最宽的包统计行 388px + 左右内边距；
        // 高度需容纳底部详情入口行），结果是右侧（上传速度单位、错误/丢包、
        // 第三个接口 chip）与底部（三个详情入口）被裁切。改为由内容实测尺寸驱动后，
        // 翻译文案、字号、数值长度变化都不再引发裁切。
        // 保留原值作为下限：占位态（未检测到接口）内容更矮更窄，
        // 避免弹窗塌缩成一条，同时维持"打开即为稳定尺寸"的观感
        width: Math.max(330, popupContent.implicitWidth)
        height: Math.max(348, popupContent.implicitHeight)
        popupX: DockPanelPositioner.x
        popupY: DockPanelPositioner.y

        onPopupVisibleChanged: {
            if (popupVisible) {
                toolTip.close()
                // popup 打开时确保活动 chip 完整可见
                Qt.callLater(function() { popupContent.scrollToActiveChip(false) })
            } else if (hoverHandler.hovered) {
                // 关闭弹窗时鼠标仍停在图标上（hovered 未变化，不会触发 onHoveredChanged），
                // 若不在此恢复，提示气泡要等到鼠标移出再移入才会回来
                toolTipShowTimer.start()
            }
        }

        NetworkPopup {
            id: popupContent
            applet: root.applet
            common: common
            anchors.fill: parent

            // 弹窗内的详情入口：先关闭弹窗再打开目标窗口，避免弹窗与独立窗口并存遮挡
            onDetailsRequested: function (key) {
                networkPopup.close()
                root.openWindow(key)
            }

            // 弹窗内按 Esc：关闭入口仍收敛在本文件（与详情入口走同一个 close()）
            onCloseRequested: networkPopup.close()
        }

        Component.onCompleted: {
            // 保持为绑定而非一次性取值：弹窗宽度随内容变化时锚点要跟着重算
            DockPanelPositioner.bounding = Qt.binding(function () { return root.popupBounding() })
        }
    }

    // 右键菜单：使用 Qt.labs.platform.Menu + MenuHelper
    // 设计原因：dde-shell dock 环境下 AppletItem 嵌入 layer-shell 窗口，
    // QtQuick.Controls.Menu.popup() 无法获取有效 QQuickWindow 来弹出菜单。
    // 必须用 Qt.labs.platform.Menu（原生菜单）配合 org.deepin.ds.dock 的
    // MenuHelper 单例管理菜单生命周期（确保同一时间只有一个菜单打开）。
    Platform.Menu {
        id: contextMenu

        // 流量波动图：屏幕居中独立窗口，展示活动接口最近 30 分钟网速趋势
        Platform.MenuItem {
            text: qsTr("Traffic Chart")
            onTriggered: root.openWindow("chart")
        }

        // 流量统计：屏幕居中独立窗口，展示按日/按月持久化的累计流量
        Platform.MenuItem {
            text: qsTr("Traffic Statistics")
            onTriggered: root.openWindow("stats")
        }

        // TCP 连接清单：屏幕居中独立窗口，展示当前所有 ESTABLISHED 状态的 TCP 连接
        Platform.MenuItem {
            text: qsTr("TCP Connections")
            onTriggered: root.openWindow("tcp")
        }

        Platform.MenuItem {
            text: qsTr("Settings")
            onTriggered: root.openWindow("settings")
        }

        Platform.MenuSeparator {}

        Platform.MenuItem {
            text: qsTr("About")
            onTriggered: root.openWindow("about")
        }
    }

    // 关于窗口：抽取为独立组件 package/components/AboutWindow.qml
    // 依赖通过属性传入：accentColor = root.accentRed，version 取自 C++ 后端 applet.version，
    // isDarkMode 取自上方 DTK.palette 检测结果
    AboutWindow {
        id: aboutWindow
        accentColor: root.accentRed
        version: root.applet ? root.applet.version : ""
        isDarkMode: root.isDarkMode
    }

    // 流量波动图窗口：屏幕居中独立窗口，展示活动接口最近 30 分钟网速趋势
    // 依赖通过属性传入：accentColor = root.accentRed，applet = root.applet，
    // isDarkMode 取自上方 DTK.palette 检测结果
    TrafficChartWindow {
        id: trafficChartWindow
        accentColor: root.accentRed
        applet: root.applet
        isDarkMode: root.isDarkMode
    }

    // 流量统计窗口：屏幕居中独立窗口，展示按日/按月持久化的累计流量
    // 依赖通过属性传入：accentColor = root.accentRed，applet = root.applet，
    // isDarkMode 取自上方 DTK.palette 检测结果
    TrafficStatsWindow {
        id: trafficStatsWindow
        accentColor: root.accentRed
        applet: root.applet
        isDarkMode: root.isDarkMode
    }

    // TCP 连接清单窗口：屏幕居中独立窗口，展示当前所有 ESTABLISHED 状态的 TCP 连接
    // 依赖通过属性传入：accentColor = root.accentRed，applet = root.applet，
    // isDarkMode 取自上方 DTK.palette 检测结果
    TcpConnectionsWindow {
        id: tcpConnectionsWindow
        accentColor: root.accentRed
        applet: root.applet
        isDarkMode: root.isDarkMode
    }

    // 设置窗口：独立顶层窗口，在桌面中间弹出
    // 设计原因：Dialog 使用父窗口（dock layer-surface）的 overlay，仅覆盖任务栏区域，
    // 无法在桌面中间显示。改用 Window 创建独立顶层窗口，可在桌面任意位置弹出。
    SettingsWindow {
        id: settingsWindow
        applet: root.applet
        networkInterfaces: root.networkInterfaces
        wirelessInterfaces: root.wirelessInterfaces
        activeInterface: root.activeInterface
        accentColor: root.accentRed
        isDarkMode: root.isDarkMode
    }

    // 点击处理
    TapHandler {
        acceptedButtons: Qt.LeftButton
        gesturePolicy: TapHandler.ReleaseWithinBounds

        onTapped: {
            if (networkPopup.popupVisible) {
                networkPopup.close()
            } else {
                Panel.requestClosePopup()
                // 图标可能已位移，重新求值锚点；用 Qt.binding 赋值以保留绑定语义
                // （直接赋值会拆掉 Component.onCompleted 建立的绑定，弹窗宽度变化后不再重算）
                networkPopup.DockPanelPositioner.bounding = Qt.binding(function () { return root.popupBounding() })
                // 先同步坐标再 open，避免 dde-shell ≤2.0.53 下首帧用默认 (0,0) 闪现到面板原点
                syncPanelPositioner(networkPopup.DockPanelPositioner)
                networkPopup.open()
            }
            toolTip.close()
        }
    }

    // 右键点击：弹出上下文菜单
    TapHandler {
        acceptedButtons: Qt.RightButton
        gesturePolicy: TapHandler.ReleaseWithinBounds

        onTapped: {
            // 关闭可能打开的 popup，避免视觉冲突
            if (networkPopup.popupVisible) networkPopup.close()
            toolTip.close()
            // 使用 MenuHelper 打开菜单（dde-shell dock 环境必需，
            // 它会先关闭当前活动菜单再打开新菜单，保证同一时间只有一个菜单）
            MenuHelper.openMenu(contextMenu)
        }
    }
}