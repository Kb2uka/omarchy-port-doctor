import QtQuick
import "Palette.js" as P

// Compact port number pill; ports that serve something known get the warm
// accent text, unknowns stay quiet.
Rectangle {
    id: root
    required property int port
    property string service: ""
    property string klass: ""
    property string fontFamily: P.sans

    readonly property bool known: service !== ""

    implicitWidth: label.implicitWidth + 14
    implicitHeight: label.implicitHeight + 4
    radius: 4
    color: known ? P.accentSoft : P.alpha(P.border, 0.45)

    Text {
        id: label
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: String(root.port)
        color: root.known ? P.accent : P.secondary
        font.family: root.fontFamily
        font.pixelSize: 10
        font.bold: root.known
    }
}
