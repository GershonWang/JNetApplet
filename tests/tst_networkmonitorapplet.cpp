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
// std::numeric_limits：阈值设置用例需要构造 NaN 与无穷大，验证被归一为"关闭"
#include <limits>

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

    // iw SSID 解析：正常 SSID、含空格与中文、未连接、无 SSID 行
    void testParseIwSsid_data();
    void testParseIwSsid();

    // 速度格式化：三档单位 × 多量级，以及任务栏紧凑写法
    void testFormatSpeed_data();
    void testFormatSpeed();
    void testFormatSpeedCompact_data();
    void testFormatSpeedCompact();

    // 速度单位的读写、非法值忽略与持久化
    void testSpeedUnitSetting();

    // 流量提醒：周期用量合计（与统计窗口同口径）
    void testPeriodUsedBytes();
    // 流量提醒：是否应当提醒的真值表（阈值边界、同周期去重、跨周期重置、关闭）
    void testShouldNotifyQuota_data();
    void testShouldNotifyQuota();
    // 流量提醒：阈值设置的归一化（负数/NaN 按关闭处理）
    void testQuotaLimitSetting();

    // 多接口聚合：合计速率只累加物理网卡
    void testAggregateSpeedOnlyPhysical();
    // 多接口聚合：流量日志按接口分别累加（修正"只计活动接口"）
    void testTrafficLogAllInterfaces();
    // 多接口聚合：开关的持久化与幂等
    void testAggregateSpeedSetting();

    // 流量日志：当日/当月累加与按接口分桶
    void testAppendToTrafficLog();
    // 流量日志：超期裁剪（按日 30 条、按月 12 条）
    void testPruneTrafficLog();
    // 流量日志：文件损坏时降级为空结构而非崩溃
    void testLoadTrafficLogInvalid();
    // 流量日志：文件存在但不可读时禁止写盘，避免覆盖历史
    void testLoadTrafficLogUnreadableBlocksSave();

    // 导出：CSV 序列化（含转义、大数精度、行序）
    void testExportTrafficAsCsv();
    // 导出：JSON 序列化（结构、section、字段完整）
    void testExportTrafficAsJson();
    // 导出：落盘成功/失败路径
    void testSaveExportFile();
    // 导出：降级路径的文件名与扩展名
    void testDefaultExportPath();

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

    // 回归：板上网卡常见 eno1、虚拟机常见 ens33、USB 有线常见 enx<MAC>，
    // 原白名单只认 enp/eth，这三类全被判为非物理——自动选择会跳过主网卡，
    // 多接口聚合会静默漏算它们的流量
    QTest::newRow("eno1") << "eno1" << true;
    QTest::newRow("ens33") << "ens33" << true;
    QTest::newRow("enx00e04c") << "enx00e04c" << true;
    // 排除法对未知命名同样成立（未来新命名不会被漏判）
    QTest::newRow("unknown-but-not-virtual") << "foo0" << true;
    QTest::newRow("wgp") << "wgp2s0" << true;   // 无线 p2p 接口，非 wg 隧道

    // 非物理接口
    QTest::newRow("lo") << "lo" << false;
    QTest::newRow("wg0") << "wg0" << false;
    QTest::newRow("tap0") << "tap0" << false;
    QTest::newRow("virbr0") << "virbr0" << false;
    QTest::newRow("vnet0") << "vnet0" << false;
    QTest::newRow("ifb0") << "ifb0" << false;
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

