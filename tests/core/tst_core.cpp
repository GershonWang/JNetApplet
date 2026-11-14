// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 纯逻辑核心库的单元测试。
//
// 为什么单独一个测试目标：
// tst_networkmonitorapplet 编译 NetworkMonitorApplet，而它继承 DApplet，
// 必须链接 Dtk6::Core 与 Dde::Shell——这两者只在 deepin 仓库提供，
// GitHub 托管 runner 上装不了，于是那份测试永远进不了 CI。
// 本文件只链接 Qt6::Core 与 Qt6::Test，**任何装了 qt6-base-dev 的机器都能跑**：
//
//     cmake -B build && cmake --build build && ctest --output-on-failure
//
// 覆盖范围刻意只含纯函数：解析（iw/ss）、判定（链路/物理接口/阈值）、
// 日志数据操作（累加/裁剪/展平/周期合计）。所有样本都取自真机实测输出，
// 不是臆造的理想化字符串——历史上正是"用例用了理想化输入、真机全解析不出"
// 这类问题反复出现。
#include "core/netparsers.h"
#include "core/netstate.h"
#include "core/trafficlog.h"
#include "core/format.h"

#include <QJsonObject>
#include <QTest>

class CoreLogicTest : public QObject
{
    Q_OBJECT

private slots:
    // ---- iw 输出解析 ----
    void testParseIwBitrate_data();
    void testParseIwBitrate();
    void testParseIwSsid_data();
    void testParseIwSsid();

    // ---- ss 输出解析 ----
    void testParseTcpConnections();

    // ---- 链路与接口判定 ----
    void testIsLinkDown_data();
    void testIsLinkDown();
    void testIsWirelessByPrefix_data();
    void testIsWirelessByPrefix();
    void testIsPhysicalInterface_data();
    void testIsPhysicalInterface();

    // ---- 流量阈值 ----
    void testShouldNotifyQuota_data();
    void testShouldNotifyQuota();

    // ---- 速度格式化与数值归一化 ----
    void testFormatSpeed_data();
    void testFormatSpeed();
    void testFormatSpeedCompact_data();
    void testFormatSpeedCompact();
    void testCsvEscape_data();
    void testCsvEscape();
    void testNormalizeLimitGb();

    // ---- 流量日志数据操作 ----
    void testAppendTraffic();
    void testAppendTrafficRejectsEmpty();
    void testPruneTraffic();
    void testFlattenTraffic();
    void testPeriodUsedBytes();
};

void CoreLogicTest::testParseIwBitrate_data()
{
    QTest::addColumn<QString>("output");
    QTest::addColumn<int>("expected");

    QTest::newRow("empty") << QString() << 0;
    QTest::newRow("no-bitrate")
        << QStringLiteral("Connected to 11:22:33:44:55:66 (on wlp3s0)") << 0;

    // 真机实测样本（wlo1，deepin 25）：rx/tx 前缀 + MBit/s 大写 B + 制表符缩进。
    // 这三处正是历史缺陷所在：按行首匹配、按小写 bit/s 匹配、只从位置 0 尝试
    QTest::newRow("real-iw-output")
        << QStringLiteral("Connected to 8c:de:f9:xx:xx:xx (on wlo1)\n"
                          "\tSSID: Home\n"
                          "\tfreq: 5180\n"
                          "\tsignal: -52 dBm\n"
                          "\ttx bitrate: 866.7 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 2\n"
                          "\trx bitrate: 390.0 MBit/s VHT-MCS 8 80MHz short GI VHT-NSS 1")
        << 867;
    // rx 在 tx 之前时仍应取 tx（发送方向代表协商上限）
    QTest::newRow("tx-preferred-over-rx")
        << QStringLiteral("\trx bitrate: 390.0 MBit/s\n\ttx bitrate: 866.7 MBit/s") << 867;
    // 仅 rx 时回退取 rx
    QTest::newRow("rx-fallback") << QStringLiteral("\trx bitrate: 390.0 MBit/s") << 390;
    // 理想化裸行（兼容其它输出形态）
    QTest::newRow("mbps") << QStringLiteral("    bitrate: 54.0 MBit/s") << 54;
    QTest::newRow("gbps") << QStringLiteral("    bitrate: 1.2 Gbit/s") << 1200;
    // 单位小写也接受（不同 iw 版本/本地化差异）
    QTest::newRow("lowercase-unit") << QStringLiteral("    bitrate: 72.2 mbit/s") << 72;
}

