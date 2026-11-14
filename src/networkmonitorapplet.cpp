// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#include "networkmonitorapplet.h"
// 纯逻辑核心库：解析/判定/日志操作，只依赖 Qt6::Core，可在无 deepin 环境单测
#include "core/netparsers.h"
#include "core/netstate.h"
#include "core/trafficlog.h"
#include "core/format.h"
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
// std::reverse：导出时把周期键降序排列（最新在前），与统计窗口行序一致。
// 显式包含而非依赖其它头文件间接引入，避免将来调整 include 顺序后编译失败
#include <algorithm>
// 系统通知：Dtk6 Core 提供的封装，内部走 org.freedesktop.Notifications。
// 选用它而非自建 DBus 调用的原因：本项目已依赖 Dtk6::Core，无需引入新依赖；
// 且 Dtk6::Core 已传递 Qt6::DBus（见其 INTERFACE_LINK_LIBRARIES），
// 头文件里的 QDBusPendingCall 能正常解析，CMake 无需改动
#include <DNotifySender>

DS_BEGIN_NAMESPACE

NetworkMonitorApplet::NetworkMonitorApplet(QObject *parent)
    : DApplet(parent)
    , m_refreshTimer(nullptr)
    , m_lastRxBytes(0)
    , m_lastTxBytes(0)
    // m_baselineInterface 默认构造为空：首轮 calculateSpeed 因 m_firstUpdate 直接记录基线
    , m_baselineInterface()
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
    , m_activeSsid()
    , m_speedUnit(SpeedUnitAuto)
    , m_linkDown(false)
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

    // 从配置文件读取持久化的速度显示单位，仅接受三档合法值；
    // 配置被手工改坏时保持默认的"智能自动"，不写入脏值
    if (settings.contains(QStringLiteral("speedUnit"))) {
        const int unit = settings.value(QStringLiteral("speedUnit")).toInt();
        if (unit == SpeedUnitAuto || unit == SpeedUnitKBps || unit == SpeedUnitMbps) {
            m_speedUnit = unit;
        }
    }

    // 流量提醒阈值（GB）：负数/NaN 一律按 0（关闭）处理，与 setter 的校验保持一致，
    // 避免手工改坏的配置在运行期参与换算导致提醒永不触发
    const double daily = settings.value(QStringLiteral("dailyLimitGb"), 0.0).toDouble();
    m_dailyLimitGb = (daily > 0) ? daily : 0.0;
    const double monthly = settings.value(QStringLiteral("monthlyLimitGb"), 0.0).toDouble();
    m_monthlyLimitGb = (monthly > 0) ? monthly : 0.0;

    // 已提醒周期键必须跨重启保留，否则重启 dde-shell 会在同一周期重复提醒
    m_notifiedDay = settings.value(QStringLiteral("notifiedDay")).toString();
    m_notifiedMonth = settings.value(QStringLiteral("notifiedMonth")).toString();

    // 任务栏是否显示所有物理网卡合计速率（默认 false，保持原"只看活动接口"的行为）
    m_aggregateSpeed = settings.value(QStringLiteral("aggregateSpeed"), false).toBool();
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

