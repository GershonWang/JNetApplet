// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 网络状态的纯判定逻辑（无 IO、无状态、无 deepin 依赖）。
//
// 为什么需要这个文件：这些判定决定"任务栏显示 — 还是数字""某接口是否参与合计"
// "是否该提醒用户超量"，全是分支密集、易错、且完全可以用样本断言的部分。
// 抽离后可随 tests/core/ 在任意装有 qt6-base-dev 的机器上运行（含 CI）。
#pragma once

#include <QString>

namespace JNetCore {

// 由 carrier 与 operstate 判定链路是否断开。
// carrier 取 -1（读不到）/0（无载波）/1（有载波），operState 取 sysfs 原文小写。
//
// 规则按顺序短路，先命中先返回。优先级依据：operstate 是内核给出的权威状态，
// 只要它明确表态（up 或 down/dormant 等）就以它为准；只有它含糊（unknown/读不到）
// 时才回退看 carrier。
//   1. operstate == "up"   → 未断开（存在 operstate 为 up 而 carrier 为 0 的驱动）
//   2. carrier == 0        → 断开（拔网线、接口 down、WiFi 未关联）
//   3. operstate 明确为非 unknown → 断开
//   4. 其余（operstate 含糊、carrier 读不到或非 0）→ 未断开：宁可漏报不误报
// 真机教训：初版把 carrier < 0 放最前一律判"未断开"，而 WiFi 断开后
// carrier 读取返回 EINVAL（-1）、operstate 已明确为 down，导致断连态永不显示。
bool isLinkDown(int carrier, const QString &operState);

// 按命名约定判断是否为无线接口（wlp / wlan / wlo / wlx）。
// 注意：这只是**回退判据**。更可靠的判据是探测内核是否暴露
// /sys/class/net/<iface>/wireless 目录，那部分涉及文件系统访问，
// 保留在 NetworkMonitorApplet::isWirelessInterface() 中（切分点：纯命名 vs IO）。
bool isWirelessByPrefix(const QString &iface);

// 判断是否为物理网卡（用于"自动选择默认接口"与"多接口聚合"）。
//
// 实现是**排除已知虚拟接口**而非白名单：板载网卡常见 eno1、虚拟机常见 ens33、
// USB 有线常见 enx<MAC>，白名单（enp/eth）会把这些全判为"非物理"，
// 后果是自动选择跳过主网卡、聚合静默漏算流量。排除法天然覆盖未知命名。
//
// 虚拟接口：lo / Meta（精确）；tun / tap / docker / veth / br- / virbr / vnet /
// ifb（前缀）；wg 单独要求 ^wg\d+$——WireGuard 隧道是 wg0/wg1，
// 而无线 p2p 接口 wgp2s0 以 wg 开头却属于物理网卡。
bool isPhysicalInterface(const QString &iface);

// 判断本次是否应当发出流量超限提醒。
//   usedBytes      当前周期已用字节
//   limitGb        阈值（十进制 GB，<=0 表示关闭）
//   currentPeriod  当前周期键（"yyyy-MM-dd" 或 "yyyy-MM"）
//   notifiedPeriod 上次已提醒的周期键（空串表示从未提醒）
// 规则：阈值已启用 且 已用量达标 且 本周期尚未提醒。
// limitGb 须排除 NaN 与无穷大：+infinity 也满足 `> 0`，若不显式排除，
// 字节换算会得到未定义结果（实测曾把 inf 写进配置）。
bool shouldNotifyQuota(qint64 usedBytes, double limitGb,
                       const QString &currentPeriod,
                       const QString &notifiedPeriod);

}   // namespace JNetCore
