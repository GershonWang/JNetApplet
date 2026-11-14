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
    // 无线接口名列表（networkInterfaces 的子集），供 QML 判定接口类型。
    // 设计原因：QML 读不了 /sys/class/net/<iface>/wireless，故由后端判定后暴露；
    // 采用 Q_PROPERTY 而非 Q_INVOKABLE 方法：真机实测 Q_INVOKABLE 方法
    // （bool f(const QString&) const）在 QML 侧报 "Property ... is not a function"，
    // 而属性读取路径（networkInterfaces 等）稳定可用，故与既有属性保持同一机制。
    // 与 networkInterfaces 共用 interfacesChanged 通知：两者同时更新，无需独立信号
    Q_PROPERTY(QStringList wirelessInterfaces READ wirelessInterfaces NOTIFY interfacesChanged)
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
    // 活动接口链路层是否断开（carrier 为 0 或 operstate 非 up），供任务栏、悬停提示与弹窗显示断连态
    // 设计原因：ready 表示"有没有接口"，与"接口是否连得通"无关，两者混淆会让"网线被拔"
    // 显示成"未检测到接口"，故这里独立成一个属性；判定挂在 5 秒低频探测中（链路状态变化远慢于速度）
    Q_PROPERTY(bool linkDown READ linkDown NOTIFY linkDownChanged)
    // 刷新间隔（毫秒），默认 1000，用户在设置窗口选择后持久化并即时生效
    Q_PROPERTY(int refreshInterval READ refreshInterval WRITE setRefreshInterval NOTIFY refreshIntervalChanged)
    // 当前活动接口的 TCP ESTABLISHED 连接数，供弹窗展示
    Q_PROPERTY(int tcpConnections READ tcpConnections NOTIFY tcpConnectionsChanged)
    // 活动接口的 WiFi 信号强度（dBm，负值如 -65），非无线接口或不可用时为 0
    Q_PROPERTY(int wifiSignal READ wifiSignal NOTIFY wifiSignalChanged)
    // 活动接口连接到的 WiFi 名称（SSID），非无线或未连接时为空串。
    // 设计原因：任务栏提示与弹窗原显示接口名 wlo1/eno1，这类名字由内核按 PCI 位置生成，
    // 用户无法据此判断"连的是哪个 WiFi"。SSID 与链路速率来自同一次 `iw dev link` 调用，
    // 不新增子进程与定时器。QML 侧经 NetCommon.displayName() 做"有 SSID 用 SSID、
    // 否则回退接口名"的统一处理，避免各处各写一套回退逻辑
    Q_PROPERTY(QString activeSsid READ activeSsid NOTIFY activeSsidChanged)
    // 速度显示单位：0=智能自动（B/s→KB/s→MB/s→GB/s），1=固定 KB/s，2=固定 Mbps
    // 写值经 setSpeedUnit() 校验，非法值忽略；变化后持久化到 settings.ini 并即时生效。
    // 设计原因：二进制单位（KB/s）与运营商/测速工具的十进制 Mbps 相差约 8 倍，
    // 用户拿插件数值与宽带套餐比对时会对不上，故提供可选项
    Q_PROPERTY(int speedUnit READ speedUnit WRITE setSpeedUnit NOTIFY speedUnitChanged)
    // 语义化的单位判据，供 QML 直接使用，避免在界面代码里写 `=== 1` / `=== 2` 这类魔法数字。
    // 设计原因：QML 里若按整数比较，日后再加一档单位或调整取值顺序时，
    // 散落各处的数字比较会静默失配（表现为"设置不生效"且不报错）；
    // 用布尔属性把"当前是不是这个口径"的语义固定在后端一处
    Q_PROPERTY(bool speedUnitIsMbps READ speedUnitIsMbps NOTIFY speedUnitChanged)
    Q_PROPERTY(bool speedUnitIsKBps READ speedUnitIsKBps NOTIFY speedUnitChanged)
    // 日流量提醒阈值（GB，十进制 1 GB = 1000³ 字节）；0 表示不提醒。
    // 写值经 setDailyLimitGb() 校验：负数/NaN/无限大一律按 0 处理，不写脏值。
    // 设计原因：运营商套餐以十进制 GB 计（1 GB 流量包 = 1000 MB），
    // 若用二进制 GiB 会与套餐数字对不上，用户无法据此判断是否快超量
    Q_PROPERTY(double dailyLimitGb READ dailyLimitGb WRITE setDailyLimitGb NOTIFY quotaLimitChanged)
    // 月流量提醒阈值（GB），语义同 dailyLimitGb
    Q_PROPERTY(double monthlyLimitGb READ monthlyLimitGb WRITE setMonthlyLimitGb NOTIFY quotaLimitChanged)
    // 当前周期已用流量（字节），供设置窗口回显"今日已用/本月已用"，便于用户判断阈值该填多少。
    // 与「流量统计」窗口顶部数字同口径（该周期下所有接口 rx+tx 之和）
    Q_PROPERTY(double todayUsedBytes READ todayUsedBytes NOTIFY trafficLogChanged)
    Q_PROPERTY(double monthUsedBytes READ monthUsedBytes NOTIFY trafficLogChanged)
    // 是否在任务栏显示"所有物理网卡合计速率"（默认 false = 只显示活动接口）。
    // 设计原因：多网卡场景下（有线 + 无线同时工作、或容器宿主多网口），
    // 只看单卡会低估实际吞吐；聚合口径排除 tun/docker/veth 等虚拟接口，
    // 避免与物理网卡重复计数（代理软件的 tun0 流量实际仍走物理网卡）
    Q_PROPERTY(bool aggregateSpeed READ aggregateSpeed WRITE setAggregateSpeed NOTIFY aggregateSpeedChanged)
    // 所有物理网卡的速率之和（字节/秒）；仅在 aggregateSpeed 开启时供任务栏使用。
    // 与 downloadSpeed/uploadSpeed（单接口）并存，由 QML 按开关二选一显示
    Q_PROPERTY(double totalDownloadSpeed READ totalDownloadSpeed NOTIFY speedChanged)
    Q_PROPERTY(double totalUploadSpeed READ totalUploadSpeed NOTIFY speedChanged)
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
    // 速度显示单位取值（与 Q_PROPERTY speedUnit 对应）
    // 用常量而非 enum class 的原因：QML 侧直接传 int，且需与配置文件中的整数互转，
    // 保留为 int 可省去元类型注册；命名常量保证 C++ 侧不出现魔法数字
    static constexpr int SpeedUnitAuto = 0;   // 智能自动：B/s → KB/s → MB/s → GB/s
    static constexpr int SpeedUnitKBps = 1;   // 固定千字节每秒（二进制）
    static constexpr int SpeedUnitMbps = 2;   // 固定兆比特每秒（十进制，运营商口径）

    explicit NetworkMonitorApplet(QObject *parent = nullptr);
    ~NetworkMonitorApplet();

    virtual bool load() override;
    virtual bool init() override;

    double downloadSpeed() const;
    double uploadSpeed() const;
    double totalDownload() const;
    double totalUpload() const;
    QStringList networkInterfaces() const;
    // 返回无线接口名列表（m_interfaceList 过滤 isWirelessInterface）
    QStringList wirelessInterfaces() const;
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
    // 返回活动接口链路层是否断开（carrier 为 0 或 operstate 非 up），true 表示断连
    bool linkDown() const;
    // 返回刷新间隔（毫秒）
    int refreshInterval() const;
    // 设置刷新间隔（毫秒），校验后持久化并即时生效
    void setRefreshInterval(int ms);
    // 返回当前活动接口的 TCP ESTABLISHED 连接数
    int tcpConnections() const;
    // 返回活动接口的 WiFi 信号强度（dBm），0 表示不可用
    int wifiSignal() const;
    // 返回活动接口的 WiFi 名称（SSID），非无线或未连接时为空串
    QString activeSsid() const;
    // 返回当前速度单位（0=智能自动，1=固定 KB/s，2=固定 Mbps）
    int speedUnit() const;
    // 当前是否固定 Mbps / 固定 KB/s（QML 语义化判据，避免魔法数字）
    bool speedUnitIsMbps() const;
    bool speedUnitIsKBps() const;
    // 设置速度单位，仅接受 0/1/2；非法值忽略，变化后持久化并发射 speedUnitChanged
    void setSpeedUnit(int unit);

    // ---- 流量提醒阈值 ----
    // 返回日/月流量提醒阈值（GB），0 表示不提醒
    double dailyLimitGb() const;
    double monthlyLimitGb() const;
    // 设置日/月流量阈值（GB）：负数、NaN、无穷大统一按 0（关闭）处理。
    // 设计原因：QML 侧是文本输入框，用户可能输入 "-1"、空串或异常字符，
    // 若不在此收敛，脏值会被持久化并在下次启动时参与换算，导致提醒永不触发
    void setDailyLimitGb(double gb);
    void setMonthlyLimitGb(double gb);
    // 返回当前周期已用流量（字节），供设置窗口回显，便于用户判断阈值填多少合适
    double todayUsedBytes() const;
    double monthUsedBytes() const;

    // ---- 多接口聚合 ----
    // 是否在任务栏显示所有物理网卡合计速率
    bool aggregateSpeed() const;
    void setAggregateSpeed(bool enabled);
    // 所有物理网卡的下行/上行速率之和（字节/秒）
    double totalDownloadSpeed() const;
    double totalUploadSpeed() const;

    // ---- 速度格式化（唯一定义处，QML 只消费不再各自实现换算）----
    // 返回带单位的完整速度字符串，如 "4.11 MB/s"、"33.70 Mbps"
    // 设计原因：单位换算若只写在 QML，将无法被单元测试覆盖；放到 C++ 后
    // 换算规则只有一份，且能被 tests/ 下的用例真实执行验证
    Q_INVOKABLE QString formatSpeed(double bytesPerSec, int unit) const;
    // 返回任务栏用的紧凑写法（无空格），如 "194.07K"、"0.85Mbps"
    // intPart 为 true 时只返回数值部分（不含单位），用于小数点对齐的两段式渲染
    Q_INVOKABLE QString formatSpeedCompact(double bytesPerSec, int unit, bool intPart) const;
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

    // ---- 独立窗口位置持久化（图表/流量统计/TCP 连接清单三个窗口共用）----
    // 设计原因：三个窗口此前每次打开都居中，用户拖到顺手的位置后下次打开又回到屏幕中央；
    // 位置与其它设置共用 settings.ini，不再引入新的配置文件。
    // 返回 {valid, x, y}：valid 为 false 表示"无记录/记录不可用"，QML 侧据此回退为居中显示
    Q_INVOKABLE QVariantMap windowGeometry(const QString &key) const;
    // 保存指定窗口的位置（由 QML 在窗口移动停止后调用；键名不在白名单内时静默忽略）
    Q_INVOKABLE void saveWindowGeometry(const QString &key, int x, int y);
    // 读取窗口的"置顶"状态（无记录时返回 false）
    Q_INVOKABLE bool windowPinned(const QString &key) const;
    // 保存窗口的"置顶"状态（键名不在白名单内时静默忽略）
    Q_INVOKABLE void setWindowPinned(const QString &key, bool pinned);

    // ---- 流量数据导出 ----
    // 把指定 section（"byDay"/"byMonth"）的数据序列化为 CSV 文本。
    // 设计原因：序列化逻辑放在 C++ 而非 QML，唯一目的是**可被单元测试覆盖**——
    // 转义、大数精度、排序这些正确性问题在 QML 里写就只能靠肉眼验证。
    // 数值用纯字节数而非 "1.23 GB"：导出用于二次分析，格式化会丢精度且无法求和
    Q_INVOKABLE QString exportTrafficAsCsv(const QString &section) const;
    // 把指定 section 的数据序列化为带缩进的 JSON 文本（附 section 与导出时间）
    Q_INVOKABLE QString exportTrafficAsJson(const QString &section) const;
    // 把 content 写到 path，返回 {ok, path, error}。
    // 负责创建目标目录；写失败时返回 ok=false 并带错误信息，不抛异常也不崩溃
    Q_INVOKABLE QVariantMap saveExportFile(const QString &path, const QString &content);
    // 返回降级导出路径（下载目录下、带周期与扩展名）。
    // 用途有二：作为文件对话框的默认文件名；供无文件门户服务的环境直接落盘
    Q_INVOKABLE QString defaultExportPath(const QString &section, const QString &extension) const;

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
    // 活动接口链路断开状态变化时通知 QML 更新
    void linkDownChanged();
    // 刷新间隔变化时通知 QML 更新
    void refreshIntervalChanged();
    // TCP ESTABLISHED 连接数变化时通知 QML 更新
    void tcpConnectionsChanged();
    // WiFi 信号强度变化时通知 QML 更新
    void wifiSignalChanged();
    // 活动接口的 WiFi 名称变化时通知 QML 更新
    void activeSsidChanged();
    // 速度显示单位变化时通知 QML 更新
    void speedUnitChanged();
    // 流量提醒阈值变化时通知 QML 回显
    void quotaLimitChanged();
    // 任务栏"合计速率"开关变化时通知 QML 更新
    void aggregateSpeedChanged();
    void speedHistoryChanged();
    // 任务栏网速字体颜色变化时通知 QML 更新
    void textColorChanged();
    // 流量统计日志变化时通知 QML 更新（降频，每 30 秒发射一次）
    void trafficLogChanged();
    // TCP 连接详情列表变化时通知 QML 更新（降频，每 5 秒发射一次）
    void tcpConnectionListChanged();

