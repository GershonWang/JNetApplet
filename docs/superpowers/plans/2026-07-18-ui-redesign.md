# JNetApplet UI 重新设计实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 重写 `package/networkview.qml`，实现 deepin 原生简约风格的任务栏图标、左键弹出面板、右键菜单和 Tooltip。

**Architecture:** 单文件 QML 重写，不动 C++ 后端。颜色派生自 `DockPalette.iconTextPalette`，深/浅色自适应。新增 `formatSpeedShort`、右键 `Menu`、chip 接口切换器。

**Tech Stack:** QML 2.15、QtQuick.Controls 2.15、QtQuick.Layouts 1.15、org.deepin.ds 1.0、org.deepin.ds.dock 1.0、org.deepin.dtk 1.0。

## Global Constraints

- 仅修改 `package/networkview.qml`，不改 C++、`metadata.json`、`CMakeLists.txt`
- 保留 SPDX 文件头与所有 imports
- Root 元素为 `AppletItem`（来自 `import org.deepin.ds 1.0`）
- QML 属性类型用 `double`/`real`，不用 `qint64`
- 注释统一中文
- 项目无测试/lint/CI，验证方式：`cmake --build build` + 手动安装重启 dde-shell
- Commit 中文 conventional commits，仅在被显式请求时提交

**Spec 引用：** `docs/superpowers/specs/2026-07-18-ui-redesign-design.md`

---

## File Structure

仅修改 `package/networkview.qml`（当前 521 行）。无新文件、无 C++ 改动。

重写后内部结构：

```
AppletItem (root)
├── 属性区：applet 绑定、颜色派生、formatSpeedShort
├── 任务栏图标区：Column { Row(↓值), Row(↑值) }
├── PanelToolTip
├── Timer × 2
├── HoverHandler
├── PanelPopup
│   └── Control > ColumnLayout
│       ├── 标题栏（标题+副标题+刷新按钮）
│       ├── 实时速度卡片（双列）
│       ├── 总量统计（单行）
│       ├── 接口切换 chip 列表
│       └── 未检测到接口占位
├── Menu (contextMenu)  ← 新增
├── Dialog (aboutDialog)  ← 新增
├── TapHandler (左键)
└── TapHandler (右键)  ← 新增
```

---

## Task 1: 属性区与格式化函数（基础层）

**Files:** Modify `package/networkview.qml:32-72`

**Interfaces:**
- Produces: `formatSpeedShort()`、`accentGreen`、`accentGreenLight`、`accentOrange`、`accentRed`、`downloadValueColor`、`uploadValueColor` - 后续任务全部依赖

**说明：** 替换 root 的函数块和颜色属性块。保留所有 `applet` 绑定属性不变。

- [ ] **Step 1: 替换函数区（原 32-56 行）**

将 `// 格式化速度显示` 注释到 `formatTotal` 函数结束替换为：

```qml
    // 紧凑格式化速度（用于任务栏图标和 tooltip，不带单位后缀，节省空间）
    // 设计原因：任务栏 ~48px 空间有限，"1.2M" 比 "1.2 MB/s" 节省约一半宽度
    function formatSpeedShort(bytesPerSec) {
        if (bytesPerSec < 1024) {
            return bytesPerSec.toFixed(0)
        } else if (bytesPerSec < 1024 * 1024) {
            return (bytesPerSec / 1024).toFixed(1) + "K"
        } else if (bytesPerSec < 1024 * 1024 * 1024) {
            return (bytesPerSec / (1024 * 1024)).toFixed(1) + "M"
        } else {
            return (bytesPerSec / (1024 * 1024 * 1024)).toFixed(1) + "G"
        }
    }

    // 格式化速度显示（带单位，用于弹出面板，信息更完整）
    function formatSpeed(bytesPerSec) {
        if (bytesPerSec < 1024) {
            return bytesPerSec.toFixed(0) + " B/s"
        } else if (bytesPerSec < 1024 * 1024) {
            return (bytesPerSec / 1024).toFixed(1) + " KB/s"
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
```

