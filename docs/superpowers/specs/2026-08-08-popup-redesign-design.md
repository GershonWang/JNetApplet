# 左键弹窗重新设计

> 日期：2026-08-08
> 状态：已批准，待制定实现计划
> 涉及文件：`NetworkPopup.qml`、`NetCommon.qml`、`SettingsWindow.qml`、`networkview.qml`

## 背景与问题

当前左键弹窗（`NetworkPopup.qml`）存在以下设计问题（基于截图分析 + 代码阅读）：

1. **深色模式下文字对比度极低**：卡片背景 `cardBackground` 仅 6% 透明度，在 PanelPopup 自动提供的毛玻璃上几乎不可见，导致区域"糊"在一起，且遮挡了原生通透感。
2. **IPv6 地址拥挤**：长 IPv6 地址撑满接口信息卡片，破坏平衡。
3. **底部 chip 未选中态过弱**：未选中 chip 用 `cardBackground` 填充几乎不可见，缺乏交互暗示。
4. **箭头图标风格不统一**：速度区用圆形底色块 + 文本箭头，累计区用纯文本箭头。
5. **冗余标题**：弹窗本身就是网络监控，标题"网络速度监控"浪费空间且字号小发闷。
6. **字号层次不足**：速度数值 18px 不够突出，与标签层次差距小。

### 关键技术发现（librarian 研究）

`PanelPopup`（dde-shell 源码实测）已自动提供：
- **毛玻璃背景**（`enableBlurWindow: true`，透明度跟随系统外观设置）
- **圆角**（跟随系统 `windowRadius`，fallback 4px）
- **阴影**（偏移 `(0, 25)`，深色 50% 黑 / 浅色 20% 黑）

官方参考（`PanelPluginPage.qml`）：内容区宽度 330px，内边距 10px，元素间距 10px。DTK 字号表 T3=24px、T6=14px、T7=13px、T8=12px。

**结论：弹窗内不应自绘背景卡片，应让 PanelPopup 的毛玻璃直接透出，用分隔线 + 留白划分区域。**

## 设计目标

- 重新设计布局结构（非仅视觉微调）
- 速度与接口信息并重（用户第一眼需求）
- Deepin 原生风格（毛玻璃通透、DTK 字号、系统调色板）
- 适配用户配置：字体颜色、网卡类型图标、预留字号缩放

## 设计方案

选定方案 A：**通透分区，速度为锚点**。去掉所有自绘卡片背景，用分隔线 + 留白划分区域，速度数字放大为视觉锚点。

### 第 1 节：整体布局结构

**容器调整**（`networkview.qml`）：
- `PanelPopup` 宽度从 360 -> **330px**（对齐官方 `PanelPluginPage` 参考值）
- 高度从固定 320 -> **跟随内容**（预估约 230px，若 PanelPopup 不支持自动高度则 fallback 固定 230）
- padding 从 16 -> **12px**，区域间 spacing 12 -> **10px**

**纵向布局**（4 个分区 + 3 条分隔线，自上而下）：

```
┌───────────────────────────────┐
│  接口信息区  (次要)            │   行1: ∿ wlp3s0 · 192.168.3.83
│                               │   行2: IPv6 截断显示 + tooltip
│ ───────────────────────────── │ ← 分隔线1
│  速度区  (锚点, 最大视觉权重)  │   ↓ 4.11 KB/s    ↑ 3.55 KB/s
│ ───────────────────────────── │ ← 分隔线2
│  累计流量区  (紧凑)            │   总计 ↓ 4.85 GB  ↑ 134 MB
│ ───────────────────────────── │ ← 分隔线3
│  接口切换 chip 区              │   [enp2s0] [wlp3s0] [Meta]
└───────────────────────────────┘
```

**关键变化**：
- 去掉冗余标题"网络速度监控"
- 移除所有自绘卡片 `Rectangle` 背景填充，毛玻璃直接透出
- 分隔线用 `cardBorder` 色（0.10 透明度）1px 横线，替代原来的卡片边界

### 第 2 节：配色与字体层次

保留 `NetCommon.qml` 的颜色定义和格式化函数不变（networkview.qml 和 TrafficChartWindow 共享），仅改 `NetworkPopup.qml` 内的使用方式。

