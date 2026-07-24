// SPDX-FileCopyrightText: 2026 Jokul
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
#include <QColor>
#include <QSettings>
#include <QStandardPaths>
#include <QTranslator>
#include <QLocale>
#include <QCoreApplication>

DS_BEGIN_NAMESPACE

NetworkMonitorApplet::NetworkMonitorApplet(QObject *parent)
    : DApplet(parent)
    , m_refreshTimer(nullptr)
    , m_lastRxBytes(0)
    , m_lastTxBytes(0)
    , m_lastTimestampMs(0)
    , m_downloadSpeed(0)
    , m_uploadSpeed(0)
    , m_totalDownload(0)
    , m_totalUpload(0)
    , m_ready(false)
    , m_firstUpdate(true)
    , m_textColor()
{
    // 从独立配置文件读取持久化的字体颜色
    // 设计原因：使用独立配置文件避免污染 dde-shell 的共享配置，
    // 空串表示"跟随系统"，由 QML 层回退到 primaryText 实现
    const QString configPath = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
                               + QStringLiteral("/jnetapplet/settings.ini");
    QSettings settings(configPath, QSettings::IniFormat);
    if (settings.contains(QStringLiteral("textColor"))) {
        const QString saved = settings.value(QStringLiteral("textColor")).toString();
        // 空串合法（跟随系统），非空则校验是否为合法颜色值
        if (saved.isEmpty() || QColor::isValidColorName(saved)) {
            m_textColor = saved;
        }
        // 若校验失败则保持空串默认值（跟随系统），不抛出也不记录
    }

    // 从配置文件读取持久化的活动接口，启动时自动恢复用户上次选择
    // 设计原因：用户手动选择的网卡应跨重启保持，而非每次启动重新自动检测；
    // 若保存的接口已不存在（如 USB 网卡拔出），readNetworkStats 会清空并回退到自动选择
    if (settings.contains(QStringLiteral("activeInterface"))) {
        m_activeInterface = settings.value(QStringLiteral("activeInterface")).toString();
    }
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
    // 加载翻译文件：根据系统语言加载对应的 .qm 文件
    // 设计原因：QML 源串为英文，中文翻译通过 .qm 文件在运行时加载。
    // 翻译上下文为 QML 文件名（如 "networkview"、"AboutWindow"），
    // 安装到 QCoreApplication 后 qsTr() 自动查找匹配。
    QTranslator *translator = new QTranslator(this);
    const QString locale = QLocale::system().name();
    if (translator->load(QStringLiteral("jnetapplet_%1.qm").arg(locale),
                         QStringLiteral(TRANSLATIONS_DIR))) {
        qApp->installTranslator(translator);
    }

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
    return m_downloadSpeed;
}

double NetworkMonitorApplet::uploadSpeed() const
{
    return m_uploadSpeed;
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
    const QString ver = pluginMetaData().value("Version").toString();
    // 兜底：元数据未加载或无 Version 字段时回退到编译时版本号
    // 设计原因：QML 各处 version 属性兜底不一致（networkview.qml 有 "1.0"，AboutWindow 无），
    // 统一在后端兜底，避免 AboutWindow 版本行显示空白
    return ver.isEmpty() ? QStringLiteral(PROJECT_VERSION) : ver;
}

// 返回任务栏网速字体颜色，空串表示跟随系统主题
QString NetworkMonitorApplet::textColor() const
{
    return m_textColor;
}