- [ ] **Step 2: 替换颜色属性区（原 58-72 行）**

将 `// 根据速度计算图标颜色` 注释到 `accentBlueLight` 属性结束替换为：

```qml
    // 任务栏与面板的颜色全部派生自 DockPalette.iconTextPalette
    // 这样在深色/浅色任务栏下自动适配，无需手动判断主题
    property Palette basePalette: DockPalette.iconTextPalette
    readonly property color primaryText: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.95)
    readonly property color secondaryText: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.80)
    readonly property color tertiaryText: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.65)
    readonly property color cardBackground: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.06)
    readonly property color cardBorder: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.10)

    // 强调色：下载蓝、上传绿，是面板与任务栏的主视觉区分
    readonly property color accentBlue: Qt.rgba(20 / 255, 80 / 255, 160 / 255, 1)
    readonly property color accentBlueLight: Qt.rgba(20 / 255, 80 / 255, 160 / 255, 0.12)
    readonly property color accentGreen: Qt.rgba(22 / 255, 163 / 255, 74 / 255, 1)
    readonly property color accentGreenLight: Qt.rgba(22 / 255, 163 / 255, 74 / 255, 0.12)

    // 高速警示色：下载速度超过阈值时由蓝转橙再转红
    readonly property color accentOrange: Qt.rgba(245 / 255, 158 / 255, 11 / 255, 1)
    readonly property color accentRed: Qt.rgba(220 / 255, 38 / 255, 38 / 255, 1)

    // 下载值颜色：保留原有阈值逻辑（>10MB/s 红、>1MB/s 橙、否则蓝），仅作用于下载值
    readonly property color downloadValueColor: {
        if (downloadSpeed > 10 * 1024 * 1024) return accentRed
        if (downloadSpeed > 1 * 1024 * 1024) return accentOrange
        return accentBlue
    }

    // 上传值颜色：固定绿色，不做高速警示
    readonly property color uploadValueColor: accentGreen
```

- [ ] **Step 3: 验证标识符已定义**

Run: `grep -n "formatSpeedShort\|downloadValueColor\|uploadValueColor\|accentGreen " /home/Jokul/Documents/projects/JNetApplet/package/networkview.qml`
Expected: 每个标识符至少出现一次。

- [ ] **Step 4: 验证 C++ 仍可构建**

Run: `cmake --build /home/Jokul/Documents/projects/JNetApplet/build 2>&1 | tail -5`
Expected: 构建成功，无 error。

---

## Task 2: 任务栏图标区重写

**Files:** Modify `package/networkview.qml`（原 74-120 行的圆圈 `Rectangle`）

**Interfaces:**
- Consumes: `formatSpeedShort()`、`downloadValueColor`、`uploadValueColor`、`secondaryText`、`dockSize`
- Produces: 任务栏双行数值显示

- [ ] **Step 1: 替换图标区域**

将 `// 图标区域` 注释到对应 `Rectangle` 闭合 `}` 替换为：

```qml
    // 任务栏图标区：双行紧凑数值，移除原圆圈边框
    // 上行下载、下行上传，箭头为次级色、数值为强调色
    // 设计原因：圆圈边框在 ~48px dock 内压缩可用空间，去掉后数值字号可放大提升可读性
    Column {
        anchors.centerIn: parent
        spacing: 1

        // 下载速度行
        Row {
            spacing: 2
            anchors.horizontalCenter: parent.horizontalCenter

            Text {
                text: "↓"
                font.pixelSize: root.dockSize * 0.16
                color: root.secondaryText
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                text: root.formatSpeedShort(root.downloadSpeed)
                font.pixelSize: root.dockSize * 0.22
                font.weight: Font.Medium
                color: root.downloadValueColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        // 上传速度行
        Row {
            spacing: 2
            anchors.horizontalCenter: parent.horizontalCenter

            Text {
                text: "↑"
                font.pixelSize: root.dockSize * 0.16
                color: root.secondaryText
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                text: root.formatSpeedShort(root.uploadSpeed)
                font.pixelSize: root.dockSize * 0.22
                font.weight: Font.Medium
                color: root.uploadValueColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
```

