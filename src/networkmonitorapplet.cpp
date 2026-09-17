// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#include "networkmonitorapplet.h"
#include <pluginfactory.h>

#include <QFile>
#include <QSaveFile>
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
#include <QProcess>
#include <QJsonDocument>
#include <QJsonObject>
#include <QFileInfo>
#include <QDate>
#include <QGuiApplication>
#include <QScreen>

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
    , m_rxPackets(0)
    , m_txPackets(0)
    , m_rxErrors(0)
    , m_txErrors(0)
    , m_rxDropped(0)
    , m_txDropped(0)
    , m_linkSpeed(0)
    , m_refreshInterval(1000)
    , m_tcpConnections(0)
    , m_wifiSignal(0)
    , m_lowFreqCounter(4)
    , m_ipDetectCounter(4)
    , m_ready(false)
    , m_firstUpdate(true)
    , m_textColor()
    , m_historyDirty(true)
    , m_trafficSaveCounter(0)
{
    // 从独立配置文件读取持久化的字体颜色
    // 设计原因：使用独立配置文件避免污染 dde-shell 的共享配置，
    // 空串表示"跟随系统"，由 QML 层回退到 primaryText 实现
    QSettings settings(configFilePath(), QSettings::IniFormat);
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

    // 从配置文件读取持久化的刷新间隔（毫秒），仅接受 1/2/5 秒合法值
    if (settings.contains(QStringLiteral("refreshInterval"))) {
        const int iv = settings.value(QStringLiteral("refreshInterval")).toInt();
        if (iv == 1000 || iv == 2000 || iv == 5000) {
            m_refreshInterval = iv;
        }
    }
}