| 元素 | 颜色 | 字号(DTK) | 字重 |
|---|---|---|---|
| 接口名 `wlp3s0` | `primaryText`(用户色或0.95) | T7(13px) | Normal |
| 接口类型图标 `∿` | `tertiaryText`(0.65) | T8(12px) | Normal |
| IPv4 地址 | `secondaryText`(0.80) | T7(13px) | Normal |
| IPv6 地址 | `tertiaryText`(0.65) | T8(12px) | Normal |
| 下载/上传标签 `下载` | `secondaryText`(0.80) | T8(12px) | Normal |
| **速度数值** `4.11` | **蓝/绿强调色**(下载带阈值变色) | **T3(24px)** | **Bold** |
| 速度单位 `KB/s` | 强调色(同数值) | T7(13px) | Normal |
| `总计` 标签 | `tertiaryText`(0.65) | T8(12px) | Normal |
| 累计数值 | `primaryText`(用户色或0.95) | T7(13px) | Normal |
| 累计箭头 `↓↑` | 蓝/绿强调色 | T8(12px) | Bold |
| chip 选中文字 | white | T8(12px) | Bold |
| chip 未选中文字 | `primaryText`(用户色或0.95) | T8(12px) | Normal |
| 分隔线 | `cardBorder`(0.10) | - | - |

**关键变化**：
1. 速度数字从 18px -> 24px(T3)，成为绝对视觉锚点
2. 箭头图标统一为文本符号（去掉速度区的 32x32 圆形底色块），速度区和累计区风格一致
3. 速度数值和单位拆分显示：`4.11` 大号粗体 + `KB/s` 小号
4. 下载值保留阈值变色逻辑（>10MB/s 红、>1MB/s 橙、否则蓝），上传固定绿

### 第 3 节：各分区内部布局细节

#### 3.1 接口信息区（顶部）

```
│  ∿ wlp3s0 · 192.168.3.83              │   行1: 类型图标 + 接口名 + 中点 + IPv4
│  IPv6 2408:823c:9c12:a69:...:3      │   行2: IPv6 截断显示
```

- 行1：接口类型图标 + 接口名 + `·` + IPv4，用 `secondaryText`/`tertiaryText`，T7 13px
- 行2：`IPv6` 标签 + 地址。地址超长时截断显示，末尾加 `…`，hover 显示完整地址 tooltip
- 整体水平居中，垂直间距 4px
- 无 IPv6 时只显示行1

#### 3.2 速度区（锚点）

```
│     ↓ 4.11 KB/s      ↑ 3.55 KB/s    │
```

- 双栏等宽，中间无竖线（靠留白区分）
- 每栏内部布局：
  ```
  下载          (T8 12px, secondaryText, 居中)
  ↓ 4.11 KB/s   (↓+数值 T3 24px Bold 强调色, KB/s T7 13px)
  ```
- 下载/上传标签在上方居中小字，下方是箭头 + 大号数值 + 小号单位

#### 3.3 累计流量区

```
│  总计  ↓ 4.85 GB  ↑ 134 MB          │
```

- 单行紧凑，水平居中
- `总计` 标签 tertiaryText，箭头蓝/绿强调色 Bold，数值 primaryText

#### 3.4 接口切换 chip 区

```
│  [enp2s0]  [wlp3s0]  [Meta]         │
```

- chip 样式重做：
  - **选中态**：蓝色填充背景 `accentBlue` + 白字 + 蓝色边框（保持不变）
  - **未选中态**：**透明背景** + `cardBorder` 边框 + primaryText 文字（原来是 cardBackground 填充几乎不可见）
  - hover：边框变 `accentBlue`，文字变 `accentBlue`
- 宽度逻辑、滚动逻辑、`scrollToActiveChip`、`sortedInterfaces`、`Connections` 全部保留不变

#### 3.5 分隔线

- 3 条横线，分别在：接口区下方、速度区下方、累计区下方
- 颜色 `cardBorder`(0.10 透明度)，高度 1px，撑满 padding 内宽度

### 第 4 节：错误态与尺寸约束

#### 4.1 未检测到接口的占位态

```
┌───────────────────────────────┐
│            ⚠                  │   (T1 40px, tertiaryText)
│   未检测到网络接口             │   (T6 14px, secondaryText)
└───────────────────────────────┘
```

- 去掉卡片背景填充，直接在毛玻璃上居中
- 警告图标从 24px -> 40px(T1)，更醒目
- 占位态时不显示分隔线、速度区、累计区、chip 区

#### 4.2 尺寸与高度自适应

- 宽度固定 330px（`networkview.qml` 的 `PanelPopup` 设置）
- 高度跟随内容（预估约 230px）。各分区预估高度：
  - 接口区：~40px（两行）
  - 分隔线：1px + 上下 10px spacing
  - 速度区：~60px（标签 + 大号数值）
  - 累计区：~30px
  - chip 区：40px
  - padding 上下各 12px
  - 合计：~213px
- 若 PanelPopup 不支持自动高度，fallback 为固定 `height: 230`

### 第 5 节：可配置适配

#### 5.1 字体颜色适配（仅主要文字跟随用户色）

`NetworkPopup.qml` 新增属性覆盖：