// iw SSID 解析真值表
// 设计原因：SSID 直接展示给用户，解析错会显示成 "SSID: Home" 这类带前缀的脏值；
// 而未连接时若误判为空以外的内容，会让 QML 的"回退接口名"逻辑失效
void NetworkMonitorAppletTest::testParseIwSsid_data()
{
    QTest::addColumn<QString>("output");
    QTest::addColumn<QString>("expected");

    QTest::newRow("empty") << QString() << QString();
    // 未连接：iw 只输出 "Not connected."
    QTest::newRow("not-connected")
        << QStringLiteral("Not connected.") << QString();
    QTest::newRow("not-connected-with-reason")
        << QStringLiteral("Not connected (Reason: 3)") << QString();

    // 真机实测输出：SSID 行带制表符缩进
    QTest::newRow("real-iw-output")
        << QStringLiteral("Connected to 8c:de:f9:xx:xx:xx (on wlo1)\n"
                          "\tSSID: Home\n"
                          "\tfreq: 5180\n"
                          "\tsignal: -52 dBm\n"
                          "\ttx bitrate: 866.7 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 2")
        << QStringLiteral("Home");

    // SSID 含空格：不能只取第一个词
    QTest::newRow("ssid-with-spaces")
        << QStringLiteral("\tSSID: My Home WiFi 5G\n\tfreq: 5180") << QStringLiteral("My Home WiFi 5G");
    // 中文 SSID
    QTest::newRow("ssid-chinese")
        << QStringLiteral("\tSSID: 我家网络\n\tfreq: 2412") << QStringLiteral("我家网络");
    // 无缩进
    QTest::newRow("no-indent")
        << QStringLiteral("SSID: Office") << QStringLiteral("Office");
    // 只有 "SSID:" 没有内容：视为未连接，不能返回 "SSID:"
    QTest::newRow("ssid-empty-value")
        << QStringLiteral("\tSSID: \n\tfreq: 5180") << QString();
}

void NetworkMonitorAppletTest::testParseIwSsid()
{
    QFETCH(QString, output);
    QFETCH(QString, expected);
    QCOMPARE(NetworkMonitorApplet::parseIwSsid(output), expected);
}

// 速度格式化真值表：三档单位 × 多量级
// 设计原因：单位换算从 QML 移到 C++ 的唯一目的就是能被测试覆盖。
// 这里固定住"智能自动的三级换挡边界""KB/s 不做换挡""Mbps 按十进制 ×8/1e6"
// 三条规则，避免日后改动把 1 MB/s 算成 8.39 Mbps 之类的偏差带进界面
void NetworkMonitorAppletTest::testFormatSpeed_data()
{
    QTest::addColumn<double>("bytes");
    QTest::addColumn<int>("unit");
    QTest::addColumn<QString>("expected");

    // ---- 智能自动（默认）----
    // 0 与负值都显示 0 KB/s，不能出现负号
    QTest::newRow("auto-zero") << 0.0 << 0 << QStringLiteral("0.00 KB/s");
    QTest::newRow("auto-negative") << -1024.0 << 0 << QStringLiteral("0.00 KB/s");
    QTest::newRow("auto-512B") << 512.0 << 0 << QStringLiteral("0.50 KB/s");
    QTest::newRow("auto-1K") << 1024.0 << 0 << QStringLiteral("1.00 KB/s");
    // 边界：刚好 1 MB 应换到 MB/s
    QTest::newRow("auto-1M") << 1048576.0 << 0 << QStringLiteral("1.00 MB/s");
    QTest::newRow("auto-4M11") << 4308992.0 << 0 << QStringLiteral("4.11 MB/s");
    // 边界：刚好 1 GB 应换到 GB/s
    QTest::newRow("auto-1G") << 1073741824.0 << 0 << QStringLiteral("1.00 GB/s");

    // ---- 固定 KB/s：不做任何换挡 ----
    QTest::newRow("kbps-1K") << 1024.0 << 1 << QStringLiteral("1.00 KB/s");
    // 10 MB 仍是 10240.00 KB/s，而不是 10.00 MB/s
    QTest::newRow("kbps-10M") << 10485760.0 << 1 << QStringLiteral("10240.00 KB/s");

    // ---- 固定 Mbps：十进制，bytes×8/1e6 ----
    // 125000 B/s = 1 Mbps
    QTest::newRow("mbps-1") << 125000.0 << 2 << QStringLiteral("1.00 Mbps");
    // 1 MB/s（1048576 B/s）≈ 8.39 Mbps（1024 与 1000 的差异，属预期口径）
    QTest::newRow("mbps-1MBps") << 1048576.0 << 2 << QStringLiteral("8.39 Mbps");
    // 100 Mbps 宽带满速 = 12.5 MB/s
    QTest::newRow("mbps-100") << 12500000.0 << 2 << QStringLiteral("100.00 Mbps");
    QTest::newRow("mbps-zero") << 0.0 << 2 << QStringLiteral("0.00 Mbps");
}

void NetworkMonitorAppletTest::testFormatSpeed()
{
    NetworkMonitorApplet *applet = createApplet();
    QFETCH(double, bytes);
    QFETCH(int, unit);
    QFETCH(QString, expected);
    QCOMPARE(applet->formatSpeed(bytes, unit), expected);
    delete applet;
}