// 无线接口名列表：从当前接口列表中筛出无线接口，供 QML 显示类型图标与文案
// 设计原因：每次调用都重新判定（不缓存成员），因为接口热插拔会改变列表内容，
// 而缓存需要额外的失效逻辑且易与 networkInterfaces 不一致；
// 接口数量通常个位数，判定成本可接受（仅在 QML 需要时求值）
QStringList NetworkMonitorApplet::wirelessInterfaces() const
{
    QStringList wireless;
    for (const QString &iface : m_interfaceList) {
        if (isWirelessInterface(iface)) {
            wireless.append(iface);
        }
    }
    return wireless;
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

bool NetworkMonitorApplet::linkDown() const { return m_linkDown; }

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

// 返回活动接口的 WiFi 名称（SSID），非无线或未连接时为空串
QString NetworkMonitorApplet::activeSsid() const
{
    return m_activeSsid;
}

// 返回当前速度单位（0=智能自动，1=固定 KB/s，2=固定 Mbps）
int NetworkMonitorApplet::speedUnit() const
{
    return m_speedUnit;
}

// 语义化判据：当前是否固定 Mbps。供 QML 使用，避免界面代码里写 `=== 2` 这类魔法数字
bool NetworkMonitorApplet::speedUnitIsMbps() const
{
    return m_speedUnit == SpeedUnitMbps;
}

// 语义化判据：当前是否固定 KB/s
bool NetworkMonitorApplet::speedUnitIsKBps() const
{
    return m_speedUnit == SpeedUnitKBps;
}

// 设置速度单位：仅接受 0/1/2
// 设计原因：与 setRefreshInterval() 同一套校验-持久化-通知流程，
// 非法值静默忽略（例如配置文件被手工改坏），避免把脏值写回配置
void NetworkMonitorApplet::setSpeedUnit(int unit)
{
    if (unit != SpeedUnitAuto && unit != SpeedUnitKBps && unit != SpeedUnitMbps) {
        return;
    }
    if (m_speedUnit == unit) {
        return;
    }
    m_speedUnit = unit;
    persistSetting(QStringLiteral("speedUnit"), m_speedUnit);
    emit speedUnitChanged();
}

// ---- 流量提醒阈值 ----

double NetworkMonitorApplet::dailyLimitGb() const
{
    return m_dailyLimitGb;
}

double NetworkMonitorApplet::monthlyLimitGb() const
{
    return m_monthlyLimitGb;
}


void NetworkMonitorApplet::setDailyLimitGb(double gb)
{
    const double normalized = JNetCore::normalizeLimitGb(gb);
    if (qFuzzyCompare(m_dailyLimitGb, normalized)) {
        return;
    }
    m_dailyLimitGb = normalized;
    persistSetting(QStringLiteral("dailyLimitGb"), m_dailyLimitGb);
    emit quotaLimitChanged();
}

void NetworkMonitorApplet::setMonthlyLimitGb(double gb)
{
    const double normalized = JNetCore::normalizeLimitGb(gb);
    if (qFuzzyCompare(m_monthlyLimitGb, normalized)) {
        return;
    }
    m_monthlyLimitGb = normalized;
    persistSetting(QStringLiteral("monthlyLimitGb"), m_monthlyLimitGb);
    emit quotaLimitChanged();
}

// 当前周期已用流量（字节）：今日/本月
// 数据取自内存中的流量日志，与「流量统计」窗口同源，避免两处数字不一致
double NetworkMonitorApplet::todayUsedBytes() const
{
    return static_cast<double>(periodUsedBytes(
        m_trafficLog, QStringLiteral("byDay"),
        QDate::currentDate().toString(QStringLiteral("yyyy-MM-dd"))));
}

double NetworkMonitorApplet::monthUsedBytes() const
{
    return static_cast<double>(periodUsedBytes(
        m_trafficLog, QStringLiteral("byMonth"),
        QDate::currentDate().toString(QStringLiteral("yyyy-MM"))));
}

// ---- 多接口聚合 ----

bool NetworkMonitorApplet::aggregateSpeed() const
{
    return m_aggregateSpeed;
}

// 切换任务栏显示口径：false=单接口（默认），true=所有物理网卡合计
void NetworkMonitorApplet::setAggregateSpeed(bool enabled)
{
    if (m_aggregateSpeed == enabled) {
        return;
    }
    m_aggregateSpeed = enabled;
    persistSetting(QStringLiteral("aggregateSpeed"), m_aggregateSpeed);
    emit aggregateSpeedChanged();
}

// 所有物理网卡的速率之和（字节/秒），由 calculateSpeed 每轮更新
double NetworkMonitorApplet::totalDownloadSpeed() const
{
    return m_totalDownloadSpeed;
}

double NetworkMonitorApplet::totalUploadSpeed() const
{
    return m_totalUploadSpeed;
}

// 计算指定周期键下所有接口的 rx+tx 合计
// 结构：{"byDay": {日期: {接口: {rx, tx}}}}，section 取 "byDay" 或 "byMonth"
// 设计原因：口径必须与「流量统计」窗口一致（该周期下所有接口相加），
// 否则窗口显示 1.2 GB 而提醒说用了 0.8 GB，用户会怀疑哪边错了
qint64 NetworkMonitorApplet::periodUsedBytes(const QJsonObject &trafficLog,
                                             const QString &section,
                                             const QString &periodKey)

{
    return JNetCore::periodUsedBytes(trafficLog, section, periodKey);
}

// 判定本次是否应当提醒（纯函数）
// 规则：阈值已启用 且 已用量达到阈值 且 本周期尚未提醒。
// 「本周期尚未提醒」用周期键字符串比较实现——日期键形如 "yyyy-MM-dd"，
// 进入新的一天的瞬间键即变化，天然完成"每日重置"，无需额外维护时间差
bool NetworkMonitorApplet::shouldNotifyQuota(qint64 usedBytes, double limitGb,
                                             const QString &currentPeriod,
                                             const QString &notifiedPeriod)

{
    return JNetCore::shouldNotifyQuota(usedBytes, limitGb, currentPeriod, notifiedPeriod);
}

// 检查日/月阈值并发送通知
// 调用时机：挂在既有的 30 秒保存周期上（refresh() 内），不新增定时器。
// 判定用内存中的流量日志，与写盘解耦，因此不受 m_trafficLogWriteBlocked 影响
void NetworkMonitorApplet::checkQuotaAndNotify()
{
    const QDate today = QDate::currentDate();
    const QString dayKey = today.toString(QStringLiteral("yyyy-MM-dd"));
    const QString monthKey = today.toString(QStringLiteral("yyyy-MM"));

    // 日阈值
    if (m_dailyLimitGb > 0) {
        const qint64 used = periodUsedBytes(m_trafficLog, QStringLiteral("byDay"), dayKey);
        if (shouldNotifyQuota(used, m_dailyLimitGb, dayKey, m_notifiedDay)) {
            // 已用量按 GB 显示两位小数，与阈值同一单位便于直接比较
            const double usedGb = used / 1.0e9;
            // 源串用英文，翻译走 .ts（与 QML 侧 qsTr 的约定一致）；
            // 不直接写中文，否则非中文环境也会显示中文
            sendNotification(
                tr("Daily traffic limit exceeded"),
                tr("Used %1 GB today (limit %2 GB)")
                    .arg(usedGb, 0, 'f', 2)
                    .arg(m_dailyLimitGb, 0, 'g', 6));
            // 记录已提醒的周期并落盘：不持久化的话，重启 dde-shell 后同一天会再提醒
            m_notifiedDay = dayKey;
            persistSetting(QStringLiteral("notifiedDay"), m_notifiedDay);
        }
    }

    // 月阈值
    if (m_monthlyLimitGb > 0) {
        const qint64 used = periodUsedBytes(m_trafficLog, QStringLiteral("byMonth"), monthKey);
        if (shouldNotifyQuota(used, m_monthlyLimitGb, monthKey, m_notifiedMonth)) {
            const double usedGb = used / 1.0e9;
            sendNotification(
                tr("Monthly traffic limit exceeded"),
                tr("Used %1 GB this month (limit %2 GB)")
                    .arg(usedGb, 0, 'f', 2)
                    .arg(m_monthlyLimitGb, 0, 'g', 6));
            m_notifiedMonth = monthKey;
            persistSetting(QStringLiteral("notifiedMonth"), m_notifiedMonth);
        }
    }
}

// 发送系统通知
// 用固定 replaceId：同一时刻只会有一条流量提醒，避免日/月两条同时超限时
// 在通知中心堆叠成两条几乎相同的内容（后一条替换前一条）
void NetworkMonitorApplet::sendNotification(const QString &summary, const QString &body)
{
    Dtk::Core::DUtil::DNotifySender sender(summary);
    sender.appName(QStringLiteral("JNetApplet"))
        .appIcon(QStringLiteral("network-wired"))
        .appBody(body)
        .timeOut(8000)
        .replaceId(20261114)
        .call();   // 异步调用，不阻塞主线程；无通知服务时静默失败
}

// ---- 流量数据导出 ----

// 把流量日志展平为有序行，供 CSV/JSON 两种导出共用
// 排序口径必须与统计窗口一致（日期降序、同日期内接口名升序），否则导出文件的
// 行序与用户在界面上看到的不同，用户会怀疑导出的不是同一份数据。
// 抽为独立函数的另一原因：CSV 与 JSON 若各排一次序，两处规则迟早漂移
static QVariantList flattenTrafficRows(const QJsonObject &trafficLog, const QString &section)
{
    // 排序口径（日期降序、同日接口名升序）与界面共用同一实现，避免导出与展示不一致
    return JNetCore::flattenTraffic(trafficLog, section);
}



// 把指定 section 的数据导出为 CSV 文本
// 表头与数据都用纯字节数，便于在表格软件里直接求和；行序与界面一致
QString NetworkMonitorApplet::exportTrafficAsCsv(const QString &section) const
{
    const QVariantList rows = flattenTrafficRows(m_trafficLog, section);

    QString csv;
    csv += QStringLiteral("date,interface,download_bytes,upload_bytes,total_bytes\n");
    for (const QVariant &item : rows) {
        const QVariantMap row = item.toMap();
        csv += JNetCore::csvEscape(row.value(QStringLiteral("date")).toString());
        csv += QLatin1Char(',');
        csv += JNetCore::csvEscape(row.value(QStringLiteral("iface")).toString());
        csv += QLatin1Char(',');
        csv += QString::number(row.value(QStringLiteral("rx")).toLongLong());
        csv += QLatin1Char(',');
        csv += QString::number(row.value(QStringLiteral("tx")).toLongLong());
        csv += QLatin1Char(',');
        csv += QString::number(row.value(QStringLiteral("total")).toLongLong());
        csv += QLatin1Char('\n');
    }
    return csv;
}

// 把指定 section 的数据导出为 JSON 文本
// 保留原有嵌套结构并附带 section/exportedAt，便于脚本区分日/月与判断导出时间
QString NetworkMonitorApplet::exportTrafficAsJson(const QString &section) const
{
    QJsonObject root;
    root[QStringLiteral("section")] = section;
    root[QStringLiteral("exportedAt")] =
        QDateTime::currentDateTime().toString(Qt::ISODate);
    root[QStringLiteral("data")] = m_trafficLog.value(section).toObject();
    return QString::fromUtf8(QJsonDocument(root).toJson(QJsonDocument::Indented));
}

// 把导出内容写到用户选定的路径
// 返回 {ok, path, error}：失败时带原因而非抛异常，QML 侧据此显示提示
QVariantMap NetworkMonitorApplet::saveExportFile(const QString &path, const QString &content)
{
    QVariantMap result;
    result[QStringLiteral("ok")] = false;
    result[QStringLiteral("path")] = path;
    result[QStringLiteral("error")] = QString();

    if (path.isEmpty()) {
        result[QStringLiteral("error")] = tr("No file path selected");
        return result;
    }

    // 确保目标目录存在：用户在对话框里新建子目录、或降级到下载目录都可能不存在
    const QFileInfo info(path);
    QDir dir;
    if (!dir.mkpath(info.absolutePath())) {
        result[QStringLiteral("error")] = tr("Cannot create directory: %1").arg(info.absolutePath());
        return result;
    }

    // WriteOnly|Truncate = 覆盖写入：覆盖确认由文件对话框负责（用户在对话框里
    // 明确选定了文件名），此处不再二次询问，否则会出现"对话框问一次、插件再问一次"。
    // 降级路径（右键导出到下载目录）的文件名带日期，同一天重复导出会覆盖上一次，
    // 这是刻意的——避免下载目录堆满 jnetapplet-daily-2026-11-14(1).csv 这类副本
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        // 权限不足、路径是目录、磁盘满等都会走到这里
        result[QStringLiteral("error")] =
            tr("Cannot write file: %1").arg(file.errorString());
        return result;
    }

    const QByteArray payload = content.toUtf8();
    const qint64 written = file.write(payload);
    file.close();
    if (written != payload.size()) {
        result[QStringLiteral("error")] = tr("Incomplete write, file may be corrupted");
        return result;
    }

    result[QStringLiteral("ok")] = true;
    return result;
}

