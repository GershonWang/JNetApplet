// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#pragma once

#include <applet.h>

#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVariantList>
#include <QMap>
#include <QHash>
#include <QPointF>
#include <QDateTime>
#include <QColor>
#include <QSettings>
#include <QJsonObject>
#include <QMetaType>
#include <QVariantMap>

DS_BEGIN_NAMESPACE

struct NetworkInterface {
    QString name;           // 接口名称，如 "eth0", "wlan0"
    qint64 rxBytes;         // 接收字节数
    qint64 txBytes;         // 发送字节数
    qint64 rxPackets;       // 接收包数
    qint64 txPackets;       // 发送包数
    qint64 rxErrors;        // 接收错误数
    qint64 txErrors;        // 发送错误数
    qint64 rxDropped;       // 接收丢弃数
    qint64 txDropped;       // 发送丢弃数
};

// 单个速度采样点：用于趋势图的环形缓冲
// timestamp: 自 epoch 的秒级时间戳，作为 X 轴定位
// downloadSpeed / uploadSpeed: 当时的瞬时速度（字节/秒），作为两条折线的 Y 值
struct SpeedSample {
    qint64 timestamp;
    double downloadSpeed;
    double uploadSpeed;
};

class NetworkMonitorApplet : public DApplet
{
    Q_OBJECT

