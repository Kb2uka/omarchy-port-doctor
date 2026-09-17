import QtQuick

// Tiny online/offline indicator used in the table, map nodes, and headers.
Rectangle {
    id: root
    property bool online: true
    width: 7
    height: 7
    radius: width / 2
    color: online ? "#46a36e" : "#5f6b77"
}