void CoreLogicTest::testParseIwBitrate()
{
    QFETCH(QString, output);
    QFETCH(int, expected);
    QCOMPARE(JNetCore::parseIwBitrate(output), expected);
}

void CoreLogicTest::testParseIwSsid_data()
{
    QTest::addColumn<QString>("output");
    QTest::addColumn<QString>("expected");

    QTest::newRow("empty") << QString() << QString();
    // 未连接：iw 只输出 "Not connected."
    QTest::newRow("not-connected") << QStringLiteral("Not connected.") << QString();
    QTest::newRow("not-connected-with-reason")
        << QStringLiteral("Not connected (Reason: 3)") << QString();

    QTest::newRow("real-iw-output")
        << QStringLiteral("Connected to 8c:de:f9:xx:xx:xx (on wlo1)\n"
                          "\tSSID: Home\n"
                          "\tfreq: 5180\n"
                          "\tsignal: -52 dBm\n"
                          "\ttx bitrate: 866.7 MBit/s")
        << QStringLiteral("Home");
    // SSID 含空格：不能只取第一个词
    QTest::newRow("ssid-with-spaces")
        << QStringLiteral("\tSSID: My Home WiFi 5G\n\tfreq: 5180")
        << QStringLiteral("My Home WiFi 5G");
    QTest::newRow("ssid-chinese")
        << QStringLiteral("\tSSID: 我家网络\n\tfreq: 2412") << QStringLiteral("我家网络");
    QTest::newRow("no-indent") << QStringLiteral("SSID: Office") << QStringLiteral("Office");
    // 只有 "SSID:" 没有内容：多行正则的 \s* 会吃掉换行，把下一行当成 SSID。
    // 这条用例固定住"必须逐行匹配"的实现约束
    QTest::newRow("ssid-empty-value")
        << QStringLiteral("\tSSID: \n\tfreq: 5180") << QString();
}

void CoreLogicTest::testParseIwSsid()
{
    QFETCH(QString, output);
    QFETCH(QString, expected);
    QCOMPARE(JNetCore::parseIwSsid(output), expected);
}

void CoreLogicTest::testParseTcpConnections()
{
    const QString output = QStringLiteral(
        "Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n"
        "0      0          127.0.0.1:631       127.0.0.1:45678 users:((\"cupsd\",pid=1234,fd=7))\n"
        "0      0          [::1]:8080          [2001:db8::1]:443 users:((\"nginx\",pid=99,fd=3))\n"
        "0      0          192.168.1.5%wlp3s0:52001 93.184.216.34:443\n");

    const QVariantList list = JNetCore::parseTcpConnections(output);
    QCOMPARE(list.size(), 3);

    const QVariantMap first = list.at(0).toMap();
    QCOMPARE(first.value(QStringLiteral("localAddress")).toString(), QStringLiteral("127.0.0.1"));
    QCOMPARE(first.value(QStringLiteral("localPort")).toInt(), 631);
    QCOMPARE(first.value(QStringLiteral("remotePort")).toInt(), 45678);
    QCOMPARE(first.value(QStringLiteral("processName")).toString(), QStringLiteral("cupsd"));
    QCOMPARE(first.value(QStringLiteral("state")).toString(), QStringLiteral("ESTABLISHED"));

    // IPv6 方括号需被剥离
    const QVariantMap second = list.at(1).toMap();
    QCOMPARE(second.value(QStringLiteral("localAddress")).toString(), QStringLiteral("::1"));
    QCOMPARE(second.value(QStringLiteral("remoteAddress")).toString(), QStringLiteral("2001:db8::1"));

    // %iface 后缀需被剥离；无进程名时不崩溃且为空串
    const QVariantMap third = list.at(2).toMap();
    QCOMPARE(third.value(QStringLiteral("localAddress")).toString(), QStringLiteral("192.168.1.5"));
    QCOMPARE(third.value(QStringLiteral("processName")).toString(), QString());

    // 空输入只有表头 => 空列表
    QVERIFY(JNetCore::parseTcpConnections(QString()).isEmpty());
}