NetworkMonitorApplet::~NetworkMonitorApplet()
{
    // 析构时兜底保存流量日志，确保进程退出前最后一段累加数据不丢失
    // 设计原因：降频保存每 30 秒才写一次盘，若用户在两次保存之间退出，
    // 这段增量会丢失；析构保存保证数据完整性
    saveTrafficLog();
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
    
    // 初始化流量日志持久化
    // 设计原因：日志与设置共用 ~/.config/jnetapplet 目录；
    // 启动时从 JSON 文件加载历史累计数据，当日/当月键由 appendToTrafficLog 按需取用
    m_trafficLogPath = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
                       + QStringLiteral("/jnetapplet/traffic_log.json");
    loadTrafficLog();
    
    // 启动定时刷新
    m_refreshTimer = new QTimer(this);
    connect(m_refreshTimer, &QTimer::timeout, this, &NetworkMonitorApplet::refresh);
    // 用持久化的刷新间隔启动（默认 1000ms = 1 秒）
    m_refreshTimer->start(m_refreshInterval);
    
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

// ---- 活动接口包统计 getter（累计值，自开机起）----
// 供弹窗接口信息区展示收发包/错误/丢包数
quint64 NetworkMonitorApplet::rxPackets() const { return m_rxPackets; }
quint64 NetworkMonitorApplet::txPackets() const { return m_txPackets; }
quint64 NetworkMonitorApplet::rxErrors() const { return m_rxErrors; }
quint64 NetworkMonitorApplet::txErrors() const { return m_txErrors; }
quint64 NetworkMonitorApplet::rxDropped() const { return m_rxDropped; }
quint64 NetworkMonitorApplet::txDropped() const { return m_txDropped; }

// 返回活动接口的链路协商速率（Mbps），0 表示不可用
int NetworkMonitorApplet::linkSpeed() const { return m_linkSpeed; }

// 返回刷新间隔（毫秒）
int NetworkMonitorApplet::refreshInterval() const { return m_refreshInterval; }

// 独立配置文件的完整路径（~/.config/jnetapplet/settings.ini）
// 设计原因：字体颜色、活动接口、刷新间隔的读写都落在这个文件，
// 路径拼接与 QSettings 构造集中一处，避免多处重复导致不一致
QString NetworkMonitorApplet::configFilePath()
{
    return QStandardPaths::writableLocation(QStandardPaths::ConfigLocation)
           + QStringLiteral("/jnetapplet/settings.ini");
}

// 写入单个配置项并立即落盘
// 设计原因：三个 setter 都需要"构造 QSettings + setValue + sync"这组动作，统一收敛到一处；
// 写盘失败时不抛异常也不回滚内存值——设置在本次会话已生效，仅下次启动会丢失，属可接受降级
void NetworkMonitorApplet::persistSetting(const QString &key, const QVariant &value)
{
    QSettings settings(configFilePath(), QSettings::IniFormat);
    settings.setValue(key, value);
    settings.sync();
}

// 判断窗口键是否属于允许持久化位置的窗口集合（白名单）
// 设计原因：键名由 QML 传入，若不限制则任意字符串都会在 settings.ini 里留下一条记录，
// 配置项会随版本迭代无限增长；独立窗口集合本身是固定的，用白名单把可写范围收敛到已知窗口。
// 三个键分别对应 TrafficChartWindow / TrafficStatsWindow / TcpConnectionsWindow
bool NetworkMonitorApplet::isKnownWindowKey(const QString &key)
{
    static const QStringList known{QStringLiteral("chart"),
                                   QStringLiteral("stats"),
                                   QStringLiteral("tcp")};
    return known.contains(key);
}

// 读取窗口上次保存的位置，返回 {valid, x, y}
// 设计原因：调用方（QML 窗口）需要在"有记录"与"无记录"之间区分对待——
// 无记录时回退为居中显示，因此用 valid 标记而不是返回无效坐标（-1,-1 在多屏下是合法坐标）。
// 记录不可用（未保存过、被手工改坏、或落在当前已不存在的屏幕上）一律按无记录处理，
// 交由 QML 居中：显示器被拔掉后若仍按旧坐标恢复，窗口会落在屏幕外，用户表现为"窗口打不开"
QVariantMap NetworkMonitorApplet::windowGeometry(const QString &key) const
{
    QVariantMap result;
    result.insert(QStringLiteral("valid"), false);
    if (!isKnownWindowKey(key)) {
        return result;
    }

    QSettings settings(configFilePath(), QSettings::IniFormat);
    const QString saved = settings.value(QStringLiteral("geometry/") + key).toString();
    const QStringList parts = saved.split(QLatin1Char(','));
    if (parts.size() != 2) {
        return result;
    }

    bool okX = false;
    bool okY = false;
    const int x = parts.at(0).trimmed().toInt(&okX);
    const int y = parts.at(1).trimmed().toInt(&okY);
    if (!okX || !okY) {
        return result;
    }
    // 多显示器下旧位置可能已不存在：screenAt 返回空表示该点不在任何屏幕上
    if (!QGuiApplication::screenAt(QPoint(x, y))) {
        return result;
    }

    result.insert(QStringLiteral("valid"), true);
    result.insert(QStringLiteral("x"), x);
    result.insert(QStringLiteral("y"), y);
    return result;
}

// 保存窗口位置：以 "x,y" 形式写入 geometry/<key>，与其它设置同一份 settings.ini
// 写盘频率由 QML 侧防抖控制（拖动停止后写一次），此处不再做节流
void NetworkMonitorApplet::saveWindowGeometry(const QString &key, int x, int y)
{
    if (!isKnownWindowKey(key)) {
        return;
    }
    persistSetting(QStringLiteral("geometry/") + key,
                   QStringLiteral("%1,%2").arg(x).arg(y));
}

// 读取窗口置顶状态：无记录（或键名非法）时返回 false，即默认不置顶
// 单独存 pinned/<key> 而不与几何记录混写：二者变更时机不同（移动 vs 点击置顶），
// 合并成一条记录会让任一方变更都要读改写整条，徒增出错面
bool NetworkMonitorApplet::windowPinned(const QString &key) const
{
    if (!isKnownWindowKey(key)) {
        return false;
    }
    QSettings settings(configFilePath(), QSettings::IniFormat);
    return settings.value(QStringLiteral("pinned/") + key, false).toBool();
}

// 保存窗口置顶状态（QML 侧在开关置顶时调用）
void NetworkMonitorApplet::setWindowPinned(const QString &key, bool pinned)
{
    if (!isKnownWindowKey(key)) {
        return;
    }
    persistSetting(QStringLiteral("pinned/") + key, pinned);
}

// 设置刷新间隔（毫秒），校验后持久化并即时生效// 设计原因：仅接受 1/2/5 秒，避免非法值破坏刷新频率；
// 速度计算基于真实流逝时间（elapsedSec），改变间隔不影响计算正确性
void NetworkMonitorApplet::setRefreshInterval(int ms)
{
    if (ms != 1000 && ms != 2000 && ms != 5000) {
        return;
    }
    if (m_refreshInterval == ms) {
        return;
    }
    m_refreshInterval = ms;
    if (m_refreshTimer) {
        m_refreshTimer->start(m_refreshInterval);
    }

    // 持久化到独立配置文件，重启后仍生效
    persistSetting(QStringLiteral("refreshInterval"), m_refreshInterval);

    emit refreshIntervalChanged();
}

// 返回当前活动接口的 TCP ESTABLISHED 连接数
int NetworkMonitorApplet::tcpConnections() const { return m_tcpConnections; }

// 返回活动接口的 WiFi 信号强度（dBm），0 表示不可用
int NetworkMonitorApplet::wifiSignal() const { return m_wifiSignal; }

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
    persistSetting(QStringLiteral("textColor"), m_textColor);

    emit textColorChanged();
}

