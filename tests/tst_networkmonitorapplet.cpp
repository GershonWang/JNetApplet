// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// NetworkMonitorApplet 单元测试
// 覆盖核心纯逻辑函数：isPhysicalInterface、isWirelessInterface、速度计算
//（含真实间隔/负值钳制/总量累加/切换接口重置基线）、接口选择决策、
// setActiveInterface 接口校验、isLinkDown 链路通断判定
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
#include <QList>
#include <QStandardPaths>
#include <QTemporaryDir>

// geteuid()：判断测试是否以 root 运行（root 可读任意文件，权限类用例需跳过）。
// 放在 Qt 头文件之后包含，避免与 Qt 的 Windows 兼容层头文件顺序冲突
#include <unistd.h>

// dde-shell 的 DS 命名空间（DS_BEGIN_NAMESPACE = namespace ds {）
DS_USE_NAMESPACE

class NetworkMonitorAppletTest : public QObject
{
    Q_OBJECT

private:
    // 测试期间的隔离目录：把 HOME/XDG_CONFIG_HOME 指到临时目录，
    // 使被测代码的配置读写（~/.config/jnetapplet/settings.ini）与流量日志
    //（~/.config/jnetapplet/traffic_log.json）全部落在沙箱内
    QTemporaryDir m_sandbox;
    // 保存原始环境变量，cleanupTestCase 时还原
    QByteArray m_origHome;
    QByteArray m_origXdgConfig;
    bool m_hadHome = false;
    bool m_hadXdgConfig = false;

    // 创建 applet 实例的辅助方法
    // 构造时不调用 init()（会启动定时器），仅用于测试纯逻辑方法
    NetworkMonitorApplet *createApplet()
    {
        return new NetworkMonitorApplet();
    }

private slots:
    // 全局隔离：在第一个用例之前把配置目录重定向到临时目录
    // 设计原因（真实缺陷）：测试会调用 setActiveInterface()，其内部 persistSetting()
    // 直接写 ~/.config/jnetapplet/settings.ini；构造器也会读同一文件。此前跑一次 ctest
    // 就会把用户真实的活动网卡改成测试里的 "wlan0"，并可能触发真实子进程。
    // 在 initTestCase 中重定向环境变量后，所有用例的读写都发生在一次性临时目录里，
    // 既不会污染用户配置，也不会因用户既有配置而让用例结果产生差异
    void initTestCase()
    {
        QVERIFY(m_sandbox.isValid());
        m_hadHome = qEnvironmentVariableIsSet("HOME");
        m_origHome = qgetenv("HOME");
        m_hadXdgConfig = qEnvironmentVariableIsSet("XDG_CONFIG_HOME");
        m_origXdgConfig = qgetenv("XDG_CONFIG_HOME");

        // QStandardPaths 在首次调用后会缓存结果，故必须在任何被测代码运行前设置
        qputenv("HOME", m_sandbox.path().toUtf8());
        qputenv("XDG_CONFIG_HOME", m_sandbox.filePath(QStringLiteral("config")).toUtf8());
        // 双保险：Qt 自带的测试模式（把路径指向 ~/.qttest），与上面的重定向叠加后
        // 即使将来有人改回读写 QStandardPaths::ConfigLocation 也不会碰到真实目录
        QStandardPaths::setTestModeEnabled(true);
    }

    void cleanupTestCase()
    {
        if (m_hadHome) {
            qputenv("HOME", m_origHome);
        } else {
            qunsetenv("HOME");
        }
        if (m_hadXdgConfig) {
            qputenv("XDG_CONFIG_HOME", m_origXdgConfig);
        } else {
            qunsetenv("XDG_CONFIG_HOME");
        }
    }
    // isPhysicalInterface：物理网卡前缀匹配
    void testIsPhysicalInterface_data();
    void testIsPhysicalInterface();

    // isWirelessInterface/isWireless：无线判定唯一入口（含 wlo1 回归）
    void testIsWirelessInterface_data();
    void testIsWirelessInterface();