void CoreLogicTest::testIsLinkDown_data()
{
    QTest::addColumn<int>("carrier");
    QTest::addColumn<QString>("operState");
    QTest::addColumn<bool>("expected");

    // ★ 真机实测回归：`ip link set wlo1 down` 后 carrier 读取返回 EINVAL（-1），
    // operstate 明确为 "down"。初版把 carrier<0 放最前一律判未断开，断连态永不显示
    QTest::newRow("wifi-down-carrier-unreadable") << -1 << QStringLiteral("down") << true;

    QTest::newRow("up-with-carrier") << 1 << QStringLiteral("up") << false;
    QTest::newRow("up-without-carrier") << 0 << QStringLiteral("up") << false;
    QTest::newRow("up-carrier-unreadable") << -1 << QStringLiteral("up") << false;
    QTest::newRow("down-without-carrier") << 0 << QStringLiteral("down") << true;
    QTest::newRow("down-with-carrier") << 1 << QStringLiteral("down") << true;
    QTest::newRow("dormant") << 1 << QStringLiteral("dormant") << true;
    QTest::newRow("dormant-carrier-unreadable") << -1 << QStringLiteral("dormant") << true;
    QTest::newRow("lowerlayerdown") << 1 << QStringLiteral("lowerlayerdown") << true;

    // operstate 含糊（unknown / 读不到）时回退看 carrier，避免虚拟接口误报
    QTest::newRow("unknown-with-carrier") << 1 << QStringLiteral("unknown") << false;
    QTest::newRow("unknown-without-carrier") << 0 << QStringLiteral("unknown") << true;
    QTest::newRow("unknown-carrier-unreadable") << -1 << QStringLiteral("unknown") << false;
    QTest::newRow("empty-state-with-carrier") << 1 << QString() << false;
    QTest::newRow("empty-state-without-carrier") << 0 << QString() << true;
    QTest::newRow("empty-state-carrier-unreadable") << -1 << QString() << false;
}

void CoreLogicTest::testIsLinkDown()
{
    QFETCH(int, carrier);
    QFETCH(QString, operState);
    QFETCH(bool, expected);
    QCOMPARE(JNetCore::isLinkDown(carrier, operState), expected);
}

void CoreLogicTest::testIsWirelessByPrefix_data()
{
    QTest::addColumn<QString>("name");
    QTest::addColumn<bool>("expected");

    QTest::newRow("wlp3s0") << "wlp3s0" << true;
    QTest::newRow("wlan0") << "wlan0" << true;
    // deepin 25 真机接口名，曾是漏判现场
    QTest::newRow("wlo1") << "wlo1" << true;
    QTest::newRow("wlx00c0ca") << "wlx00c0ca" << true;
    QTest::newRow("enp3s0") << "enp3s0" << false;
    QTest::newRow("eno1") << "eno1" << false;
    QTest::newRow("empty") << "" << false;
}

void CoreLogicTest::testIsWirelessByPrefix()
{
    QFETCH(QString, name);
    QFETCH(bool, expected);
    QCOMPARE(JNetCore::isWirelessByPrefix(name), expected);
}