// 返回流量统计日志（JSON 对象），结构见 trafficLog 属性注释
// QJsonObject 可直接暴露给 QML 作为 JS 对象读取，无需额外转换
QJsonObject NetworkMonitorApplet::trafficLog() const
{
    return m_trafficLog;
}

// 返回 TCP 连接详情列表（QVariantList of QVariantMap），供 QML 连接清单窗口展示
QVariantList NetworkMonitorApplet::tcpConnectionList() const
{
    return m_tcpConnectionList;
}

// 返回当前活动接口的下行速度历史，转换为 QVariantList of QPointF 供 QML 使用
// 设计原因：QPointF 仅携带 x/y 两个值，上传与下载分别对应两个列表；
// 结果缓存于成员变量，仅当 m_historyDirty 时重建，避免 QML 每次读取都重新构造上千个点
QVariantList NetworkMonitorApplet::speedHistoryDownload() const
{
    if (m_historyDirty) {
        rebuildHistoryCache();
    }
    return m_cachedHistoryDl;
}

// 返回当前活动接口的上行速度历史，结构同 speedHistoryDownload
QVariantList NetworkMonitorApplet::speedHistoryUpload() const
{
    if (m_historyDirty) {
        rebuildHistoryCache();
    }
    return m_cachedHistoryUpload;
}

// 重建上下行历史缓存（一次遍历同时填充两个列表）
// 仅当 dirty 时由两个 getter 调用，避免重复构建；
// 单 dirty 标记 + 一次重建双缓存，保证先后读取两个列表时数据一致
void NetworkMonitorApplet::rebuildHistoryCache() const
{
    m_cachedHistoryDl.clear();
    m_cachedHistoryUpload.clear();
    if (!m_activeInterface.isEmpty() && m_speedHistory.contains(m_activeInterface)) {
        const QVector<SpeedSample> &samples = m_speedHistory[m_activeInterface];
        m_cachedHistoryDl.reserve(samples.size());
        m_cachedHistoryUpload.reserve(samples.size());
        for (const SpeedSample &s : samples) {
            m_cachedHistoryDl.append(QPointF(s.timestamp, s.downloadSpeed));
            m_cachedHistoryUpload.append(QPointF(s.timestamp, s.uploadSpeed));
        }
    }
    m_historyDirty = false;
}

void NetworkMonitorApplet::refresh()
{
    readNetworkStats();

    // 流量日志降频保存：每 30 秒写盘一次并通知 QML
    // 设计原因：累加在 calculateSpeed 中每秒执行（纯内存操作开销低），
    // 而写盘与 QML 重绘若每秒执行会造成不必要的磁盘 IO 与界面刷新；
    // 计数器按刷新间隔折算（1s=30 次，2s=15 次，5s=6 次）保证实际每 30 秒保存一次
    const int saveEveryMs = 30000;
    const int saveThreshold = qMax(1, saveEveryMs / m_refreshInterval);
    if (++m_trafficSaveCounter >= saveThreshold) {
        m_trafficSaveCounter = 0;
        saveTrafficLog();
        emit trafficLogChanged();
    }
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

        // 接口切换后历史数据变化，标记脏缓存让趋势图立即重建
        m_historyDirty = true;

        // 接口切换后包统计指向新接口，旧值不再有效，重置并通知 QML
        // 设计原因：包统计为各接口独立的累计值，切换后应显示新接口的数据
        m_rxPackets = 0;
        m_txPackets = 0;
        m_rxErrors = 0;
        m_txErrors = 0;
        m_rxDropped = 0;
        m_txDropped = 0;
        emit packetStatsChanged();

        // 持久化到配置文件，下次启动自动加载用户选择的网卡
        // 设计原因：弹窗 chip 和设置窗口都调用此方法，统一持久化保证两处选择一致
        persistSetting(QStringLiteral("activeInterface"), m_activeInterface);

        emit activeInterfaceChanged();
        // 接口切换后通知 QML 趋势图切换显示新接口的历史数据
        emit speedHistoryChanged();
        // 接口切换后立即检测新接口的 IP 地址
        detectIpAddress();
        // 接口切换后立即读取新接口的链路速率与 WiFi 信号
        detectLowFreqStats();
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
        // static const 仅首次调用时编译正则一次，后续复用，避免每秒对每行重复编译
        static const QRegularExpression re("^([^:]+):\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+\\d+\\s+\\d+\\s+\\d+\\s+\\d+\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)");
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
    // IP 地址变化频率极低（DHCP 续约/网络切换等），降频至每 5 秒检测一次，
    // 减少每秒 QNetworkInterface::interfaceFromName 的系统查询开销
    // 计数器每次 refresh 递增，达到 5 时归零并执行检测
    if (++m_ipDetectCounter >= 5) {
        m_ipDetectCounter = 0;
        detectIpAddress();
    }
    // 链路速率与 WiFi 信号同样变化频率低，每 5 秒检测一次
    if (++m_lowFreqCounter >= 5) {
        m_lowFreqCounter = 0;
        detectLowFreqStats();
    }
    // TCP 连接清单同样每 5 秒更新一次（进程名反查需遍历 /proc 开销大，不能每秒执行）
    if (++m_tcpListCounter >= 5) {
        m_tcpListCounter = 0;
        requestTcpConnectionList();
    }
}