private:
    // ---- 设置持久化（~/.config/jnetapplet/settings.ini）----
    // 配置文件完整路径：字体颜色、活动接口、刷新间隔三处读写共用，避免重复拼接
    static QString configFilePath();
    // 写入单个配置项并立即落盘
    void persistSetting(const QString &key, const QVariant &value);
    // 判断窗口键是否属于允许持久化位置的窗口集合（见 .cpp 中的白名单说明）
    static bool isKnownWindowKey(const QString &key);

    void readNetworkStats();
    void calculateSpeed();
    void detectInterfaces();
    // 切换活动接口的唯一入口：重置速度基线、派生状态并发送相应信号。
    // persist 为 true 表示用户显式选择（写入配置），false 表示系统自动回退（不覆盖用户选择）
    void applyActiveInterface(const QString &interface, bool persist);
    // 自动选择默认活动接口（有流量的物理网卡 > 有流量的任意接口 > 第一个），
    // 仅做决策不产生副作用，由 readNetworkStats() 取结果后交给 applyActiveInterface()
    QString chooseDefaultInterface() const;
    // 检测活动接口的 IPv4 与 IPv6 地址，变化时分别发射对应信号
    void detectIpAddress();
    // 低频统计检测：链路速率与 WiFi 信号（每 5 秒），变化时发射对应信号
    void detectLowFreqStats();
    // 链路协商速率检测入口：有线同步读 sysfs（一次微小文件读取），
    // 无线降级执行 iw 时改为异步，由回调在值变化时发射 linkSpeedChanged
    void updateLinkSpeed();
    // 同步读取 /sys/class/net/<iface>/speed（Mbps）；不可用时返回 -1，表示需走 iw 降级路径
    int readSysfsLinkSpeed(const QString &iface) const;
    // 更新链路速率缓存，仅在值变化时发射 linkSpeedChanged
    void setLinkSpeed(int mbps);

    // ---- 链路层通断检测（carrier / operstate）----
    // 读取活动接口的 carrier 与 operstate 并更新 m_linkDown；
    // 仅由低频探测在活动接口非空时调用（链路通断变化远慢于速度），不新增定时器
    void updateLinkState();
    // 读取 /sys/class/net/<iface>/carrier，返回 -1 表示读不到（接口已消失、权限不足等，
    // 调用方按"未知"处理、不做断连判定），0 表示无载波，1 表示有载波
    int readSysfsCarrier(const QString &iface) const;
    // 读取 /sys/class/net/<iface>/operstate 原文并转小写（如 "up"/"down"/"unknown"），
    // 读不到返回空串（与 carrier 读不到同样按"未知"处理）
    QString readSysfsOperState(const QString &iface) const;
    // 由 carrier 与 operstate 判定链路是否断开（纯函数，便于单元测试覆盖真值表）；
    // carrier 取 -1/0/1，operstate 取 sysfs 原文小写，规则见实现处注释
    static bool isLinkDown(int carrier, const QString &operState);
    // 更新链路断开缓存，仅在值变化时发射 linkDownChanged，避免 QML 无效重绘
    void setLinkDown(bool down);
    // 解析 `iw dev <iface> link` 输出中的 bitrate（Mbps），失败返回 0
    int parseIwBitrate(const QString &output) const;
    // 解析 `iw dev <iface> link` 输出中的 SSID，未连接或输出无 SSID 行时返回空串。
    // 抽为静态纯函数的原因：与 bitrate 解析一样，输出样本固定、可直接单测，
    // 无需真的启动 iw 子进程
    static QString parseIwSsid(const QString &output);
    // 更新 WiFi 名称缓存，仅在值变化时发射 activeSsidChanged，避免 QML 无效重绘
    void setActiveSsid(const QString &ssid);
    // 统计 /proc/net/tcp 与 tcp6 中 ESTABLISHED（状态 01）的连接数
    int countTcpConnections() const;
    // 异步请求 TCP 连接详情列表（ss 子进程，含进程名反查），仅 ESTABLISHED
    // 子进程不再阻塞主线程，解析完成后更新 m_tcpConnectionList 并发射 tcpConnectionListChanged
    void requestTcpConnectionList();
    // 解析 ss -tnp 输出为连接列表（纯函数，便于单元测试）
    QVariantList parseTcpConnectionList(const QString &output) const;
    // 读取指定接口的 WiFi 信号强度（dBm），非无线接口或不可用时返回 0
    int detectWifiSignal(const QString &iface);
    // 判断是否为物理网卡（无线走 isWirelessInterface，有线匹配 enp/eth），
    // 用于自动选择时优先真实网卡而非虚拟代理接口（如 Meta/tun0）
    bool isPhysicalInterface(const QString &name) const;
    // 判断接口是否为无线网卡（链路上"是否无线"的唯一判定入口）：
    // 优先探测 /sys/class/net/<iface>/wireless 目录是否存在（不依赖命名约定），
    // 探测不到时回退前缀匹配 wlp/wlan/wlo/wlx。
    // 设计原因：原先多处硬编码 wlp/wlan 前缀，deepin 25 上的 wlo1 全部漏判
    // （协商速率恒 0、WiFi 信号恒 0、被当成有线、自动选择时被排除），
    // 收敛为单一入口后新增命名只需改这一处
    static bool isWirelessInterface(const QString &iface);
    qint64 getActiveRxBytes() const;
    qint64 getActiveTxBytes() const;

    // ---- 流量日志（日/月持久化）----
    // 启动时从 traffic_log.json 加载日志；文件不存在或解析失败时降级为空结构，不崩溃
    void loadTrafficLog();
    // 将日志写入 traffic_log.json（先裁剪超期记录再写盘），供析构与降频保存调用
    void saveTrafficLog();
    // 将指定接口的流量增量累加到当日/当月的日志记录中（每秒对每个物理接口调用，内存操作）
    // 设计原因：原实现只累加活动接口，切换网卡后另一块的流量不计入历史，
    // 而统计窗口是按接口分行展示的，于是永远缺一行
    void appendToTrafficLog(const QString &iface, qint64 rxDelta, qint64 txDelta);
    // 裁剪超期记录：按日最多 30 天、按月最多 12 个月，超出删除最旧记录
    void pruneTrafficLog();

    // ---- 流量超限提醒 ----
    // 判定本次是否应当提醒（静态纯函数，便于单测覆盖边界与周期重置）。
    // usedBytes：当前周期已用字节；limitGb：阈值（GB，<=0 表示关闭）；
    // currentPeriod：当前周期键（"yyyy-MM-dd" 或 "yyyy-MM"）；
    // notifiedPeriod：上一次已提醒的周期键（空串表示从未提醒）
    static bool shouldNotifyQuota(qint64 usedBytes, double limitGb,
                                  const QString &currentPeriod,
                                  const QString &notifiedPeriod);
    // 计算指定周期键下所有接口的 rx+tx 合计（纯函数，输入为流量日志 JSON）。
    // 抽出来的原因：与「流量统计」窗口的周期合计口径必须一致（该周期下所有接口相加），
    // 直接单测即可保证两处不会各算一套
    static qint64 periodUsedBytes(const QJsonObject &trafficLog,
                                  const QString &section, const QString &periodKey);
    // 检查日/月阈值并在超限且本周期未提醒时发送系统通知（挂在 30 秒保存周期上）
    void checkQuotaAndNotify();
    // 发送系统通知：summary 为标题，body 为正文
    void sendNotification(const QString &summary, const QString &body);

    QTimer *m_refreshTimer;
    QMap<QString, NetworkInterface> m_interfaces;
    QStringList m_interfaceList;
    QString m_activeInterface;
    QString m_ipAddress;           // 活动接口的 IPv4 地址
    QString m_ipv6Address;         // 活动接口的 IPv6 全球地址（过滤 link-local）
    
    // 速度计算
    qint64 m_lastRxBytes;
    qint64 m_lastTxBytes;
    // m_lastRxBytes/m_lastTxBytes 所对应的接口名。
    // 设计原因：基线必须与接口绑定——活动接口一旦变化而基线未重记，
    // 两接口累计字节数相减会得到数量级错误的增量（见 calculateSpeed 的兜底逻辑）
    QString m_baselineInterface;
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
    // 活动接口连接到的 WiFi 名称（SSID），非无线或未连接时为空串
    QString m_activeSsid;
    // 速度显示单位：0=智能自动，1=固定 KB/s，2=固定 Mbps（见 SpeedUnit 枚举注释）
    int m_speedUnit;
    // 活动接口链路层是否断开（carrier 为 0 或 operstate 非 up）
    // 与 m_linkSpeed/m_wifiSignal 同属低频探测结果，故放在一起
    bool m_linkDown;
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
    // 注意：缓冲"时长"与刷新间隔耦合——1/2/5 秒间隔分别对应约 30/60/150 分钟覆盖，
    // 30 分钟窗口在 1 秒间隔下刚好满足；QML 侧按时间戳裁剪可视范围，不依赖点位数
    static constexpr int MAX_HISTORY_SAMPLES = 1800;

    // 历史 QVariantList 缓存：避免 QML 每次读取都重新构造上千个 QPointF
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
    // 降频保存计数器：每 30 秒（按刷新间隔折算）写盘一次并通知 QML，
    // 避免每秒磁盘 IO 与 QML 重绘；析构函数再兜底保存一次
    int m_trafficSaveCounter;
    // 是否禁止写盘：加载时文件存在但不可读（权限/属主问题）会置位。
    // 设计原因：这种情形下内存里只有空结构，而 QSaveFile 靠临时文件 + rename，
    // 即便原文件不可读也能成功覆盖——若继续写盘，30 天历史会被静默清零。
    // 宁可本次会话不记录新流量，也不破坏既有数据
    bool m_trafficLogWriteBlocked = false;
    // 按日记录最多保留 30 天、按月最多保留 12 个月，超出自动裁剪最旧记录
    static constexpr int MAX_DAY_ENTRIES = 30;

    // ---- 流量超限提醒成员 ----
    // 日/月提醒阈值（GB），0 表示不提醒
    double m_dailyLimitGb = 0;
    double m_monthlyLimitGb = 0;
    // 已提醒过的周期键（"yyyy-MM-dd" / "yyyy-MM"），空串表示本周期尚未提醒。
    // 必须持久化：否则重启 dde-shell 后同一周期会再提醒一次
    QString m_notifiedDay;
    QString m_notifiedMonth;
    static constexpr int MAX_MONTH_ENTRIES = 12;

    // ---- 多接口聚合 ----
    // 是否在任务栏显示所有物理网卡合计速率（持久化到 settings.ini）
    bool m_aggregateSpeed = false;
    // 所有物理网卡的速率之和（字节/秒），每轮采样更新
    double m_totalDownloadSpeed = 0;
    double m_totalUploadSpeed = 0;

    // ---- TCP 连接清单成员 ----
    // TCP 连接详情列表（QVariantList of QVariantMap），供 QML 连接清单窗口读取
    // 设计原因：QVariantMap 便于 QML 以 JS 对象直接访问各字段，
    // 不暴露中间结构体（需注册元类型，QML 访问繁琐）
    QVariantList m_tcpConnectionList;
    // TCP 连接清单降频计数器：ss 命令需启动子进程开销大，每 5 次 refresh 更新一次
    // 初始化 4 使首次 refresh 立即更新
    int m_tcpListCounter = 4;

    // 子进程运行标记：异步化后用于避免上一次任务未返回时重复启动子进程
    // （iw 为无线链路速率降级路径，ss 为 TCP 连接清单采集路径）
    bool m_iwPending = false;
    bool m_ssPending = false;
};

DS_END_NAMESPACE