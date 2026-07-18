# JNetApplet UI 重新设计规范

**日期**：2026-07-18
**范围**：`package/networkview.qml` 单文件
**方案**：A - 精简重塑（deepin 原生简约风）

## 背景与目标

当前 JNetApplet 任务栏图标在 ~48px dock 区域内塞入圆圈边框 + 4 行内容（↓/下载速度/↑/上传速度），视觉拥挤；左键弹出面板色调偏灰、层次弱、接口切换 `ComboBox` 不够直观；右键行为未实现。

本次重新设计目标：

- 任务栏展示精简、易读，跟随 deepin 任务栏视觉语言
- 左键弹出面板信息层次清晰、视觉舒适
- 新增右键菜单提供快捷操作
- 全部颜色派生自 `DockPalette`，深/浅色任务栏自适应

## 范围

**包含**：

- `package/networkview.qml` 全部重写
- 任务栏图标区、左键弹出面板、右键菜单、Tooltip 四处视觉与交互

**排除**（YAGNI）：

- 不改 C++ 后端（`networkmonitorapplet.h/.cpp`）
- 不新增 `Q_PROPERTY` 或 `Q_INVOKABLE`
- 不引入设置面板（刷新间隔、单位制等）
- 不加历史趋势图表、sparkline
- 不持久化任何用户配置
- 不改 `metadata.json`、`CMakeLists.txt`

## 设计决策记录

| 决策点 | 选择 | 理由 |
|---|---|---|
| 整体风格 | deepin 原生简约风 | 跟随宿主环境视觉语言，自适应深/浅色 |
| 任务栏展示 | 双行数值（↓下载/↑上传） | 信息密集但不拥挤，无需 hover 即可读 |
| 右键行为 | deepin 风格 Menu | 符合 deepin 交互习惯，提供快捷操作 |
| 设置项 | 不做 | 控制范围，避免不持久化带来的困惑 |
| 历史图表 | 不做 | 超出"重新设计样式与交互"范围 |

## §1. 任务栏图标区（dock item）

### 布局

- 移除当前圆圈 `Rectangle` 容器
- 双行 `Column` 居中：
  - 上行：小号 `↓` + 下载速度数值（如 `1.2M`）
  - 下行：小号 `↑` + 上传速度数值（如 `256K`）
- 箭头与数值同行，箭头为次级色、数值为强调色

### 新格式化函数 `formatSpeedShort(bytesPerSec)`

紧凑格式，用于任务栏与 tooltip：

| 字节范围 | 输出 |
|---|---|
| `< 1024` | 整数 B/s，如 `"512"` |
| `< 1024²` | 1 位小数 + `K`，如 `"1.2K"` |
| `< 1024³` | 1 位小数 + `M`，如 `"3.5M"` |
| `≥ 1024³` | 1 位小数 + `G`，如 `"2.4G"` |

保留原 `formatSpeed` / `formatTotal` 函数供弹出面板使用（带单位更清晰）。

### 字号与字重

- 箭头：`dockSize * 0.16`
- 数值：`dockSize * 0.22`（当前 0.12 太小）
- 数值字重：`Font.Medium`

### 颜色

- 下载值：`accentBlue` (`#1450A0`)
- 上传值：`accentGreen` (`#16A34A`)
- 高速警示（保留现有阈值逻辑）：
  - 下载 > 10 MB/s：红 (`#DC2626`)
  - 下载 > 1 MB/s：橙 (`#F59E0B`)

## §2. 左键弹出面板（popup）

### 尺寸

从 `400×350` 调整为 `360×320`（更紧凑）。

### 结构（顶到底）

1. **标题栏**
   - 左：主标题「网络速度监控」+ 副标题（活动接口名，次级色 12px）
   - 右：圆形刷新按钮（hover 高亮 + 旋转动画）

2. **实时速度卡片**（主视觉）
   - 横向双列布局
   - 左列：`↓` 圆形底（`accentBlueLight` 背景）+ 「下载」标签 + 大字号速度值（蓝）
   - 右列：`↑` 圆形底（`accentGreenLight` 背景）+ 「上传」标签 + 大字号速度值（绿）
   - 数值字号 22px、字重 Bold
   - 使用 `formatSpeed`（带单位，更清晰）

3. **总量统计**
   - 单行紧凑横向布局
   - 「总计」标签 + `↓ 1.07 GB` + `↑ 74.8 MB`
   - 字号 12px、次级色