void NetworkMonitorApplet::calculateSpeed()
{
    // 当前采样时间戳（毫秒），用于按真实流逝时间计算速度
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const qint64 nowSec = QDateTime::currentSecsSinceEpoch();
    const double elapsedSec = (nowMs - m_lastTimestampMs) / 1000.0;
    m_lastTimestampMs = nowMs;

    // 记录旧值用于 dirty 比较：网络空闲时速度/总量可能不变，
    // 仅在真正变化时才发射信号，避免 QML 每秒无效重绘
    const double oldDownload = m_downloadSpeed;
    const double oldUpload = m_uploadSpeed;
    const qint64 oldTotalDownload = m_totalDownload;
    const qint64 oldTotalUpload = m_totalUpload;

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
        // 会话总量：累加差值（dde-shell 启动至今的流量），重启清零
        // 设计原因：用户期望"本次会话"是本次 dde-shell 运行期间的流量，
        // 与流量统计窗口的"今日累计"（从0点起）区分，数值不会超过今日累计
        m_totalDownload += rxDeltaClamped;
        m_totalUpload += txDeltaClamped;
        // 累加日/月流量日志（仅活动接口增量，与速度计算口径一致）
        appendToTrafficLog(rxDeltaClamped, txDeltaClamped);
        m_lastRxBytes = currentRxBytes;
        m_lastTxBytes = currentTxBytes;
    }

    // ---- 活动接口包统计（累计值，自开机起）----
    // 直接从当前活动接口读取收发包/错误/丢包计数，任一值变化时发射 packetStatsChanged
    if (!m_activeInterface.isEmpty() && m_interfaces.contains(m_activeInterface)) {
        const NetworkInterface &iface = m_interfaces[m_activeInterface];
        if (m_rxPackets != static_cast<quint64>(iface.rxPackets)
            || m_txPackets != static_cast<quint64>(iface.txPackets)
            || m_rxErrors != static_cast<quint64>(iface.rxErrors)
            || m_txErrors != static_cast<quint64>(iface.txErrors)
            || m_rxDropped != static_cast<quint64>(iface.rxDropped)
            || m_txDropped != static_cast<quint64>(iface.txDropped)) {
            m_rxPackets = static_cast<quint64>(iface.rxPackets);
            m_txPackets = static_cast<quint64>(iface.txPackets);
            m_rxErrors = static_cast<quint64>(iface.rxErrors);
            m_txErrors = static_cast<quint64>(iface.txErrors);
            m_rxDropped = static_cast<quint64>(iface.rxDropped);
            m_txDropped = static_cast<quint64>(iface.txDropped);
        emit packetStatsChanged();
        }
    }

    // ---- TCP 连接数（每秒统计）----
    // /proc/net/tcp 与 tcp6 文件很小，遍历开销低；仅在连接数变化时发射信号
    const int conns = countTcpConnections();
    if (m_tcpConnections != conns) {
        m_tcpConnections = conns;
        emit tcpConnectionsChanged();
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

            // 滑动窗口裁剪：超过 MAX_HISTORY_SAMPLES（1800）点时丢弃最旧的
            QVector<SpeedSample> &samples = m_speedHistory[name];
            while (samples.size() > MAX_HISTORY_SAMPLES) {
                samples.removeFirst();
            }

            m_lastRxBytesByIface[name] = iface.rxBytes;
            m_lastTxBytesByIface[name] = iface.txBytes;
        }
        // 历史采样点已追加，标记脏缓存，QML 下次读取时重建
        m_historyDirty = true;
        emit speedHistoryChanged();
    }

    // 仅在速度/总量实际变化时发射信号，避免空闲时每秒触发 QML 无效重绘
    if (m_downloadSpeed != oldDownload || m_uploadSpeed != oldUpload) {
        emit speedChanged();
    }
    if (m_totalDownload != oldTotalDownload || m_totalUpload != oldTotalUpload) {
        emit totalChanged();
    }
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