    // 速度计算：按真实时间间隔计算
    void testCalculateSpeed();
    // 计数器回绕时负值钳制为 0
    void testNegativeDeltaClamped();
    // 总量累加而非取计数器值
    void testTotalAccumulation();
    // 切换活动接口时重置速度基线（跨接口求差会产生数量级错误的假增量）
    void testSwitchInterfaceResetsBaseline();
    // 基线一致性兜底：绕过统一入口直接改写活动接口时也不产生假增量
    void testBaselineGuardCatchesDirectSwitch();
    // 自动选择默认接口的决策规则
    void testChooseDefaultInterface_data();
    void testChooseDefaultInterface();
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
    // 流量日志：文件存在但不可读时禁止写盘，避免覆盖历史
    void testLoadTrafficLogUnreadableBlocksSave();
    // ss 输出解析：IPv4/IPv6/无进程名/空输入
    void testParseTcpConnectionList();

    // 链路断开判定：carrier 三态（读不到/无载波/有载波）与 operstate 组合的真值表
    void testIsLinkDown_data();
    void testIsLinkDown();
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

    // 回归：deepin 25 的无线接口名为 wlo1，曾是漏判现场（协商速率/信号强度恒 0）
    QTest::newRow("wlo1") << "wlo1" << true;
    // USB 无线网卡常见命名 wlx<MAC>
    QTest::newRow("wlx00c0ca") << "wlx00c0ca" << true;

    // 非物理接口
    QTest::newRow("lo") << "lo" << false;
    QTest::newRow("docker0") << "docker0" << false;
    QTest::newRow("veth0") << "veth0" << false;
    QTest::newRow("br-xxx") << "br-xxx" << false;
    QTest::newRow("tun0") << "tun0" << false;
    QTest::newRow("Meta") << "Meta" << false;
    QTest::newRow("empty") << "" << false;
}

// 无线判定的唯一入口测试：命名集合（wlp/wlan/wlo/wlx）与有线前缀的区分。
// 注意：真实机器上优先走 /sys/class/net/<iface>/wireless 探测，测试环境无该目录，
// 因此这里实际覆盖的是前缀兜底分支；能力探测分支由真机验证覆盖
void NetworkMonitorAppletTest::testIsWirelessInterface_data()
{
    QTest::addColumn<QString>("name");
    QTest::addColumn<bool>("expected");

    QTest::newRow("wlp3s0") << "wlp3s0" << true;
    QTest::newRow("wlan0") << "wlan0" << true;
    QTest::newRow("wlo1") << "wlo1" << true;      // deepin 25 真机接口名
    QTest::newRow("wlx00c0ca") << "wlx00c0ca" << true;

    QTest::newRow("enp3s0") << "enp3s0" << false;
    QTest::newRow("eth0") << "eth0" << false;
    QTest::newRow("lo") << "lo" << false;
    QTest::newRow("docker0") << "docker0" << false;
    QTest::newRow("empty") << "" << false;
}

