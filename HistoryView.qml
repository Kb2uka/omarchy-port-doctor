import QtQuick
import QtQuick.Controls
import "Palette.js" as P

// Scan history for this session (in memory; resets when the shell restarts).
Item {
  id: root
  property string fontMono: "monospace"
  property var history: []

  Column {
    anchors.fill: parent
    anchors.margins: 18
    spacing: 10

    Row {
      spacing: 10
      Text {
        textFormat: Text.PlainText
        text: "History"
        color: P.text
        font.family: P.sans
        font.pixelSize: 15
        font.weight: Font.DemiBold
      }
      Text {
        textFormat: Text.PlainText
        text: "kept in memory for this session"
        color: P.muted
        font.family: P.sans
        font.pixelSize: 11
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Rectangle {
      width: parent.width
      height: 34
      color: P.alpha(P.border, 0.18)
      radius: 4
      Row {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        Repeater {
          model: [["TIME", 0.30], ["PROFILE", 0.18], ["HOSTS", 0.16],
                  ["OPEN PORTS", 0.18], ["DURATION", 0.18]]
          Text {
            required property var modelData
            textFormat: Text.PlainText
            width: parent.width * modelData[1]
            anchors.verticalCenter: parent.verticalCenter
            text: modelData[0]
            color: P.muted
            font.family: P.sans
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 0.8
          }
        }
      }
    }

    Flickable {
      width: parent.width
      height: parent.height - 54 - parent.spacing * 2
      contentWidth: width
      contentHeight: historyColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: historyColumn
        width: parent.width

        Repeater {
          model: root.history

          Rectangle {
            required property var modelData
            width: historyColumn.width
            height: 34
            color: histHover.containsMouse ? P.hover : "transparent"
            Behavior on color { ColorAnimation { duration: 80 } }

            Row {
              anchors.fill: parent
              anchors.leftMargin: 10
              anchors.rightMargin: 10
              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.30
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.at).replace("T", " ").slice(0, 19)
                color: P.text
                font.family: root.fontMono
                font.pixelSize: 11
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.18
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.profile === "quick" ? "Quick" : "Standard"
                color: P.secondary
                font.family: P.sans
                font.pixelSize: 11
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.16
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.hostsUp)
                color: P.text
                font.family: root.fontMono
                font.pixelSize: 11
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.18
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.openPorts)
                color: P.accent
                font.family: root.fontMono
                font.pixelSize: 11
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width * 0.18
                anchors.verticalCenter: parent.verticalCenter
                text: (modelData.scanMs / 1000).toFixed(1) + " s"
                color: P.secondary
                font.family: root.fontMono
                font.pixelSize: 11
              }
            }

            MouseArea {
              id: histHover
              anchors.fill: parent
              hoverEnabled: true
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.history.length === 0
          width: parent.width
          topPadding: 24
          horizontalAlignment: Text.AlignHCenter
          text: "No scans recorded yet this session."
          color: P.muted
          font.family: P.sans
          font.pixelSize: 12
        }
      }
    }
  }
}
