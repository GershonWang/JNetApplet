# JNetApplet 项目审查清单

> 审查日期：2026-07-22
> 审查范围：全部源码（C++ 后端 + QML 前端 + 构建脚本 + 文档）

---

## 一、缺陷（Bug / 逻辑错误）

### 🔴 高优先级

**1. ~~速度计算假设定时间隔严格为 1 秒~~ ✅ 已修复**
~~`calculateSpeed()` 直接用 `currentRxBytes - m_lastRxBytes` 作为 bytes/sec，未除以实际流逝时间。系统负载高或定时器抖动时，速度值会失真。~~
已改为记录上次采样的毫秒时间戳 `m_lastTimestampMs`，按真实流逝时间 `delta_bytes / elapsed_seconds` 计算速度；速度存储由 `qint64` 改为 `double` 保留精度；`elapsedSec > 0` 守卫避免除零。

**2. ~~计数器回绕/重置产生负速度~~ ✅ 已修复**
~~网卡重启、`/proc/net/dev` 计数器溢出或接口重置时，`currentRxBytes - m_lastRxBytes` 可能为负。代码无任何兜底，QML 会显示负速度。~~
已在 `calculateSpeed()` 中对 `rxDelta` / `txDelta` 钳制为 0，计数器回绕/接口重置/网卡重启时不再产生负速度。

**3. ~~"总量统计"语义有误导~~ ✅ 已修复**
~~`m_totalDownload = currentRxBytes` 只存储活动接口的当前计数器值，并非真正的累计流量。~~
已改为累加会话增量 `m_totalDownload += rxDeltaClamped`，"总计"语义从"活动接口计数器值"变为"本次会话累计流量"：从 0 开始增长，切换网卡不再跳变，网卡重启不归零。跨重启持久化属于 #18 的范畴。

**4. ~~独立窗口不支持深色模式~~ ✅ 已修复**
~~`AboutWindow.qml`、`SettingsWindow.qml`、`TextColorPicker.qml`、`TrafficChartWindow.qml` 全部硬编码浅色，不随系统主题适配。~~
已为 4 个独立窗口新增 `isDarkMode` 属性（由 networkview.qml 检测后注入），各窗口定义深/浅双色方案切换。深色模式检测改用 `DTK.palette.window.hslLightness < 0.5`（原 `DockPalette.iconTextPalette` 不随系统主题变化）。同时修复 networkview.qml 任务栏图标和 NetworkPopup 弹窗的颜色基：从 `DockPalette.iconTextPalette` 改为 `DTK.palette.windowText`，解决深色模式黑底黑字问题。

**5. ~~`detectInterfaces()` 过滤规则与 `readNetworkStats()` 不一致~~ ✅ 已修复**
~~`init()` 先调 `detectInterfaces()`（仅过滤 `lo`），再调 `readNetworkStats()`（过滤 `lo`/`veth`/`docker`/`br-`），首次刷新前 docker/veth 接口短暂出现造成 UI 闪烁。~~
已将 `detectInterfaces()` 的过滤规则统一为与 `readNetworkStats()` 一致（`lo`/`veth*`/`docker*`/`br-*`）。

### 🟡 中优先级

**6. ~~`setActiveInterface()` 不校验接口有效性~~ ✅ 已修复**
~~可传入不存在的接口名，会被持久化到配置文件，当前会话期间速度恒为 0。~~
已在方法入口增加 `m_interfaceList.contains(interface)` 校验，无效接口名直接忽略。

**7. ~~速度历史仅记录活动接口~~ ✅ 已修复**
~~`m_speedHistory` 每秒只给 `m_activeInterface` 追加采样点，非活动接口永不采集，切换到新接口时趋势图为空。~~
已新增 `m_lastRxBytesByIface` / `m_lastTxBytesByIface` 跟踪所有接口的字节基线，`calculateSpeed()` 遍历所有接口采集速度历史。切换接口时趋势图立即有数据。

**8. ~~窗口居中未考虑多显示器~~ ✅ 已修复**
~~`AboutWindow`、`SettingsWindow`、`TrafficChartWindow` 用 `Screen.width/height` 居中，frameless 窗口在多屏环境下可能出现在非预期屏幕。~~
已加 `Screen.virtualX` / `Screen.virtualY` 偏移，窗口在任务栏所在屏幕内居中而非虚拟桌面原点。

**9. ~~SPDX 版权归属为占位符~~ ✅ 已修复**
~~所有文件头 `SPDX-FileCopyrightText: 2024 MyCompany`，"MyCompany" 是模板占位符。~~
已将 8 个源文件的版权头改为 `SPDX-FileCopyrightText: 2026 Jokul`。

**10. ~~`version()` 无兜底~~ ✅ 已修复**
~~若 `pluginMetaData().value("Version")` 返回空（元数据未加载），AboutWindow 版本行显示空白。~~
已在 `version()` 中加兜底：元数据返回空时回退到编译时版本号 `PROJECT_VERSION` 宏。CMakeLists.txt 新增 `target_compile_definitions` 将 `project(VERSION)` 暴露为编译宏。

---

## 二、代码质量 / 可维护性

**11. 大量重复代码跨组件复制**
以下代码在 `networkview.qml` 和 `NetworkPopup.qml` 中完全重复，`formatSpeed` 还在 `TrafficChartWindow.qml` 中第三份拷贝：
- `isPhysicalIf()` 函数
- `sortedInterfaces` 属性
- `formatSpeed()` / `formatTotal()` 函数
- 全套调色板定义（`basePalette`、`primaryText`、`accentBlue`…）
- `downloadValueColor` / `uploadValueColor`

