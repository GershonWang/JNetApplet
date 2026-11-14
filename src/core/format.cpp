// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 格式化与归一化的实现。
// 逻辑从 NetworkMonitorApplet 原样迁移，行为不得改变——迁移后由
// tests/core/tst_core.cpp 用三档单位 × 多量级的表驱动断言。
#include "format.h"

#include <QString>
#include <QtGlobal>

namespace JNetCore {

namespace {

// 负值/NaN 一律按 0：上游已做钳制，这里是防御性兜底，
// 避免异常值在界面上显示成 "-1.00 KB/s"。
// 用 !(v > 0) 而非 v < 0：NaN 与任何值比较都为 false，这样能一并覆盖。
double clampToZero(double bytesPerSec)
{
    return (bytesPerSec > 0) ? bytesPerSec : 0.0;
}

}   // namespace

QString formatSpeed(double bytesPerSec, int unit)
{
    bytesPerSec = clampToZero(bytesPerSec);

    if (unit == SpeedUnitMbps) {
        // 字节/秒 → 兆比特/秒：×8 得比特，再除以 1e6（十进制，与运营商口径一致）
        const double mbps = bytesPerSec * 8.0 / 1000000.0;
        return QStringLiteral("%1 Mbps").arg(mbps, 0, 'f', 2);
    }
    if (unit == SpeedUnitKBps) {
        // 固定千字节每秒：不做自适应换挡，数值可能很大（如 12345.67 KB/s），
        // 但这是用户显式选择的口径，不应擅自改成 MB/s
        return QStringLiteral("%1 KB/s").arg(bytesPerSec / 1024.0, 0, 'f', 2);
    }

    // 智能自动：沿用既有的二进制阶梯与两位小数，保持与历史版本一致的观感
    if (bytesPerSec < 1024.0 * 1024.0) {
        return QStringLiteral("%1 KB/s").arg(bytesPerSec / 1024.0, 0, 'f', 2);
    }
    if (bytesPerSec < 1024.0 * 1024.0 * 1024.0) {
        return QStringLiteral("%1 MB/s").arg(bytesPerSec / (1024.0 * 1024.0), 0, 'f', 2);
    }
    return QStringLiteral("%1 GB/s").arg(bytesPerSec / (1024.0 * 1024.0 * 1024.0), 0, 'f', 2);
}

QString formatSpeedCompact(double bytesPerSec, int unit, bool intPart)
{
    bytesPerSec = clampToZero(bytesPerSec);

    QString value;
    QString suffix;

    if (unit == SpeedUnitMbps) {
        // 固定 Mbps 采用两位小数（用户选定口径），如 "0.85Mbps"、"100.00Mbps"
        value = QString::number(bytesPerSec * 8.0 / 1000000.0, 'f', 2);
        suffix = QStringLiteral("Mbps");
    } else if (unit == SpeedUnitKBps) {
        value = QString::number(bytesPerSec / 1024.0, 'f', 2);
        suffix = QStringLiteral("K");
    } else {
        // 智能自动：与完整显示保持一致的三级换挡，但单位缩写为单个字母
        if (bytesPerSec < 1024.0 * 1024.0) {
            value = QString::number(bytesPerSec / 1024.0, 'f', 2);
            suffix = QStringLiteral("K");
        } else if (bytesPerSec < 1024.0 * 1024.0 * 1024.0) {
            value = QString::number(bytesPerSec / (1024.0 * 1024.0), 'f', 2);
            suffix = QStringLiteral("M");
        } else {
            value = QString::number(bytesPerSec / (1024.0 * 1024.0 * 1024.0), 'f', 2);
            suffix = QStringLiteral("G");
        }
    }

    if (intPart) {
        return value;
    }
    return value + suffix;
}

QString csvEscape(const QString &field)
{
    if (!field.contains(QLatin1Char(',')) && !field.contains(QLatin1Char('"'))
        && !field.contains(QLatin1Char('\n')) && !field.contains(QLatin1Char('\r'))) {
        return field;
    }
    QString escaped = field;
    escaped.replace(QLatin1String("\""), QLatin1String("\"\""));
    return QLatin1Char('"') + escaped + QLatin1Char('"');
}

double normalizeLimitGb(double gb)
{
    // qIsFinite 同时排除 NaN 与 ±infinity；随后再排除负数与 0。
    // 只判 `gb > 0` 会让 +infinity 通过，字节换算会得到未定义结果
    if (!qIsFinite(gb) || !(gb > 0)) {
        return 0.0;
    }
    return gb;
}

}   // namespace JNetCore
