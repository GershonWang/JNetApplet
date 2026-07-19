// SPDX-FileCopyrightText: 2024 MyCompany
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#include "networkmonitorapplet.h"
#include <pluginfactory.h>

#include <QFile>
#include <QTextStream>
#include <QDebug>
#include <QDir>
#include <QRegularExpression>
#include <QNetworkInterface>

DS_BEGIN_NAMESPACE

NetworkMonitorApplet::NetworkMonitorApplet(QObject *parent)
    : DApplet(parent)
    , m_refreshTimer(nullptr)
    , m_lastRxBytes(0)
    , m_lastTxBytes(0)
    , m_downloadSpeed(0)
    , m_uploadSpeed(0)
    , m_totalDownload(0)
    , m_totalUpload(0)
    , m_ready(false)
    , m_firstUpdate(true)
{
}

NetworkMonitorApplet::~NetworkMonitorApplet()
{
}

bool NetworkMonitorApplet::load()
{
    return DApplet::load();
}

bool NetworkMonitorApplet::init()
{
    detectInterfaces();
    
    // 启动定时刷新
    m_refreshTimer = new QTimer(this);
    connect(m_refreshTimer, &QTimer::timeout, this, &NetworkMonitorApplet::refresh);
    m_refreshTimer->start(1000); // 每秒刷新一次
    
    // 初始读取
    readNetworkStats();
    
    return DApplet::init();
}

double NetworkMonitorApplet::downloadSpeed() const
{
    return static_cast<double>(m_downloadSpeed);
}

double NetworkMonitorApplet::uploadSpeed() const
{
    return static_cast<double>(m_uploadSpeed);
}

double NetworkMonitorApplet::totalDownload() const
{
    return static_cast<double>(m_totalDownload);
}

double NetworkMonitorApplet::totalUpload() const
{
    return static_cast<double>(m_totalUpload);
}

QStringList NetworkMonitorApplet::networkInterfaces() const
{
    return m_interfaceList;
}

QStringList NetworkMonitorApplet::interfaceStats() const
{
    QStringList stats;
    for (const QString &name : m_interfaceList) {
        if (m_interfaces.contains(name)) {
            const NetworkInterface &iface = m_interfaces[name];
            stats << QString("%1|%2|%3|%4|%5")
                .arg(iface.name)
                .arg(iface.rxBytes)
                .arg(iface.txBytes)
                .arg(iface.rxPackets)
                .arg(iface.txPackets);
        }
    }
    return stats;
}

bool NetworkMonitorApplet::ready() const
{
    return m_ready;
}

QString NetworkMonitorApplet::activeInterface() const
{
    return m_activeInterface;
}

// 返回活动接口的 IPv4 地址，供 QML 显示
QString NetworkMonitorApplet::ipAddress() const
{
    return m_ipAddress;
}

// 返回活动接口的 IPv6 全球地址，供 QML 显示
QString NetworkMonitorApplet::ipv6Address() const
{
    return m_ipv6Address;
}

// 返回插件版本号，从 dde-shell 插件元数据（metadata.json）读取
// 版本唯一源为 CMakeLists.txt 的 project(VERSION)，经 configure_file 写入 metadata.json，
// dde-shell 加载时存入 DPluginMetaData，此处通过继承自 DApplet 的 pluginMetaData() 读取
QString NetworkMonitorApplet::version() const
{
    // DPluginMetaData::value() 已在 "Plugin" 层级内部查找（源码：frame/pluginmetadata.cpp）
    // metadata.json 的 { "Plugin": { "Version": "x.y.z" } } 被 DPluginMetaData 加载后，
    // value("Version") 直接返回版本号，无需再 .value("Plugin").toMap() 展开
    return pluginMetaData().value("Version").toString();
}

void NetworkMonitorApplet::refresh()
{
    readNetworkStats();
}

