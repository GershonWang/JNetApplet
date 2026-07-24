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

QTEST_MAIN(NetworkMonitorAppletTest)
#include "tst_networkmonitorapplet.moc"
