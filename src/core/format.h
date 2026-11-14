// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 面向展示的格式化与数值归一化（纯函数，无 IO、无状态、无 deepin 依赖）。
//
// 为什么需要这个文件：速度单位换算（智能自动 / 固定 KB/s / 固定 Mbps）、
// CSV 字段转义、阈值输入归一化这三类逻辑分支密集、边界多，且此前完全没有
// 独立测试覆盖——它们只随着集成测试间接执行，而集成测试在没有 deepin 的
// 环境（含 CI）里根本跑不起来。抽到 core 后可随 tests/core 一起被执行。
#pragma once

#include <QString>

namespace JNetCore {

// 速度显示单位取值（与 C++ Q_PROPERTY speedUnit 对应）
constexpr int SpeedUnitAuto = 0;   // 智能自动：KB/s → MB/s → GB/s
constexpr int SpeedUnitKBps = 1;   // 固定千字节每秒（二进制）
constexpr int SpeedUnitMbps = 2;   // 固定兆比特每秒（十进制，运营商口径）

// 带单位的完整速度字符串，如 "4.11 MB/s"、"33.70 Mbps"。
// 负值/NaN 一律按 0 显示（上游已做钳制，这里是防御性兜底，
// 避免异常值在界面上显示成 "-1.00 KB/s"）。
//
// 三档口径：
//   Auto   二进制阶梯，2 位小数，与历史版本观感一致；
//   KBps   固定千字节每秒，**不做自适应换挡**（用户显式选择的口径，不应擅自改成 MB/s）；
//   Mbps   bytes × 8 / 1e6，与运营商宽带速率定义一致（1 MB/s ≈ 8.39 Mbps）。
QString formatSpeed(double bytesPerSec, int unit);

// 任务栏用的紧凑写法（无空格），如 "194.07K"、"0.85Mbps"。
// intPart 为 true 时只返回数值部分（不含单位缩写）——任务栏采用
// "整数部分右对齐 + 小数部分左对齐"的两段式渲染来对齐小数点。
QString formatSpeedCompact(double bytesPerSec, int unit, bool intPart);

// CSV 字段转义（RFC 4180）。
// 字段含逗号、双引号或换行时整体加引号，内部双引号成对转义。
// 当前接口名（eno1/wlo1）不会触发，但这是 CSV 正确性问题——
// 用户可能改过配置、将来也可能支持自定义别名，届时坏掉极难排查。
QString csvEscape(const QString &field);

// 流量阈值输入归一化：负数、0、NaN、无穷大一律归为 0（表示关闭提醒）。
// 设计原因：QML 侧是文本输入框，用户可能键入 "-1"、空串或异常字符；
// 若不收敛，脏值会被持久化并在下次启动时参与换算，导致提醒永不触发且无提示。
// 注意 +infinity 也满足 `> 0`，故不能只判 `> 0`（实测曾把 inf 写进配置）。
double normalizeLimitGb(double gb);

}   // namespace JNetCore