void CoreLogicTest::testIsPhysicalInterface_data()
{
    QTest::addColumn<QString>("name");
    QTest::addColumn<bool>("expected");

    // 物理网卡：既有命名 + 曾被白名单漏判的命名
    QTest::newRow("wlp3s0") << "wlp3s0" << true;
    QTest::newRow("wlan0") << "wlan0" << true;
    QTest::newRow("wlo1") << "wlo1" << true;
    QTest::newRow("enp3s0") << "enp3s0" << true;
    QTest::newRow("eth0") << "eth0" << true;
    // 白名单漏判的三类：板载 / 虚拟机 / USB 有线
    QTest::newRow("eno1") << "eno1" << true;
    QTest::newRow("ens33") << "ens33" << true;
    QTest::newRow("enx00e04c") << "enx00e04c" << true;
    // 排除法对未知命名同样成立（未来新命名不会被漏判）
    QTest::newRow("unknown-but-not-virtual") << "foo0" << true;
    // 无线 p2p 接口以 wg 开头却属物理网卡（不能用裸前缀判 wg 隧道）
    QTest::newRow("wgp2s0") << "wgp2s0" << true;

    // 虚拟接口
    QTest::newRow("lo") << "lo" << false;
    QTest::newRow("Meta") << "Meta" << false;
    QTest::newRow("docker0") << "docker0" << false;
    QTest::newRow("veth0") << "veth0" << false;
    QTest::newRow("br-xxx") << "br-xxx" << false;
    QTest::newRow("tun0") << "tun0" << false;
    QTest::newRow("tap0") << "tap0" << false;
    QTest::newRow("wg0") << "wg0" << false;
    QTest::newRow("wg1") << "wg1" << false;
    QTest::newRow("virbr0") << "virbr0" << false;
    QTest::newRow("vnet0") << "vnet0" << false;
    QTest::newRow("ifb0") << "ifb0" << false;
    QTest::newRow("empty") << "" << false;
}

void CoreLogicTest::testIsPhysicalInterface()
{
    QFETCH(QString, name);
    QFETCH(bool, expected);
    QCOMPARE(JNetCore::isPhysicalInterface(name), expected);
}

void CoreLogicTest::testShouldNotifyQuota_data()
{
    QTest::addColumn<qint64>("usedBytes");
    QTest::addColumn<double>("limitGb");
    QTest::addColumn<QString>("currentPeriod");
    QTest::addColumn<QString>("notifiedPeriod");
    QTest::addColumn<bool>("expected");

    // 阈值为 0 = 关闭提醒
    QTest::newRow("disabled-zero") << qint64(9999999999LL) << 0.0
                                   << QStringLiteral("2026-11-14") << QString() << false;
    QTest::newRow("disabled-negative") << qint64(9999999999LL) << -1.0
                                       << QStringLiteral("2026-11-14") << QString() << false;
    // 无穷大也满足 `> 0`，若不显式排除，字节换算得到未定义结果（实测曾把 inf 写进配置）
    QTest::newRow("disabled-infinity")
        << qint64(9999999999LL) << std::numeric_limits<double>::infinity()
        << QStringLiteral("2026-11-14") << QString() << false;
    QTest::newRow("disabled-nan")
        << qint64(9999999999LL) << std::numeric_limits<double>::quiet_NaN()
        << QStringLiteral("2026-11-14") << QString() << false;

    // 1 GB 阈值 = 1e9 字节（十进制，不是 1<<30）
    QTest::newRow("below-limit") << qint64(999999999LL) << 1.0
                                 << QStringLiteral("2026-11-14") << QString() << false;
    // 恰好等于阈值即触发（>= 而非 >）
    QTest::newRow("exactly-limit") << qint64(1000000000LL) << 1.0
                                   << QStringLiteral("2026-11-14") << QString() << true;
    QTest::newRow("above-limit") << qint64(1500000000LL) << 1.0
                                 << QStringLiteral("2026-11-14") << QString() << true;

    // 同周期已提醒过：不再重复
    QTest::newRow("same-period-already-notified") << qint64(5000000000LL) << 1.0
                                                  << QStringLiteral("2026-11-14")
                                                  << QStringLiteral("2026-11-14") << false;
    // 跨周期：昨天提醒过，今天应重新提醒
    QTest::newRow("new-period-after-notified") << qint64(5000000000LL) << 1.0
                                               << QStringLiteral("2026-11-15")
                                               << QStringLiteral("2026-11-14") << true;
    // 月周期键：同月去重、跨月重置
    QTest::newRow("month-same") << qint64(50000000000LL) << 20.0
                                << QStringLiteral("2026-11") << QStringLiteral("2026-11") << false;
    QTest::newRow("month-next") << qint64(50000000000LL) << 20.0
                                << QStringLiteral("2026-12") << QStringLiteral("2026-11") << true;
    // 小数阈值：1.5 GB = 1.5e9 字节
    QTest::newRow("fractional-hit") << qint64(1500000000LL) << 1.5
                                    << QStringLiteral("2026-11-14") << QString() << true;
    QTest::newRow("fractional-miss") << qint64(1499999999LL) << 1.5
                                     << QStringLiteral("2026-11-14") << QString() << false;
}

