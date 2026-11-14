// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 网络状态判定的实现。
// 逻辑从 NetworkMonitorApplet 原样迁移，行为不得改变——迁移后由
// tests/core/tst_core.cpp 用同一批样本（含真机实测的断连组合）断言。
#include "netstate.h"

#include <QRegularExpression>
#include <QRegularExpressionMatch>
#include <QStringList>
#include <QtGlobal>

namespace JNetCore {

bool isLinkDown(int carrier, const QString &operState)
{
    if (operState == QLatin1String("up")) {
        return false;
    }
    if (carrier == 0) {
        return true;
    }
    // 走到这里 operstate 非 up：明确断开态判为断开，
    // 含糊态（unknown/空）继续往下看 carrier
    if (!operState.isEmpty() && operState != QLatin1String("unknown")) {
        return true;
    }
    // operstate 含糊：carrier 读不到则无依据（未知），读得到且非 0 视为可用
    return false;
}

bool isWirelessByPrefix(const QString &iface)
{
    if (iface.isEmpty()) {
        return false;
    }
    // 前缀集合含 wlo（deepin/部分发行版）与 wlx（USB 无线网卡常见命名）
    return iface.startsWith(QLatin1String("wlp"))
        || iface.startsWith(QLatin1String("wlan"))
        || iface.startsWith(QLatin1String("wlo"))
        || iface.startsWith(QLatin1String("wlx"));
}

bool isPhysicalInterface(const QString &iface)
{
    if (iface.isEmpty()) {
        return false;
    }
    // 精确匹配的虚拟接口名
    static const QStringList exactVirtual{
        QStringLiteral("lo"),
        QStringLiteral("Meta"),
    };
    if (exactVirtual.contains(iface)) {
        return false;
    }
    // 注意 wg 的边界：WireGuard 隧道名是 wg0/wg1 这类「wg + 纯数字」，
    // 而无线 p2p 接口是 wgp2s0（以 wg 开头却属于物理网卡）。
    // 这类冲突不能靠加长前缀表穷举，故对 wg 单独要求「其后全为数字」。
    static const QRegularExpression wgTunnelRe(QStringLiteral("^wg\\d+$"));
    if (wgTunnelRe.match(iface).hasMatch()) {
        return false;
    }
    static const QStringList virtualPrefixes{
        QStringLiteral("tun"), QStringLiteral("tap"),
        QStringLiteral("docker"), QStringLiteral("veth"), QStringLiteral("br-"),
        QStringLiteral("virbr"), QStringLiteral("vnet"), QStringLiteral("ifb"),
    };
    for (const QString &prefix : virtualPrefixes) {
        if (iface.startsWith(prefix)) {
            return false;
        }
    }
    return true;
}

bool shouldNotifyQuota(qint64 usedBytes, double limitGb,
                       const QString &currentPeriod,
                       const QString &notifiedPeriod)
{
    // 阈值为 0、负数、NaN 或无穷大 = 关闭提醒。
    // 无穷大若不排除，limitBytes 会溢出成未定义值，可能导致"一启动就提醒"
    if (!qIsFinite(limitGb) || !(limitGb > 0)) {
        return false;
    }
    // 十进制 GB：运营商套餐口径，1 GB = 1000³ 字节
    const qint64 limitBytes = static_cast<qint64>(limitGb * 1000.0 * 1000.0 * 1000.0);
    if (usedBytes < limitBytes) {
        return false;
    }
    // 同一周期只提醒一次；跨周期（键不同）自然重新允许
    return notifiedPeriod != currentPeriod;
}

}   // namespace JNetCore