改一处需同步改 2-3 处，极易遗漏。应抽取为公共 QML 文件（如 `Theme.qml` 单例 + `Format.js`）。

**12. 死代码：`interfaceStats` 属性未被使用**
`networkview.qml:43` 绑定了 `interfaceStats` 属性，但从未在任何 UI 中读取。C++ 侧的 `interfaceStats()` 函数和 `Q_PROPERTY` 也是死代码。且其 `QStringList` 用 `|` 分隔符编码结构化数据的方式本身也很脆弱。

**13. 死代码：`refresh()` Q_INVOKABLE 从未被 QML 调用**
注释（networkview.qml:276）说明此前 QML 调 `applet.refresh()` 导致问题后已移除调用，但 C++ 侧的 `Q_INVOKABLE void refresh()` 仍保留。若确无外部调用方，可删除或标注保留原因。

**14. `interfaceStats` 暴露的数据不完整**
`NetworkInterface` 结构体解析了 `rxErrors`/`txErrors`/`rxDropped`/`txDropped`，但 `interfaceStats()` 输出时丢弃了这些字段。若未来要展示丢包/错误率，需补全。

**15. README.md 和 AGENTS.md 严重过时**
- 项目结构只列 `AboutWindow.qml`，实际有 5 个组件（缺 `NetworkPopup`、`SettingsWindow`、`TextColorPicker`、`TrafficChartWindow`）
- README 功能特性未提及：设置窗口、字体颜色自定义、流量波动图、IPv6 显示
- README 写"支持从弹窗一键卸载插件"，但卸载功能实际在设置窗口
- AGENTS.md "Project structure" 同样过时

**16. `qsTr()` 源字符串为中文，无翻译基础设施**
QML 中 `qsTr("网络速度监控")` 等以中文为源串，但项目无 `.ts` 翻译文件、无 `lupdate`/`lrelease` 构建步骤、C++ 无翻译加载逻辑。`qsTr()` 实质为空操作。若仅面向中文用户可接受；若计划国际化，需补全 i18n 基础设施并以英文为源串。

**17. C++ 后端无单元测试**
项目无任何测试。`calculateSpeed`、`readNetworkStats` 的正则解析、`isPhysicalInterface`、`niceCeil`（QML）等纯逻辑函数适合且应该有单元测试覆盖。

---

## 三、可开发的新需求 / 功能增强

### 🟢 推荐开发

| # | 需求 | 说明 | 价值 |
|---|------|------|------|
| 18 | **日/月流量统计持久化** | 将每日累计流量写入 `settings.ini`，重启后保留。弹窗/设置窗口展示今日/本月用量 | 解决缺陷 #3，核心功能提升 |
| 19 | **深色模式适配** | AboutWindow/SettingsWindow/TextColorPicker/TrafficChartWindow 改用 DTK 主题色或 `DockPalette` 派生色 | 解决缺陷 #4，视觉一致性 |
| 20 | **公共代码抽取** | 颜色/格式化/排序逻辑抽取为共享文件，消除 3 处重复 | 解决 #11，降低维护成本 |
| 21 | **文档同步** | 更新 README + AGENTS.md 的项目结构、功能列表、组件说明 | 解决 #15，新人/AI 接手必备 |
| 22 | **网络断连检测** | 活动接口 `operState != Up` 或 IP 丢失时，任务栏显示断连图标 + tooltip 提示 | 用户体验提升 |
| 23 | **全接口持续采样** | 后台为所有接口采集速度历史，切换接口时趋势图立即有数据 | 解决缺陷 #7 |
| 24 | **速度单位切换** | 设置中可选 KB/s（二进制）或 Mbps（十进制），或智能自动切换 | 国际化/习惯适配 |

### 🔵 可选增强

| # | 需求 | 说明 |
|---|------|------|
| 25 | **刷新间隔可配置** | 设置中可选 1s/2s/5s 刷新频率，降低低端设备 CPU 占用 |
| 26 | **流量超限通知** | 设置阈值，下载/上传超限时发送系统通知 |
| 27 | **趋势图时间窗口可选** | 流量波动图支持 5min / 30min / 1h 切换（需持久化历史数据） |
| 28 | **多接口聚合速度** | 任务栏可选显示所有接口合计速度，而非仅活动接口 |
| 29 | **HiDPI 适配** | 独立窗口使用相对尺寸而非固定像素，适配高分辨率屏幕 |
| 30 | **i18n 翻译基础设施** | 源串改英文 + 添加中文 `.ts` + `lrelease` 构建集成 |
| 31 | **DTK 原生窗口框架** | 独立窗口改用 `DWindow` / DTK 窗口装饰，获得原生 deepin 标题栏、圆角、阴影 |
| 32 | **导出流量数据** | 将流量统计导出为 CSV/JSON，便于分析 |
| 33 | **C++ 后端单元测试** | 为速度计算、正则解析、接口检测添加 Qt Test 单元测试 |
| 34 | **丢包/错误率展示** | 弹窗中展示 `rxErrors`/`rxDropped`，网络质量诊断 |
| 35 | **开机自启保障** | 确保 dde-shell 启动时插件自动加载（可能需 dde-shell 配置） |

---

## 优先级建议

**第一优先级**（影响正确性）：#1 速度计算间隔、#2 负速度、#5 接口过滤不一致

**第二优先级**（影响体验）：#4 深色模式、#3 总量语义、#7 历史采样、#15 文档过时

**第三优先级**（工程质量）：#11 重复代码、#12-14 死代码、#17 测试缺失

**第四优先级**（功能扩展）：#18 日/月统计、#22 断连检测、#26 流量通知