// 设置任务栏网速字体颜色，空串表示跟随系统主题
// 设计原因：
//   - 空串语义：空串作为"跟随系统"的语义值，QML 层用 textColor ? textColor : primaryText 做回退，
//     避免后端硬编码系统色
//   - 校验逻辑：非空颜色值通过 QColor::isValidColor 校验，无效值直接忽略，不存储不发射信号
//   - 独立配置文件：使用 ~/.config/jnetapplet/settings.ini 而非 dde-shell 共享配置，
//     避免污染其他组件的配置空间
void NetworkMonitorApplet::setTextColor(const QString &color)
{
    // 空串视为合法（表示跟随系统），不校验
    if (!color.isEmpty() && !QColor::isValidColorName(color)) {
        return;
    }

    if (m_textColor == color) {
        return;
    }

    m_textColor = color;

    // 持久化到独立配置文件
    const QString configPath = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
                               + QStringLiteral("/jnetapplet/settings.ini");
    QSettings settings(configPath, QSettings::IniFormat);
    settings.setValue(QStringLiteral("textColor"), m_textColor);
    settings.sync();

    emit textColorChanged();
}

// 返回当前活动接口的下行速度历史，转换为 QVariantList of QPointF 供 QML 使用
// 设计原因：QPointF 仅携带 x/y 两个值，上传与下载分别对应两个列表
QVariantList NetworkMonitorApplet::speedHistoryDownload() const
{
    QVariantList list;
    if (m_activeInterface.isEmpty() || !m_speedHistory.contains(m_activeInterface)) {
        return list;
    }
    const QVector<SpeedSample> &samples = m_speedHistory[m_activeInterface];
    list.reserve(samples.size());
    for (const SpeedSample &s : samples) {
        list.append(QPointF(s.timestamp, s.downloadSpeed));
    }
    return list;
}

// 返回当前活动接口的上行速度历史，结构同 speedHistoryDownload
QVariantList NetworkMonitorApplet::speedHistoryUpload() const
{
    QVariantList list;
    if (m_activeInterface.isEmpty() || !m_speedHistory.contains(m_activeInterface)) {
        return list;
    }
    const QVector<SpeedSample> &samples = m_speedHistory[m_activeInterface];
    list.reserve(samples.size());
    for (const SpeedSample &s : samples) {
        list.append(QPointF(s.timestamp, s.uploadSpeed));
    }
    return list;
}

void NetworkMonitorApplet::refresh()
{
    readNetworkStats();
}