void NetworkMonitorAppletTest::testIsWirelessInterface()
{
    QFETCH(QString, name);
    QFETCH(bool, expected);
    // 判定入口是静态纯函数 isWirelessInterface，QML 经 wirelessInterfaces 属性间接使用它，
    // 故这里同时断言"单接口判定"与"列表属性筛选"两条路径，防止只改一处造成漂移
    QCOMPARE(NetworkMonitorApplet::isWirelessInterface(name), expected);

    NetworkMonitorApplet *applet = createApplet();
    applet->m_interfaceList = QStringList() << name;
    const QStringList wireless = applet->wirelessInterfaces();
    if (expected) {
        QCOMPARE(wireless, QStringList() << name);
    } else {
        QVERIFY(wireless.isEmpty());
    }
    delete applet;
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

// 切换活动接口不得产生"跨接口求差"的假增量
// 设计原因（真机缺陷回归）：活动网卡被热拔后，后端会自动回退到另一块网卡。
// 若切换时只改接口名而不重置速度基线，下一轮 calculateSpeed 会拿
// "新接口自开机累计 − 旧接口累计"当增量——两块网卡累计值可能相差数百 GB，
// 任务栏会显示数百 GB/s，且该假增量会被永久累加进会话总量与日/月流量日志。
// 本用例固定住"切换后首轮只记基线、不产出速度与总量"的行为
void NetworkMonitorAppletTest::testSwitchInterfaceResetsBaseline()
{
    NetworkMonitorApplet *applet = createApplet();

    // 两块网卡：eth0 已有少量流量，wlan0 自开机累计很大（模拟已运行多日的网卡）
    applet->m_interfaceList = QStringList() << "eth0" << "wlan0";
    NetworkInterface eth;
    eth.name = "eth0";
    eth.rxBytes = 1000;
    eth.txBytes = 500;
    NetworkInterface wlan;
    wlan.name = "wlan0";
    wlan.rxBytes = 900000000;   // 约 900 MB，代表旧网卡累计
    wlan.txBytes = 450000000;
    applet->m_interfaces["eth0"] = eth;
    applet->m_interfaces["wlan0"] = wlan;
    applet->m_activeInterface = "eth0";
    applet->m_totalDownload = 0;
    applet->m_totalUpload = 0;

    // 先在 eth0 上跑一轮，建立基线并产出一次正常增量
    applet->m_firstUpdate = true;
    applet->calculateSpeed();
    eth.rxBytes = 2000;
    eth.txBytes = 1000;
    applet->m_interfaces["eth0"] = eth;
    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;
    applet->calculateSpeed();
    const qint64 totalAfterEth = applet->m_totalDownload;
    QCOMPARE(totalAfterEth, qint64(1000));

    // 模拟"活动网卡消失后自动回退到 wlan0"：走统一入口，persist=false
    applet->applyActiveInterface("wlan0", false);
    QCOMPARE(applet->m_activeInterface, QString("wlan0"));
    // 基线仍指向上一个接口：正是 calculateSpeed() 据以判定"需要重记基线"的依据
    QCOMPARE(applet->m_baselineInterface, QString("eth0"));

    // 切换后的第一轮采样：只能记录基线，绝不能把两接口累计值之差当增量
    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;
    applet->calculateSpeed();
    QCOMPARE(applet->m_downloadSpeed, 0.0);
    QCOMPARE(applet->m_uploadSpeed, 0.0);
    QCOMPARE(applet->m_totalDownload, totalAfterEth);   // 总量不得被污染
    QCOMPARE(applet->m_totalUpload, qint64(500));

    // 第二轮才是 wlan0 的真实增量（+1000 rx / +500 tx）
    wlan.rxBytes += 1000;
    wlan.txBytes += 500;
    applet->m_interfaces["wlan0"] = wlan;
    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;
    applet->calculateSpeed();
    QVERIFY(applet->m_downloadSpeed > 900 && applet->m_downloadSpeed < 1100);
    QCOMPARE(applet->m_totalDownload, totalAfterEth + 1000);

    delete applet;
}

// 基线一致性兜底：即使有代码绕过统一入口直接改写 m_activeInterface，
// 也不得把跨接口的累计差当成增量（宁可丢一次采样）
void NetworkMonitorAppletTest::testBaselineGuardCatchesDirectSwitch()
{
    NetworkMonitorApplet *applet = createApplet();

    applet->m_interfaceList = QStringList() << "eth0" << "wlan0";
    NetworkInterface eth;
    eth.name = "eth0";
    eth.rxBytes = 1000;
    eth.txBytes = 0;
    NetworkInterface wlan;
    wlan.name = "wlan0";
    wlan.rxBytes = 500000000;   // 与 eth0 差距巨大
    wlan.txBytes = 0;
    applet->m_interfaces["eth0"] = eth;
    applet->m_interfaces["wlan0"] = wlan;
    applet->m_activeInterface = "eth0";
    applet->m_totalDownload = 0;

    // 建立 eth0 的基线
    applet->m_firstUpdate = true;
    applet->calculateSpeed();

    // 绕过统一入口，直接改写活动接口（模拟将来新增代码路径的疏漏）
    applet->m_activeInterface = "wlan0";
    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;
    applet->calculateSpeed();

    // 兜底生效：本轮只重记基线，总量与速度都不得出现数量级错误的值
    QCOMPARE(applet->m_totalDownload, qint64(0));
    QCOMPARE(applet->m_downloadSpeed, 0.0);
    QCOMPARE(applet->m_baselineInterface, QString("wlan0"));

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

// 自动选择规则：有流量的物理网卡 > 有流量的任意接口 > 第一个
// 设计原因：该规则此前内联在 readNetworkStats() 的嵌套循环里，无法单独测试；
// 抽出为 chooseDefaultInterface() 后成为可断言纯决策逻辑
void NetworkMonitorAppletTest::testChooseDefaultInterface_data()
{
    QTest::addColumn<QStringList>("interfaces");
    // 与 interfaces 一一对应的 rx 值（用 -1 表示该接口不在 m_interfaces 中）
    QTest::addColumn<QList<qint64>>("rxValues");
    QTest::addColumn<QString>("expected");

    // 无接口：返回空串
    QTest::newRow("empty") << QStringList() << QList<qint64>() << QString();

    // 物理网卡有流量，虚拟接口流量更大 → 仍选物理网卡
    QTest::newRow("prefer-physical-with-traffic")
        << (QStringList() << "Meta" << "enp3s0")
        << (QList<qint64>() << 9000000 << 100)
        << QString("enp3s0");

    // 物理网卡都无流量 → 选有流量的虚拟接口
    QTest::newRow("fallback-to-virtual-with-traffic")
        << (QStringList() << "Meta" << "enp3s0")
        << (QList<qint64>() << 100 << 0)
        << QString("Meta");

    // 全部无流量 → 选第一个
    QTest::newRow("fallback-to-first")
        << (QStringList() << "Meta" << "enp3s0")
        << (QList<qint64>() << 0 << 0)
        << QString("Meta");
}

void NetworkMonitorAppletTest::testChooseDefaultInterface()
{
    QFETCH(QStringList, interfaces);
    QFETCH(QList<qint64>, rxValues);
    QFETCH(QString, expected);

    NetworkMonitorApplet *applet = createApplet();
    applet->m_interfaceList = interfaces;
    for (int i = 0; i < interfaces.size(); ++i) {
        NetworkInterface iface;
        iface.name = interfaces.at(i);
        iface.rxBytes = rxValues.value(i, 0);
        iface.txBytes = 0;
        applet->m_interfaces[interfaces.at(i)] = iface;
    }

    QCOMPARE(applet->chooseDefaultInterface(), expected);
    delete applet;
}

// iw dev link 输出的 bitrate 解析：M/G 单位换算、rx/tx 方向、非法输入
// 设计原因：此前的用例只用了"以 bitrate: 开头"的理想化输入，而真实 iw 输出
// 带 rx/tx 前缀且单位是 MBit/s（大写 B），导致用例全绿但真机始终解析不出速率。
// 故这里补入真机实测的完整输出样本，保证用例与真实数据同构。
void NetworkMonitorAppletTest::testParseIwBitrate_data()
{
    QTest::addColumn<QString>("output");
    QTest::addColumn<int>("expected");

    QTest::newRow("empty") << QString() << 0;
    QTest::newRow("no-bitrate") << QStringLiteral("Connected to 11:22:33:44:55:66 (on wlp3s0)") << 0;

    // 真机实测样本（wlo1，deepin 25）：rx/tx 前缀 + MBit/s 大写 B + 制表符缩进
    // 取值约定为 tx 优先（发送方向代表协商上限）
    QTest::newRow("real-iw-output")
        << QStringLiteral("Connected to 8c:de:f9:xx:xx:xx (on wlo1)\n"
                          "\tSSID: Home\n"
                          "\tfreq: 5180\n"
                          "\tsignal: -52 dBm\n"
                          "\ttx bitrate: 866.7 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 2\n"
                          "\trx bitrate: 390.0 MBit/s VHT-MCS 8 80MHz short GI VHT-NSS 1")
        << 867;
    // rx 在 tx 之前时仍应取 tx
    QTest::newRow("tx-preferred-over-rx")
        << QStringLiteral("\trx bitrate: 390.0 MBit/s\n\ttx bitrate: 866.7 MBit/s") << 867;
    // 仅 rx 时回退取 rx
    QTest::newRow("rx-fallback") << QStringLiteral("\trx bitrate: 390.0 MBit/s") << 390;

    // 理想化的裸 bitrate 行（保留原有覆盖，兼容其它输出形态）
    QTest::newRow("mbps") << QStringLiteral("    bitrate: 54.0 MBit/s") << 54;
    QTest::newRow("mbps-fraction") << QStringLiteral("    bitrate: 866.7 MBit/s") << 867;
    QTest::newRow("gbps") << QStringLiteral("    bitrate: 1.2 Gbit/s") << 1200;
    // 单位小写也接受（不同 iw 版本/本地化差异）
    QTest::newRow("lowercase-unit") << QStringLiteral("    bitrate: 72.2 mbit/s") << 72;
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
    // 解析失败的文件内容已无价值，应允许重建成合法空结构（不禁止写盘）
    QVERIFY(!applet->m_trafficLogWriteBlocked);

    // 清空路径，避免析构函数兜底保存时写入测试目录
    applet->m_trafficLogPath.clear();
    delete applet;
}

// 文件存在但不可读时：禁止写盘，避免用内存里的空结构覆盖磁盘上的完整历史
// 设计原因（缺陷回归）：QSaveFile 依靠"临时文件 + rename"，即使原文件不可读也能
// 成功覆盖。若不作保护，权限被改（chmod 000、属主变 root、ACL）后的一次兜底保存
// 就会把 30 天 byDay/byMonth 静默清零，用户完全无感知。
// 注意：以 root 运行时 chmod 不生效（root 可读任意文件），此时跳过用例
void NetworkMonitorAppletTest::testLoadTrafficLogUnreadableBlocksSave()
{
    if (::geteuid() == 0) {
        QSKIP("以 root 运行，无法通过权限构造不可读文件");
    }

    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("traffic_log.json"));

    // 先写入一份带历史数据的合法日志
    const QByteArray original =
        R"({"byDay":{"2026-01-01":{"eth0":{"rx":100,"tx":50}}},"byMonth":{}})";
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    file.write(original);
    file.close();
    // 只保留属主写权限：属主（非 root）随后无法再读该文件，模拟"权限被改坏"的场景。
    // root 会绕过权限位，故本用例在文件开头已对 root 跳过
    QVERIFY(file.setPermissions(QFileDevice::WriteOwner));

    NetworkMonitorApplet *applet = createApplet();
    applet->m_trafficLogPath = path;
    applet->loadTrafficLog();

    // 加载失败后应禁止写盘（无论内存结构如何，都不得覆盖磁盘上的历史）
    QVERIFY(applet->m_trafficLogWriteBlocked);

    // 尝试保存：文件内容必须原样保留
    applet->saveTrafficLog();

    // 校验前先恢复读权限（否则本进程自己也读不到该文件）
    QVERIFY(file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner));
    QFile check(path);
    QVERIFY(check.open(QIODevice::ReadOnly));
    QCOMPARE(check.readAll(), original);
    check.close();

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

// 链路断开判定真值表
// carrier 三态（-1 读不到 / 0 无载波 / 1 有载波）与 operstate 的组合。
// 优先级：operstate 明确表态（up / down / dormant 等）时以其为准，
// 只有它含糊（unknown / 空）时才回退看 carrier
void NetworkMonitorAppletTest::testIsLinkDown_data()
{
    QTest::addColumn<int>("carrier");
    QTest::addColumn<QString>("operState");
    QTest::addColumn<bool>("expected");

    // ★ 真机实测回归：`ip link set wlo1 down` 后 carrier 读取返回 EINVAL（读不到，
    // 即 -1），operstate 明确为 "down"。原实现把 carrier<0 放最前一律返回未断开，
    // 导致断连态永不显示；此用例固定住修正后的行为
    QTest::newRow("wifi-down-carrier-unreadable") << -1 << QStringLiteral("down") << true;
    // operstate 明确表态时的其余组合
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

void NetworkMonitorAppletTest::testIsLinkDown()
{
    QFETCH(int, carrier);
    QFETCH(QString, operState);
    QFETCH(bool, expected);

    // isLinkDown 为静态纯函数，直接按值断言，不依赖 applet 实例状态
    QCOMPARE(NetworkMonitorApplet::isLinkDown(carrier, operState), expected);
}

QTEST_MAIN(NetworkMonitorAppletTest)
#include "tst_networkmonitorapplet.moc"