// 任务栏紧凑写法真值表
// 设计原因：任务栏宽度有限，且采用"整数部分 + 小数部分"两段式渲染做小数点对齐，
// 因此 intPart 两种取值的输出都必须逐字固定，否则切换单位时对齐会错位
void NetworkMonitorAppletTest::testFormatSpeedCompact_data()
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

    // 固定 KB/s：任务栏用 K 后缀（与智能自动保持同一视觉密度）
    QTest::newRow("kbps-full") << 198727.0 << 1 << false << QStringLiteral("194.07K");
    QTest::newRow("kbps-10M") << 10485760.0 << 1 << false << QStringLiteral("10240.00K");

    // 固定 Mbps：用户选定保留两位小数
    QTest::newRow("mbps-full") << 125000.0 << 2 << false << QStringLiteral("1.00Mbps");
    QTest::newRow("mbps-100") << 12500000.0 << 2 << false << QStringLiteral("100.00Mbps");
    QTest::newRow("mbps-int-part") << 100000.0 << 2 << true << QStringLiteral("0.80");
    QTest::newRow("mbps-zero") << 0.0 << 2 << false << QStringLiteral("0.00Mbps");
}

void NetworkMonitorAppletTest::testFormatSpeedCompact()
{
    NetworkMonitorApplet *applet = createApplet();
    QFETCH(double, bytes);
    QFETCH(int, unit);
    QFETCH(bool, intPart);
    QFETCH(QString, expected);
    QCOMPARE(applet->formatSpeedCompact(bytes, unit, intPart), expected);
    delete applet;
}

// 速度单位的读写、非法值忽略与持久化
void NetworkMonitorAppletTest::testSpeedUnitSetting()
{
    NetworkMonitorApplet *applet = createApplet();

    // 默认智能自动
    QCOMPARE(applet->speedUnit(), NetworkMonitorApplet::SpeedUnitAuto);

    // 合法值生效
    applet->setSpeedUnit(NetworkMonitorApplet::SpeedUnitMbps);
    QCOMPARE(applet->speedUnit(), NetworkMonitorApplet::SpeedUnitMbps);
    applet->setSpeedUnit(NetworkMonitorApplet::SpeedUnitKBps);
    QCOMPARE(applet->speedUnit(), NetworkMonitorApplet::SpeedUnitKBps);

    // 非法值被忽略，且不会把当前值改坏
    applet->setSpeedUnit(99);
    QCOMPARE(applet->speedUnit(), NetworkMonitorApplet::SpeedUnitKBps);
    applet->setSpeedUnit(-1);
    QCOMPARE(applet->speedUnit(), NetworkMonitorApplet::SpeedUnitKBps);

    // 语义化判据必须与枚举值保持一致：QML 用它们替代 `=== 1` / `=== 2` 的魔法数字，
    // 一旦两者脱节，界面会显示与设置不符的单位且不报错
    applet->setSpeedUnit(NetworkMonitorApplet::SpeedUnitMbps);
    QVERIFY(applet->speedUnitIsMbps());
    QVERIFY(!applet->speedUnitIsKBps());

    applet->setSpeedUnit(NetworkMonitorApplet::SpeedUnitKBps);
    QVERIFY(!applet->speedUnitIsMbps());
    QVERIFY(applet->speedUnitIsKBps());

    applet->setSpeedUnit(NetworkMonitorApplet::SpeedUnitAuto);
    QVERIFY(!applet->speedUnitIsMbps());
    QVERIFY(!applet->speedUnitIsKBps());

    delete applet;
}

