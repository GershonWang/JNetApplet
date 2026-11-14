// SPDX-FileCopyrightText: 2026 Jokul
//
// SPDX-License-Identifier: LGPL-3.0-or-later

// 流量日志的数据操作（纯 QJsonObject 进出，无 IO、无状态、无 deepin 依赖）。
//
// 为什么需要这个文件：日志结构是嵌套 JSON（byDay[日期][接口]{rx,tx}），
// 累加、裁剪、展平、周期合计四处都在这份结构上做读写，任何一处键名或精度
// 处理出错都会让统计窗口数字不对——而这类问题过去只能靠真机观察。
// 抽离后可用构造的 JSON 样本直接断言（见 tests/core/）。
//
// 精度约定：字节数一律走 qint64。累计值可能超过 2^53，用 double 会丢精度，
// 因此读写都经 QVariant::toLongLong()，不得改成 toDouble()。
#pragma once

#include <QJsonObject>
#include <QString>
#include <QVariantList>

namespace JNetCore {

// 把一次流量增量累加到指定接口的当日/当月记录。
//   log      完整日志（会被就地修改）
//   iface    接口名（调用方指定，**不再依赖"当前活动接口"**：
//            原实现只累加活动接口，切换网卡后另一块的流量凭空消失）
//   date     日期键 "yyyy-MM-dd"
//   month    月份键 "yyyy-MM"
// 零增量或空接口名直接返回（不产生空记录）。
void appendTraffic(QJsonObject &log, const QString &iface,
                   const QString &date, const QString &month,
                   qint64 rxDelta, qint64 txDelta);

// 裁剪超期记录：按日最多 maxDays 条、按月最多 maxMonths 条。
// 键均为 ISO 格式（"yyyy-MM-dd"/"yyyy-MM"），字典序即时间序，
// 排序后删除最小的超量个，保证始终保留最近的记录。
void pruneTraffic(QJsonObject &log, int maxDays, int maxMonths);

// 展平为「每行一个（周期, 接口）」的有序列表，供 CSV/JSON 导出与表格展示。
// 每项为 QVariantMap（date/iface/rx/tx/total）。
// 排序口径：日期降序（最新在前），同日期内接口名升序——导出与界面必须一致，
// 否则用户会怀疑导出的不是同一份数据。
QVariantList flattenTraffic(const QJsonObject &log, const QString &section);

// 指定周期键下所有接口的 rx+tx 合计（字节）。
// section 取 "byDay" 或 "byMonth"；键不存在时返回 0（新的一天尚未产生记录）。
qint64 periodUsedBytes(const QJsonObject &log, const QString &section,
                       const QString &periodKey);

}   // namespace JNetCore
