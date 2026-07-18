// SPDX-FileCopyrightText: 2024 MyCompany
//
// SPDX-License-Identifier: LGPL-3.0-or-later

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import org.deepin.ds 1.0
import org.deepin.ds.dock 1.0
import org.deepin.dtk 1.0

AppletItem {
    id: root
    objectName: "network monitor applet"
    property int dockOrder: 21
    property int dockSize: Panel.rootObject.dockItemMaxSize || 48

    implicitWidth: dockSize
    implicitHeight: dockSize

    readonly property var applet: Applet
    readonly property bool ready: applet ? applet.ready : false
    readonly property qint64 downloadSpeed: applet ? applet.downloadSpeed : 0
    readonly property qint64 uploadSpeed: applet ? applet.uploadSpeed : 0
    readonly property qint64 totalDownload: applet ? applet.totalDownload : 0
    readonly property qint64 totalUpload: applet ? applet.totalUpload : 0
    readonly property string activeInterface: applet ? (applet.activeInterface || "") : ""
    readonly property var networkInterfaces: applet ? (applet.networkInterfaces || []) : []
    readonly property var interfaceStats: applet ? (applet.interfaceStats || []) : []

    // 格式化速度显示
    function formatSpeed(bytesPerSec) {
        if (bytesPerSec < 1024) {
            return bytesPerSec.toFixed(0) + " B/s"
        } else if (bytesPerSec < 1024 * 1024) {
            return (bytesPerSec / 1024).toFixed(1) + " KB/s"
        } else if (bytesPerSec < 1024 * 1024 * 1024) {
            return (bytesPerSec / (1024 * 1024)).toFixed(2) + " MB/s"
        } else {
            return (bytesPerSec / (1024 * 1024 * 1024)).toFixed(2) + " GB/s"
        }
    }

    // 格式化总量显示
    function formatTotal(bytes) {
        if (bytes < 1024) {
            return bytes.toFixed(0) + " B"
        } else if (bytes < 1024 * 1024) {
            return (bytes / 1024).toFixed(1) + " KB"
        } else if (bytes < 1024 * 1024 * 1024) {
            return (bytes / (1024 * 1024)).toFixed(1) + " MB"
        } else {
            return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB"
        }
    }

    // 根据速度计算图标颜色
    readonly property color iconColor: {
        if (downloadSpeed > 10 * 1024 * 1024) return Qt.rgba(220/255, 38/255, 38/255, 1) // 高速红色
        if (downloadSpeed > 1 * 1024 * 1024) return Qt.rgba(245/255, 158/255, 11/255, 1)  // 中速橙色
        return root.primaryText // 正常颜色
    }

    property Palette basePalette: DockPalette.iconTextPalette
    readonly property color primaryText: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.95)
    readonly property color secondaryText: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.8)
    readonly property color tertiaryText: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.65)
    readonly property color cardBackground: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.06)
    readonly property color cardBorder: Qt.rgba(basePalette.r, basePalette.g, basePalette.b, 0.1)
    readonly property color accentBlue: Qt.rgba(20 / 255, 80 / 255, 160 / 255, 1)
    readonly property color accentBlueLight: Qt.rgba(20 / 255, 80 / 255, 160 / 255, 0.12)

    // 图标区域
    Rectangle {
        anchors.centerIn: parent
        width: dockSize * 0.7
        height: dockSize * 0.7
        color: "transparent"
        radius: width * 0.45
        border.width: 1
        border.color: root.iconColor

        Column {
            anchors.centerIn: parent
            spacing: 2

            // 下载速度
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "↓"
                font.pixelSize: root.dockSize * 0.18
                color: root.iconColor
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: formatSpeed(root.downloadSpeed)
                font.pixelSize: root.dockSize * 0.12
                font.bold: true
                color: root.iconColor
            }

            // 上传速度
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "↑"
                font.pixelSize: root.dockSize * 0.18
                color: root.iconColor
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: formatSpeed(root.uploadSpeed)
                font.pixelSize: root.dockSize * 0.12
                font.bold: true
                color: root.iconColor
            }
        }
    }

    // 悬停提示
    PanelToolTip {
        id: toolTip
        text: root.ready ? buildToolTipText() : qsTr("No network interface detected")
        toolTipX: DockPanelPositioner.x
        toolTipY: DockPanelPositioner.y
    }

    // 统计数据刷新定时器
    Timer {
        id: statsRefreshTimer
        interval: 1000
        repeat: true
        onTriggered: {
            if (root.applet) {
                root.applet.refresh()
            }
        }
    }

    Timer {
        id: toolTipShowTimer
        interval: 50
        onTriggered: {
            const point = root.mapToItem(null, root.width / 2, root.height / 2)
            toolTip.DockPanelPositioner.bounding = Qt.rect(point.x, point.y, toolTip.width, toolTip.height)
            toolTip.open()
        }
    }

    HoverHandler {
        onHoveredChanged: {
            if (hovered && !networkPopup.popupVisible) {
                toolTipShowTimer.start()
                if (root.applet) {
                    root.applet.refresh()
                }
                statsRefreshTimer.start()
            } else {
                if (toolTipShowTimer.running) {
                    toolTipShowTimer.stop()
                }
                toolTip.close()
                if (!networkPopup.popupVisible) {
                    statsRefreshTimer.stop()
                }
            }
        }
    }

    // 弹出窗口
    PanelPopup {
        id: networkPopup
        width: 400
        height: 350
        popupX: DockPanelPositioner.x
        popupY: DockPanelPositioner.y

        onPopupVisibleChanged: {
            if (popupVisible) {
                toolTip.close()
                statsRefreshTimer.start()
                if (root.applet) {
                    root.applet.refresh()
                }
            } else {
                statsRefreshTimer.stop()
            }
        }

        Control {
            id: popupContainer
            anchors.fill: parent
            padding: 16

            contentItem: ColumnLayout {
                spacing: 14

                // 标题区域
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        width: 28
                        height: 28
                        color: accentBlueLight
                        radius: 8

                        Text {
                            anchors.centerIn: parent
                            text: "NET"
                            font.pixelSize: 12
                            font.bold: true
                            color: accentBlue
                        }
                    }

                    Text {
                        text: qsTr("Network Monitor")
                        font.pixelSize: 16
                        font.bold: true
                        color: root.primaryText
                    }

                    Item { Layout.fillWidth: true }

                    // 刷新图标
                    Rectangle {
                        width: 28
                        height: 28
                        radius: 6
                        color: refreshIconArea.containsMouse ? root.accentBlueLight : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: "⟳"
                            font.pixelSize: 18
                            color: refreshIconArea.containsMouse ? root.accentBlue : root.secondaryText
                        }

                        MouseArea {
                            id: refreshIconArea
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.applet) {
                                    root.applet.refresh()
                                }
                            }
                        }

                        // 旋转动画
                        RotationAnimator on rotation {
                            id: refreshSpin
                            running: false
                            from: 0
                            to: 360
                            duration: 500
                        }

                        Connections {
                            target: refreshIconArea
                            function onClicked() { refreshSpin.start() }
                        }
                    }
                }

                // 分隔线
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: root.cardBorder
                }

                // 当前接口信息
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    visible: root.ready

                    Text {
                        text: qsTr("Interface:")
                        font.pixelSize: 12
                        color: root.secondaryText
                    }

                    Text {
                        text: root.activeInterface
                        font.pixelSize: 12
                        font.bold: true
                        color: root.primaryText
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                }

                // 速度统计卡片
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 120
                    color: root.cardBackground
                    radius: 10
                    border.width: 1
                    border.color: root.cardBorder

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 12

                        // 下载速度
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                text: "↓ " + qsTr("Download")
                                font.pixelSize: 13
                                color: root.secondaryText
                            }

                            Item { Layout.fillWidth: true }

                            Text {
                                text: formatSpeed(root.downloadSpeed)
                                font.pixelSize: 18
                                font.bold: true
                                color: root.accentBlue
                            }
                        }

                        // 上传速度
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                text: "↑ " + qsTr("Upload")
                                font.pixelSize: 13
                                color: root.secondaryText
                            }

                            Item { Layout.fillWidth: true }

                            Text {
                                text: formatSpeed(root.uploadSpeed)
                                font.pixelSize: 18
                                font.bold: true
                                color: Qt.rgba(22/255, 163/255, 74/255, 1)
                            }
                        }
                    }
                }

                // 总量统计卡片
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 80
                    color: root.cardBackground
                    radius: 10
                    border.width: 1
                    border.color: root.cardBorder

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 8

                        Text {
                            text: qsTr("Total Data")
                            font.pixelSize: 12
                            font.bold: true
                            color: root.secondaryText
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 20

                            // 下载总量
                            ColumnLayout {
                                spacing: 2
                                Text {
                                    text: "↓ " + qsTr("Download")
                                    font.pixelSize: 11
                                    color: root.tertiaryText
                                }
                                Text {
                                    text: formatTotal(root.totalDownload)
                                    font.pixelSize: 14
                                    font.bold: true
                                    color: root.primaryText
                                }
                            }

                            // 上传总量
                            ColumnLayout {
                                spacing: 2
                                Text {
                                    text: "↑ " + qsTr("Upload")
                                    font.pixelSize: 11
                                    color: root.tertiaryText
                                }
                                Text {
                                    text: formatTotal(root.totalUpload)
                                    font.pixelSize: 14
                                    font.bold: true
                                    color: root.primaryText
                                }
                            }
                        }
                    }
                }

                // 接口切换下拉框
                ComboBox {
                    id: interfaceCombo
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    visible: root.networkInterfaces.length > 1
                    model: root.networkInterfaces
                    currentIndex: {
                        var idx = root.networkInterfaces.indexOf(root.activeInterface)
                        return idx >= 0 ? idx : 0
                    }
                    onActivated: {
                        if (root.applet && root.networkInterfaces[index]) {
                            root.applet.setActiveInterface(root.networkInterfaces[index])
                        }
                    }

                    background: Rectangle {
                        color: interfaceCombo.hovered ? root.accentBlueLight : root.cardBackground
                        radius: 6
                        border.width: 1
                        border.color: root.cardBorder
                    }

                    contentItem: Text {
                        text: interfaceCombo.displayText
                        font.pixelSize: 12
                        color: root.primaryText
                        verticalAlignment: Text.AlignVCenter
                        leftPadding: 10
                    }
                }

                // 未检测到网络接口提示
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 60
                    color: root.cardBackground
                    radius: 10
                    border.width: 1
                    border.color: root.cardBorder
                    visible: !root.ready

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: "⚠"
                            font.pixelSize: 20
                        }

                        Text {
                            text: qsTr("No network interface detected")
                            font.pixelSize: 12
                            color: root.secondaryText
                        }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }

        Component.onCompleted: {
            DockPanelPositioner.bounding = Qt.binding(function () {
                const point = root.mapToItem(null, root.width / 2, root.height / 2)
                return Qt.rect(point.x, point.y, networkPopup.width, networkPopup.height)
            })
        }
    }

    // 构建 tooltip 文本
    function buildToolTipText() {
        if (!root.ready) {
            return qsTr("No network interface detected")
        }

        var lines = []
        lines.push("↓ " + formatSpeed(root.downloadSpeed))
        lines.push("↑ " + formatSpeed(root.uploadSpeed))
        lines.push(root.activeInterface)
        return lines.join("  |  ")
    }

    // 点击处理
    TapHandler {
        acceptedButtons: Qt.LeftButton
        gesturePolicy: TapHandler.ReleaseWithinBounds

        onTapped: {
            if (networkPopup.popupVisible) {
                networkPopup.close()
            } else {
                Panel.requestClosePopup()
                const point = root.mapToItem(null, root.width / 2, root.height / 2)
                networkPopup.DockPanelPositioner.bounding = Qt.rect(point.x, point.y, networkPopup.width, networkPopup.height)
                networkPopup.open()
            }
            toolTip.close()
        }
    }
}