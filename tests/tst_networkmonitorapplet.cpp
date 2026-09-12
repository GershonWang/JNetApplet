// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// NetworkMonitorApplet 单元测试
// 覆盖核心纯逻辑函数：isPhysicalInterface、速度计算（含真实间隔/负值钳制/总量累加）、
// setActiveInterface 接口校验
// 用 #define private public 技巧访问私有成员（friend 声明因 DS_BEGIN_NAMESPACE
// 命名空间与 Q_OBJECT 宏交互而无法正确解析，此为 C++ 测试常用替代方案）

// 必须在 include 头文件之前定义，使 private 成员在测试编译单元中可访问
#define private public
#include "networkmonitorapplet.h"
#undef private

#include <QtTest/QtTest>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QJsonObject>
#include <QTemporaryDir>

// dde-shell 的 DS 命名空间（DS_BEGIN_NAMESPACE = namespace ds {）
DS_USE_NAMESPACE

class NetworkMonitorAppletTest : public QObject
{
    Q_OBJECT

private:
    // 创建 applet 实例的辅助方法
    // 构造时不调用 init()（会启动定时器），仅用于测试纯逻辑方法
    NetworkMonitorApplet *createApplet()
    {
        return new NetworkMonitorApplet();
    }

private slots:
    // isPhysicalInterface：物理网卡前缀匹配
    void testIsPhysicalInterface_data();
    void testIsPhysicalInterface();

    // 速度计算：按真实时间间隔计算
    void testCalculateSpeed();
    // 计数器回绕时负值钳制为 0
    void testNegativeDeltaClamped();
    // 总量累加而非取计数器值
    void testTotalAccumulation();
    // setActiveInterface 拒绝无效接口名
    void testSetActiveInterfaceValidation();

    // iw bitrate 解析：M/G 单位、无 bitrate 行、非法输入
    void testParseIwBitrate_data();
    void testParseIwBitrate();

    // 流量日志：当日/当月累加与按接口分桶
    void testAppendToTrafficLog();
    // 流量日志：超期裁剪（按日 30 条、按月 12 条）
    void testPruneTrafficLog();
    // 流量日志：文件损坏时降级为空结构而非崩溃
    void testLoadTrafficLogInvalid();
    // ss 输出解析：IPv4/IPv6/无进程名/空输入
    void testParseTcpConnectionList();
};

void NetworkMonitorAppletTest::testIsPhysicalInterface_data()
{
    QTest::addColumn<QString>("name");
    QTest::addColumn<bool>("expected");

    // 物理网卡
    QTest::newRow("wlp3s0") << "wlp3s0" << true;
    QTest::newRow("wlan0") << "wlan0" << true;
    QTest::newRow("enp3s0") << "enp3s0" << true;
    QTest::newRow("eth0") << "eth0" << true;

    // 非物理接口
    QTest::newRow("lo") << "lo" << false;
    QTest::newRow("docker0") << "docker0" << false;
    QTest::newRow("veth0") << "veth0" << false;
    QTest::newRow("br-xxx") << "br-xxx" << false;
    QTest::newRow("tun0") << "tun0" << false;
    QTest::newRow("Meta") << "Meta" << false;
    QTest::newRow("empty") << "" << false;
}

void NetworkMonitorAppletTest::testIsPhysicalInterface()
{
    NetworkMonitorApplet *applet = createApplet();
    QFETCH(QString, name);
    QFETCH(bool, expected);
    QCOMPARE(applet->isPhysicalInterface(name), expected);
    delete applet;
}