- [ ] **Step 2: 确认旧 `iconColor` 已无引用**

Run: `grep -n "iconColor" /home/Jokul/Documents/projects/JNetApplet/package/networkview.qml`
Expected: 无输出。

- [ ] **Step 3: 安装并目视验证**

Run: `sudo cmake --install /home/Jokul/Documents/projects/JNetApplet/build && systemctl --user restart dde-shell@DDE`
Expected: 任务栏图标显示双行「↓数值 / ↑数值」，下载蓝、上传绿，无圆圈边框。

---

## Task 3: Tooltip 文本更新

**Files:** Modify `package/networkview.qml`（`buildToolTipText` 函数）

**Interfaces:**
- Consumes: `formatSpeedShort()`、`activeInterface`、`ready`

**说明：** Tooltip 改用 `formatSpeedShort` 与任务栏一致。`PanelToolTip.text` 是纯文本，不支持富文本着色，箭头无法单独着色。

- [ ] **Step 1: 替换 buildToolTipText 函数体**

```qml
    // 构建 tooltip 文本：单行紧凑展示下载/上传速度和活动接口
    // 设计原因：tooltip 空间有限，用 formatSpeedShort 与任务栏保持视觉一致
    // 用 "·" 分隔速度区与接口名，比 " | " 更轻量
    function buildToolTipText() {
        if (!root.ready) {
            return qsTr("未检测到网络接口")
        }

        var lines = []
        lines.push("↓ " + root.formatSpeedShort(root.downloadSpeed))
        lines.push("↑ " + root.formatSpeedShort(root.uploadSpeed))
        lines.push(root.activeInterface)
        return lines.join("   ·   ")
    }
```

- [ ] **Step 2: 确认 PanelToolTip 未就绪文案为中文**

确认 `PanelToolTip` 的 `text` 属性为：

```qml
    PanelToolTip {
        id: toolTip
        text: root.ready ? root.buildToolTipText() : qsTr("未检测到网络接口")
        toolTipX: DockPanelPositioner.x
        toolTipY: DockPanelPositioner.y
    }
```

若为英文 `"No network interface detected"`，替换为上述中文。

- [ ] **Step 3: 安装并目视验证**

Run: `sudo cmake --install /home/Jokul/Documents/projects/JNetApplet/build && systemctl --user restart dde-shell@DDE`
Expected: 悬停时 tooltip 显示形如 `↓ 1.2M   ·   ↑ 256K   ·   eth0`。

---

## Task 4: 左键弹出面板重写

**Files:** Modify `package/networkview.qml`（`PanelPopup` 内部，原 173-489 行）

**Interfaces:**
- Consumes: `formatSpeed`、`formatTotal`、`primaryText`、`secondaryText`、`tertiaryText`、`cardBackground`、`cardBorder`、`accentBlue`、`accentBlueLight`、`accentGreen`、`accentGreenLight`、`downloadValueColor`、`uploadValueColor`、`ready`、`activeInterface`、`downloadSpeed`、`uploadSpeed`、`totalDownload`、`totalUpload`、`networkInterfaces`、`applet`
- Produces: 360×320 重构面板

**说明：** 尺寸从 400×350 改为 360×320。结构：标题栏（含副标题）+ 实时速度双列卡片 + 总量单行 + chip 接口切换 + 未就绪占位。

- [ ] **Step 1: 调整 PanelPopup 尺寸**

将 `PanelPopup` 的 `width: 400` / `height: 350` 改为 `width: 360` / `height: 320`。保留 `popupX`/`popupY`/`onPopupVisibleChanged` 不变。

