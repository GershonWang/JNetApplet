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
};

DS_END_NAMESPACE