// 降级导出路径：下载目录下、带周期与扩展名的文件名
// 用途：无文件门户服务的环境（FileDialog 弹不出来）直接落盘；
// 也作为文件对话框的默认文件名，避免用户重复导出时互相覆盖
QString NetworkMonitorApplet::defaultExportPath(const QString &section,
                                               const QString &extension) const
{
    QString dirPath = QStandardPaths::writableLocation(QStandardPaths::DownloadLocation);
    if (dirPath.isEmpty()) {
        // 精简环境可能没有配置下载目录，回退到家目录，避免写到根下
        dirPath = QStandardPaths::writableLocation(QStandardPaths::HomeLocation);
    }

    // 文件名带上范围与当前周期：按日导出 "jnetapplet-daily-2026-11-14.csv"
    const bool daily = (section == QLatin1String("byDay"));
    const QString scope = daily ? QStringLiteral("daily") : QStringLiteral("monthly");
    const QString periodKey = daily ? QDate::currentDate().toString(QStringLiteral("yyyy-MM-dd"))
                                    : QDate::currentDate().toString(QStringLiteral("yyyy-MM"));

    // 扩展名容错：调用方可能传 "csv"、"CSV" 或 ".csv"
    QString ext = extension;
    if (ext.startsWith(QLatin1Char('.'))) {
        ext.remove(0, 1);
    }
    if (ext.isEmpty()) {
        ext = QStringLiteral("csv");
    }

    return QDir(dirPath).filePath(
        QStringLiteral("jnetapplet-%1-%2.%3").arg(scope, periodKey, ext));
}