void NetworkMonitorApplet::setActiveInterface(const QString &interface)
{
    if (m_activeInterface != interface) {
        m_activeInterface = interface;
        m_firstUpdate = true;
        emit activeInterfaceChanged();
        // 接口切换后立即检测新接口的 IP 地址
        detectIpAddress();
    }
}

void NetworkMonitorApplet::readNetworkStats()
{
    QFile file("/proc/net/dev");
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qDebug() << "Failed to open /proc/net/dev";
        return;
    }
    
    QTextStream stream(&file);
    QStringList lines = stream.readAll().split('\n', Qt::SkipEmptyParts);
    file.close();
    
    QMap<QString, NetworkInterface> newInterfaces;
    
    // 跳过前两行标题
    for (int i = 2; i < lines.size(); ++i) {
        QString line = lines[i].trimmed();
        if (line.isEmpty()) continue;
        
        // 格式: "interface: rx_bytes rx_packets rx_errors rx_dropped ... tx_bytes tx_packets tx_errors tx_dropped ..."
        QRegularExpression re("^([^:]+):\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+\\d+\\s+\\d+\\s+\\d+\\s+\\d+\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)");
        QRegularExpressionMatch match = re.match(line);
        
        if (match.hasMatch()) {
            NetworkInterface iface;
            iface.name = match.captured(1);
            iface.rxBytes = match.captured(2).toLongLong();
            iface.rxPackets = match.captured(3).toLongLong();
            iface.rxErrors = match.captured(4).toLongLong();
            iface.rxDropped = match.captured(5).toLongLong();
            iface.txBytes = match.captured(6).toLongLong();
            iface.txPackets = match.captured(7).toLongLong();
            iface.txErrors = match.captured(8).toLongLong();
            iface.txDropped = match.captured(9).toLongLong();
            
            // 过滤掉回环接口和虚拟接口
            if (iface.name != "lo" && !iface.name.startsWith("veth") && 
                !iface.name.startsWith("docker") && !iface.name.startsWith("br-")) {
                newInterfaces[iface.name] = iface;
            }
        }
    }
    
    // 检测接口变化
    if (newInterfaces.keys() != m_interfaces.keys()) {
        m_interfaceList = newInterfaces.keys();
        m_interfaces = newInterfaces;
        
        // 自动选择活动接口
        if (m_activeInterface.isEmpty() && !m_interfaceList.isEmpty()) {
            // 优先选择物理网卡（wlp/wlan/enp/eth）中有流量的接口，
            // 避免选中 Meta/tun0 等虚拟代理接口作为默认显示
            for (const QString &name : m_interfaceList) {
                if (!isPhysicalInterface(name)) continue;
                const NetworkInterface &iface = m_interfaces[name];
                if (iface.rxBytes > 0 || iface.txBytes > 0) {
                    m_activeInterface = name;
                    break;
                }
            }
            // 其次选择任意有流量的接口（物理网卡都无流量时的兜底）
            if (m_activeInterface.isEmpty()) {
                for (const QString &name : m_interfaceList) {
                    const NetworkInterface &iface = m_interfaces[name];
                    if (iface.rxBytes > 0 || iface.txBytes > 0) {
                        m_activeInterface = name;
                        break;
                    }
                }
            }
            // 最后选第一个（无任何流量时）
            if (m_activeInterface.isEmpty()) {
                m_activeInterface = m_interfaceList.first();
            }
            emit activeInterfaceChanged();
        }
        
        m_ready = !m_interfaceList.isEmpty();
        emit interfacesChanged();
        emit readyChanged();
    } else {
        m_interfaces = newInterfaces;
    }
    
    calculateSpeed();
    emit statsChanged();
    // 每次刷新都检测 IP，以应对 DHCP 续约等 IP 变更场景
    detectIpAddress();
}