- [ ] **Step 2: 替换 Control 及其 contentItem 全部内容**

将 `PanelPopup` 内的 `Control { id: popupContainer ... }` 整体替换为：

```qml
        Control {
            id: popupContainer
            anchors.fill: parent
            padding: 16

            contentItem: ColumnLayout {
                spacing: 12

                // 标题栏：左标题+副标题，右刷新按钮
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    ColumnLayout {
                        spacing: 0
                        Text {
                            text: qsTr("网络速度监控")
                            font.pixelSize: 15
                            font.weight: Font.Bold
                            color: root.primaryText
                        }
                        Text {
                            text: root.ready ? root.activeInterface : qsTr("未连接")
                            font.pixelSize: 11
                            color: root.secondaryText
                            visible: root.ready
                        }
                    }

                    Item { Layout.fillWidth: true }

                    // 刷新按钮：hover 高亮 + 旋转动画
                    Rectangle {
                        width: 28
                        height: 28
                        radius: 6
                        color: refreshIconArea.containsMouse ? root.accentBlueLight : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: "⟳"
                            font.pixelSize: 16
                            color: refreshIconArea.containsMouse ? root.accentBlue : root.secondaryText
                        }

                        MouseArea {
                            id: refreshIconArea
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.applet) root.applet.refresh()
                                refreshSpin.start()
                            }
                        }

                        RotationAnimator on rotation {
                            id: refreshSpin
                            running: false
                            from: 0
                            to: 360
                            duration: 500
                        }
                    }
                }

                // 实时速度卡片：双列布局，主视觉
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 110
                    color: root.cardBackground
                    radius: 12
                    border.width: 1
                    border.color: root.cardBorder

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 0

                        // 下载列
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4
                            anchors.verticalCenter: parent.verticalCenter

                            Rectangle {
                                width: 32
                                height: 32
                                radius: 16
                                color: root.accentBlueLight
                                Layout.alignment: Qt.AlignHCenter

                                Text {
                                    anchors.centerIn: parent
                                    text: "↓"
                                    font.pixelSize: 18
                                    font.weight: Font.Bold
                                    color: root.accentBlue
                                }
                            }

                            Text {
                                text: qsTr("下载")
                                font.pixelSize: 11
                                color: root.secondaryText
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: root.formatSpeed(root.downloadSpeed)
                                font.pixelSize: 18
                                font.weight: Font.Bold
                                color: root.downloadValueColor
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }

                        // 分隔线
                        Rectangle {
                            width: 1
                            Layout.fillHeight: true
                            color: root.cardBorder
                        }

                        // 上传列
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4
                            anchors.verticalCenter: parent.verticalCenter

                            Rectangle {
                                width: 32
                                height: 32
                                radius: 16
                                color: root.accentGreenLight
                                Layout.alignment: Qt.AlignHCenter

                                Text {
                                    anchors.centerIn: parent
                                    text: "↑"
                                    font.pixelSize: 18
                                    font.weight: Font.Bold
                                    color: root.accentGreen
                                }
                            }

                            Text {
                                text: qsTr("上传")
                                font.pixelSize: 11
                                color: root.secondaryText
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Text {
                                text: root.formatSpeed(root.uploadSpeed)
                                font.pixelSize: 18
                                font.weight: Font.Bold
                                color: root.uploadValueColor
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }
                }

                // 总量统计：单行紧凑
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44
                    color: root.cardBackground
                    radius: 12
                    border.width: 1
                    border.color: root.cardBorder
                    visible: root.ready

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 8

                        Text {
                            text: qsTr("总计")
                            font.pixelSize: 11
                            font.weight: Font.Bold
                            color: root.secondaryText
                        }

                        Text {
                            text: "↓ " + root.formatTotal(root.totalDownload)
                            font.pixelSize: 12
                            color: root.primaryText
                        }

                        Item { Layout.fillWidth: true }

                        Text {
                            text: "↑ " + root.formatTotal(root.totalUpload)
                            font.pixelSize: 12
                            color: root.primaryText
                        }
                    }
                }

                // 接口切换 chip 列表（仅多接口时显示）
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    visible: root.ready && root.networkInterfaces.length > 1

                    Repeater {
                        model: root.networkInterfaces

                        Rectangle {
                            width: chipText.implicitWidth + 20
                            height: 28
                            radius: 8
                            color: modelData === root.activeInterface
                                   ? root.accentBlue
                                   : (chipMouse.containsMouse ? root.accentBlueLight : root.cardBackground)
                            border.width: 1
                            border.color: modelData === root.activeInterface
                                          ? root.accentBlue
                                          : root.cardBorder

                            Text {
                                id: chipText
                                anchors.centerIn: parent
                                text: modelData
                                font.pixelSize: 11
                                font.weight: modelData === root.activeInterface ? Font.Bold : Font.Normal
                                color: modelData === root.activeInterface ? "white" : root.primaryText
                            }

                            MouseArea {
                                id: chipMouse
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                hoverEnabled: true
                                onClicked: {
                                    if (root.applet) root.applet.setActiveInterface(modelData)
                                }
                            }
                        }
                    }
                }

                // 未检测到接口占位
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 80
                    color: root.cardBackground
                    radius: 12
                    border.width: 1
                    border.color: root.cardBorder
                    visible: !root.ready

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: "⚠"
                            font.pixelSize: 24
                            color: root.secondaryText
                            Layout.alignment: Qt.AlignHCenter
                        }

                        Text {
                            text: qsTr("未检测到网络接口")
                            font.pixelSize: 12
                            color: root.secondaryText
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }
```