// 低频统计检测：链路速率与 WiFi 信号（每 5 秒或接口切换时），变化时发射对应信号
// 设计原因：这两项数据变化频率极低（协商速率/信号强度基本稳定），
// 无需每秒读取，降频降低系统调用与文件读取开销
void NetworkMonitorApplet::detectLowFreqStats()
{
    if (!m_activeInterface.isEmpty()) {
        // 链路速率：有线走同步 sysfs，无线走异步 iw；两者内部负责在变化时发射信号
        updateLinkSpeed();
        const int sig = detectWifiSignal(m_activeInterface);
        if (m_wifiSignal != sig) {
            m_wifiSignal = sig;
            emit wifiSignalChanged();
        }
    } else {
        // 无活动接口时归零，避免显示上一接口的残留数据
        setLinkSpeed(0);
        if (m_wifiSignal != 0) {
            m_wifiSignal = 0;
            emit wifiSignalChanged();
        }
    }
}

// 链路协商速率检测入口（Mbps）
// 有线：直接读 /sys/class/net/<iface>/speed（同步，一次微小文件读取，开销可忽略）
// 无线：speed 文件常返回 EINVAL，降级执行 `iw dev <iface> link` 解析 bitrate。
//       子进程改为异步执行——dde-shell 的 applet 与面板同进程，原同步
//       waitForFinished(1000) 在 iw 卡住时会冻结整个任务栏
// 不可用时置 0（表示不可用）
void NetworkMonitorApplet::updateLinkSpeed()
{
    if (m_activeInterface.isEmpty()) {
        setLinkSpeed(0);
        return;
    }

    const int sysSpeed = readSysfsLinkSpeed(m_activeInterface);
    if (sysSpeed >= 0) {
        setLinkSpeed(sysSpeed);
        return;
    }

    if (!m_activeInterface.startsWith("wlp") && !m_activeInterface.startsWith("wlan")) {
        setLinkSpeed(0);
        return;
    }

    // 上一次 iw 尚未返回时跳过本轮，避免子进程堆积
    if (m_iwPending) {
        return;
    }

    const QString iface = m_activeInterface;
    m_iwPending = true;
    QProcess *proc = new QProcess(this);
    // 超时兜底：保留原同步实现的 1 秒上限，kill 后仍按已读取的输出解析
    QTimer::singleShot(1000, proc, [proc]() {
        if (proc->state() != QProcess::NotRunning) {
            proc->kill();
        }
    });
    connect(proc, &QProcess::errorOccurred, this, [this, proc, iface](QProcess::ProcessError error) {
        // FailedToStart 不会触发 finished（如系统未安装 iw），需在此清理；
        // kill 导致的异常退出仍会走 finished，故只处理 FailedToStart 避免重复处理
        if (error != QProcess::FailedToStart) {
            return;
        }
        m_iwPending = false;
        // 与同步实现保持一致：iw 不可用时速率视为不可用（0）
        if (m_activeInterface == iface) {
            setLinkSpeed(0);
        }
        proc->deleteLater();
    });
    connect(proc, &QProcess::finished, this, [this, proc, iface](int, QProcess::ExitStatus) {
        m_iwPending = false;
        // 期间用户可能已切换接口，此时结果对当前接口已无意义，直接丢弃
        if (m_activeInterface == iface) {
            const int br = parseIwBitrate(QString::fromUtf8(proc->readAllStandardOutput()));
            setLinkSpeed(br > 0 ? br : 0);
        }
        proc->deleteLater();
    });
    proc->start(QStringLiteral("iw"), {QStringLiteral("dev"), iface, QStringLiteral("link")});
}

// 同步读取 /sys/class/net/<iface>/speed（Mbps）
// 返回 -1 表示不可用（文件不存在、驱动返回负数或 "unknown"），调用方据此决定是否走 iw 降级；
// 返回 0 是合法值（部分驱动在链路断开时报 0），故不能用 0 表示失败
int NetworkMonitorApplet::readSysfsLinkSpeed(const QString &iface) const
{
    QFile f(QStringLiteral("/sys/class/net/%1/speed").arg(iface));
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return -1;
    }
    const QString val = QString::fromLatin1(f.readAll()).trimmed();
    f.close();
    bool ok = false;
    const int speed = val.toInt(&ok);
    // 超大值（部分驱动返回 4294967295）会导致 toInt 失败，与负数一起视为不可用
    return (ok && speed >= 0) ? speed : -1;
}

// 更新链路速率缓存，仅在值变化时发射 linkSpeedChanged，避免 QML 无效重绘
void NetworkMonitorApplet::setLinkSpeed(int mbps)
{
    if (m_linkSpeed == mbps) {
        return;
    }
    m_linkSpeed = mbps;
    emit linkSpeedChanged();
}