void NetworkMonitorAppletTest::testCalculateSpeed()
{
    NetworkMonitorApplet *applet = createApplet();

    // 设置活动接口和接口数据
    applet->m_interfaceList = QStringList() << "eth0";
    NetworkInterface iface;
    iface.name = "eth0";
    iface.rxBytes = 1000;
    iface.txBytes = 500;
    applet->m_interfaces["eth0"] = iface;
    applet->m_activeInterface = "eth0";

    // 模拟首次更新：记录基线
    applet->m_firstUpdate = true;
    applet->calculateSpeed();
    QVERIFY(!applet->m_firstUpdate);

    // 第二次更新：字节增加了 1000 rx / 500 tx，间隔约 1 秒
    iface.rxBytes = 2000;
    iface.txBytes = 1000;
    applet->m_interfaces["eth0"] = iface;
    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;

    applet->calculateSpeed();

    // 速度应约为 1000 bytes/sec（允许误差因真实时间戳）
    QVERIFY(applet->m_downloadSpeed > 900 && applet->m_downloadSpeed < 1100);
    QVERIFY(applet->m_uploadSpeed > 450 && applet->m_uploadSpeed < 550);

    delete applet;
}

void NetworkMonitorAppletTest::testNegativeDeltaClamped()
{
    NetworkMonitorApplet *applet = createApplet();

    applet->m_interfaceList = QStringList() << "eth0";
    NetworkInterface iface;
    iface.name = "eth0";
    iface.rxBytes = 2000;
    iface.txBytes = 1000;
    applet->m_interfaces["eth0"] = iface;
    applet->m_activeInterface = "eth0";

    // 首次更新记录基线
    applet->m_firstUpdate = true;
    applet->calculateSpeed();

    // 模拟计数器回绕：当前值小于上次值
    iface.rxBytes = 500;  // 回绕！
    iface.txBytes = 200;  // 回绕！
    applet->m_interfaces["eth0"] = iface;
    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;

    applet->calculateSpeed();

    // 速度应为 0，不应为负
    QVERIFY(applet->m_downloadSpeed >= 0);
    QVERIFY(applet->m_uploadSpeed >= 0);

    delete applet;
}

void NetworkMonitorAppletTest::testTotalAccumulation()
{
    NetworkMonitorApplet *applet = createApplet();

    applet->m_interfaceList = QStringList() << "eth0";
    NetworkInterface iface;
    iface.name = "eth0";
    iface.rxBytes = 0;
    iface.txBytes = 0;
    applet->m_interfaces["eth0"] = iface;
    applet->m_activeInterface = "eth0";
    applet->m_totalDownload = 0;
    applet->m_totalUpload = 0;

    // 首次更新记录基线
    applet->m_firstUpdate = true;
    applet->calculateSpeed();

    // 第一次增量：rx +1000, tx +500
    iface.rxBytes = 1000;
    iface.txBytes = 500;
    applet->m_interfaces["eth0"] = iface;
    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;
    applet->calculateSpeed();
    QCOMPARE(applet->m_totalDownload, qint64(1000));
    QCOMPARE(applet->m_totalUpload, qint64(500));

    // 第二次增量：rx +2000, tx +1000
    iface.rxBytes = 3000;
    iface.txBytes = 1500;
    applet->m_interfaces["eth0"] = iface;
    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;
    applet->calculateSpeed();
    // 总量应累加，而非取计数器值
    QCOMPARE(applet->m_totalDownload, qint64(3000));
    QCOMPARE(applet->m_totalUpload, qint64(1500));

    delete applet;
}

void NetworkMonitorAppletTest::testSetActiveInterfaceValidation()
{
    NetworkMonitorApplet *applet = createApplet();

    applet->m_interfaceList = QStringList() << "eth0" << "wlan0";
    applet->m_activeInterface = "eth0";

    // 无效接口名应被忽略
    applet->setActiveInterface("nonexistent");
    QCOMPARE(applet->m_activeInterface, QString("eth0"));

    // 有效接口名应被设置
    applet->setActiveInterface("wlan0");
    QCOMPARE(applet->m_activeInterface, QString("wlan0"));

    delete applet;
}