// 流量日志累加：同接口累加、不同接口分桶、零增量不产生记录
void NetworkMonitorAppletTest::testAppendToTrafficLog()
{
    NetworkMonitorApplet *applet = createApplet();
    const QString today = QDate::currentDate().toString(QStringLiteral("yyyy-MM-dd"));
    const QString month = QDate::currentDate().toString(QStringLiteral("yyyy-MM"));

    // 接口由调用方显式指定（不再依赖 m_activeInterface）：
    // 原先只累加活动接口，切换网卡后另一块的流量完全不入账
    applet->appendToTrafficLog(QStringLiteral("eth0"), 100, 50);
    applet->appendToTrafficLog(QStringLiteral("eth0"), 200, 20);

    // 零增量应被直接忽略
    applet->appendToTrafficLog(QStringLiteral("eth0"), 0, 0);
    // 空接口名同样忽略（防御性：调用方传空不应产生以空串为键的记录）
    applet->appendToTrafficLog(QString(), 999, 999);

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

    // 另一个接口写入独立的桶，原有接口数据不受影响
    applet->appendToTrafficLog(QStringLiteral("wlan0"), 7, 3);

    dayEntry = applet->m_trafficLog.value(QStringLiteral("byDay")).toObject()
                   .value(today).toObject();
    QCOMPARE(dayEntry.value(QStringLiteral("eth0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(300));
    QCOMPARE(dayEntry.value(QStringLiteral("wlan0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(7));
    // 空接口名不应产生记录
    QVERIFY(!dayEntry.contains(QString()));

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

// 周期用量合计：该周期下所有接口的 rx+tx 之和
// 设计原因：该口径必须与「流量统计」窗口顶部数字一致，否则窗口显示 1.2 GB
// 而提醒说用了 0.8 GB，用户会怀疑哪边错了。此处固定住"跨接口相加"的语义
void NetworkMonitorAppletTest::testPeriodUsedBytes()
{
    QJsonObject log;
    QJsonObject days;

    // 同一天两块网卡：eth0 1GB + 0.5GB，wlo1 0.25GB + 0.25GB = 2GB 整
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

    // 另一天单独一条，用于验证只取指定键
    QJsonObject other;
    other[QStringLiteral("rx")] = qint64(999);
    QJsonObject otherDay;
    otherDay[QStringLiteral("eth0")] = other;
    days[QStringLiteral("2026-11-13")] = otherDay;

    log[QStringLiteral("byDay")] = days;

    // 跨接口合计 = 2_000_000_000
    QCOMPARE(NetworkMonitorApplet::periodUsedBytes(log, QStringLiteral("byDay"),
                                                   QStringLiteral("2026-11-14")),
             qint64(2000000000));
    // 只取指定日期，不会把前一天算进来
    QCOMPARE(NetworkMonitorApplet::periodUsedBytes(log, QStringLiteral("byDay"),
                                                   QStringLiteral("2026-11-13")),
             qint64(999));
    // 不存在的键返回 0（新的一天尚未产生记录）
    QCOMPARE(NetworkMonitorApplet::periodUsedBytes(log, QStringLiteral("byDay"),
                                                   QStringLiteral("2026-11-15")),
             qint64(0));
    // section 不存在时同样返回 0，不崩溃
    QCOMPARE(NetworkMonitorApplet::periodUsedBytes(log, QStringLiteral("byMonth"),
                                                   QStringLiteral("2026-11")),
             qint64(0));

    // 大数精度：超过 2^53 的累计值必须走整数路径，不能被 double 截断
    QJsonObject huge;
    huge[QStringLiteral("rx")] = qint64(9007199254740993LL);   // 2^53 + 1
    QJsonObject hugeDay;
    hugeDay[QStringLiteral("eth0")] = huge;
    QJsonObject hugeLog;
    QJsonObject hugeDays;
    hugeDays[QStringLiteral("2026-11-14")] = hugeDay;
    hugeLog[QStringLiteral("byDay")] = hugeDays;
    QCOMPARE(NetworkMonitorApplet::periodUsedBytes(hugeLog, QStringLiteral("byDay"),
                                                   QStringLiteral("2026-11-14")),
             qint64(9007199254740993LL));
}

// 是否提醒的真值表
// 覆盖：阈值关闭、未达阈值、恰好达到、同周期去重、跨周期重置
void NetworkMonitorAppletTest::testShouldNotifyQuota_data()
{
    QTest::addColumn<qint64>("usedBytes");
    QTest::addColumn<double>("limitGb");
    QTest::addColumn<QString>("currentPeriod");
    QTest::addColumn<QString>("notifiedPeriod");
    QTest::addColumn<bool>("expected");

    // 阈值为 0 = 关闭提醒，无论用了多少
    QTest::newRow("disabled-zero") << qint64(9999999999LL) << 0.0
                                   << QStringLiteral("2026-11-14") << QString() << false;
    // 负数阈值同样视为关闭（配置被改坏时的兜底）
    QTest::newRow("disabled-negative") << qint64(9999999999LL) << -1.0
                                       << QStringLiteral("2026-11-14") << QString() << false;
    // 无穷大阈值：+infinity 满足 `> 0`，若不显式排除会被当成"永不超限"，
    // 更糟的是 limitBytes 转换溢出后行为未定义。必须按关闭处理
    QTest::newRow("disabled-infinity")
        << qint64(9999999999LL) << std::numeric_limits<double>::infinity()
        << QStringLiteral("2026-11-14") << QString() << false;
    // NaN 阈值：与任何数比较都为 false，同样按关闭处理
    QTest::newRow("disabled-nan")
        << qint64(9999999999LL) << std::numeric_limits<double>::quiet_NaN()
        << QStringLiteral("2026-11-14") << QString() << false;

    // 1 GB 阈值 = 1_000_000_000 字节（十进制，不是 1<<30）
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

    // 月周期键（yyyy-MM）：同月去重、跨月重置
    QTest::newRow("month-same") << qint64(50000000000LL) << 20.0
                                << QStringLiteral("2026-11") << QStringLiteral("2026-11") << false;
    QTest::newRow("month-next") << qint64(50000000000LL) << 20.0
                                << QStringLiteral("2026-12") << QStringLiteral("2026-11") << true;

    // 小数阈值：1.5 GB = 1_500_000_000 字节
    QTest::newRow("fractional-limit-hit") << qint64(1500000000LL) << 1.5
                                          << QStringLiteral("2026-11-14") << QString() << true;
    QTest::newRow("fractional-limit-miss") << qint64(1499999999LL) << 1.5
                                           << QStringLiteral("2026-11-14") << QString() << false;
}

void NetworkMonitorAppletTest::testShouldNotifyQuota()
{
    QFETCH(qint64, usedBytes);
    QFETCH(double, limitGb);
    QFETCH(QString, currentPeriod);
    QFETCH(QString, notifiedPeriod);
    QFETCH(bool, expected);

    QCOMPARE(NetworkMonitorApplet::shouldNotifyQuota(usedBytes, limitGb,
                                                     currentPeriod, notifiedPeriod),
             expected);
}

// 阈值设置：非法输入的归一化
// 设计原因：QML 是文本输入框，用户可能键入负数或非法字符；若不收敛，
// 脏值会被持久化，导致阈值永远大于已用量、提醒永不触发且无任何提示
void NetworkMonitorAppletTest::testQuotaLimitSetting()
{
    NetworkMonitorApplet *applet = createApplet();

    // 默认关闭
    QCOMPARE(applet->dailyLimitGb(), 0.0);
    QCOMPARE(applet->monthlyLimitGb(), 0.0);

    // 合法值
    applet->setDailyLimitGb(1.5);
    QCOMPARE(applet->dailyLimitGb(), 1.5);
    applet->setMonthlyLimitGb(20.0);
    QCOMPARE(applet->monthlyLimitGb(), 20.0);

    // 负数与 0 一律归一为 0（关闭）
    applet->setDailyLimitGb(-3.0);
    QCOMPARE(applet->dailyLimitGb(), 0.0);
    applet->setDailyLimitGb(5.0);
    QCOMPARE(applet->dailyLimitGb(), 5.0);
    applet->setDailyLimitGb(0.0);
    QCOMPARE(applet->dailyLimitGb(), 0.0);

    // NaN 与无穷大：按关闭处理，不能写进配置
    applet->setMonthlyLimitGb(std::numeric_limits<double>::quiet_NaN());
    QCOMPARE(applet->monthlyLimitGb(), 0.0);
    applet->setMonthlyLimitGb(std::numeric_limits<double>::infinity());
    QCOMPARE(applet->monthlyLimitGb(), 0.0);

    delete applet;
}

// 多接口聚合：合计速率只累加物理网卡
// 设计原因：tun/docker/veth 的流量实际仍走物理网卡，计入会重复计数
//（代理软件场景下 tun0 与底层 eno1 各算一遍，数字翻倍）
void NetworkMonitorAppletTest::testAggregateSpeedOnlyPhysical()
{
    NetworkMonitorApplet *applet = createApplet();

    // 两块物理网卡 + 一个 VPN 隧道
    applet->m_interfaceList = QStringList() << "eno1" << "wlo1" << "tun0";
    auto setIface = [applet](const QString &name, qint64 rx, qint64 tx) {
        NetworkInterface i;
        i.name = name;
        i.rxBytes = rx;
        i.txBytes = tx;
        applet->m_interfaces[name] = i;
    };
    setIface("eno1", 1000, 500);
    setIface("wlo1", 2000, 800);
    setIface("tun0", 3000, 900);

    // 第一轮：为每个接口建立基线（首轮不产出速度）
    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;
    applet->calculateSpeed();

    // 第二轮：每接口各增加固定字节数
    setIface("eno1", 1000 + 100, 500 + 50);    // +100 / +50
    setIface("wlo1", 2000 + 200, 800 + 80);    // +200 / +80
    setIface("tun0", 3000 + 900, 900 + 900);   // VPN 增量很大，但不应计入合计
    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;
    applet->calculateSpeed();

    // 合计 = 物理网卡之和（约 300 / 130 字节每秒），不含 tun0 的 900
    QVERIFY(applet->totalDownloadSpeed() > 250 && applet->totalDownloadSpeed() < 350);
    QVERIFY(applet->totalUploadSpeed() > 100 && applet->totalUploadSpeed() < 160);

    // 单接口速度仍只反映活动接口，两者并存不冲突
    QVERIFY(applet->downloadSpeed() >= 0);

    delete applet;
}

// 多接口聚合：流量日志按接口分别累加
// 设计原因（缺陷回归）：原实现只累加活动接口，切换网卡后另一块的流量凭空消失，
// 而统计窗口是按接口分行展示的，于是永远缺一行
void NetworkMonitorAppletTest::testTrafficLogAllInterfaces()
{
    NetworkMonitorApplet *applet = createApplet();
    const QString today = QDate::currentDate().toString(QStringLiteral("yyyy-MM-dd"));

    applet->m_interfaceList = QStringList() << "eno1" << "wlo1" << "tun0";
    auto setIface = [applet](const QString &name, qint64 rx, qint64 tx) {
        NetworkInterface i;
        i.name = name;
        i.rxBytes = rx;
        i.txBytes = tx;
        applet->m_interfaces[name] = i;
    };
    setIface("eno1", 1000, 500);
    setIface("wlo1", 2000, 800);
    setIface("tun0", 3000, 900);
    // 活动接口设为 eno1：旧实现只会把 eno1 的增量写进日志
    applet->m_activeInterface = "eno1";

    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;
    applet->calculateSpeed();

    setIface("eno1", 1000 + 100, 500 + 50);
    setIface("wlo1", 2000 + 200, 800 + 80);
    setIface("tun0", 3000 + 900, 900 + 900);
    applet->m_lastTimestampMs = QDateTime::currentMSecsSinceEpoch() - 1000;
    applet->calculateSpeed();

    const QJsonObject dayEntry = applet->m_trafficLog.value(QStringLiteral("byDay"))
                                     .toObject().value(today).toObject();

    // 两块物理网卡都要有记录——这正是旧实现缺失的部分
    QVERIFY(dayEntry.contains(QStringLiteral("eno1")));
    QVERIFY(dayEntry.contains(QStringLiteral("wlo1")));
    // VPN 隧道不计入，避免与物理网卡重复统计
    QVERIFY(!dayEntry.contains(QStringLiteral("tun0")));

    QCOMPARE(dayEntry.value(QStringLiteral("eno1")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(100));
    QCOMPARE(dayEntry.value(QStringLiteral("wlo1")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(), qint64(200));
    QCOMPARE(dayEntry.value(QStringLiteral("wlo1")).toObject()
                 .value(QStringLiteral("tx")).toVariant().toLongLong(), qint64(80));

    // 会话总量同样是物理网卡之和（100 + 200），不含 tun0
    QCOMPARE(applet->m_totalDownload, qint64(300));
    QCOMPARE(applet->m_totalUpload, qint64(130));

    delete applet;
}

// 聚合开关：默认关闭，切换生效并持久化
void NetworkMonitorAppletTest::testAggregateSpeedSetting()
{
    NetworkMonitorApplet *applet = createApplet();

    // 默认关闭：保持原有"只看活动接口"的行为
    QVERIFY(!applet->aggregateSpeed());

    applet->setAggregateSpeed(true);
    QVERIFY(applet->aggregateSpeed());

    // 幂等：重复设置同值不应产生额外副作用
    applet->setAggregateSpeed(true);
    QVERIFY(applet->aggregateSpeed());

    applet->setAggregateSpeed(false);
    QVERIFY(!applet->aggregateSpeed());

    delete applet;
}

// 构造一份用于导出测试的流量日志
// 覆盖多日期、多接口、含特殊字符的接口名与大数值
static QJsonObject makeExportFixture()
{
    auto rec = [](qint64 rx, qint64 tx) {
        QJsonObject o;
        o[QStringLiteral("rx")] = rx;
        o[QStringLiteral("tx")] = tx;
        return o;
    };

    // 2026-11-14：两个接口
    QJsonObject day1;
    day1[QStringLiteral("eno1")] = rec(1000, 500);
    // 含逗号与双引号的接口名：CSV 必须正确转义，否则导出的列数会错
    day1[QStringLiteral("wlan, \"guest\"")] = rec(2000, 800);

    // 2026-11-13：一个接口，数值超过 2^53（double 会丢精度）
    QJsonObject day2;
    day2[QStringLiteral("eth0")] = rec(qint64(9007199254740993LL), 1);

    QJsonObject byDay;
    byDay[QStringLiteral("2026-11-14")] = day1;
    byDay[QStringLiteral("2026-11-13")] = day2;

    QJsonObject byMonth;
    byMonth[QStringLiteral("2026-11")] = day1;

    QJsonObject log;
    log[QStringLiteral("byDay")] = byDay;
    log[QStringLiteral("byMonth")] = byMonth;
    return log;
}

// CSV 导出：表头、行序、转义与大数精度
void NetworkMonitorAppletTest::testExportTrafficAsCsv()
{
    NetworkMonitorApplet *applet = createApplet();
    applet->m_trafficLog = makeExportFixture();

    const QString csv = applet->exportTrafficAsCsv(QStringLiteral("byDay"));
    const QStringList lines = csv.split(QLatin1Char('\n'), Qt::SkipEmptyParts);

    // 表头 + 3 行数据（2026-11-14 两个接口，2026-11-13 一个接口）
    QCOMPARE(lines.size(), 4);
    QCOMPARE(lines.at(0), QStringLiteral("date,interface,download_bytes,upload_bytes,total_bytes"));

    // 行序：日期降序（最新在前），同日期内接口名升序
    QVERIFY(lines.at(1).startsWith(QStringLiteral("2026-11-14,")));
    QVERIFY(lines.at(2).startsWith(QStringLiteral("2026-11-14,")));
    QVERIFY(lines.at(3).startsWith(QStringLiteral("2026-11-13,")));

    // 同一日期内按接口名升序："eno1" < "wlan, \"guest\""
    QVERIFY(lines.at(1).contains(QStringLiteral("eno1")));
    QVERIFY(lines.at(2).contains(QStringLiteral("wlan")));

    // 普通字段不加引号
    QCOMPARE(lines.at(1), QStringLiteral("2026-11-14,eno1,1000,500,1500"));

    // 含逗号与双引号的接口名：必须整体加引号、内部双引号成对转义。
    // 原始名称为  wlan, "guest"  →  CSV 中应为  "wlan, ""guest"""
    QVERIFY(lines.at(2).contains(QStringLiteral("\"wlan, \"\"guest\"\"\"")));

    // 大数精度：超过 2^53 的值不得被 double 截断（9007199254740993 而非 ...992）
    QVERIFY(lines.at(3).contains(QStringLiteral("9007199254740993")));

    // 按月导出：只有一组数据，同样带表头
    const QString monthCsv = applet->exportTrafficAsCsv(QStringLiteral("byMonth"));
    QCOMPARE(monthCsv.split(QLatin1Char('\n'), Qt::SkipEmptyParts).size(), 3);

    // 空 section：只返回表头，不崩溃
    const QString emptyCsv = applet->exportTrafficAsCsv(QStringLiteral("nope"));
    QCOMPARE(emptyCsv, QStringLiteral("date,interface,download_bytes,upload_bytes,total_bytes\n"));

    delete applet;
}

// JSON 导出：结构、section 与字段完整性、大数精度
void NetworkMonitorAppletTest::testExportTrafficAsJson()
{
    NetworkMonitorApplet *applet = createApplet();
    applet->m_trafficLog = makeExportFixture();

    const QString json = applet->exportTrafficAsJson(QStringLiteral("byDay"));
    QJsonParseError err;
    const QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8(), &err);
    QCOMPARE(err.error, QJsonParseError::NoError);
    QVERIFY(doc.isObject());

    const QJsonObject root = doc.object();
    QCOMPARE(root.value(QStringLiteral("section")).toString(), QStringLiteral("byDay"));
    // exportedAt 必须存在且可解析，便于用户判断导出时间
    QVERIFY(!root.value(QStringLiteral("exportedAt")).toString().isEmpty());

    const QJsonObject data = root.value(QStringLiteral("data")).toObject();
    QCOMPARE(data.keys(), (QStringList() << QStringLiteral("2026-11-13")
                                        << QStringLiteral("2026-11-14")));

    // 大数精度：JSON 里的 2^53+1 必须原样保留
    const QJsonObject day2 = data.value(QStringLiteral("2026-11-13")).toObject();
    QCOMPARE(day2.value(QStringLiteral("eth0")).toObject()
                 .value(QStringLiteral("rx")).toVariant().toLongLong(),
             qint64(9007199254740993LL));

    // 按月导出只含对应 section，不串数据
    const QJsonObject monthRoot = QJsonDocument::fromJson(
        applet->exportTrafficAsJson(QStringLiteral("byMonth")).toUtf8()).object();
    QCOMPARE(monthRoot.value(QStringLiteral("section")).toString(), QStringLiteral("byMonth"));
    QVERIFY(monthRoot.value(QStringLiteral("data")).toObject()
                .contains(QStringLiteral("2026-11")));

    delete applet;
}

// 落盘：成功、目录自动创建、失败不崩溃
void NetworkMonitorAppletTest::testSaveExportFile()
{
    NetworkMonitorApplet *applet = createApplet();

    QTemporaryDir dir;
    QVERIFY(dir.isValid());

    // 1. 目标目录尚不存在：应自动创建并写入成功
    const QString nested = dir.filePath(QStringLiteral("a/b/c/export.csv"));
    QVariantMap result = applet->saveExportFile(nested, QStringLiteral("hello,世界\n"));
    QVERIFY2(result.value(QStringLiteral("ok")).toBool(),
             qPrintable(result.value(QStringLiteral("error")).toString()));
    QCOMPARE(result.value(QStringLiteral("path")).toString(), nested);

    QFile check(nested);
    QVERIFY(check.open(QIODevice::ReadOnly));
    QCOMPARE(QString::fromUtf8(check.readAll()), QStringLiteral("hello,世界\n"));
    check.close();

    // 2. 空路径：返回失败并给出原因，不崩溃
    result = applet->saveExportFile(QString(), QStringLiteral("x"));
    QVERIFY(!result.value(QStringLiteral("ok")).toBool());
    QVERIFY(!result.value(QStringLiteral("error")).toString().isEmpty());

    // 3. 路径指向一个目录：写入应失败而非异常
    result = applet->saveExportFile(dir.path(), QStringLiteral("x"));
    QVERIFY(!result.value(QStringLiteral("ok")).toBool());
    QVERIFY(!result.value(QStringLiteral("error")).toString().isEmpty());

    delete applet;
}

// 降级路径：文件名含范围与周期，扩展名容错
void NetworkMonitorAppletTest::testDefaultExportPath()
{
    NetworkMonitorApplet *applet = createApplet();
    const QString today = QDate::currentDate().toString(QStringLiteral("yyyy-MM-dd"));
    const QString thisMonth = QDate::currentDate().toString(QStringLiteral("yyyy-MM"));

    // 按日：daily + 当天日期
    const QString daily = applet->defaultExportPath(QStringLiteral("byDay"), QStringLiteral("csv"));
    QVERIFY(daily.endsWith(QStringLiteral("jnetapplet-daily-%1.csv").arg(today)));

    // 按月：monthly + 当月
    const QString monthly = applet->defaultExportPath(QStringLiteral("byMonth"), QStringLiteral("json"));
    QVERIFY(monthly.endsWith(QStringLiteral("jnetapplet-monthly-%1.json").arg(thisMonth)));

    // 扩展名容错：带点、大写、空值
    QVERIFY(applet->defaultExportPath(QStringLiteral("byDay"), QStringLiteral(".CSV"))
                .endsWith(QStringLiteral(".CSV")));
    QVERIFY(applet->defaultExportPath(QStringLiteral("byDay"), QString())
                .endsWith(QStringLiteral(".csv")));

    // 必须是绝对路径（否则 QML 侧无法判断写到了哪里）
    QVERIFY(QFileInfo(daily).isAbsolute());

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