// 解析 `iw dev <iface> link` 输出中的 bitrate（Mbps），失败返回 0
// 输出形如 "    bitrate: 866.7 MBit/s"，也兼容 "Gbit/s"（换算为 Mbps）
int NetworkMonitorApplet::parseIwBitrate(const QString &output) const
{
    static const QRegularExpression re("bitrate:\\s*([\\d.]+)\\s*(M|G)bit/s");
    QRegularExpressionMatch m = re.match(output);
    if (!m.hasMatch()) {
        return 0;
    }
    const double val = m.captured(1).toDouble();
    const bool isGigabit = m.captured(2) == QLatin1String("G");
    return isGigabit ? qRound(val * 1000.0) : qRound(val);
}

// 统计 /proc/net/tcp 与 /proc/net/tcp6 中 ESTABLISHED（状态 01）的连接数
// 文件第 4 列（st）为连接状态码，01 表示 ESTABLISHED；
// 任一文件读取失败时跳过，不因单个文件缺失而失败
int NetworkMonitorApplet::countTcpConnections() const
{
    int count = 0;
    const QStringList paths = {QStringLiteral("/proc/net/tcp"), QStringLiteral("/proc/net/tcp6")};
    for (const QString &path : paths) {
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
            continue;
        }
        QTextStream stream(&f);
        // 跳过标题行
        stream.readLine();
        while (!stream.atEnd()) {
            const QString line = stream.readLine().trimmed();
            if (line.isEmpty()) {
                continue;
            }
            // static const：正则仅首次编译，避免每条连接重复构造（连接数可能上千）
            static const QRegularExpression wsRe(QStringLiteral("\\s+"));
            const QStringList parts = line.split(wsRe, Qt::SkipEmptyParts);
            if (parts.size() > 3 && parts[3] == QLatin1String("01")) {
                ++count;
            }
        }
        f.close();
    }
    return count;
}

// 异步请求 TCP 连接详情列表（QVariantList of QVariantMap），仅保留 ESTABLISHED 连接
// 设计原因：ss 需启动子进程通过 netlink 取信息（原先遍历 /proc/<pid>/fd 因权限拿不到进程名），
// 原同步 waitForFinished(3000) 在 ss 卡住时会冻结同进程的 dde-shell 面板；
// 改为异步 + 定时器兜底后，主线程不再等待子进程
void NetworkMonitorApplet::requestTcpConnectionList()
{
    if (m_ssPending) {
        return; // 上一次 ss 尚未返回，跳过本轮，避免子进程堆积
    }
    m_ssPending = true;

    QProcess *proc = new QProcess(this);
    // 超时兜底：保留原同步实现的 3 秒上限；kill 后仍按已读取到的输出解析
    QTimer::singleShot(3000, proc, [proc]() {
        if (proc->state() != QProcess::NotRunning) {
            proc->kill();
        }
    });
    connect(proc, &QProcess::errorOccurred, this, [this, proc](QProcess::ProcessError error) {
        // FailedToStart 不会触发 finished（如精简系统未安装 iproute2），需在此降级为空清单；
        // kill 导致的异常退出仍会走 finished，故只处理 FailedToStart 以避免重复处理
        if (error != QProcess::FailedToStart) {
            return;
        }
        m_ssPending = false;
        m_tcpConnectionList.clear();
        proc->deleteLater();
        emit tcpConnectionListChanged();
    });
    connect(proc, &QProcess::finished, this, [this, proc](int, QProcess::ExitStatus) {
        m_ssPending = false;
        m_tcpConnectionList = parseTcpConnectionList(QString::fromUtf8(proc->readAllStandardOutput()));
        proc->deleteLater();
        emit tcpConnectionListChanged();
    });
    // -t TCP, -n 不解析服务名（显示端口）, -p 显示进程信息, state established 仅已建立连接
    proc->start(QStringLiteral("ss"), {QStringLiteral("-tnp"), QStringLiteral("state"), QStringLiteral("established")});
}