// iw dev link 输出的 bitrate 解析：M/G 单位换算与非法输入
void NetworkMonitorAppletTest::testParseIwBitrate_data()
{
    QTest::addColumn<QString>("output");
    QTest::addColumn<int>("expected");

    QTest::newRow("empty") << QString() << 0;
    QTest::newRow("no-bitrate") << QStringLiteral("Connected to 11:22:33:44:55:66 (on wlp3s0)") << 0;
    QTest::newRow("mbps") << QStringLiteral("    bitrate: 54.0 MBit/s") << 54;
    QTest::newRow("mbps-fraction") << QStringLiteral("    bitrate: 866.7 MBit/s") << 867;
    QTest::newRow("gbps") << QStringLiteral("    bitrate: 1.2 Gbit/s") << 1200;
}

void NetworkMonitorAppletTest::testParseIwBitrate()
{
    NetworkMonitorApplet *applet = createApplet();
    QFETCH(QString, output);
    QFETCH(int, expected);
    QCOMPARE(applet->parseIwBitrate(output), expected);
    delete applet;
}

// 流量日志累加：同接口累加、不同接口分桶、零增量不产生记录
void NetworkMonitorAppletTest::testAppendToTrafficLog()
{
    NetworkMonitorApplet *applet = createApplet();
    const QString today = QDate::currentDate().toString(QStringLiteral("yyyy-MM-dd"));
    const QString month = QDate::currentDate().toString(QStringLiteral("yyyy-MM"));

    applet->m_activeInterface = QStringLiteral("eth0");
    applet->appendToTrafficLog(100, 50);
    applet->appendToTrafficLog(200, 20);

    // 零增量应被直接忽略
    applet->appendToTrafficLog(0, 0);

    QJsonObject dayEntry = applet->m_trafficLog.value(QStringLiteral("byDay")).toObject()
                               .value(today).toObject();
    QCOMPARE(dayEntry.value(QStringLiteral("eth0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(300));
    QCOMPARE(dayEntry.value(QStringLiteral("eth0")).toObject()
                 .value(QStringLiteral("tx")).toVariant().toLongLong(), qint64(70));

    QJsonObject monthEntry = applet->m_trafficLog.value(QStringLiteral("byMonth")).toObject()
                                 .value(month).toObject();
    QCOMPARE(monthEntry.value(QStringLiteral("eth0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(300));

    // 切换接口后写入新接口的桶，原有接口数据不受影响
    applet->m_activeInterface = QStringLiteral("wlan0");
    applet->appendToTrafficLog(7, 3);

    dayEntry = applet->m_trafficLog.value(QStringLiteral("byDay")).toObject()
                   .value(today).toObject();
    QCOMPARE(dayEntry.value(QStringLiteral("eth0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(300));
    QCOMPARE(dayEntry.value(QStringLiteral("wlan0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(7));

    delete applet;
}

// 超期裁剪：按日最多 30 条、按月最多 12 条，删除的是最旧键而非最新键
void NetworkMonitorAppletTest::testPruneTrafficLog()
{
    NetworkMonitorApplet *applet = createApplet();

    QJsonObject byDay;
    for (int i = 1; i <= 31; ++i) {
        byDay.insert(QStringLiteral("2026-01-%1").arg(i, 2, 10, QLatin1Char('0')), QJsonObject());
    }
    QJsonObject byMonth;
    for (int i = 1; i <= 12; ++i) {
        byMonth.insert(QStringLiteral("2025-%1").arg(i, 2, 10, QLatin1Char('0')), QJsonObject());
    }
    byMonth.insert(QStringLiteral("2026-01"), QJsonObject());

    QJsonObject log;
    log.insert(QStringLiteral("byDay"), byDay);
    log.insert(QStringLiteral("byMonth"), byMonth);
    applet->m_trafficLog = log;

    applet->pruneTrafficLog();

    const QJsonObject prunedDay = applet->m_trafficLog.value(QStringLiteral("byDay")).toObject();
    const QJsonObject prunedMonth = applet->m_trafficLog.value(QStringLiteral("byMonth")).toObject();
    QCOMPARE(prunedDay.size(), 30);
    QCOMPARE(prunedMonth.size(), 12);
    // ISO 键字典序即时间序：最旧被删除，最新保留
    QVERIFY(!prunedDay.contains(QStringLiteral("2026-01-01")));
    QVERIFY(prunedDay.contains(QStringLiteral("2026-01-31")));
    QVERIFY(!prunedMonth.contains(QStringLiteral("2025-01")));
    QVERIFY(prunedMonth.contains(QStringLiteral("2026-01")));

    delete applet;
}

// 日志文件损坏时应降级为空结构继续运行，而不是崩溃或保留半截数据
void NetworkMonitorAppletTest::testLoadTrafficLogInvalid()
{
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("traffic_log.json"));
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write("{ this is not valid json");
    file.close();

    NetworkMonitorApplet *applet = createApplet();
    applet->m_trafficLogPath = path;
    applet->loadTrafficLog();

    QVERIFY(applet->m_trafficLog.contains(QStringLiteral("byDay")));
    QVERIFY(applet->m_trafficLog.contains(QStringLiteral("byMonth")));
    QVERIFY(applet->m_trafficLog.value(QStringLiteral("byDay")).toObject().isEmpty());

    // 清空路径，避免析构函数兜底保存时写入测试目录
    applet->m_trafficLogPath.clear();
    delete applet;
}

// ss -tnp 输出解析：跳过表头、IPv6 方括号与 %接口 后缀剥离、无进程名不崩溃
void NetworkMonitorAppletTest::testParseTcpConnectionList()
{
    NetworkMonitorApplet *applet = createApplet();

    const QString output = QStringLiteral(
        "Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n"
        "0      0          127.0.0.1:631       127.0.0.1:45678 users:((\"cupsd\",pid=1234,fd=7))\n"
        "0      0          [::1]:8080          [2001:db8::1]:443 users:((\"nginx\",pid=99,fd=3))\n"
        "0      0          192.168.1.5%wlp3s0:52001 93.184.216.34:443\n");

    const QVariantList list = applet->parseTcpConnectionList(output);
    QCOMPARE(list.size(), 3);

    const QVariantMap first = list.at(0).toMap();
    QCOMPARE(first.value(QStringLiteral("localAddress")).toString(), QStringLiteral("127.0.0.1"));
    QCOMPARE(first.value(QStringLiteral("localPort")).toInt(), 631);
    QCOMPARE(first.value(QStringLiteral("remoteAddress")).toString(), QStringLiteral("127.0.0.1"));
    QCOMPARE(first.value(QStringLiteral("remotePort")).toInt(), 45678);
    QCOMPARE(first.value(QStringLiteral("processName")).toString(), QStringLiteral("cupsd"));
    QCOMPARE(first.value(QStringLiteral("state")).toString(), QStringLiteral("ESTABLISHED"));

    // IPv6 方括号需被剥离
    const QVariantMap second = list.at(1).toMap();
    QCOMPARE(second.value(QStringLiteral("localAddress")).toString(), QStringLiteral("::1"));
    QCOMPARE(second.value(QStringLiteral("remoteAddress")).toString(), QStringLiteral("2001:db8::1"));
    QCOMPARE(second.value(QStringLiteral("processName")).toString(), QStringLiteral("nginx"));

    // %接口 后缀需被剥离；无进程信息时进程名为空串
    const QVariantMap third = list.at(2).toMap();
    QCOMPARE(third.value(QStringLiteral("localAddress")).toString(), QStringLiteral("192.168.1.5"));
    QCOMPARE(third.value(QStringLiteral("processName")).toString(), QStringLiteral(""));

    // 空输入返回空列表，不崩溃
    QVERIFY(applet->parseTcpConnectionList(QString()).isEmpty());

    delete applet;
}

QTEST_MAIN(NetworkMonitorAppletTest)
#include "tst_networkmonitorapplet.moc"
