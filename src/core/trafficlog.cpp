// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 流量日志数据操作的实现。
// 逻辑从 NetworkMonitorApplet 原样迁移，行为不得改变；
// 迁移后由 tests/core/tst_core.cpp 用构造的 JSON 样本断言（含 2^53 边界）。
#include "trafficlog.h"

#include <QJsonValue>
#include <QStringList>
#include <QVariantMap>
#include <algorithm>

namespace JNetCore {

namespace {

// 读取记录里的 rx / tx，走 qint64 而非 double。
// 累计字节数可能超过 2^53，double 会丢精度；Qt6 的 QJsonValue 对整数按整数存储，
// 这条路径无损。
qint64 readBytes(const QJsonObject &rec, const QString &key)
{
    return rec.value(key).toVariant().toLongLong();
}

}   // namespace

void appendTraffic(QJsonObject &log, const QString &iface,
                   const QString &date, const QString &month,
                   qint64 rxDelta, qint64 txDelta)
{
    if (rxDelta <= 0 && txDelta <= 0) {
        return;
    }
    // 由调用方明确指定接口：原先只认"当前活动接口"，导致切换网卡后
    // 另一块网卡的流量完全不计入历史（统计窗口按接口分行展示，却永远缺一行）
    if (iface.isEmpty()) {
        return;
    }

    // 直接取当日/当月键累加：跨日/跨月时键自然变化，新键从零累加，旧键不再增长，
    // 无需维护额外的"上次日期"状态
    QJsonObject byDay = log.value(QStringLiteral("byDay")).toObject();
    QJsonObject dayEntry = byDay.value(date).toObject();
    QJsonObject ifaceDay = dayEntry.value(iface).toObject();
    ifaceDay[QStringLiteral("rx")] = readBytes(ifaceDay, QStringLiteral("rx")) + rxDelta;
    ifaceDay[QStringLiteral("tx")] = readBytes(ifaceDay, QStringLiteral("tx")) + txDelta;
    dayEntry[iface] = ifaceDay;
    byDay[date] = dayEntry;
    log[QStringLiteral("byDay")] = byDay;

    QJsonObject byMonth = log.value(QStringLiteral("byMonth")).toObject();
    QJsonObject monthEntry = byMonth.value(month).toObject();
    QJsonObject ifaceMonth = monthEntry.value(iface).toObject();
    ifaceMonth[QStringLiteral("rx")] = readBytes(ifaceMonth, QStringLiteral("rx")) + rxDelta;
    ifaceMonth[QStringLiteral("tx")] = readBytes(ifaceMonth, QStringLiteral("tx")) + txDelta;
    monthEntry[iface] = ifaceMonth;
    byMonth[month] = monthEntry;
    log[QStringLiteral("byMonth")] = byMonth;
}

void pruneTraffic(QJsonObject &log, int maxDays, int maxMonths)
{
    QJsonObject byDay = log.value(QStringLiteral("byDay")).toObject();
    QStringList dayKeys = byDay.keys();
    dayKeys.sort();
    while (dayKeys.size() > maxDays) {
        byDay.remove(dayKeys.first());
        dayKeys.removeFirst();
    }
    log[QStringLiteral("byDay")] = byDay;

    QJsonObject byMonth = log.value(QStringLiteral("byMonth")).toObject();
    QStringList monthKeys = byMonth.keys();
    monthKeys.sort();
    while (monthKeys.size() > maxMonths) {
        byMonth.remove(monthKeys.first());
        monthKeys.removeFirst();
    }
    log[QStringLiteral("byMonth")] = byMonth;
}

QVariantList flattenTraffic(const QJsonObject &log, const QString &section)
{
    const QJsonObject periods = log.value(section).toObject();

    // 周期键降序（"yyyy-MM-dd"/"yyyy-MM" 字典序即时间序）
    QStringList dates = periods.keys();
    dates.sort();
    std::reverse(dates.begin(), dates.end());

    QVariantList rows;
    for (const QString &date : dates) {
        const QJsonObject interfaces = periods.value(date).toObject();
        // 同一周期内按接口名升序
        QStringList names = interfaces.keys();
        names.sort();
        for (const QString &iface : names) {
            const QJsonObject rec = interfaces.value(iface).toObject();
            const qint64 rx = readBytes(rec, QStringLiteral("rx"));
            const qint64 tx = readBytes(rec, QStringLiteral("tx"));

            QVariantMap row;
            row[QStringLiteral("date")] = date;
            row[QStringLiteral("iface")] = iface;
            row[QStringLiteral("rx")] = rx;
            row[QStringLiteral("tx")] = tx;
            row[QStringLiteral("total")] = rx + tx;
            rows.append(row);
        }
    }
    return rows;
}

qint64 periodUsedBytes(const QJsonObject &log, const QString &section,
                       const QString &periodKey)
{
    const QJsonObject periods = log.value(section).toObject();
    const QJsonObject interfaces = periods.value(periodKey).toObject();
    qint64 total = 0;
    for (auto it = interfaces.constBegin(); it != interfaces.constEnd(); ++it) {
        const QJsonObject rec = it.value().toObject();
        total += readBytes(rec, QStringLiteral("rx"));
        total += readBytes(rec, QStringLiteral("tx"));
    }
    return total;
}

}   // namespace JNetCore
