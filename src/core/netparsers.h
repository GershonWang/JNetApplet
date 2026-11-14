// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 外部命令输出的纯解析逻辑（无 IO、无状态、无 deepin 依赖）。
//
// 为什么需要这个文件：
// NetworkMonitorApplet 直接继承 DApplet，编译它必须链接 Dtk6::Core 与 Dde::Shell，
// 而这两者只在 deepin 仓库提供——GitHub 托管 runner 上装不了，导致单元测试
// 永远无法进入 CI，只能靠真机手工验证。而本项目的解析逻辑（iw / ss 输出）
// 恰恰是最容易出错、也最适合用样本断言的部分。
//
// 因此把"纯字符串进、结构化数据出"的函数抽到这里：本文件只依赖 Qt6::Core，
// 在任何装了 qt6-base-dev 的机器上都能编译并测试（见 tests/core/）。
// 需要 IO 或子进程的部分（读 /proc、启动 iw）刻意**不抽**——那会变成假抽象。
#pragma once

#include <QString>
#include <QVariantList>

namespace JNetCore {

// 解析 `iw dev <iface> link` 输出中的链路协商速率（Mbps），失败返回 0。
// 真实输出形如：
//     Connected to aa:bb:cc:dd:ee:ff (on wlo1)
//             rx bitrate: 390.0 MBit/s VHT-MCS 8 ...
//             tx bitrate: 866.7 MBit/s VHT-MCS 9 ...
// 三处历史缺陷均在此处修复（详见单元测试用例）：
//   1. bitrate 行带 rx/tx 前缀，并非以 "bitrate:" 开头；
//   2. 单位是 MBit/s（大写 B），按小写匹配会全部失败；
//   3. 真实输出带制表符缩进，不能用 `match(output)` 只从位置 0 尝试。
// 取值优先 tx（发送方向代表协商上限），缺失时回退 rx。
int parseIwBitrate(const QString &output);

// 解析 `iw dev <iface> link` 输出中的 SSID。
// 未连接（只有 "Not connected."）或 SSID 为空时返回空串，由调用方回退显示接口名。
// 必须逐行匹配：`SSID:` 后为空时，多行正则的 \s* 会吃掉换行，
// 把下一行 "freq: 5180" 当成 SSID 返回（该场景有专门的测试用例）。
QString parseIwSsid(const QString &output);

// 解析 `ss -tnp state established` 输出为连接列表。
// 每项为 QVariantMap（键：localAddress/localPort/remoteAddress/remotePort/
// state/processName），仅含 ESTABLISHED。
// 用 QVariantMap 而非中间结构体的原因：QML 侧直接以 JS 对象访问，无需注册元类型。
// 处理要点：IPv6 地址形如 [::1]:port 需去方括号；地址可能带 %iface 后缀需剥离；
// 进程列可能为空（无权限反查时）。
QVariantList parseTcpConnections(const QString &output);

}   // namespace JNetCore
