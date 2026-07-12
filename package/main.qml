// SPDX-FileCopyrightText: 2024 MyCompany
// SPDX-License-Identifier: LGPL-3.0-or-later

import QtQuick 2.11
import QtQuick.Controls 2.4
import org.deepin.ds 1.0

AppletItem {
    objectName: "JnetApplet"
    implicitWidth: 100
    implicitHeight: 100
    
    Rectangle {
        anchors.fill: parent
        color: "#2ecc71"
        radius: 8
        
        Text {
            anchors.centerIn: parent
            text: "你好，世界！"
            font.pixelSize: 14
            color: "white"
        }
    }
}