- [ ] **Step 3: 确认 `Component.onCompleted` 中 `DockPanelPositioner.bounding` 绑定保留**

`PanelPopup` 末尾的 `Component.onCompleted` 块保留不变（用于定位 popup 位置）。

- [ ] **Step 4: 安装并目视验证**

Run: `sudo cmake --install /home/Jokul/Documents/projects/JNetApplet/build && systemctl --user restart dde-shell@DDE`
Expected:
- 左键点击任务栏图标，弹出 360×320 面板
- 标题栏显示「网络速度监控」+ 接口名副标题
- 实时速度卡片双列：下载蓝、上传绿，各带圆形图标底
- 总量统计单行显示「总计 ↓ X · ↑ Y」
- 多接口时显示 chip 列表，当前接口高亮蓝色
- 未检测到接口时显示占位卡片

---

## Task 5: 右键菜单与关于对话框

**Files:** Modify `package/networkview.qml`（新增 `Menu`、`Dialog`、右键 `TapHandler`，替换原左键 `TapHandler`）

**Interfaces:**
- Consumes: `applet.refresh()`、`applet.setActiveInterface()`、`networkInterfaces`、`activeInterface`、`primaryText`、`secondaryText`、`accentBlue`
- Produces: 右键弹出 deepin 风格菜单

**说明：** 在 `PanelPopup` 之后、原左键 `TapHandler` 之前，新增 `Menu` 和 `Dialog`。在原左键 `TapHandler` 之后新增右键 `TapHandler`。

- [ ] **Step 1: 新增 contextMenu 和 aboutDialog**

在 `PanelPopup` 闭合 `}` 之后，原 `// 构建 tooltip 文本` 注释之前，插入：

