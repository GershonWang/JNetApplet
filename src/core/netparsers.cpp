// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 外部命令输出解析的实现。
// 逻辑从 NetworkMonitorApplet 原样迁移，行为不得改变——迁移后由
// tests/core/tst_core.cpp 用同一批真实样本断言（含真机实测的 iw 输出）。
#include "netparsers.h"

#include <QRegularExpression>
#include <QRegularExpressionMatch>
#include <QStringList>
#include <QStringView>
#include <QVariantMap>

namespace JNetCore {

int parseIwBitrate(const QString &output)
{
    static const QRegularExpression re(
        QStringLiteral("^\\s*(?:(rx|tx)\\s+)?bitrate:\\s*([\\d.]+)\\s*(M|G)bit/s"),
        QRegularExpression::CaseInsensitiveOption);
    const QStringList lines = output.split(QLatin1Char('\n'));

    // 一次扫描：记录 tx 与"无方向/rx"各自的候选值，扫描结束后按 tx 优先取值。
    // 不用两轮扫描是因为"先找 tx 再找 rx"需要重复遍历并在第二轮排除 tx，逻辑绕；
    // 这里各留一个候选，O(n) 一遍即可，也更易读。
    int txCandidate = 0;
    int rxOrPlainCandidate = 0;
    for (const QString &rawLine : lines) {
        const QRegularExpressionMatch m = re.match(rawLine.trimmed());
        if (!m.hasMatch()) {
            continue;
        }
        const double val = m.captured(2).toDouble();
        // 大小写不敏感后 captured(3) 可能是 "m"/"g"，比较亦需不敏感
        const bool isGigabit =
            m.captured(3).compare(QLatin1String("G"), Qt::CaseInsensitive) == 0;
        const int mbps = isGigabit ? qRound(val * 1000.0) : qRound(val);
        if (m.captured(1).compare(QLatin1String("tx"), Qt::CaseInsensitive) == 0) {
            txCandidate = mbps;
        } else if (rxOrPlainCandidate == 0) {
            rxOrPlainCandidate = mbps;
        }
    }
    return txCandidate > 0 ? txCandidate : rxOrPlainCandidate;
}

QString parseIwSsid(const QString &output)
{
    // 必须逐行匹配：`SSID:` 后为空时多行的 \s* 会吃掉换行，
    // 把下一行 "freq: 5180" 当成 SSID 返回
    static const QRegularExpression re(QStringLiteral("^\\s*SSID:\\s*(.*)$"));
    const QStringList lines = output.split(QLatin1Char('\n'));
    for (const QString &line : lines) {
        const QRegularExpressionMatch m = re.match(line.trimmed());
        if (m.hasMatch()) {
            // SSID 为空视为未连接（返回空串），与"无 SSID 行"同样交由调用方回退
            const QString ssid = m.captured(1).trimmed();
            return ssid.isEmpty() ? QString() : ssid;
        }
    }
    return QString();
}

QVariantList parseTcpConnections(const QString &output)
{
    QVariantList list;

    // static const：正则仅首次编译一次，避免每条连接重复编译
    static const QRegularExpression lineRe(
        QStringLiteral("(\\S+)\\s+(\\S+)\\s+(\\S+):(\\d+)\\s+(\\S+):(\\d+)\\s*(.*)"));
    static const QRegularExpression nameRe(QStringLiteral("\\(\"([^\"]+)\""));

    const QStringList lines = output.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (int i = 0; i < lines.size(); ++i) {
        if (i == 0) {
            continue;   // 跳过表头（Recv-Q Send-Q ...）
        }

        const QString line = lines.at(i).trimmed();
        if (line.isEmpty()) {
            continue;
        }

        // ss 输出按多空格分割：Recv-Q Send-Q Local:Port Peer:Port [Process]
        // 注意 Process 列可能为空，且 IPv6 地址形如 [::1]:port（方括号内无空格），
        // 用正则提取更可靠，可容忍列之间任意空白
        const QRegularExpressionMatch match = lineRe.match(line);
        if (!match.hasMatch()) {
            continue;
        }

        QString localAddress = match.captured(3);
        const QString localPort = match.captured(4);
        QString remoteAddress = match.captured(5);
        const QString remotePort = match.captured(6);
        const QString processField = match.captured(7).trimmed();

        // 去掉地址中的接口后缀（如 192.168.3.83%wlp3s0 -> 192.168.3.83）
        localAddress = localAddress.split(QLatin1Char('%')).first();
        remoteAddress = remoteAddress.split(QLatin1Char('%')).first();
        // 去掉 IPv6 地址的方括号（[::1] -> ::1）
        if (localAddress.startsWith(QLatin1Char('['))) {
            localAddress = localAddress.mid(1, localAddress.size() - 2);
        }
        if (remoteAddress.startsWith(QLatin1Char('['))) {
            remoteAddress = remoteAddress.mid(1, remoteAddress.size() - 2);
        }

        // 提取进程名：users:(("进程名",pid=xxx,fd=xxx))，取第一个双引号内的内容
        QString processName;
        if (processField.startsWith(QStringLiteral("users:"))) {
            const QRegularExpressionMatch nameMatch = nameRe.match(processField);
            if (nameMatch.hasMatch()) {
                processName = nameMatch.captured(1);
            }
        }

        QVariantMap item;
        item[QStringLiteral("localAddress")] = localAddress;
        item[QStringLiteral("localPort")] = localPort.toInt();
        item[QStringLiteral("remoteAddress")] = remoteAddress;
        item[QStringLiteral("remotePort")] = remotePort.toInt();
        item[QStringLiteral("state")] = QStringLiteral("ESTABLISHED");
        item[QStringLiteral("processName")] = processName;
        list.append(item);
    }

    return list;
}

}   // namespace JNetCore