    Q_PROPERTY(double downloadSpeed READ downloadSpeed NOTIFY speedChanged)
    Q_PROPERTY(double uploadSpeed READ uploadSpeed NOTIFY speedChanged)
    Q_PROPERTY(double totalDownload READ totalDownload NOTIFY totalChanged)
    Q_PROPERTY(double totalUpload READ totalUpload NOTIFY totalChanged)
    Q_PROPERTY(QStringList networkInterfaces READ networkInterfaces NOTIFY interfacesChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
    // 当前活动接口，用户在弹窗或设置窗口选择后持久化到 ~/.config/jnetapplet/settings.ini，
    // 下次启动自动恢复；若保存的接口已不存在则回退到自动选择
    Q_PROPERTY(QString activeInterface READ activeInterface NOTIFY activeInterfaceChanged)
    // 活动接口的 IPv4 地址，供 QML 在弹出面板和 tooltip 中显示
    Q_PROPERTY(QString ipAddress READ ipAddress NOTIFY ipAddressChanged)
    // 活动接口的 IPv6 全球地址（已过滤 link-local 和 loopback），供 QML 显示
    Q_PROPERTY(QString ipv6Address READ ipv6Address NOTIFY ipv6AddressChanged)
    // 活动接口的收发包/错误/丢包累计统计（自开机起累计值），供弹窗接口信息区展示
    // 全部用 quint64 类型，QML 侧可直接读取；任一值变化时统一发射 packetStatsChanged
    Q_PROPERTY(quint64 rxPackets READ rxPackets NOTIFY packetStatsChanged)
    Q_PROPERTY(quint64 txPackets READ txPackets NOTIFY packetStatsChanged)
    Q_PROPERTY(quint64 rxErrors READ rxErrors NOTIFY packetStatsChanged)
    Q_PROPERTY(quint64 txErrors READ txErrors NOTIFY packetStatsChanged)
    Q_PROPERTY(quint64 rxDropped READ rxDropped NOTIFY packetStatsChanged)
    Q_PROPERTY(quint64 txDropped READ txDropped NOTIFY packetStatsChanged)
    // 活动接口的链路协商速率（Mbps）：有线读 /sys/class/net/<iface>/speed，
    // 无线读失败时降级解析 `iw dev link` 的 bitrate；0 表示不可用
    Q_PROPERTY(int linkSpeed READ linkSpeed NOTIFY linkSpeedChanged)
    // 刷新间隔（毫秒），默认 1000，用户在设置窗口选择后持久化并即时生效
    Q_PROPERTY(int refreshInterval READ refreshInterval WRITE setRefreshInterval NOTIFY refreshIntervalChanged)
    // 当前活动接口的 TCP ESTABLISHED 连接数，供弹窗展示
    Q_PROPERTY(int tcpConnections READ tcpConnections NOTIFY tcpConnectionsChanged)
    // 活动接口的 WiFi 信号强度（dBm，负值如 -65），非无线接口或不可用时为 0
    Q_PROPERTY(int wifiSignal READ wifiSignal NOTIFY wifiSignalChanged)
    // 插件版本号，从 dde-shell 元数据读取，版本唯一源为 CMakeLists.txt project(VERSION)
    Q_PROPERTY(QString version READ version CONSTANT)
    // 任务栏网速数值字体颜色，空串表示跟随系统主题（由 QML 回退到 primaryText），
    // 用户在设置窗口选择后持久化到 ~/.config/jnetapplet/settings.ini
    Q_PROPERTY(QString textColor READ textColor WRITE setTextColor NOTIFY textColorChanged)
    // 当前活动接口的下行速度历史采样点（QPointF 列表：x=时间戳秒, y=速度 bytes/sec）
    // 用于趋势图绘制下载折线，每次 calculateSpeed 追加一个点并发射 speedHistoryChanged
    Q_PROPERTY(QVariantList speedHistoryDownload READ speedHistoryDownload NOTIFY speedHistoryChanged)
    // 当前活动接口的上行速度历史采样点，结构同 speedHistoryDownload
    Q_PROPERTY(QVariantList speedHistoryUpload READ speedHistoryUpload NOTIFY speedHistoryChanged)
    // 流量统计日志（JSON 对象），供 QML 流量统计窗口读取展示
    // 结构：{"byDay": {日期: {接口: {rx, tx}}}, "byMonth": {月份: {接口: {rx, tx}}}}
    // 设计原因：会话总量重启清零，用户无法了解长期趋势；按日/月聚合让用户看
    // 每日使用量和月度汇总，按接口分让多网卡各自独立统计。
    // 保存频率：累加每秒执行（内存操作），写盘与通知 QML 降频（每 30 秒一次），
    // 避免每秒磁盘 IO 与 QML 重绘
    Q_PROPERTY(QJsonObject trafficLog READ trafficLog NOTIFY trafficLogChanged)
    // TCP 连接详情列表，供 QML 连接清单窗口展示
    // 每项为 QVariantMap（键：localAddress/localPort/remoteAddress/remotePort/state/processName）
    // 仅包含 ESTABLISHED 状态连接，含进程名反查
    // 设计原因：用 ss 命令反查进程名，通过 netlink 获取不受 /proc 权限限制，
    // 但仍需启动子进程开销较大，故降频至每 5 秒更新一次
    Q_PROPERTY(QVariantList tcpConnectionList READ tcpConnectionList NOTIFY tcpConnectionListChanged)

public:
    explicit NetworkMonitorApplet(QObject *parent = nullptr);
    ~NetworkMonitorApplet();

    virtual bool load() override;
    virtual bool init() override;

    double downloadSpeed() const;
    double uploadSpeed() const;
    double totalDownload() const;
    double totalUpload() const;
    QStringList networkInterfaces() const;
    bool ready() const;
    QString activeInterface() const;
    QString ipAddress() const;
    QString ipv6Address() const;
    // 返回活动接口的收发包/错误/丢包累计值（自开机起），供弹窗接口信息区展示
    quint64 rxPackets() const;
    quint64 txPackets() const;
    quint64 rxErrors() const;
    quint64 txErrors() const;
    quint64 rxDropped() const;
    quint64 txDropped() const;
    // 返回活动接口的链路协商速率（Mbps），0 表示不可用
    int linkSpeed() const;
    // 返回刷新间隔（毫秒）
    int refreshInterval() const;
    // 设置刷新间隔（毫秒），校验后持久化并即时生效
    void setRefreshInterval(int ms);
    // 返回当前活动接口的 TCP ESTABLISHED 连接数
    int tcpConnections() const;
    // 返回活动接口的 WiFi 信号强度（dBm），0 表示不可用
    int wifiSignal() const;
    // 返回当前活动接口的下行速度历史（QPointF 列表），供 QML 趋势图绘制
    QVariantList speedHistoryDownload() const;
    // 返回当前活动接口的上行速度历史（QPointF 列表），供 QML 趋势图绘制
    QVariantList speedHistoryUpload() const;
    // 返回插件版本号，从 dde-shell 插件元数据（metadata.json）读取
    QString version() const;
    // 返回任务栏网速字体颜色，空串表示跟随系统主题
    QString textColor() const;
    // 设置任务栏网速字体颜色，空串表示跟随系统主题
    void setTextColor(const QString &color);
    // 返回流量统计日志（JSON 对象），结构见 trafficLog 属性注释，供 QML 流量统计窗口读取
    QJsonObject trafficLog() const;
    // 返回 TCP 连接详情列表（QVariantList of QVariantMap），供 QML 连接清单窗口展示
    QVariantList tcpConnectionList() const;

    // 定时器回调，由 m_refreshTimer 每秒调用。非 Q_INVOKABLE（QML 不应直接调用，
    // 否则会打破 1 秒定时间隔导致速度计算失真）
    void refresh();
    Q_INVOKABLE void setActiveInterface(const QString &interface);

signals:
    void speedChanged();
    void totalChanged();
    void interfacesChanged();
    void readyChanged();
    void activeInterfaceChanged();
    void ipAddressChanged();
    void ipv6AddressChanged();
    // 活动接口包统计（收发包/错误/丢包）变化时通知 QML 更新
    void packetStatsChanged();
    // 活动接口链路速率变化时通知 QML 更新
    void linkSpeedChanged();
    // 刷新间隔变化时通知 QML 更新
    void refreshIntervalChanged();
    // TCP ESTABLISHED 连接数变化时通知 QML 更新
    void tcpConnectionsChanged();
    // WiFi 信号强度变化时通知 QML 更新
    void wifiSignalChanged();
    void speedHistoryChanged();
    // 任务栏网速字体颜色变化时通知 QML 更新
    void textColorChanged();
    // 流量统计日志变化时通知 QML 更新（降频，每 30 秒发射一次）
    void trafficLogChanged();
    // TCP 连接详情列表变化时通知 QML 更新（降频，每 5 秒发射一次）
    void tcpConnectionListChanged();

private:
    void readNetworkStats();
    void calculateSpeed();
    void detectInterfaces();
    // 检测活动接口的 IPv4 与 IPv6 地址，变化时分别发射对应信号
    void detectIpAddress();
    // 低频统计检测：链路速率与 WiFi 信号（每 5 秒），变化时发射对应信号
    void detectLowFreqStats();
    // 读取指定接口的链路协商速率（Mbps），无线读 speed 失败时降级解析 iw bitrate
    int detectLinkSpeed(const QString &iface);
    // 解析 `iw dev <iface> link` 输出中的 bitrate（Mbps），失败返回 0
    int parseIwBitrate(const QString &output) const;
    // 统计 /proc/net/tcp 与 tcp6 中 ESTABLISHED（状态 01）的连接数
    int countTcpConnections() const;
    // 构建 TCP 连接详情列表（调用 ss 命令获取 ESTABLISHED 连接，含进程名反查）
    // 结果存入 m_tcpConnectionList 并发射 tcpConnectionListChanged；仅 ESTABLISHED
    void buildTcpConnectionList();
    // 读取指定接口的 WiFi 信号强度（dBm），非无线接口或不可用时返回 0
    int detectWifiSignal(const QString &iface);
    // 判断是否为物理网卡（无线 wlp/wlan，有线 enp/eth），
    // 用于自动选择时优先真实网卡而非虚拟代理接口（如 Meta/tun0）
    bool isPhysicalInterface(const QString &name) const;
    qint64 getActiveRxBytes() const;
    qint64 getActiveTxBytes() const;

    // ---- 流量日志（日/月持久化）----
    // 启动时从 traffic_log.json 加载日志；文件不存在或解析失败时降级为空结构，不崩溃
    void loadTrafficLog();
    // 将日志写入 traffic_log.json（先裁剪超期记录再写盘），供析构与降频保存调用
    void saveTrafficLog();
    // 将本次流量增量累加到当日/当月/当前活动接口的日志记录中（每秒调用，内存操作）
    void appendToTrafficLog(qint64 rxDelta, qint64 txDelta);
    // 裁剪超期记录：按日最多 90 天、按月最多 24 个月，超出删除最旧记录
    void pruneTrafficLog();

    QTimer *m_refreshTimer;
    QMap<QString, NetworkInterface> m_interfaces;
    QStringList m_interfaceList;
    QString m_activeInterface;
    QString m_ipAddress;           // 活动接口的 IPv4 地址
    QString m_ipv6Address;         // 活动接口的 IPv6 全球地址（过滤 link-local）
    
    // 速度计算
    qint64 m_lastRxBytes;
    qint64 m_lastTxBytes;
    // 上次采样的毫秒时间戳，用于按真实间隔计算速度（避免定时器抖动失真）
    qint64 m_lastTimestampMs;
    // 当前瞬时速度（字节/秒），用 double 存储以保留按真实间隔除算的小数精度
    double m_downloadSpeed;
    double m_uploadSpeed;
    // 每个接口的上次收发字节数，用于为所有接口（非仅活动接口）计算速度并采集历史
    // 设计原因：原仅跟踪活动接口，切换到非活动接口时趋势图为空需等待数分钟才有数据
    QHash<QString, qint64> m_lastRxBytesByIface;
    QHash<QString, qint64> m_lastTxBytesByIface;
    
    // 总量
    qint64 m_totalDownload;
    qint64 m_totalUpload;

    // 活动接口包统计缓存（自开机起累计值），供弹窗接口信息区展示
    // 设计原因：/proc/net/dev 已解析包计数但此前直接丢弃，现缓存并暴露给 QML
    quint64 m_rxPackets;
    quint64 m_txPackets;
    quint64 m_rxErrors;
    quint64 m_txErrors;
    quint64 m_rxDropped;
    quint64 m_txDropped;

    // IP 地址检测降频计数器：IP 变化频率极低，每 5 次 refresh 才检测一次
    // 初始化 4 使首次 refresh 立即检测，避免启动后 IP 显示延迟
    int m_ipDetectCounter;

    // 活动接口链路协商速率（Mbps），0 表示不可用
    int m_linkSpeed;
    // 刷新间隔（毫秒），默认 1000，可配置并持久化
    int m_refreshInterval;
    // 当前活动接口的 TCP ESTABLISHED 连接数
    int m_tcpConnections;
    // 活动接口的 WiFi 信号强度（dBm），0 表示不可用
    int m_wifiSignal;
    // 低频统计检测计数器：链路速率/WiFi 信号每 5 次 refresh 检测一次
    // 初始化 4 使首次 refresh 立即检测
    int m_lowFreqCounter;
    
    bool m_ready;
    bool m_firstUpdate;
    // 任务栏网速字体颜色，空串表示跟随系统主题
    // 设计原因：空串作为"跟随系统"的语义值，QML 层用 textColor ? textColor : primaryText
    // 做回退，避免后端硬编码系统色
    QString m_textColor;

    // 速度历史环形缓冲：每个接口独立维护一份，key 为接口名
    // 设计原因：接口切换时趋势图不出现跳变，切回时仍能看到该接口历史
    QHash<QString, QVector<SpeedSample>> m_speedHistory;
    // 每个接口最多保留的采样点数：30 分钟 × 60 秒 = 1800
    // 设计原因：流量波动图支持 1/5/30 分钟时间窗口切换，需在展示层选择显示范围，
    // 故后端需存够 30 分钟的历史数据；时间窗口选择是纯 QML 展示层行为，后端只需
    // 提供足够长的历史缓冲，无需新增 Q_PROPERTY
    static constexpr int MAX_HISTORY_SAMPLES = 1800;

    // 历史 QVariantList 缓存：避免 QML 每次读取都重新构造 300 个 QPointF
    // 设计原因：Canvas 每秒读取一次 + hover 时也读取，逐个 append 开销可观；
    // 用 dirty 标记懒重建，仅当追加采样点或切换接口后重建一次
    // 注意：getter 为 const，故缓存与 dirty 标记声明为 mutable
    mutable QVariantList m_cachedHistoryDl;
    mutable QVariantList m_cachedHistoryUpload;
    mutable bool m_historyDirty;
    // 重建历史缓存：仅当 m_historyDirty 时由两个 getter 调用
    void rebuildHistoryCache() const;

    // ---- 流量日志成员 ----
    // 完整流量日志 JSON：{"byDay": {日期: {接口: {rx, tx}}}, "byMonth": {月份: {接口: {rx, tx}}}}
    // 设计原因：会话总量重启清零，用户无法了解长期趋势；按日/月聚合让用户看
    // 每日使用量和月度汇总，按接口分让多网卡各自独立统计
    QJsonObject m_trafficLog;
    // 日志文件路径（~/.config/jnetapplet/traffic_log.json）
    QString m_trafficLogPath;
    // 当前日期 "yyyy-MM-dd" 与月份 "yyyy-MM"，用于跨日/跨月检测
    QString m_currentDate;
    QString m_currentMonth;
    // 降频保存计数器：每 30 秒（按刷新间隔折算）写盘一次并通知 QML，
    // 避免每秒磁盘 IO 与 QML 重绘；析构函数再兜底保存一次
    int m_trafficSaveCounter;
    // 按日记录最多保留 90 天、按月最多保留 24 个月，超出自动裁剪最旧记录
    static constexpr int MAX_DAY_ENTRIES = 90;
    static constexpr int MAX_MONTH_ENTRIES = 24;

    // ---- TCP 连接清单成员 ----
    // TCP 连接详情列表（QVariantList of QVariantMap），供 QML 连接清单窗口读取
    // 设计原因：QVariantMap 便于 QML 以 JS 对象直接访问各字段，
    // 不暴露中间结构体（需注册元类型，QML 访问繁琐）
    QVariantList m_tcpConnectionList;
    // TCP 连接清单降频计数器：ss 命令需启动子进程开销大，每 5 次 refresh 更新一次
    // 初始化 4 使首次 refresh 立即更新
    int m_tcpListCounter = 4;
};

DS_END_NAMESPACE