```qml
// 用户自定义字体色（来自 C++ 后端 applet.textColor，持久化到 settings.ini）
// 非空时覆盖 primaryText，空串时回退到 DTK 调色板派生（保持自适应）
readonly property string userTextColor: applet ? applet.textColor : ""
readonly property color primaryText: userTextColor.length > 0
    ? Qt.rgba(userTextColor.r, userTextColor.g, userTextColor.b, 0.95)
    : common.primaryText
```

**跟随范围**（用 `popup.primaryText` 的元素）：
- 接口名 `wlp3s0`
- 速度数值 `4.11`（注意：下载值有阈值变色逻辑，用户色不覆盖蓝/橙/红阈值色，仅覆盖"未超阈值"时的回退色）
- 累计数值 `4.85 GB`
- chip 未选中文字

**不跟随**（仍从 `common` 取 DTK 派生）：
- `secondaryText`（IPv4、标签）
- `tertiaryText`（IPv6、总计标签）
- 蓝绿强调色（下载/上传箭头、chip 选中态）

> 用户选了红色时，弹窗的接口名、数值、chip 文字变红，但标签和辅助信息仍保持系统主题色，层次不崩。

#### 5.2 网卡类型图标（接口信息区）

**提取公共函数**：将 `SettingsWindow.qml` 中的 `interfaceIcon(name)` 和 `interfaceDescription(name)` 提取到 `NetCommon.qml`，消除重复定义。

**弹窗接口信息区布局更新**：
- 接口名前加类型图标，与设置窗口列表的图标一致
- 图标颜色 `tertiaryText`（次要，不抢速度区焦点）
- 图标字号 T8(12px)，与接口名行对齐

#### 5.3 字号缩放预留（fontScale）

`NetworkPopup.qml` 新增属性：

```qml
// 字号缩放因子：默认 1.0，后续 C++ 后端新增 applet.fontScale 后绑定
// 所有字号 = 基准字号 × fontScale，实现全局字号调节
readonly property real fontScale: (applet && applet.fontScale !== undefined)
    ? applet.fontScale : 1.0
```

**所有 `font.pixelSize` 改为缩放形式**：

| 元素 | 基准字号 | 缩放后 |
|---|---|---|
| 速度数值 | 24 | `Math.round(24 * fontScale)` |
| 速度单位 | 13 | `Math.round(13 * fontScale)` |
| 接口名/IPv4 | 13 | `Math.round(13 * fontScale)` |
| IPv6/标签/箭头 | 12 | `Math.round(12 * fontScale)` |
| chip 文字 | 12 | `Math.round(12 * fontScale)` |
| 占位图标 | 40 | `Math.round(40 * fontScale)` |
| 占位文字 | 14 | `Math.round(14 * fontScale)` |

**当前状态**：`applet.fontScale` 尚不存在，`fontScale` 恒为 1.0，视觉无变化。后续 C++ 后端加属性 + 设置窗口加选项后即可生效，弹窗代码无需再改。

## 影响范围

| 文件 | 改动 |
|---|---|
| `NetCommon.qml` | 新增 `interfaceIcon`/`interfaceDescription` 公共函数（从 SettingsWindow 迁移） |
| `NetworkPopup.qml` | 重写布局（主体工作）+ 新增 `userTextColor`/`fontScale`/`primaryText` 覆盖 |
| `SettingsWindow.qml` | `interfaceIcon`/`interfaceDescription` 改为调用 `common.xxx`（消除本地重复定义） |
| `networkview.qml` | 仅改 `PanelPopup` 的 width/height 两个数值 |
| C++ 后端 | **本次不改**（fontScale 预留扩展点，后续再加） |

## 保持不变的部分

- `NetCommon.qml` 的颜色定义和格式化函数（networkview.qml 和 TrafficChartWindow 共享）
- chip 滚动逻辑、`scrollToActiveChip`、`sortedInterfaces`、`Connections`
- `TrafficChartWindow.qml`、`AboutWindow.qml`
- C++ 后端
- 深浅主题适配机制（颜色派生自 `DTK.palette.windowText`，自动切换）

## 验证方式

本项目无测试/lint/CI 目标，验证为手动：
1. `cmake -B build && cmake --build build && sudo cmake --install build`
2. `systemctl --user restart dde-shell@DDE`
3. 左键点击任务栏网络监控图标，检查弹窗：
   - 毛玻璃通透，无卡片填充色块
   - 速度数字 24px 为视觉锚点
   - 接口信息区显示类型图标
   - chip 未选中态有清晰边框
   - 分隔线划分四个区域
4. 深色/浅色模式切换，检查文字对比度
5. 设置窗口选字体颜色，检查弹窗主要文字是否跟随
6. 切换网卡，检查 chip 滚动和接口信息更新