4. **接口切换 chip 列表**（仅当 `networkInterfaces.length > 1` 时显示）
   - 横向排列，每个接口一个圆角 chip（`radius: 8`）
   - 当前活动 chip：`accentBlue` 背景 + 白字
   - 其他 chip：`cardBackground` + `primaryText`
   - hover：`accentBlueLight` 背景
   - 点击触发 `applet.setActiveInterface(name)`

5. **未检测到接口占位**
   - 保留现有卡片样式
   - 文案居中：`⚠` + 「未检测到网络接口」

### 视觉

- 卡片圆角 12px
- 内边距 16px、卡片内边距 12px、元素间距 12px
- 分隔线：`cardBorder` 色、1px

## §3. 右键菜单（新功能）

### 触发

在现有 `TapHandler`（左键）旁新增 `TapHandler` 处理 `Qt.RightButton`，调用 `menu.popup()`。

### 菜单项

```
刷新
─────────────
切换接口  ▸   （子菜单）
─────────────
关于
```

### 行为

- **刷新**：调用 `applet.refresh()`
- **切换接口子菜单**：
  - 动态构建 `MenuItem`，绑定 `networkInterfaces`
  - 当前 `activeInterface` 项打勾（`checkable: true`、`checked: true`）
  - 点击触发 `applet.setActiveInterface(name)`
  - 接口数 ≤ 1 时禁用此项
- **关于**：弹出小型 `Dialog`
  - 插件名：网络速度监控
  - 版本：1.0（硬编码，与 `metadata.json` 一致）
  - 描述：监控网络速度和流量

### 实现要点

- 使用 `QtQuick.Controls` 的 `Menu`（deepin DTK 自动适配风格）
- `Menu` 作为 root 的子元素，id 为 `contextMenu`
- 子菜单用 `Menu` 嵌套

## §4. Tooltip

单行简洁：

```
↓ 1.2M/s   ↑ 256K/s   ·   eth0
```

- 方向箭头用对应强调色（下载蓝、上传绿）
- 接口名前用 `·` 分隔
- 复用 `formatSpeedShort` 保持与任务栏一致
- 未检测到接口时显示「未检测到网络接口」

## §5. 视觉规范

### 颜色派生表

| 用途 | 计算 |
|---|---|
| 主文字 `primaryText` | `basePalette` α 0.95 |
| 次级文字 `secondaryText` | `basePalette` α 0.80 |
| 三级文字 `tertiaryText` | `basePalette` α 0.65 |
| 卡片背景 `cardBackground` | `basePalette` α 0.06 |
| 卡片边框 `cardBorder` | `basePalette` α 0.10 |
| 强调蓝 `accentBlue` | `#1450A0` |
| 强调蓝浅 `accentBlueLight` | `#1450A0` α 0.12 |
| 强调绿 `accentGreen` | `#16A34A` |
| 强调绿浅 `accentGreenLight` | `#16A34A` α 0.12 |
| 高速橙 `accentOrange` | `#F59E0B` |
| 高速红 `accentRed` | `#DC2626` |

### 尺寸规范

- 卡片圆角：12px
- chip 圆角：8px
- 按钮圆角：6px
- 面板内边距：16px
- 卡片内边距：12px
- 元素间距：12px

### 字体

跟随系统无衬线字体，不指定 family。字重使用 `Font.Medium` / `Font.Bold`。

## 实现性质

- **文件**：仅 `package/networkview.qml`
- **风险**：低（纯前端、不动后端、不改构建）
- **验证**：手动安装 + 重启 dde-shell

## 验证清单

安装后重启 dde-shell，依次检查：

- [ ] 任务栏图标：双行数值显示，下载在上、上传在下
- [ ] 任务栏图标：颜色正确（下载蓝、上传绿）
- [ ] 任务栏图标：高速时下载值变橙/红
- [ ] 任务栏图标：深色任务栏下文字可读
- [ ] 任务栏图标：浅色任务栏下文字可读
- [ ] 悬停 tooltip：单行显示 ↓↑速度 + 接口名
- [ ] 左键弹出：尺寸 360×320
- [ ] 左键弹出：标题栏 + 接口名副标题
- [ ] 左键弹出：实时速度双列卡片
- [ ] 左键弹出：总量统计单行
- [ ] 左键弹出：接口 chip 列表（多接口时）
- [ ] 左键弹出：刷新按钮 hover + 旋转动画
- [ ] 左键弹出：未检测到接口时显示占位
- [ ] 右键菜单：弹出 deepin 风格菜单
- [ ] 右键菜单：刷新项可用
- [ ] 右键菜单：切换接口子菜单列出接口、当前项打勾
- [ ] 右键菜单：接口数 ≤ 1 时切换项禁用
- [ ] 右键菜单：关于对话框显示版本信息