void NetworkMonitorApplet::setActiveInterface(const QString &interface)
{
    // 校验接口是否存在于当前接口列表中，无效接口名直接忽略
    // 设计原因：传入不存在的接口名会被持久化到配置文件，且当前会话期间
    // getActiveRxBytes() 返回 0 导致速度恒为 0，用户困惑；
    // 虽然下次启动 readNetworkStats() 会清空回退，但当前会话不应接受无效值
    if (!m_interfaceList.contains(interface)) {
        return;
    }

    if (m_activeInterface != interface) {
        m_activeInterface = interface;
        m_firstUpdate = true;

        // 持久化到配置文件，下次启动自动加载用户选择的网卡
        // 设计原因：弹窗 chip 和设置窗口都调用此方法，统一持久化保证两处选择一致
        const QString configPath = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
                                   + QStringLiteral("/jnetapplet/settings.ini");
        QSettings settings(configPath, QSettings::IniFormat);
        settings.setValue(QStringLiteral("activeInterface"), m_activeInterface);
        settings.sync();

        emit activeInterfaceChanged();
        // 接口切换后通知 QML 趋势图切换显示新接口的历史数据
        emit speedHistoryChanged();
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

        // 清理已消失接口的历史缓冲和基线数据，避免内存泄漏
        // 设计原因：USB 网卡、VPN 隧道等接口可能随时消失，其历史数据和基线不再需要
        const QStringList oldIfaces = m_speedHistory.keys();
        for (const QString &name : oldIfaces) {
            if (!newInterfaces.contains(name)) {
                m_speedHistory.remove(name);
                m_lastRxBytesByIface.remove(name);
                m_lastTxBytesByIface.remove(name);
            }
        }

        // 保存的接口已不在当前列表中（如 USB 网卡拔出），清空让自动选择接管
        if (!m_activeInterface.isEmpty() && !m_interfaceList.contains(m_activeInterface)) {
            m_activeInterface.clear();
        }

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
    // 每次刷新都检测 IP，以应对 DHCP 续约等 IP 变更场景
    detectIpAddress();
}

void NetworkMonitorApplet::calculateSpeed()
{
    // 当前采样时间戳（毫秒），用于按真实流逝时间计算速度
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const qint64 nowSec = QDateTime::currentSecsSinceEpoch();
    const double elapsedSec = (nowMs - m_lastTimestampMs) / 1000.0;
    m_lastTimestampMs = nowMs;

    // ---- 活动接口速度计算（用于任务栏显示和总量累加）----
    if (m_firstUpdate) {
        // 首次更新或接口切换后：仅记录基线，不计算速度
        m_firstUpdate = false;
        m_lastRxBytes = getActiveRxBytes();
        m_lastTxBytes = getActiveTxBytes();
    } else if (elapsedSec > 0 && !m_activeInterface.isEmpty()) {
        // 按真实流逝时间计算速度（字节/秒），避免定时器抖动失真
        const qint64 currentRxBytes = getActiveRxBytes();
        const qint64 currentTxBytes = getActiveTxBytes();
        // 计数器回绕/接口重置时差值可能为负，钳制为 0 避免显示负速度
        const qint64 rxDelta = currentRxBytes - m_lastRxBytes;
        const qint64 txDelta = currentTxBytes - m_lastTxBytes;
        const qint64 rxDeltaClamped = rxDelta > 0 ? rxDelta : 0;
        const qint64 txDeltaClamped = txDelta > 0 ? txDelta : 0;
        m_downloadSpeed = rxDeltaClamped / elapsedSec;
        m_uploadSpeed = txDeltaClamped / elapsedSec;
        // 累加会话总量：总量 = 本次会话期间所有活动接口的流量总和
        m_totalDownload += rxDeltaClamped;
        m_totalUpload += txDeltaClamped;
        m_lastRxBytes = currentRxBytes;
        m_lastTxBytes = currentTxBytes;
    }

    // ---- 为所有接口采集速度历史（非仅活动接口）----
    // 设计原因：原仅采集活动接口，切换到非活动接口时趋势图为空需等待数分钟。
    // 改为遍历所有接口计算各自速度并追加历史，切换接口时趋势图立即有数据。
    if (elapsedSec > 0) {
        for (const QString &name : m_interfaceList) {
            if (!m_interfaces.contains(name)) continue;
            const NetworkInterface &iface = m_interfaces[name];

            // 接口尚未初始化基线（首次采集或运行中新增的接口），记录基线跳过本次
            if (!m_lastRxBytesByIface.contains(name)) {
                m_lastRxBytesByIface[name] = iface.rxBytes;
                m_lastTxBytesByIface[name] = iface.txBytes;
                continue;
            }

            const qint64 iRxDelta = iface.rxBytes - m_lastRxBytesByIface[name];
            const qint64 iTxDelta = iface.txBytes - m_lastTxBytesByIface[name];

            SpeedSample sample;
            sample.timestamp = nowSec;
            sample.downloadSpeed = (iRxDelta > 0 ? iRxDelta : 0) / elapsedSec;
            sample.uploadSpeed = (iTxDelta > 0 ? iTxDelta : 0) / elapsedSec;
            m_speedHistory[name].append(sample);

            // 滑动窗口裁剪：超过 300 点时丢弃最旧的
            QVector<SpeedSample> &samples = m_speedHistory[name];
            while (samples.size() > MAX_HISTORY_SAMPLES) {
                samples.removeFirst();
            }

            m_lastRxBytesByIface[name] = iface.rxBytes;
            m_lastTxBytesByIface[name] = iface.txBytes;
        }
        emit speedHistoryChanged();
    }

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
        // 过滤回环接口和虚拟接口，与 readNetworkStats() 保持一致
        // 设计原因：原仅过滤 lo，docker/veth/br- 接口会短暂出现在列表中，
        // 随后被 readNetworkStats() 覆盖，造成 UI 闪烁
        if (entry != "lo" && !entry.startsWith("veth") &&
            !entry.startsWith("docker") && !entry.startsWith("br-")) {
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