// 带单位的完整速度字符串，供弹窗、趋势图与悬停提示使用
// 换算规则是全局唯一定义处，QML 侧不再各自实现 KB/MB/GB 阈值
QString NetworkMonitorApplet::formatSpeed(double bytesPerSec, int unit) const

{
    return JNetCore::formatSpeed(bytesPerSec, unit);
}

// 任务栏用的紧凑写法（无空格）
// 设计原因：任务栏宽度只有约 48px，带空格的 "4.11 MB/s" 放不下；
// 同时任务栏采用"整数部分右对齐 + 小数部分左对齐"的两段式渲染实现小数点对齐，
// 故 intPart 为 true 时只返回数值部分，由 QML 分别渲染两段
QString NetworkMonitorApplet::formatSpeedCompact(double bytesPerSec, int unit, bool intPart) const

{
    return JNetCore::formatSpeedCompact(bytesPerSec, unit, intPart);
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
        // 流量提醒与保存同一节拍：阈值判定本身是纯内存计算（遍历当前周期的接口记录），
        // 开销远低于写盘；放在这里可避免为它单独引入定时器
        checkQuotaAndNotify();
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

    // 用户显式选择：切换并持久化，下次启动自动恢复
    applyActiveInterface(interface, true);
}

// 切换活动接口的唯一入口（用户选择与接口热插拔自动回退都走这里）
// 设计原因：原实现只有 setActiveInterface() 做了"重置基线 + 刷新派生状态"，
// 而 readNetworkStats() 在活动接口消失时是直接改写 m_activeInterface 的——
// 基线没重置，下一轮 calculateSpeed 会拿"新接口自开机累计 − 旧接口累计"当增量，
// 数百 GB 的差值会显示成数百 GB/s，并被永久累加进 m_totalDownload 与日/月流量日志。
// 把两条路径收敛到同一入口后，这类"只改名字、不改派生状态"的漏洞不再有落点。
// persist 仅用户显式选择时为 true：自动回退属于临时兜底，不应覆盖用户保存的选择
void NetworkMonitorApplet::applyActiveInterface(const QString &interface, bool persist)
{
    if (m_activeInterface == interface) {
        return;
    }

    m_activeInterface = interface;
    // 不在此处直接重置 m_firstUpdate：基线是否需要重记，统一由 calculateSpeed() 里
    // "基线接口是否等于当前接口"这一处判断决定。两处同时维护会再次出现"状态没同步"的隐患，
    // 而本缺陷的根因正是"改了接口名、忘了改基线"。

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

    // 链路速率/信号/断连同属"上一接口的观测结果"，切换后立即归零再重测。
    // 设计原因：无线接口走异步 iw，最长约 1 秒才返回；若不清零，这段时间
    // 弹窗会显示上一块网卡的协商速率，属于明显的错误信息
    setLinkSpeed(0);
    setLinkDown(false);
    if (m_wifiSignal != 0) {
        m_wifiSignal = 0;
        emit wifiSignalChanged();
    }
    // WiFi 名称属于上一接口的观测结果，切换后立即清空再重测，
    // 避免"新接口名 + 旧 WiFi 名"的错配
    setActiveSsid(QString());

    // 仅在用户显式选择时持久化；自动回退（网卡拔出）不覆盖用户保存的选择，
    // 否则原网卡插回后无法自动恢复
    if (persist) {
        persistSetting(QStringLiteral("activeInterface"), m_activeInterface);
    }

    emit activeInterfaceChanged();
    // 接口切换后通知 QML 趋势图切换显示新接口的历史数据
    emit speedHistoryChanged();
    // 接口切换后立即检测新接口的 IP 地址
    detectIpAddress();
    // 接口切换后立即读取新接口的链路速率、WiFi 信号与链路通断
    detectLowFreqStats();
}

