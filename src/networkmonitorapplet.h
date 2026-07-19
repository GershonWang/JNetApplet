// SPDX-FileCopyrightText: 2024 MyCompany
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
    Q_PROPERTY(QStringList interfaceStats READ interfaceStats NOTIFY statsChanged)
    Q_PROPERTY(bool ready READ ready NOTIFY readyChanged)
    Q_PROPERTY(QString activeInterface READ activeInterface NOTIFY activeInterfaceChanged)
    // 活动接口的 IPv4 地址，供 QML 在弹出面板和 tooltip 中显示
    Q_PROPERTY(QString ipAddress READ ipAddress NOTIFY ipAddressChanged)
    // 活动接口的 IPv6 全球地址（已过滤 link-local 和 loopback），供 QML 显示
    Q_PROPERTY(QString ipv6Address READ ipv6Address NOTIFY ipv6AddressChanged)
    // 插件版本号，从 dde-shell 元数据读取，版本唯一源为 CMakeLists.txt project(VERSION)
    Q_PROPERTY(QString version READ version CONSTANT)
    // 当前活动接口的下行速度历史采样点（QPointF 列表：x=时间戳秒, y=速度 bytes/sec）
    // 用于趋势图绘制下载折线，每次 calculateSpeed 追加一个点并发射 speedHistoryChanged
    Q_PROPERTY(QVariantList speedHistoryDownload READ speedHistoryDownload NOTIFY speedHistoryChanged)
    // 当前活动接口的上行速度历史采样点，结构同 speedHistoryDownload
    Q_PROPERTY(QVariantList speedHistoryUpload READ speedHistoryUpload NOTIFY speedHistoryChanged)

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
    QStringList interfaceStats() const;
    bool ready() const;
    QString activeInterface() const;
    QString ipAddress() const;
    QString ipv6Address() const;
    // 返回当前活动接口的下行速度历史（QPointF 列表），供 QML 趋势图绘制
    QVariantList speedHistoryDownload() const;
    // 返回当前活动接口的上行速度历史（QPointF 列表），供 QML 趋势图绘制
    QVariantList speedHistoryUpload() const;
    // 返回插件版本号，从 dde-shell 插件元数据（metadata.json）读取
    QString version() const;

    Q_INVOKABLE void refresh();
    Q_INVOKABLE void setActiveInterface(const QString &interface);

signals:
    void speedChanged();
    void totalChanged();
    void interfacesChanged();
    void statsChanged();
    void readyChanged();
    void activeInterfaceChanged();
    void ipAddressChanged();
    void ipv6AddressChanged();
    void speedHistoryChanged();

private:
    void readNetworkStats();
    void calculateSpeed();
    void detectInterfaces();
    // 检测活动接口的 IPv4 与 IPv6 地址，变化时分别发射对应信号
    void detectIpAddress();
    // 判断是否为物理网卡（无线 wlp/wlan，有线 enp/eth），
    // 用于自动选择时优先真实网卡而非虚拟代理接口（如 Meta/tun0）
    bool isPhysicalInterface(const QString &name) const;
    qint64 getActiveRxBytes() const;
    qint64 getActiveTxBytes() const;

    QTimer *m_refreshTimer;
    QMap<QString, NetworkInterface> m_interfaces;
    QStringList m_interfaceList;
    QString m_activeInterface;
    QString m_ipAddress;           // 活动接口的 IPv4 地址
    QString m_ipv6Address;         // 活动接口的 IPv6 全球地址（过滤 link-local）
    
    // 速度计算
    qint64 m_lastRxBytes;
    qint64 m_lastTxBytes;
    qint64 m_downloadSpeed;
    qint64 m_uploadSpeed;
    
    // 总量
    qint64 m_totalDownload;
    qint64 m_totalUpload;
    
    bool m_ready;
    bool m_firstUpdate;

    // 速度历史环形缓冲：每个接口独立维护一份，key 为接口名
    // 设计原因：接口切换时趋势图不出现跳变，切回时仍能看到该接口历史
    QHash<QString, QVector<SpeedSample>> m_speedHistory;
    // 每个接口最多保留的采样点数：5 分钟 × 60 秒 = 300
    static constexpr int MAX_HISTORY_SAMPLES = 300;
};

DS_END_NAMESPACE