```qml
    // 右键菜单：deepin 风格 Menu，提供刷新/切换接口/关于快捷操作
    Menu {
        id: contextMenu

        MenuItem {
            text: qsTr("刷新")
            onTriggered: {
                if (root.applet) root.applet.refresh()
            }
        }

        MenuSeparator {}

        // 切换接口子菜单：动态构建可用接口列表
        Menu {
            title: qsTr("切换接口")
            enabled: root.networkInterfaces.length > 1

            Instantiator {
                model: root.networkInterfaces
                delegate: MenuItem {
                    text: modelData
                    checkable: true
                    checked: modelData === root.activeInterface
                    onTriggered: {
                        if (root.applet) root.applet.setActiveInterface(modelData)
                    }
                }
                onObjectAdded: (index, object) => contextMenu.children[2].insertItem(index, object)
                onObjectRemoved: (index, object) => contextMenu.children[2].removeItem(object)
            }
        }

        MenuSeparator {}

        MenuItem {
            text: qsTr("关于")
            onTriggered: aboutDialog.open()
        }
    }

    // 关于对话框：显示插件信息
    Dialog {
        id: aboutDialog
        anchors.centerIn: parent
        modal: true
        width: 280
        height: 160

        background: Rectangle {
            color: root.cardBackground
            radius: 12
            border.width: 1
            border.color: root.cardBorder
        }

        contentItem: ColumnLayout {
            spacing: 8

            Text {
                text: qsTr("网络速度监控")
                font.pixelSize: 16
                font.weight: Font.Bold
                color: root.primaryText
                Layout.alignment: Qt.AlignHCenter
            }

            Text {
                text: qsTr("版本：1.0")
                font.pixelSize: 12
                color: root.secondaryText
                Layout.alignment: Qt.AlignHCenter
            }

            Text {
                text: qsTr("监控网络速度和流量")
                font.pixelSize: 11
                color: root.tertiaryText
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 240
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }

            Item { Layout.fillHeight: true }

            Button {
                text: qsTr("确定")
                Layout.alignment: Qt.AlignHCenter
                onClicked: aboutDialog.close()
            }
        }
    }
```

- [ ] **Step 2: 新增右键 TapHandler**

在原左键 `TapHandler`（`acceptedButtons: Qt.LeftButton`）之后，文件末尾的 root 闭合 `}` 之前，插入：

```qml
    // 右键点击：弹出上下文菜单
    TapHandler {
        acceptedButtons: Qt.RightButton
        gesturePolicy: TapHandler.ReleaseWithinBounds

        onTapped: {
            // 关闭可能打开的 popup，避免视觉冲突
            if (networkPopup.popupVisible) networkPopup.close()
            toolTip.close()
            // 使用 root 中心点定位菜单
            contextMenu.popup()
        }
    }
```

- [ ] **Step 3: 确认 Instantiator 子菜单挂载点正确**

Run: `grep -n "Instantiator\|onObjectAdded" /home/Jokul/Documents/projects/JNetApplet/package/networkview.qml`
Expected: 出现一次 Instantiator 块。

> 注：Instantiator 的 `onObjectAdded`/`onObjectRemoved` 中 `contextMenu.children[2]` 是切换接口子菜单（菜单顺序：刷新 MenuItem / MenuSeparator / 切换接口 Menu / MenuSeparator / 关于 MenuItem）。若 QtQuick.Controls 版本不支持 `insertItem`/`removeItem`，可改用 `Menu` 的 `MenuItem` 直接列出（无 Instantiator），通过 `Instantiator` 的 `onObjectAdded` 调用 `parent.addItem(object)` 或直接在子 Menu 内用 `Repeater`+`MenuItem` 写法。验证时如报错，将子菜单改为：

```qml
        Menu {
            title: qsTr("切换接口")
            enabled: root.networkInterfaces.length > 1

            Repeater {
                model: root.networkInterfaces
                delegate: MenuItem {
                    text: modelData
                    checkable: true
                    checked: modelData === root.activeInterface
                    onTriggered: {
                        if (root.applet) root.applet.setActiveInterface(modelData)
                    }
                }
            }
        }
```

（两种写法二选一，优先用 Repeater 版本更稳。）

- [ ] **Step 4: 安装并目视验证**