// 自动选择默认活动接口：优先"有流量的物理网卡"，其次"有流量的任意接口"，最后第一个
// 提取为独立函数的原因：选择规则本身是纯决策逻辑，与"切换后的状态重置"无关；
// 拆开后 readNetworkStats() 只负责"决定选谁"，applyActiveInterface() 负责"切过去"
QString NetworkMonitorApplet::chooseDefaultInterface() const
{
    if (m_interfaceList.isEmpty()) {
        return QString();
    }
    // 优先选择物理网卡中有流量的接口，避免选中 Meta/tun0 等虚拟代理接口作为默认显示
    for (const QString &name : m_interfaceList) {
        if (!isPhysicalInterface(name)) {
            continue;
        }
        const NetworkInterface &iface = m_interfaces[name];
        if (iface.rxBytes > 0 || iface.txBytes > 0) {
            return name;
        }
    }
    // 其次选择任意有流量的接口（物理网卡都无流量时的兜底）
    for (const QString &name : m_interfaceList) {
        const NetworkInterface &iface = m_interfaces[name];
        if (iface.rxBytes > 0 || iface.txBytes > 0) {
            return name;
        }
    }
    // 最后选第一个（无任何流量时）
    return m_interfaceList.first();
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

        // 活动接口已消失（如 USB 网卡拔出）或尚未选择时，重新确定目标接口。
        // 两种情形都走统一入口 applyActiveInterface()：它负责重置速度基线、清空上一接口的
        // 派生状态（IP/协商速率/信号/断连）并立即重测，避免"新接口名 + 旧接口数据"的错配。
        // persist 固定为 false：自动回退属于临时兜底，不覆盖用户显式保存的接口选择，
        // 这样原网卡插回后仍能自动恢复
        if (m_interfaceList.isEmpty()) {
            // 列表变空：清空活动接口（若本就为空则是空操作），让 QML 回到占位态
            applyActiveInterface(QString(), false);
        } else if (m_activeInterface.isEmpty()
                   || !m_interfaceList.contains(m_activeInterface)) {
            applyActiveInterface(chooseDefaultInterface(), false);
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
    // 基线与接口绑定：m_lastRxBytes/m_lastTxBytes 只对 m_baselineInterface 有效。
    // 两者不一致（首次采样、用户切换、网卡热拔后自动回退都属此列）时只记录基线、
    // 不产出速度与总量——否则差值 = 新接口累计 − 旧接口累计，会得到数量级完全错误的增量。
    // 设计原因：把"是否需要重记基线"收敛到这一处判断，任何改写活动接口的代码路径
    //（包括将来新增的）都自动被覆盖，不需要各自记得重置 m_firstUpdate
    const bool needBaseline = m_firstUpdate || m_baselineInterface != m_activeInterface;

    if (needBaseline) {
        // 首次更新或接口切换后：仅记录基线，不计算速度
        m_firstUpdate = false;
        m_baselineInterface = m_activeInterface;
        m_lastRxBytes = getActiveRxBytes();
        m_lastTxBytes = getActiveTxBytes();
        // 速度必须一并清零：否则切换后这一轮会继续显示上一块网卡的旧速度
        //（直到下一轮才被真实值覆盖），用户看到的是"另一接口 + 旧速度"的错配。
        // 末尾的 dirty 比较会把清零本身作为变化发射 speedChanged，QML 立即刷新
        m_downloadSpeed = 0;
        m_uploadSpeed = 0;
    } else if (elapsedSec > 0 && !m_activeInterface.isEmpty()) {
        // 按真实流逝时间计算速度（字节/秒），避免定时器抖动失真。
        // 这里只算"活动接口的瞬时速度"，用于任务栏（单接口模式）与详情弹窗；
        // 会话总量与日/月流量日志改由下方"所有接口"循环按物理网卡分别累加，
        // 原因见该循环的注释——放在这里会导致只统计活动接口，且与聚合口径不一致
        const qint64 currentRxBytes = getActiveRxBytes();
        const qint64 currentTxBytes = getActiveTxBytes();
        // 计数器回绕/接口重置时差值可能为负，钳制为 0 避免显示负速度
        const qint64 rxDelta = currentRxBytes - m_lastRxBytes;
        const qint64 txDelta = currentTxBytes - m_lastTxBytes;
        const qint64 rxDeltaClamped = rxDelta > 0 ? rxDelta : 0;
        const qint64 txDeltaClamped = txDelta > 0 ? txDelta : 0;
        m_downloadSpeed = rxDeltaClamped / elapsedSec;
        m_uploadSpeed = txDeltaClamped / elapsedSec;
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
    //
    // 本次改造：这个循环同时承担三件事，避免三次遍历各自求差（易漂移）：
    //   1. 为每个接口追加趋势历史
    //   2. 累加所有物理网卡的合计速率（多接口聚合）
    //   3. 把每个物理接口的增量分别写入日/月流量日志（修正"只计活动接口"的口径）
    if (elapsedSec > 0) {
        double sumDown = 0;
        double sumUp = 0;

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
            // 计数器回绕/接口重置时差值可能为负，钳制为 0 避免出现负速度
            const qint64 rxClamped = iRxDelta > 0 ? iRxDelta : 0;
            const qint64 txClamped = iTxDelta > 0 ? iTxDelta : 0;

            SpeedSample sample;
            sample.timestamp = nowSec;
            sample.downloadSpeed = rxClamped / elapsedSec;
            sample.uploadSpeed = txClamped / elapsedSec;
            m_speedHistory[name].append(sample);

            // 滑动窗口裁剪：超过 MAX_HISTORY_SAMPLES（1800）点时丢弃最旧的
            QVector<SpeedSample> &samples = m_speedHistory[name];
            while (samples.size() > MAX_HISTORY_SAMPLES) {
                samples.removeFirst();
            }

            // 只有物理网卡参与聚合与流量统计：tun/docker/veth 的流量实际仍走物理网卡，
            // 计入会造成重复计数（例如代理软件的 tun0 与底层 eno1 各算一遍）
            if (isPhysicalInterface(name)) {
                sumDown += sample.downloadSpeed;
                sumUp += sample.uploadSpeed;
                // 会话总量（dde-shell 启动至今）与日/月流量日志同源累加，
                // 二者口径必须一致：都按物理接口分别统计，避免"总量含 A 卡、日志只含 B 卡"
                m_totalDownload += rxClamped;
                m_totalUpload += txClamped;
                // 按接口分别累加日/月流量：统计窗口本就按接口分行展示，
                // 只算活动接口会让"切网卡后另一块的流量凭空消失"
                appendToTrafficLog(name, rxClamped, txClamped);
            }

            m_lastRxBytesByIface[name] = iface.rxBytes;
            m_lastTxBytesByIface[name] = iface.txBytes;
        }

        m_totalDownloadSpeed = sumDown;
        m_totalUploadSpeed = sumUp;

        // 历史采样点已追加，标记脏缓存，QML 下次读取时重建
        m_historyDirty = true;
        emit speedHistoryChanged();
    }

    // 仅在速度/总量实际变化时发射信号，避免空闲时每秒触发 QML 无效重绘。
    // 合计速率也挂在 speedChanged 上：它每秒随采样更新，与单接口速度同一节拍，
    // 单独造一个信号只会让 QML 多一处 Connections
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

// 低频统计检测：链路层状态、链路速率与 WiFi 信号（每 5 秒或接口切换时），变化时发射对应信号
// 设计原因：这三项数据变化频率极低（链路通断/协商速率/信号强度基本稳定），
// 无需每秒读取，降频降低系统调用与文件读取开销
void NetworkMonitorApplet::detectLowFreqStats()
{
    if (!m_activeInterface.isEmpty()) {
        // 链路层状态：读 carrier 与 operstate 判断是否断连（一次微小的 sysfs 读取）
        updateLinkState();
        // 链路速率：有线走同步 sysfs，无线走异步 iw；两者内部负责在变化时发射信号
        updateLinkSpeed();
        const int sig = detectWifiSignal(m_activeInterface);
        if (m_wifiSignal != sig) {
            m_wifiSignal = sig;
            emit wifiSignalChanged();
        }
    } else {
        // 无活动接口时归零，避免显示上一接口的残留数据；
        // 断连态一并清除，该场景由 QML 的"未检测到接口"占位态负责呈现
        setLinkDown(false);
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
        setActiveSsid(QString());
        return;
    }

    const int sysSpeed = readSysfsLinkSpeed(m_activeInterface);
    if (sysSpeed >= 0) {
        setLinkSpeed(sysSpeed);
        // 有线接口能直接从 sysfs 读到速率，不会走 iw 分支；
        // 此处必须清掉 SSID，否则从无线切到有线后会继续显示上一个 WiFi 名称
        setActiveSsid(QString());
        return;
    }

    // 非无线接口直接判为不可用（判定统一走 isWirelessInterface，不再就地硬编码前缀）
    if (!isWirelessInterface(m_activeInterface)) {
        setLinkSpeed(0);
        setActiveSsid(QString());
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
        // 与同步实现保持一致：iw 不可用时速率视为不可用（0）；
        // SSID 同样无从得知，一并清空，避免 QML 继续显示上一次的 WiFi 名称
        if (m_activeInterface == iface) {
            setLinkSpeed(0);
            setActiveSsid(QString());
        }
        proc->deleteLater();
    });
    connect(proc, &QProcess::finished, this, [this, proc, iface](int, QProcess::ExitStatus) {
        m_iwPending = false;
        // 期间用户可能已切换接口，此时结果对当前接口已无意义，直接丢弃
        if (m_activeInterface == iface) {
            // 同一份输出同时产出 bitrate 与 SSID：两者都只在这里解析，
            // 避免为拿 SSID 再启动一次 iw 子进程
            const QString output = QString::fromUtf8(proc->readAllStandardOutput());
            const int br = parseIwBitrate(output);
            setLinkSpeed(br > 0 ? br : 0);
            setActiveSsid(parseIwSsid(output));
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

// 读取 /sys/class/net/<iface>/carrier
// 返回值语义：-1 读不到（未知）、0 无载波、1 有载波
// 设计原因：用三态而非 bool，是因为"读不到"与"无载波"含义完全不同——
// 前者是接口刚消失或权限不足（应保持现状、不误报），后者才是真的断了
int NetworkMonitorApplet::readSysfsCarrier(const QString &iface) const
{
    QFile f(QStringLiteral("/sys/class/net/%1/carrier").arg(iface));
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return -1;
    }
    const QString val = QString::fromLatin1(f.readAll()).trimmed();
    f.close();
    if (val == QLatin1String("1")) {
        return 1;
    }
    return val == QLatin1String("0") ? 0 : -1;
}

// 读取 /sys/class/net/<iface>/operstate 原文并转小写（如 "up"/"down"/"unknown"）
// 读不到返回空串；调用方与 carrier 读不到一样按"未知"处理
// 转小写：内核当前固定输出小写，此处不依赖该约定，避免个别环境差异导致比较失效
QString NetworkMonitorApplet::readSysfsOperState(const QString &iface) const
{
    QFile f(QStringLiteral("/sys/class/net/%1/operstate").arg(iface));
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return QString();
    }
    const QString val = QString::fromLatin1(f.readAll()).trimmed().toLower();
    f.close();
    return val;
}

// 由 carrier 与 operstate 判定链路是否断开（纯函数，便于单元测试）
// 规则按顺序短路，先命中先返回。优先级依据：operstate 是内核给出的权威状态，
// 只要它明确表态（up 或 down/dormant 等），就以它为准；只有它含糊（unknown/读不到）时
// 才回退看 carrier。
//   1. operstate == "up"      → 未断开：内核已声明链路可用
//      （存在 operstate 为 up 而 carrier 读数为 0 的驱动，此时以 operstate 为准）
//   2. carrier == 0           → 断开：无载波（拔网线、接口 down、WiFi 未关联）
//   3. operstate 明确为断开态（非 up 且非 unknown，如 down / dormant / lowerlayerdown）
//                             → 断开
//      设计原因（真机实测修正）：原实现把 carrier < 0（读不到）放在最前面一律返回
//      "未断开"，结果无线接口被 `ip link set down` 后 carrier 读取返回 EINVAL（读不到）
//      而 operstate 明确为 "down"，这个明确信号被短路丢掉，断连态永不显示。
//      实测：`ip link set wlo1 down` → carrier 报"无效的参数"、operstate=down、state DOWN。
//      故 carrier 读不到不能再无条件视为"未知"，必须让 operstate 先表态。
//   4. carrier < 0（读不到）  → 未断开：走到这里 operstate 已含糊（unknown/空），
//      无任何明确依据，宁可漏报也不误报（接口刚被删除或权限不足时任务栏不该闪断连）
//   5. 其余（operstate 为 unknown/空且 carrier > 0）→ 未断开：lo、docker0 等虚拟接口的
//      operstate 常态即 unknown，这类接口没有真实载波语义，有载波即视为可用
bool NetworkMonitorApplet::isLinkDown(int carrier, const QString &operState)

{
    return JNetCore::isLinkDown(carrier, operState);
}

// 读取活动接口的链路层状态并更新缓存
// 调用时机：仅由 detectLowFreqStats 在活动接口非空时调用，未新增定时器
void NetworkMonitorApplet::updateLinkState()
{
    setLinkDown(isLinkDown(readSysfsCarrier(m_activeInterface),
                           readSysfsOperState(m_activeInterface)));
}

// 更新链路断开缓存，仅在值变化时发射 linkDownChanged，避免 QML 无效重绘
void NetworkMonitorApplet::setLinkDown(bool down)
{
    if (m_linkDown == down) {
        return;
    }
    m_linkDown = down;
    emit linkDownChanged();
}

// 解析 `iw dev <iface> link` 输出中的 SSID
// 该输出与 bitrate 来自同一次子进程调用，因此获取 SSID 不增加任何额外开销。
// 真实输出中 SSID 行为 "\tSSID: Home"；接口未连接时整段输出只有
// "Not connected."（有时附带 "Not connected (Reason: ...)"），此时返回空串，
// 由 QML 回退显示接口名。
// 边界处理依据：
//   1. SSID 允许包含空格（如 "My Home WiFi"），故只剥离行首的 "SSID:" 前缀与
//      两侧空白，不对内容再做切分；SSID 也可能是中文，按原样返回。
//   2. 必须**逐行**匹配，不能用多行正则：`SSID:` 后为空时（"SSID: \n\tfreq: 5180"）
//      多行的 \s* 会吃掉换行符，把下一行的 "freq: 5180" 当成 SSID 返回。
//      该场景已被单元测试 testParseIwSsid(ssid-empty-value) 固定住
QString NetworkMonitorApplet::parseIwSsid(const QString &output)

{
    return JNetCore::parseIwSsid(output);
}

// 更新 WiFi 名称缓存，仅在值变化时发射 activeSsidChanged，避免 QML 无效重绘
void NetworkMonitorApplet::setActiveSsid(const QString &ssid)
{
    if (m_activeSsid == ssid) {
        return;
    }
    m_activeSsid = ssid;
    emit activeSsidChanged();
}

// 解析 `iw dev <iface> link` 输出中的 bitrate（Mbps），失败返回 0
// 真实输出（真机实测）形如：
//     Connected to aa:bb:cc:dd:ee:ff (on wlo1)
//             rx bitrate: 390.0 MBit/s VHT-MCS 8 80MHz short GI VHT-NSS 1
//             tx bitrate: 866.7 MBit/s VHT-MCS 9 80MHz short GI VHT-NSS 2
// 设计原因（真机测试暴露的既有缺陷，三处独立问题）：
//   1. 行前缀：真实输出的 bitrate 行带 "rx "/"tx " 前缀，并非以 "bitrate:" 开头。
//      只锚定行首 "bitrate:" 会让所有真实输出都解析失败，故前缀设为可选并捕获方向。
//   2. 单位大小写：真实单位是 "MBit/s"（大写 B），而原模式写死小写 "bit/s"，
//      于是最常见的 MBit/s 全部解析失败（"Gbit/s" 恰好小写 b 才侥幸匹配）。
//      故用 CaseInsensitiveOption 接受 Bit/s / bit/s。
//   3. 前导缩进：原实现用 `re.match(output)` 只从整段文本位置 0 尝试一次，
//      而真实输出以制表符缩进开头，"bitrate:" 不在位置 0；故改为逐行 trim 后匹配。
// 取值：优先 tx（发送）——发送方向通常代表链路协商上限，也与有线接口
// /sys/class/net/<iface>/speed 的量级一致；无 tx 行时回退到 rx 行。
int NetworkMonitorApplet::parseIwBitrate(const QString &output) const

{
    return JNetCore::parseIwBitrate(output);
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
    return JNetCore::parseTcpConnections(output);
}

// 判断接口是否为无线网卡（判定统一入口，链路上所有"是否无线"的决策都走这里）
// 设计原因（真机实测暴露的缺陷）：原先在 4 处各自硬编码 `startsWith("wlp") ||
// startsWith("wlan")`，而 deepin 25 上的无线接口命名为 "wlo1"，两个前缀都不匹配，
// 于是：协商速率不走 iw 降级（恒为 0）、WiFi 信号强度恒为 0、接口类型/图标被当成有线、
// 自动选择接口时被排除。前缀白名单本质上是不可靠的启发式，故改为优先探测内核能力：
//   /sys/class/net/<iface>/wireless/ 目录存在即无线（与命名约定无关）
// 探测失败（目录不存在、权限不足、虚拟接口）时回退到前缀匹配兜底，避免漏判主流命名。
// 前缀集合含 wlo（deepin/部分发行版）与 wlx（USB 无线网卡常见命名）。
bool NetworkMonitorApplet::isWirelessInterface(const QString &iface)

{
    if (iface.isEmpty()) {
        return false;
    }
    // 优先：内核是否在该接口下暴露 wireless 目录（最可靠的判据，与命名约定无关）。
    // 这一步涉及文件系统访问，故留在本类；纯命名判定已抽到 JNetCore 供单测
    const QFileInfo wirelessDir(
        QStringLiteral("/sys/class/net/%1/wireless").arg(iface));
    if (wirelessDir.isDir()) {
        return true;
    }
    return JNetCore::isWirelessByPrefix(iface);
}

// 读取指定接口的 WiFi 信号强度（dBm）
// 仅无线接口有效（判定走 isWirelessInterface）；/proc/net/wireless 桌面环境可能不存在（返回 0）
// 该文件每行形如 "wlp3s0: 60.  -65.  -256  0 ..."，level（dBm）为第 3 个数值字段
int NetworkMonitorApplet::detectWifiSignal(const QString &iface)
{
    if (!isWirelessInterface(iface)) {
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

// 判断是否为物理网卡（用于"自动选择默认接口"与"多接口聚合"两处）
//
// 实现方式：从"前缀白名单"改为"已知虚拟接口的排除法"。
// 设计原因（实测缺陷）：原白名单只认无线判定 + enp/eth，而板载网卡常见 eno1、
// 虚拟机常见 ens33、USB 有线常见 enx<MAC>——这些全部被判为"非物理"。
// 后果有两层：自动选择时会跳过真正的主网卡；多接口聚合若用它做白名单，
// 这些网卡的流量会被静默漏算（用户完全看不出少了什么）。
// 排除法天然覆盖未知命名：只要不是已知虚拟接口，就按物理网卡对待。
//
// 已知虚拟接口（Linux 上常见的几类）：
//   lo          回环
//   tun/tap/wg   VPN 隧道
//   docker/veth  容器
//   br-/virbr    网桥（含容器网桥、虚拟化网桥）
//   Meta         deepin 的代理接口
//   vnet         虚拟化（KVM/libvirt 的 vnetN）
//   ifb          流量整形
// 无线接口不在此处区分——调用方若需判断无线，另有 isWirelessInterface()
bool NetworkMonitorApplet::isPhysicalInterface(const QString &name) const

{
    return JNetCore::isPhysicalInterface(name);
}

// ---- 流量日志（日/月持久化）----

// 构造空的日志结构（byDay/byMonth 均为空对象）
// 提取的原因：首次运行、解析失败、读取失败三处都需要同一个"空结构"，
// 各写一遍容易出现字段名不一致（例如漏掉 byMonth 会让统计窗口的按月页签永远空白）
static QJsonObject makeEmptyTrafficLog()
{
    QJsonObject log;
    log[QStringLiteral("byDay")] = QJsonObject();
    log[QStringLiteral("byMonth")] = QJsonObject();
    return log;
}

// 启动时从 traffic_log.json 加载流量日志
// 优雅降级：文件不存在、读取失败或 JSON 解析失败时均使用空结构，不崩溃不抛异常；
// 首次运行（文件不存在）时先创建空的 byDay/byMonth 结构，由后续保存写盘创建文件
void NetworkMonitorApplet::loadTrafficLog()
{
    QFile file(m_trafficLogPath);

    // 文件不存在属正常首次运行：允许后续写盘创建它
    if (!file.exists()) {
        m_trafficLog = makeEmptyTrafficLog();
        m_trafficLogWriteBlocked = false;
        return;
    }

    // 文件存在但打不开（权限被改、属主变 root、ACL 限制等）：
    // 这时绝不能按"空日志"继续——QSaveFile 依靠临时文件 + rename，即便原文件不可读
    // 也能把空对象覆盖上去，结果是 30 天历史被静默清零且用户毫无感知。
    // 因此这里给出告警并置位写盘禁令：本次会话宁可不记录新流量，也不破坏既有历史
    if (!file.open(QIODevice::ReadOnly)) {
        qWarning() << "traffic_log.json 无法读取，本次会话暂停流量日志写入以免覆盖历史:"
                   << file.errorString();
        m_trafficLog = makeEmptyTrafficLog();
        m_trafficLogWriteBlocked = true;
        return;
    }

    QJsonParseError err;
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &err);
    file.close();

    if (err.error == QJsonParseError::NoError && doc.isObject()) {
        m_trafficLog = doc.object();
        m_trafficLogWriteBlocked = false;
        return;
    }

    // 解析失败（如文件被外部写坏）：降级为空结构，避免后续累加异常。
    // 记录告警而非静默降级——历史统计会整体清零，用户需要知道原因。
    // 这里不禁止写盘：文件内容已经不可用，保留它没有任何收益，重建成合法空结构更好
    qWarning() << "traffic_log.json 解析失败，历史统计已重置:" << err.errorString();
    m_trafficLog = makeEmptyTrafficLog();
    m_trafficLogWriteBlocked = false;
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
    // 加载阶段未能读到既有日志（文件不可读）时禁止写盘：
    // 否则本次会话累积的少量数据会以空结构为基础覆盖掉磁盘上的完整历史
    if (m_trafficLogWriteBlocked) {
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
void NetworkMonitorApplet::appendToTrafficLog(const QString &iface,
                                              qint64 rxDelta, qint64 txDelta)

{
    // 键在此处取（依赖 QDate），数据操作交给 core——core 保持无时间依赖，便于用固定日期断言
    const QDate today = QDate::currentDate();
    JNetCore::appendTraffic(m_trafficLog, iface,
                            today.toString(QStringLiteral("yyyy-MM-dd")),
                            today.toString(QStringLiteral("yyyy-MM")),
                            rxDelta, txDelta);
}

// 裁剪超期记录：按日最多 30 天、按月最多 12 个月，超出删除最旧记录
// 日期/月份均为 ISO 格式（"yyyy-MM-dd"/"yyyy-MM"），字典序即时间序，
// 排序后取最小的超量个删除，保证始终保留最近的记录
void NetworkMonitorApplet::pruneTrafficLog()

{
    JNetCore::pruneTraffic(m_trafficLog, MAX_DAY_ENTRIES, MAX_MONTH_ENTRIES);
}

D_APPLET_CLASS(NetworkMonitorApplet)

DS_END_NAMESPACE

#include "networkmonitorapplet.moc"