// 解析 ss -tnp 输出为连接列表（QVariantList of QVariantMap）
// 拆为纯函数的原因：解析逻辑与子进程调度解耦后可直接单元测试，无需启动真实 ss
QVariantList NetworkMonitorApplet::parseTcpConnectionList(const QString &output) const
{
    QVariantList list;

    // static const：正则仅首次编译一次，避免每条连接重复编译
    static const QRegularExpression lineRe(QStringLiteral("(\\S+)\\s+(\\S+)\\s+(\\S+):(\\d+)\\s+(\\S+):(\\d+)\\s*(.*)"));
    static const QRegularExpression nameRe(QStringLiteral("\\(\"([^\"]+)\""));

    const QStringList lines = output.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (int i = 0; i < lines.size(); ++i) {
        if (i == 0) continue; // 跳过表头（Recv-Q Send-Q ...）

        const QString line = lines[i].trimmed();
        if (line.isEmpty()) continue;

        // ss 输出按多空格分割：Recv-Q Send-Q Local:Port Peer:Port [Process]
        // 注意 Process 列可能为空，且 IPv6 地址形如 [::1]:port（方括号内无空格），
        // 用正则提取更可靠，可容忍列之间任意空白
        QRegularExpressionMatch match = lineRe.match(line);
        if (!match.hasMatch()) continue;

        QString localAddress = match.captured(3);
        const QString localPort = match.captured(4);
        QString remoteAddress = match.captured(5);
        const QString remotePort = match.captured(6);
        const QString processField = match.captured(7).trimmed();

        // 去掉地址中的接口后缀（如 192.168.3.83%wlp3s0 -> 192.168.3.83）
        localAddress = localAddress.split(QLatin1Char('%')).first();
        remoteAddress = remoteAddress.split(QLatin1Char('%')).first();
        // 去掉 IPv6 地址的方括号（[::1] -> ::1）
        if (localAddress.startsWith(QLatin1Char('['))) localAddress = localAddress.mid(1, localAddress.size() - 2);
        if (remoteAddress.startsWith(QLatin1Char('['))) remoteAddress = remoteAddress.mid(1, remoteAddress.size() - 2);

        // 提取进程名：users:(("进程名",pid=xxx,fd=xxx))，取第一个双引号内的内容
        QString processName;
        if (processField.startsWith(QStringLiteral("users:"))) {
            QRegularExpressionMatch nameMatch = nameRe.match(processField);
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

// 读取指定接口的 WiFi 信号强度（dBm）
// 仅无线接口（wlp/wlan）有效；/proc/net/wireless 桌面环境可能不存在（返回 0）
// 该文件每行形如 "wlp3s0: 60.  -65.  -256  0 ..."，level（dBm）为第 3 个数值字段
int NetworkMonitorApplet::detectWifiSignal(const QString &iface)
{
    if (!iface.startsWith("wlp") && !iface.startsWith("wlan")) {
        return 0;
    }
    QFile f(QStringLiteral("/proc/net/wireless"));
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return 0;
    }
    QTextStream stream(&f);
    // 跳过前两行标题
    stream.readLine();
    stream.readLine();
    int sig = 0;
    while (!stream.atEnd()) {
        const QString line = stream.readLine().trimmed();
        if (line.isEmpty()) {
            continue;
        }
        // static const：正则仅首次编译，避免每行重复构造
        static const QRegularExpression wsRe(QStringLiteral("\\s+"));
        const QStringList parts = line.split(wsRe, Qt::SkipEmptyParts);
        if (parts.size() > 3 && parts[0].startsWith(iface)) {
            bool ok = false;
            const double level = parts[3].toDouble(&ok);
            if (ok) {
                sig = qRound(level);
            }
            break;
        }
    }
    f.close();
    return sig;
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

// ---- 流量日志（日/月持久化）----

// 启动时从 traffic_log.json 加载流量日志
// 优雅降级：文件不存在、读取失败或 JSON 解析失败时均使用空结构，不崩溃不抛异常；
// 首次运行（文件不存在）时先创建空的 byDay/byMonth 结构，由后续保存写盘创建文件
void NetworkMonitorApplet::loadTrafficLog()
{
    QFile file(m_trafficLogPath);
    if (!file.exists()) {
        m_trafficLog = QJsonObject();
        m_trafficLog[QStringLiteral("byDay")] = QJsonObject();
        m_trafficLog[QStringLiteral("byMonth")] = QJsonObject();
        return;
    }
    if (file.open(QIODevice::ReadOnly)) {
        QJsonParseError err;
        const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &err);
        file.close();
        if (err.error == QJsonParseError::NoError && doc.isObject()) {
            m_trafficLog = doc.object();
        } else {
            // 解析失败（如文件被外部写坏）：降级为空结构，避免后续累加异常。
            // 记录告警而非静默降级——历史统计会整体清零，用户需要知道原因
            qWarning() << "traffic_log.json 解析失败，历史统计已重置:" << err.errorString();
            m_trafficLog = QJsonObject();
            m_trafficLog[QStringLiteral("byDay")] = QJsonObject();
            m_trafficLog[QStringLiteral("byMonth")] = QJsonObject();
        }
    }
}

// 将流量日志写入 traffic_log.json
// 先裁剪超期记录再写盘，避免日志无限膨胀；
// 写前 mkpath 确保目录存在（首次运行时目录尚未创建）
void NetworkMonitorApplet::saveTrafficLog()
{
    // 测试等场景未初始化日志路径时直接跳过，避免对空路径 mkpath/写文件产生告警
    if (m_trafficLogPath.isEmpty()) {
        return;
    }
    pruneTrafficLog();
    QDir dir;
    dir.mkpath(QFileInfo(m_trafficLogPath).absolutePath());

    // 用 QSaveFile 先写临时文件、commit() 时原子替换目标文件
    // 设计原因：原实现以 Truncate 直接覆盖，写入中途崩溃/断电会留下半截 JSON，
    // 而 loadTrafficLog() 对损坏文件降级为空结构，会导致 30 天历史一次性丢失；
    // 原子替换保证失败时旧文件内容仍然完整可用
    QSaveFile file(m_trafficLogPath);
    if (!file.open(QIODevice::WriteOnly)) {
        return;
    }
    // 用 Indented 缩进格式便于用户手动查看/调试日志文件
    file.write(QJsonDocument(m_trafficLog).toJson(QJsonDocument::Indented));
    // commit() 失败时不会覆盖原文件，此处无需额外处理
    file.commit();
}

// 将本次流量增量累加到当日/当月/当前活动接口的日志记录中（每秒调用，纯内存操作）
// 跨日/跨月检测：日期或月份与上次记录不同时切换当前记录，不累加到昨天的记录；
// 只累加活动接口（与 m_totalDownload 口径一致），避免多接口重复计数
void NetworkMonitorApplet::appendToTrafficLog(qint64 rxDelta, qint64 txDelta)
{
    if (rxDelta <= 0 && txDelta <= 0) {
        return;
    }
    if (m_activeInterface.isEmpty()) {
        return;
    }

    // 直接取当前日期/月份作为键：跨日/跨月时键自然变化，新键从零累加，旧键保留不再增长
    // 设计原因：无需维护额外的"上次日期"状态，每次按当天/当月取键即可保证语义正确
    const QString date = QDate::currentDate().toString(QStringLiteral("yyyy-MM-dd"));
    const QString month = QDate::currentDate().toString(QStringLiteral("yyyy-MM"));

    // 累加到按日记录：byDay[date][iface] = {rx, tx}
    // 用 toVariant().toLongLong() 读取并写回 qint64，保留整数精度
    //（直接赋值 double 会导致超过 2^53 的字节数精度丢失）
    QJsonObject byDay = m_trafficLog.value(QStringLiteral("byDay")).toObject();
    QJsonObject dayEntry = byDay.value(date).toObject();
    QJsonObject ifaceDay = dayEntry.value(m_activeInterface).toObject();
    ifaceDay[QStringLiteral("rx")] =
        ifaceDay.value(QStringLiteral("rx")).toVariant().toLongLong() + rxDelta;
    ifaceDay[QStringLiteral("tx")] =
        ifaceDay.value(QStringLiteral("tx")).toVariant().toLongLong() + txDelta;
    dayEntry[m_activeInterface] = ifaceDay;
    byDay[date] = dayEntry;
    m_trafficLog[QStringLiteral("byDay")] = byDay;

    // 累加到按月记录：byMonth[month][iface] = {rx, tx}
    QJsonObject byMonth = m_trafficLog.value(QStringLiteral("byMonth")).toObject();
    QJsonObject monthEntry = byMonth.value(month).toObject();
    QJsonObject ifaceMonth = monthEntry.value(m_activeInterface).toObject();
    ifaceMonth[QStringLiteral("rx")] =
        ifaceMonth.value(QStringLiteral("rx")).toVariant().toLongLong() + rxDelta;
    ifaceMonth[QStringLiteral("tx")] =
        ifaceMonth.value(QStringLiteral("tx")).toVariant().toLongLong() + txDelta;
    monthEntry[m_activeInterface] = ifaceMonth;
    byMonth[month] = monthEntry;
    m_trafficLog[QStringLiteral("byMonth")] = byMonth;
}

// 裁剪超期记录：按日最多 30 天、按月最多 12 个月，超出删除最旧记录
// 日期/月份均为 ISO 格式（"yyyy-MM-dd"/"yyyy-MM"），字典序即时间序，
// 排序后取最小的超量个删除，保证始终保留最近的记录
void NetworkMonitorApplet::pruneTrafficLog()
{
    QJsonObject byDay = m_trafficLog.value(QStringLiteral("byDay")).toObject();
    QStringList dayKeys = byDay.keys();
    dayKeys.sort();
    while (dayKeys.size() > MAX_DAY_ENTRIES) {
        byDay.remove(dayKeys.first());
        dayKeys.removeFirst();
    }
    m_trafficLog[QStringLiteral("byDay")] = byDay;

    QJsonObject byMonth = m_trafficLog.value(QStringLiteral("byMonth")).toObject();
    QStringList monthKeys = byMonth.keys();
    monthKeys.sort();
    while (monthKeys.size() > MAX_MONTH_ENTRIES) {
        byMonth.remove(monthKeys.first());
        monthKeys.removeFirst();
    }
    m_trafficLog[QStringLiteral("byMonth")] = byMonth;
}

D_APPLET_CLASS(NetworkMonitorApplet)

DS_END_NAMESPACE

#include "networkmonitorapplet.moc"