void NetworkMonitorApplet::calculateSpeed()
{
    qint64 currentRxBytes = getActiveRxBytes();
    qint64 currentTxBytes = getActiveTxBytes();
    
    if (m_firstUpdate) {
        m_firstUpdate = false;
        m_lastRxBytes = currentRxBytes;
        m_lastTxBytes = currentTxBytes;
        return;
    }
    
    // 计算速度（字节/秒）
    m_downloadSpeed = currentRxBytes - m_lastRxBytes;
    m_uploadSpeed = currentTxBytes - m_lastTxBytes;
    
    // 更新总量
    m_totalDownload = currentRxBytes;
    m_totalUpload = currentTxBytes;
    
    m_lastRxBytes = currentRxBytes;
    m_lastTxBytes = currentTxBytes;
    
    emit speedChanged();
    emit totalChanged();
}

void NetworkMonitorApplet::detectInterfaces()
{
    QDir sysClass("/sys/class/net");
    if (!sysClass.exists()) return;
    
    QStringList entries = sysClass.entryList(QDir::Dirs | QDir::NoDotAndDotDot);
    m_interfaceList.clear();
    
    for (const QString &entry : entries) {
        // 过滤回环接口
        if (entry != "lo") {
            m_interfaceList << entry;
        }
    }
    
    m_ready = !m_interfaceList.isEmpty();
    emit interfacesChanged();
    emit readyChanged();
}

qint64 NetworkMonitorApplet::getActiveRxBytes() const
{
    if (m_activeInterface.isEmpty() || !m_interfaces.contains(m_activeInterface)) {
        return 0;
    }
    return m_interfaces[m_activeInterface].rxBytes;
}

qint64 NetworkMonitorApplet::getActiveTxBytes() const
{
    if (m_activeInterface.isEmpty() || !m_interfaces.contains(m_activeInterface)) {
        return 0;
    }
    return m_interfaces[m_activeInterface].txBytes;
}

// 检测活动接口的 IPv4 与 IPv6 地址
// IPv4：跳过 loopback，取第一个
// IPv6：跳过 loopback 和 link-local (fe80::)，取第一个全球地址
// 任一地址变化时分别 emit 对应信号通知 QML 更新
// 设计原因：DHCP 续约、网络切换、IPv6 SLAAC 等场景下地址可能变化，需持续检测
void NetworkMonitorApplet::detectIpAddress()
{
    QString newIp;
    QString newIpv6;
    if (!m_activeInterface.isEmpty()) {
        QNetworkInterface iface = QNetworkInterface::interfaceFromName(m_activeInterface);
        for (const QNetworkAddressEntry &entry : iface.addressEntries()) {
            // IPv4：跳过 loopback，取第一个
            if (entry.ip().protocol() == QAbstractSocket::IPv4Protocol
                && !entry.ip().isLoopback()
                && newIp.isEmpty()) {
                newIp = entry.ip().toString();
            }
            // IPv6：跳过 loopback 和 link-local (fe80::)，取第一个全球地址
            if (entry.ip().protocol() == QAbstractSocket::IPv6Protocol
                && !entry.ip().isLoopback()
                && !entry.ip().isLinkLocal()
                && newIpv6.isEmpty()) {
                newIpv6 = entry.ip().toString();
            }
        }
    }
    if (m_ipAddress != newIp) {
        m_ipAddress = newIp;
        emit ipAddressChanged();
    }
    if (m_ipv6Address != newIpv6) {
        m_ipv6Address = newIpv6;
        emit ipv6AddressChanged();
    }
}

// 判断是否为物理网卡
// 物理网卡前缀：无线 wlp/wlan/wifi，有线 enp/eth
// 虚拟接口（Meta/tun/tap/docker/veth/br-）返回 false，
// 用于自动选择时优先真实网卡而非代理 TUN 接口
bool NetworkMonitorApplet::isPhysicalInterface(const QString &name) const
{
    return name.startsWith("wlp") || name.startsWith("wlan")
        || name.startsWith("enp") || name.startsWith("eth");
}

D_APPLET_CLASS(NetworkMonitorApplet)

DS_END_NAMESPACE

#include "networkmonitorapplet.moc"