Run: `sudo cmake --install /home/Jokul/Documents/projects/JNetApplet/build && systemctl --user restart dde-shell@DDE`
Expected:
- 右键点击任务栏图标，弹出 deepin 风格菜单
- 菜单项：刷新 / 切换接口（子菜单）/ 关于
- 切换接口子菜单列出所有接口，当前接口打勾
- 接口数 ≤ 1 时「切换接口」项禁用（灰色）
- 点击「关于」弹出对话框显示版本信息

---

## Task 6: 最终验证清单

**Files:** 无改动，仅验证

**说明：** 按 spec 验证清单逐项检查。

- [ ] **Step 1: 重新构建并安装**

Run: `cmake --build /home/Jokul/Documents/projects/JNetApplet/build && sudo cmake --install /home/Jokul/Documents/projects/JNetApplet/build && systemctl --user restart dde-shell@DDE`
Expected: 构建成功、安装成功、dde-shell 重启无报错。

- [ ] **Step 2: 任务栏图标验证**

逐项检查：
- [ ] 双行数值显示，下载在上、上传在下
- [ ] 颜色正确（下载蓝、上传绿）
- [ ] 高速时下载值变橙（>1MB/s）/红（>10MB/s）
- [ ] 深色任务栏下文字可读
- [ ] 浅色任务栏下文字可读
- [ ] 无圆圈边框

- [ ] **Step 3: Tooltip 验证**

悬停任务栏图标：
- [ ] 单行显示 `↓ X   ·   ↑ Y   ·   接口名`
- [ ] 未检测到接口时显示「未检测到网络接口」

- [ ] **Step 4: 左键弹出面板验证**

左键点击任务栏图标：
- [ ] 尺寸 360×320
- [ ] 标题栏：「网络速度监控」+ 接口名副标题
- [ ] 实时速度双列卡片：下载蓝、上传绿，圆形图标底
- [ ] 总量统计单行：「总计 ↓ X · ↑ Y」
- [ ] 多接口时显示 chip 列表，当前接口高亮
- [ ] 刷新按钮 hover 高亮 + 旋转动画
- [ ] 未检测到接口时显示占位卡片

- [ ] **Step 5: 右键菜单验证**

右键点击任务栏图标：
- [ ] 弹出 deepin 风格菜单
- [ ] 刷新项可用，点击后数据更新
- [ ] 切换接口子菜单列出接口、当前项打勾
- [ ] 接口数 ≤ 1 时切换项禁用
- [ ] 关于对话框显示版本信息

- [ ] **Step 6: 检查无 QML 运行时错误**

Run: `journalctl --user -u dde-shell@DDE -n 50 --no-pager | grep -i "qml\|error" | head -20`
Expected: 无 QML 加载或运行时错误。

---

## Self-Review

**Spec 覆盖检查：**
- §1 任务栏图标区 → Task 1 (颜色/函数) + Task 2 (布局) ✓
- §2 左键弹出面板 → Task 4 ✓
- §3 右键菜单 → Task 5 ✓
- §4 Tooltip → Task 3 ✓
- §5 视觉规范 → Task 1 (颜色表) + 各任务内尺寸 ✓
- §6 排除项 → Global Constraints 明确 ✓

**占位符扫描：** 无 TBD/TODO，所有代码块完整。

**类型一致性：**
- `formatSpeedShort` 在 Task 1 定义，Task 2/3 使用 ✓
- `downloadValueColor`/`uploadValueColor` 在 Task 1 定义，Task 2/4 使用 ✓
- `accentGreen`/`accentGreenLight` 在 Task 1 定义，Task 4 使用 ✓
- 颜色派生自 `basePalette` 全局一致 ✓

**已知风险：**
- Task 5 Step 1 的 `Instantiator`+`insertItem`/`removeItem` 写法在不同 QtQuick.Controls 版本可能有差异，提供了 Repeater 备选方案。
- 右键菜单的 `contextMenu.popup()` 默认在鼠标位置弹出，dde-shell 环境下应正常工作；如定位异常可改用 `contextMenu.popup(mouseX, mouseY)`。