void CoreLogicTest::testShouldNotifyQuota()
{
    QFETCH(qint64, usedBytes);
    QFETCH(double, limitGb);
    QFETCH(QString, currentPeriod);
    QFETCH(QString, notifiedPeriod);
    QFETCH(bool, expected);
    QCOMPARE(JNetCore::shouldNotifyQuota(usedBytes, limitGb, currentPeriod, notifiedPeriod),
             expected);
}

void CoreLogicTest::testAppendTraffic()
{
    QJsonObject log;
    const QString date = QStringLiteral("2026-11-14");
    const QString month = QStringLiteral("2026-11");

    // 同一接口累加
    JNetCore::appendTraffic(log, QStringLiteral("eth0"), date, month, 100, 50);
    JNetCore::appendTraffic(log, QStringLiteral("eth0"), date, month, 200, 20);

    const QJsonObject day = log.value(QStringLiteral("byDay")).toObject()
                               .value(date).toObject();
    QCOMPARE(day.value(QStringLiteral("eth0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(300));
    QCOMPARE(day.value(QStringLiteral("eth0")).toObject()
                 .value(QStringLiteral("tx")).toVariant().toLongLong(), qint64(70));

    // 另一接口独立分桶，原接口不受影响
    JNetCore::appendTraffic(log, QStringLiteral("wlan0"), date, month, 7, 3);
    const QJsonObject day2 = log.value(QStringLiteral("byDay")).toObject()
                                .value(date).toObject();
    QCOMPARE(day2.value(QStringLiteral("eth0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(300));
    QCOMPARE(day2.value(QStringLiteral("wlan0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(7));

    // 按月记录同步累加
    const QJsonObject byMonth = log.value(QStringLiteral("byMonth")).toObject()
                                   .value(month).toObject();
    QCOMPARE(byMonth.value(QStringLiteral("eth0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(300));

    // 大数精度：超过 2^53 的累计值不得被 double 截断
    QJsonObject big;
    const qint64 huge = qint64(9007199254740993LL);   // 2^53 + 1
    JNetCore::appendTraffic(big, QStringLiteral("eth0"), date, month, huge, 0);
    QCOMPARE(big.value(QStringLiteral("byDay")).toObject().value(date).toObject()
                 .value(QStringLiteral("eth0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), huge);
}

void CoreLogicTest::testAppendTrafficRejectsEmpty()
{
    QJsonObject log;

    // 零增量：不产生记录
    JNetCore::appendTraffic(log, QStringLiteral("eth0"), QStringLiteral("2026-11-14"),
                            QStringLiteral("2026-11"), 0, 0);
    QVERIFY(log.isEmpty());

    // 空接口名：不产生以空串为键的记录
    JNetCore::appendTraffic(log, QString(), QStringLiteral("2026-11-14"),
                            QStringLiteral("2026-11"), 100, 100);
    QVERIFY(log.isEmpty());
}

void CoreLogicTest::testPruneTraffic()
{
    QJsonObject log;
    QJsonObject byDay;
    // 造 35 天记录
    for (int i = 1; i <= 35; ++i) {
        QJsonObject iface;
        iface[QStringLiteral("rx")] = qint64(i);
        QJsonObject entry;
        entry[QStringLiteral("eth0")] = iface;
        byDay[QStringLiteral("2026-11-%1").arg(i, 2, 10, QLatin1Char('0'))] = entry;
    }
    log[QStringLiteral("byDay")] = byDay;

    JNetCore::pruneTraffic(log, 30, 12);

    const QStringList keys = log.value(QStringLiteral("byDay")).toObject().keys();
    QCOMPARE(keys.size(), 30);
    // 保留的是最新 30 天：11-06 … 11-35（字典序即时间序）
    QVERIFY(keys.contains(QStringLiteral("2026-11-35")));
    QVERIFY(!keys.contains(QStringLiteral("2026-11-01")));
    QVERIFY(!keys.contains(QStringLiteral("2026-11-05")));
}

void CoreLogicTest::testFlattenTraffic()
{
    QJsonObject log;
    QJsonObject byDay;

    auto makeRec = [](qint64 rx, qint64 tx) {
        QJsonObject o;
        o[QStringLiteral("rx")] = rx;
        o[QStringLiteral("tx")] = tx;
        return o;
    };

    QJsonObject day1;
    day1[QStringLiteral("eno1")] = makeRec(1000, 500);
    // 含逗号与双引号的接口名：导出 CSV 时必须正确转义
    day1[QStringLiteral("wlan, \"guest\"")] = makeRec(2000, 800);
    QJsonObject day2;
    day2[QStringLiteral("eth0")] = makeRec(qint64(9007199254740993LL), 1);

    byDay[QStringLiteral("2026-11-14")] = day1;
    byDay[QStringLiteral("2026-11-13")] = day2;
    log[QStringLiteral("byDay")] = byDay;

    const QVariantList rows = JNetCore::flattenTraffic(log, QStringLiteral("byDay"));
    QCOMPARE(rows.size(), 3);

    // 日期降序（最新在前），同日接口名升序
    QCOMPARE(rows.at(0).toMap().value(QStringLiteral("date")).toString(),
             QStringLiteral("2026-11-14"));
    QCOMPARE(rows.at(1).toMap().value(QStringLiteral("date")).toString(),
             QStringLiteral("2026-11-14"));
    QCOMPARE(rows.at(2).toMap().value(QStringLiteral("date")).toString(),
             QStringLiteral("2026-11-13"));
    QCOMPARE(rows.at(0).toMap().value(QStringLiteral("iface")).toString(),
             QStringLiteral("eno1"));

    // total = rx + tx
    QCOMPARE(rows.at(0).toMap().value(QStringLiteral("total")).toLongLong(), qint64(1500));

    // 大数精度
    QCOMPARE(rows.at(2).toMap().value(QStringLiteral("rx")).toLongLong(),
             qint64(9007199254740993LL));

    // 不存在的 section 返回空列表
    QVERIFY(JNetCore::flattenTraffic(log, QStringLiteral("byMonth")).isEmpty());
}

void CoreLogicTest::testPeriodUsedBytes()
{
    QJsonObject log;
    QJsonObject days;

    QJsonObject eth;
    eth[QStringLiteral("rx")] = qint64(1000000000);
    eth[QStringLiteral("tx")] = qint64(500000000);
    QJsonObject wlan;
    wlan[QStringLiteral("rx")] = qint64(250000000);
    wlan[QStringLiteral("tx")] = qint64(250000000);
    QJsonObject day;
    day[QStringLiteral("eth0")] = eth;
    day[QStringLiteral("wlo1")] = wlan;
    days[QStringLiteral("2026-11-14")] = day;

    QJsonObject other;
    other[QStringLiteral("rx")] = qint64(999);
    QJsonObject otherDay;
    otherDay[QStringLiteral("eth0")] = other;
    days[QStringLiteral("2026-11-13")] = otherDay;

    log[QStringLiteral("byDay")] = days;

    // 跨接口合计 = 2e9
    QCOMPARE(JNetCore::periodUsedBytes(log, QStringLiteral("byDay"),
                                       QStringLiteral("2026-11-14")),
             qint64(2000000000));
    // 只取指定日期，不把前一天算进来
    QCOMPARE(JNetCore::periodUsedBytes(log, QStringLiteral("byDay"),
                                       QStringLiteral("2026-11-13")),
             qint64(999));
    // 不存在的键返回 0
    QCOMPARE(JNetCore::periodUsedBytes(log, QStringLiteral("byDay"),
                                       QStringLiteral("2026-11-15")),
             qint64(0));

    // 大数精度：2^53 + 1 必须原样保留
    QJsonObject huge;
    huge[QStringLiteral("rx")] = qint64(9007199254740993LL);
    QJsonObject hugeDay;
    hugeDay[QStringLiteral("eth0")] = huge;
    QJsonObject hugeLog;
    QJsonObject hugeDays;
    hugeDays[QStringLiteral("2026-11-14")] = hugeDay;
    hugeLog[QStringLiteral("byDay")] = hugeDays;
    QCOMPARE(JNetCore::periodUsedBytes(hugeLog, QStringLiteral("byDay"),
                                       QStringLiteral("2026-11-14")),
             qint64(9007199254740993LL));
}


void CoreLogicTest::testFormatSpeed_data()
{
    QTest::addColumn<double>("bytes");
    QTest::addColumn<int>("unit");
    QTest::addColumn<QString>("expected");

    // 智能自动：0 与负值都显示 0，不能出现负号
    QTest::newRow("auto-zero") << 0.0 << 0 << QStringLiteral("0.00 KB/s");
    QTest::newRow("auto-negative") << -1024.0 << 0 << QStringLiteral("0.00 KB/s");
    QTest::newRow("auto-512B") << 512.0 << 0 << QStringLiteral("0.50 KB/s");
    QTest::newRow("auto-1K") << 1024.0 << 0 << QStringLiteral("1.00 KB/s");
    // 边界：刚好 1 MB 换到 MB/s；刚好 1 GB 换到 GB/s
    QTest::newRow("auto-1M") << 1048576.0 << 0 << QStringLiteral("1.00 MB/s");
    QTest::newRow("auto-1G") << 1073741824.0 << 0 << QStringLiteral("1.00 GB/s");

    // 固定 KB/s：10 MB 仍是 10240.00 KB/s，不擅自换挡
    QTest::newRow("kbps-1K") << 1024.0 << 1 << QStringLiteral("1.00 KB/s");
    QTest::newRow("kbps-10M") << 10485760.0 << 1 << QStringLiteral("10240.00 KB/s");

    // 固定 Mbps：十进制，bytes×8/1e6。1 MB/s ≈ 8.39 Mbps（1024 与 1000 的差异，属预期口径）
    QTest::newRow("mbps-1") << 125000.0 << 2 << QStringLiteral("1.00 Mbps");
    QTest::newRow("mbps-1MBps") << 1048576.0 << 2 << QStringLiteral("8.39 Mbps");
    QTest::newRow("mbps-100") << 12500000.0 << 2 << QStringLiteral("100.00 Mbps");
    QTest::newRow("mbps-zero") << 0.0 << 2 << QStringLiteral("0.00 Mbps");
}

void CoreLogicTest::testFormatSpeed()
{
    QFETCH(double, bytes);
    QFETCH(int, unit);
    QFETCH(QString, expected);
    QCOMPARE(JNetCore::formatSpeed(bytes, unit), expected);
}

void CoreLogicTest::testFormatSpeedCompact_data()
{
    QTest::addColumn<double>("bytes");
    QTest::addColumn<int>("unit");
    QTest::addColumn<bool>("intPart");
    QTest::addColumn<QString>("expected");

    // 智能自动：三位换挡，单位缩写为单字母
    QTest::newRow("auto-K-int") << 198727.0 << 0 << true << QStringLiteral("194.07");
    QTest::newRow("auto-K-full") << 198727.0 << 0 << false << QStringLiteral("194.07K");
    QTest::newRow("auto-M-full") << 4308992.0 << 0 << false << QStringLiteral("4.11M");
    QTest::newRow("auto-G-full") << 1073741824.0 << 0 << false << QStringLiteral("1.00G");
    QTest::newRow("auto-zero") << 0.0 << 0 << false << QStringLiteral("0.00K");

    // 固定 KB/s
    QTest::newRow("kbps-full") << 198727.0 << 1 << false << QStringLiteral("194.07K");
    QTest::newRow("kbps-10M") << 10485760.0 << 1 << false << QStringLiteral("10240.00K");

    // 固定 Mbps：两位小数
    QTest::newRow("mbps-full") << 125000.0 << 2 << false << QStringLiteral("1.00Mbps");
    QTest::newRow("mbps-100") << 12500000.0 << 2 << false << QStringLiteral("100.00Mbps");
    QTest::newRow("mbps-int-part") << 100000.0 << 2 << true << QStringLiteral("0.80");
    QTest::newRow("mbps-zero") << 0.0 << 2 << false << QStringLiteral("0.00Mbps");
}

void CoreLogicTest::testFormatSpeedCompact()
{
    QFETCH(double, bytes);
    QFETCH(int, unit);
    QFETCH(bool, intPart);
    QFETCH(QString, expected);
    QCOMPARE(JNetCore::formatSpeedCompact(bytes, unit, intPart), expected);
}

void CoreLogicTest::testCsvEscape_data()
{
    QTest::addColumn<QString>("input");
    QTest::addColumn<QString>("expected");

    // 普通字段不加引号
    QTest::newRow("plain") << QStringLiteral("eno1") << QStringLiteral("eno1");
    QTest::newRow("chinese") << QStringLiteral("有线网卡") << QStringLiteral("有线网卡");
    // 含逗号必须整体加引号，否则列数会错
    QTest::newRow("comma") << QStringLiteral("wlan, guest") << QStringLiteral("\"wlan, guest\"");
    // 双引号成对转义
    QTest::newRow("quote") << QStringLiteral("a\"b") << QStringLiteral("\"a\"\"b\"");
    // 逗号 + 双引号组合（导出测试里的真实样本）
    QTest::newRow("comma-and-quote")
        << QStringLiteral("wlan, \"guest\"") << QStringLiteral("\"wlan, \"\"guest\"\"\"");
    // 换行：用引号包裹表意
    QTest::newRow("newline") << QStringLiteral("a\nb") << QStringLiteral("\"a\nb\"");
}

void CoreLogicTest::testCsvEscape()
{
    QFETCH(QString, input);
    QFETCH(QString, expected);
    QCOMPARE(JNetCore::csvEscape(input), expected);
}

void CoreLogicTest::testNormalizeLimitGb()
{
    // 合法值原样保留
    QCOMPARE(JNetCore::normalizeLimitGb(1.5), 1.5);
    QCOMPARE(JNetCore::normalizeLimitGb(20.0), 20.0);

    // 负数、0 归为 0（关闭）
    QCOMPARE(JNetCore::normalizeLimitGb(-3.0), 0.0);
    QCOMPARE(JNetCore::normalizeLimitGb(0.0), 0.0);

    // NaN 与无穷大同样归 0：+infinity 满足 `> 0`，只判 > 0 会让它通过校验，
    // 而字节换算会得到未定义结果（实测曾把 inf 写进配置）
    QCOMPARE(JNetCore::normalizeLimitGb(std::numeric_limits<double>::quiet_NaN()), 0.0);
    QCOMPARE(JNetCore::normalizeLimitGb(std::numeric_limits<double>::infinity()), 0.0);
    QCOMPARE(JNetCore::normalizeLimitGb(-std::numeric_limits<double>::infinity()), 0.0);
}

QTEST_MAIN(CoreLogicTest)
#include "tst_core.moc"
